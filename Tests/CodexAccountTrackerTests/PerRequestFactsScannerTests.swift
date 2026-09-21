import Foundation
import XCTest
@testable import CodexAccountTracker

/// The per-request facts the scanners now read out of the logs: the speed setting in force,
/// the parent thread a sub-agent inherits it from, the Codex cache-write count, and the
/// Claude Code 1-hour / 5-minute cache-write split.
///
/// All fixtures are synthetic files in a temporary directory, written to match the live log
/// shapes probed on 2026-09-21.
final class PerRequestFactsScannerTests: XCTestCase {
    // MARK: - Codex speed setting

    func testTierChangeMidFileAppliesToLaterEventsOnly() throws {
        let fixture = try makeFixture()
        try write(
            lines: [
                sessionMetaLine(sessionID: "tiers", timestamp: "2026-08-17T00:00:00Z", projectPath: fixture.projectPath),
                turnContextLine(model: "gpt-6-astra", timestamp: "2026-08-17T00:00:01Z"),
                threadSettingsLine(threadID: "tiers", tier: "default", timestamp: "2026-08-17T00:00:02Z"),
                tokenCountLine(timestamp: "2026-08-17T00:00:03Z", input: 10, output: 1, cumulativeInput: 10, cumulativeOutput: 1),
                threadSettingsLine(threadID: "tiers", tier: "priority", timestamp: "2026-08-17T00:00:04Z"),
                tokenCountLine(timestamp: "2026-08-17T00:00:05Z", input: 20, output: 2, cumulativeInput: 30, cumulativeOutput: 3)
            ],
            to: fixture.root.appendingPathComponent("tiers.jsonl")
        )

        let records = makeScanner(fixture).scan(since: nil).records.sorted { $0.timestamp < $1.timestamp }
        XCTAssertEqual(records.map(\.usage.speed), [.standard, .fast])
    }

    func testEventsBeforeTheFirstTierLineAreUnknown() throws {
        let fixture = try makeFixture()
        try write(
            lines: [
                sessionMetaLine(sessionID: "late-tier", timestamp: "2026-08-17T00:00:00Z", projectPath: fixture.projectPath),
                turnContextLine(model: "gpt-6-astra", timestamp: "2026-08-17T00:00:01Z"),
                tokenCountLine(timestamp: "2026-08-17T00:00:02Z", input: 10, output: 1, cumulativeInput: 10, cumulativeOutput: 1),
                threadSettingsLine(threadID: "late-tier", tier: "priority", timestamp: "2026-08-17T00:00:03Z"),
                tokenCountLine(timestamp: "2026-08-17T00:00:04Z", input: 20, output: 2, cumulativeInput: 30, cumulativeOutput: 3)
            ],
            to: fixture.root.appendingPathComponent("late-tier.jsonl")
        )

        let records = makeScanner(fixture).scan(since: nil).records.sorted { $0.timestamp < $1.timestamp }
        // No parent to inherit from, and no setting recorded yet when the first event ran.
        XCTAssertEqual(records.map(\.usage.speed), [.unknown, .fast])
    }

    func testSubagentInheritsTheParentsTierInForceWhenItWasSpawned() throws {
        let fixture = try makeFixture()
        // Parent switches to Fast at 00:00:02 and back to Standard at 00:00:20.
        try write(
            lines: [
                sessionMetaLine(sessionID: "parent", timestamp: "2026-08-17T00:00:00Z", projectPath: fixture.projectPath),
                turnContextLine(model: "gpt-6-astra", timestamp: "2026-08-17T00:00:01Z"),
                threadSettingsLine(threadID: "parent", tier: "priority", timestamp: "2026-08-17T00:00:02Z"),
                tokenCountLine(timestamp: "2026-08-17T00:00:03Z", input: 7, output: 1, cumulativeInput: 7, cumulativeOutput: 1),
                threadSettingsLine(threadID: "parent", tier: "default", timestamp: "2026-08-17T00:00:20Z")
            ],
            to: fixture.root.appendingPathComponent("parent.jsonl")
        )
        // Sub-agent spawned at 00:00:10, i.e. while the parent was still in Fast mode.
        try write(
            lines: [
                sessionMetaLine(
                    sessionID: "child",
                    timestamp: "2026-08-17T00:00:10Z",
                    projectPath: fixture.projectPath,
                    parentThreadID: "parent"
                ),
                turnContextLine(model: "gpt-6-astra", timestamp: "2026-08-17T00:00:11Z"),
                tokenCountLine(timestamp: "2026-08-17T00:00:12Z", input: 11, output: 1, cumulativeInput: 11, cumulativeOutput: 1)
            ],
            to: fixture.root.appendingPathComponent("child.jsonl")
        )

        let records = makeScanner(fixture).scan(since: nil)
            .records
            .sorted { $0.timestamp < $1.timestamp }
        XCTAssertEqual(records.map(\.sessionID), ["parent", "child"])
        XCTAssertEqual(records.map(\.usage.speed), [.fast, .fast])
    }

    func testSubagentInheritsThroughAParentThatInheritedItself() throws {
        let fixture = try makeFixture()
        try write(
            lines: [
                sessionMetaLine(sessionID: "grandparent", timestamp: "2026-08-17T00:00:00Z", projectPath: fixture.projectPath),
                turnContextLine(model: "gpt-6-astra", timestamp: "2026-08-17T00:00:01Z"),
                threadSettingsLine(threadID: "grandparent", tier: "priority", timestamp: "2026-08-17T00:00:02Z"),
                tokenCountLine(timestamp: "2026-08-17T00:00:03Z", input: 5, output: 1, cumulativeInput: 5, cumulativeOutput: 1)
            ],
            to: fixture.root.appendingPathComponent("grandparent.jsonl")
        )
        // Middle session records no setting of its own.
        try write(
            lines: [
                sessionMetaLine(
                    sessionID: "middle",
                    timestamp: "2026-08-17T00:00:05Z",
                    projectPath: fixture.projectPath,
                    parentThreadID: "grandparent"
                ),
                turnContextLine(model: "gpt-6-astra", timestamp: "2026-08-17T00:00:06Z")
            ],
            to: fixture.root.appendingPathComponent("middle.jsonl")
        )
        try write(
            lines: [
                sessionMetaLine(
                    sessionID: "leaf",
                    timestamp: "2026-08-17T00:00:07Z",
                    projectPath: fixture.projectPath,
                    parentThreadID: "middle"
                ),
                turnContextLine(model: "gpt-6-astra", timestamp: "2026-08-17T00:00:08Z"),
                tokenCountLine(timestamp: "2026-08-17T00:00:09Z", input: 9, output: 1, cumulativeInput: 9, cumulativeOutput: 1)
            ],
            to: fixture.root.appendingPathComponent("leaf.jsonl")
        )

        let leaf = try XCTUnwrap(makeScanner(fixture).scan(since: nil).records.first { $0.sessionID == "leaf" })
        XCTAssertEqual(leaf.usage.speed, .fast)
    }

    func testMissingParentAndMissingTierLeaveTheSpeedUnknown() throws {
        let fixture = try makeFixture()
        try write(
            lines: [
                sessionMetaLine(sessionID: "orphan", timestamp: "2026-08-17T00:00:00Z", projectPath: fixture.projectPath),
                turnContextLine(model: "gpt-6-astra", timestamp: "2026-08-17T00:00:01Z"),
                tokenCountLine(timestamp: "2026-08-17T00:00:02Z", input: 3, output: 1, cumulativeInput: 3, cumulativeOutput: 1)
            ],
            to: fixture.root.appendingPathComponent("orphan.jsonl")
        )

        let records = makeScanner(fixture).scan(since: nil).records
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records[0].usage.speed, .unknown)
    }

    // MARK: - Codex cache writes

    func testCacheWriteInputTokensAreCarvedOutOfTheUncachedInput() throws {
        let fixture = try makeFixture()
        let usageBody = "{\"input_tokens\":1000,\"cached_input_tokens\":600,\"cache_write_input_tokens\":250,\"output_tokens\":10,\"reasoning_output_tokens\":0,\"total_tokens\":1010}"
        try write(
            lines: [
                sessionMetaLine(sessionID: "writes", timestamp: "2026-08-17T00:00:00Z", projectPath: fixture.projectPath),
                turnContextLine(model: "gpt-6-astra", timestamp: "2026-08-17T00:00:01Z"),
                "{\"timestamp\":\"2026-08-17T00:00:02Z\",\"type\":\"event_msg\",\"payload\":{\"type\":\"token_count\",\"info\":{\"last_token_usage\":\(usageBody),\"total_token_usage\":\(usageBody)}}}"
            ],
            to: fixture.root.appendingPathComponent("writes.jsonl")
        )

        let records = makeScanner(fixture).scan(since: nil).records
        XCTAssertEqual(records.count, 1)
        let usage = records[0].usage
        XCTAssertEqual(usage.inputTokens, 1000)
        XCTAssertEqual(usage.cachedInputTokens, 600)
        XCTAssertEqual(usage.cacheCreationInputTokens, 250)
        // The cache write is a subset of input_tokens, so it comes out of the uncached part.
        XCTAssertEqual(usage.uncachedInputTokens, 150)
        // Astra short rates: 150 * $10/M + 250 * $12.50/M + 600 * $1/M + 10 * $50/M.
        let cost = AzureModelPricing.defaultPricing(for: "gpt-6-astra", provider: .openai).estimatedCost(for: usage)
        // = 0.0015 + 0.003125 + 0.0006 + 0.0005 = $0.005725. Priced as plain input it would
        // have been $0.005100, i.e. the cache write costs more, as it should.
        XCTAssertEqual(cost, 0.005725, accuracy: 0.000000001)
    }

    func testCacheWriteIsClampedToTheUncachedRemainder() throws {
        let fixture = try makeFixture()
        // A cache-write count larger than what is left after the cache reads must not make
        // uncached input go negative or double-bill the same tokens.
        let usageBody = "{\"input_tokens\":100,\"cached_input_tokens\":90,\"cache_write_input_tokens\":50,\"output_tokens\":1,\"reasoning_output_tokens\":0,\"total_tokens\":101}"
        try write(
            lines: [
                sessionMetaLine(sessionID: "clamped", timestamp: "2026-08-17T00:00:00Z", projectPath: fixture.projectPath),
                turnContextLine(model: "gpt-6-astra", timestamp: "2026-08-17T00:00:01Z"),
                "{\"timestamp\":\"2026-08-17T00:00:02Z\",\"type\":\"event_msg\",\"payload\":{\"type\":\"token_count\",\"info\":{\"last_token_usage\":\(usageBody),\"total_token_usage\":\(usageBody)}}}"
            ],
            to: fixture.root.appendingPathComponent("clamped.jsonl")
        )

        let usage = try XCTUnwrap(makeScanner(fixture).scan(since: nil).records.first).usage
        XCTAssertEqual(usage.cacheCreationInputTokens, 10)
        XCTAssertEqual(usage.uncachedInputTokens, 0)
    }

    // MARK: - Claude Code cache-write split

    func testClaudeCodeOneHourCacheWriteSplitIsParsed() throws {
        let fixture = try makeFixture()
        try write(
            lines: [claudeAssistantLine(
                messageID: "msg_split",
                requestID: "req_split",
                timestamp: "2026-08-17T00:00:00.000Z",
                model: "claude-fable-5-1",
                input: 12,
                cacheCreation: 1000,
                oneHourCacheCreation: 800,
                cacheRead: 500,
                output: 40
            )],
            to: fixture.root.appendingPathComponent("claude.jsonl")
        )

        let records = makeClaudeScanner(fixture).scan(since: nil).records
        XCTAssertEqual(records.count, 1)
        let usage = records[0].usage
        XCTAssertEqual(usage.cacheCreationInputTokens, 1000)
        XCTAssertEqual(usage.cacheCreation1hInputTokens, 800)
        XCTAssertEqual(usage.cachedInputTokens, 500)
        XCTAssertEqual(usage.speed, .standard)
    }

    func testClaudeCodeTranscriptWithNoSplitLeavesTheOneHourCountAtZero() throws {
        let fixture = try makeFixture()
        try write(
            lines: [claudeAssistantLine(
                messageID: "msg_nosplit",
                requestID: "req_nosplit",
                timestamp: "2026-08-17T00:00:00.000Z",
                model: "claude-fable-5-1",
                input: 12,
                cacheCreation: 1000,
                oneHourCacheCreation: nil,
                cacheRead: 500,
                output: 40
            )],
            to: fixture.root.appendingPathComponent("claude-old.jsonl")
        )

        let usage = try XCTUnwrap(makeClaudeScanner(fixture).scan(since: nil).records.first).usage
        XCTAssertEqual(usage.cacheCreationInputTokens, 1000)
        XCTAssertEqual(usage.cacheCreation1hInputTokens, 0)
    }

    // MARK: - Helpers

    private func makeScanner(_ fixture: Fixture) -> AzureUsageScanner {
        AzureUsageScanner(
            provider: .openai,
            logRoots: [fixture.root],
            metadataURLs: [],
            codexLocalUsageIndexStore: CodexLocalUsageIndexStore(directoryURL: fixture.indexDirectory)
        )
    }

    private func makeClaudeScanner(_ fixture: Fixture) -> AzureUsageScanner {
        AzureUsageScanner(
            provider: .claudeCode,
            logRoots: [fixture.root],
            metadataURLs: [],
            claudeCodeUsageIndexStore: ClaudeCodeUsageIndexStore(directoryURL: fixture.indexDirectory)
        )
    }

    private func makeFixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("per-request-facts-\(UUID().uuidString)", isDirectory: true)
        let indexDirectory = root.appendingPathComponent("index", isDirectory: true)
        let projectDirectory = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: indexDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: projectDirectory, withIntermediateDirectories: true)
        return Fixture(root: root, indexDirectory: indexDirectory, projectPath: projectDirectory.path)
    }

    private func write(lines: [String], to url: URL) throws {
        try Data(lines.joined(separator: "\n").appending("\n").utf8).write(to: url, options: [.atomic])
    }

    private func sessionMetaLine(
        sessionID: String,
        timestamp: String,
        projectPath: String,
        parentThreadID: String? = nil
    ) -> String {
        let parentField = parentThreadID.map { ",\"parent_thread_id\":\"\($0)\"" } ?? ""
        return "{\"timestamp\":\"\(timestamp)\",\"type\":\"session_meta\",\"payload\":{\"session_id\":\"\(sessionID)\",\"id\":\"\(sessionID)\",\"cwd\":\"\(projectPath)\",\"model_provider\":\"openai\",\"originator\":\"Codex Desktop\"\(parentField)}}"
    }

    private func turnContextLine(model: String, timestamp: String) -> String {
        "{\"timestamp\":\"\(timestamp)\",\"type\":\"turn_context\",\"payload\":{\"model\":\"\(model)\"}}"
    }

    /// Live shape (probed 2026-09-21): the tier sits in `payload.thread_settings.service_tier`
    /// on a line that also carries the session's model and instruction settings.
    private func threadSettingsLine(threadID: String, tier: String, timestamp: String) -> String {
        "{\"timestamp\":\"\(timestamp)\",\"ordinal\":1,\"type\":\"event_msg\",\"payload\":{\"type\":\"thread_settings_applied\",\"thread_id\":\"\(threadID)\",\"thread_settings\":{\"approval_policy\":\"on-request\",\"model\":\"gpt-6-astra\",\"reasoning_effort\":\"high\",\"service_tier\":\"\(tier)\"}}}"
    }

    private func tokenCountLine(
        timestamp: String,
        input: Int,
        output: Int,
        cumulativeInput: Int,
        cumulativeOutput: Int
    ) -> String {
        let last = "{\"input_tokens\":\(input),\"cached_input_tokens\":0,\"output_tokens\":\(output),\"reasoning_output_tokens\":0,\"total_tokens\":\(input + output)}"
        let total = "{\"input_tokens\":\(cumulativeInput),\"cached_input_tokens\":0,\"output_tokens\":\(cumulativeOutput),\"reasoning_output_tokens\":0,\"total_tokens\":\(cumulativeInput + cumulativeOutput)}"
        return "{\"timestamp\":\"\(timestamp)\",\"type\":\"event_msg\",\"payload\":{\"type\":\"token_count\",\"info\":{\"last_token_usage\":\(last),\"total_token_usage\":\(total)}}}"
    }

    /// Live shape (probed 2026-09-21): `usage.cache_creation` holds the 1-hour / 5-minute
    /// breakdown of `cache_creation_input_tokens`.
    private func claudeAssistantLine(
        messageID: String,
        requestID: String,
        timestamp: String,
        model: String,
        input: Int,
        cacheCreation: Int,
        oneHourCacheCreation: Int?,
        cacheRead: Int,
        output: Int
    ) -> String {
        let splitField = oneHourCacheCreation.map {
            ",\"cache_creation\":{\"ephemeral_1h_input_tokens\":\($0),\"ephemeral_5m_input_tokens\":\(cacheCreation - $0)}"
        } ?? ""
        return "{\"type\":\"assistant\",\"timestamp\":\"\(timestamp)\",\"requestId\":\"\(requestID)\",\"sessionId\":\"session-1\",\"cwd\":\"/tmp/project\",\"message\":{\"id\":\"\(messageID)\",\"model\":\"\(model)\",\"stop_reason\":\"end_turn\",\"content\":[{\"type\":\"text\",\"text\":\"ok\"}],\"usage\":{\"input_tokens\":\(input),\"cache_creation_input_tokens\":\(cacheCreation),\"cache_read_input_tokens\":\(cacheRead),\"output_tokens\":\(output)\(splitField)}}}"
    }

    private struct Fixture {
        let root: URL
        let indexDirectory: URL
        let projectPath: String
    }
}
