import Foundation
import XCTest
@testable import CodexAccountTracker

final class CodexLocalUsageScannerTests: XCTestCase {
    func testOpenAIIncludesDesktopTUIAndCLIButRejectsUnknownOrMissingOriginators() throws {
        let fixture = try makeFixture()
        let allowed = ["Codex Desktop", "codex-tui", "codex_cli_rs"]

        for (index, originator) in allowed.enumerated() {
            try writeSession(
                at: fixture.root.appendingPathComponent("allowed-\(index).jsonl"),
                sessionID: "allowed-\(index)",
                provider: "openai",
                originator: originator,
                model: "gpt-5.6-luna",
                tokenEvents: [TokenEvent(input: index + 1, output: 2, total: index + 3)]
            )
        }
        try writeSession(
            at: fixture.root.appendingPathComponent("unknown.jsonl"),
            sessionID: "unknown-originator",
            provider: "openai",
            originator: "codex-other",
            model: "gpt-5.6-luna",
            tokenEvents: [TokenEvent(input: 10, output: 2, total: 12)]
        )
        try writeSession(
            at: fixture.root.appendingPathComponent("missing.jsonl"),
            sessionID: "missing-originator",
            provider: "openai",
            originator: nil,
            model: "gpt-5.6-luna",
            tokenEvents: [TokenEvent(input: 20, output: 2, total: 22)]
        )
        try writeSession(
            at: fixture.root.appendingPathComponent("near-miss.jsonl"),
            sessionID: "near-miss-originator",
            provider: "openai",
            originator: "Codex Desktop ",
            model: "gpt-5.6-luna",
            tokenEvents: [TokenEvent(input: 30, output: 2, total: 32)]
        )

        let scanner = makeScanner(fixture)
        let result = scanner.scan(since: nil)

        XCTAssertEqual(AzureUsageScanner.supportedOpenAICodexOriginators, Set(allowed))
        XCTAssertEqual(result.summary.sessionsScanned, 6)
        XCTAssertEqual(result.summary.providerSessions, 3)
        XCTAssertEqual(result.records.count, 3)
        XCTAssertEqual(Set(result.records.map(\.sessionID)), Set(["allowed-0", "allowed-1", "allowed-2"]))
        XCTAssertEqual(Set(result.records.map(\.projectPath)), Set([fixture.projectPath]))
        XCTAssertEqual(Set(result.records.map(\.model)), Set(["gpt-5.6-luna"]))
    }

    func testAzureOriginatorEligibilityRemainsUnchanged() throws {
        let fixture = try makeFixture()
        try writeSession(
            at: fixture.root.appendingPathComponent("azure.jsonl"),
            sessionID: "azure-session",
            provider: "azure",
            originator: "unknown-client",
            model: "gpt-5.5",
            tokenEvents: [TokenEvent(input: 3, output: 4, total: 7)]
        )

        let scanner = AzureUsageScanner(
            provider: .azure,
            logRoots: [fixture.root],
            metadataURLs: [],
            codexLocalUsageIndexStore: CodexLocalUsageIndexStore(directoryURL: fixture.indexDirectory)
        )
        let result = scanner.scan(since: nil)

        XCTAssertEqual(result.summary.providerSessions, 1)
        XCTAssertEqual(result.records.count, 1)
        XCTAssertEqual(result.records[0].sessionID, "azure-session")
    }

    func testNamedAzureDeploymentProviderCountsAsAzureAndPricesAstra() throws {
        let fixture = try makeFixture()
        try writeSession(
            at: fixture.root.appendingPathComponent("astra.jsonl"),
            sessionID: "astra-session",
            provider: "azure-astra",
            originator: "Codex Desktop",
            model: "gpt-6-astra",
            tokenEvents: [TokenEvent(input: 1_000_000, output: 100_000, total: 1_100_000)]
        )
        try writeSession(
            at: fixture.root.appendingPathComponent("echo.jsonl"),
            sessionID: "echo-session",
            provider: "azure_echo",
            originator: "Codex Desktop",
            model: "gpt-5.5",
            tokenEvents: [TokenEvent(input: 5, output: 5, total: 10)]
        )

        func scan(_ provider: CodexLogUsageProvider) -> AzureUsageScanResult {
            AzureUsageScanner(
                provider: provider,
                logRoots: [fixture.root],
                metadataURLs: [],
                codexLocalUsageIndexStore: CodexLocalUsageIndexStore(directoryURL: fixture.indexDirectory)
            ).scan(since: nil)
        }

        let azure = scan(.azure)
        XCTAssertEqual(azure.records.map(\.sessionID), ["astra-session"])
        // 1M uncached input at $10 + 100K output at $50/M.
        let record = try XCTUnwrap(azure.records.first)
        let cost = AzureModelPricing.defaultPricing(for: record.model, provider: .azure).estimatedCost(for: record.usage)
        XCTAssertEqual(cost, 15.00, accuracy: 0.0001)

        // The Azure session must not leak into the OpenAI Codex dashboard.
        XCTAssertTrue(scan(.openai).records.isEmpty)
    }

    func testRepeatedCumulativeSignatureCountsOnce() throws {
        let fixture = try makeFixture()
        try writeSession(
            at: fixture.root.appendingPathComponent("duplicate.jsonl"),
            sessionID: "duplicate-session",
            provider: "openai",
            originator: "codex-tui",
            model: "gpt-5.6-sol",
            tokenEvents: [
                TokenEvent(input: 4, output: 3, total: 7),
                TokenEvent(input: 4, output: 3, total: 7)
            ]
        )

        let result = makeScanner(fixture).scan(since: nil)

        XCTAssertEqual(result.records.count, 1)
        XCTAssertEqual(result.records[0].usage.totalTokens, 7)
        XCTAssertEqual(result.summary.duplicateEventsSkipped, 1)
    }

    func testForkedChildSkipsCopiedParentPrefixButCountsNewTokenEvent() throws {
        let fixture = try makeFixture()
        try writeSession(
            at: fixture.root.appendingPathComponent("parent.jsonl"),
            sessionID: "parent-session",
            provider: "openai",
            originator: "Codex Desktop",
            model: "gpt-5.6-orbit",
            tokenEvents: [TokenEvent(input: 1, output: 1, total: 2)]
        )
        try writeSession(
            at: fixture.root.appendingPathComponent("child.jsonl"),
            sessionID: "child-session",
            provider: "openai",
            originator: "codex-tui",
            model: "gpt-5.6-orbit",
            tokenEvents: [
                TokenEvent(input: 1, output: 1, total: 2),
                TokenEvent(input: 2, output: 1, total: 3)
            ],
            metaTimestamp: "2026-08-17T00:01:00Z",
            forkedFromID: "parent-session"
        )

        let result = makeScanner(fixture).scan(since: nil)

        XCTAssertEqual(result.records.map(\.id), ["parent-session-1", "child-session-2"])
        XCTAssertEqual(result.records.map(\.usage.totalTokens), [2, 3])
        XCTAssertEqual(result.summary.startupReplayEventsSkipped, 1)
    }

    func testSameSessionCumulativeSignatureAcrossFilesCountsOnce() throws {
        let fixture = try makeFixture()
        for filename in ["first.jsonl", "second.jsonl"] {
            try writeSession(
                at: fixture.root.appendingPathComponent(filename),
                sessionID: "shared-session",
                provider: "openai",
                originator: "codex_cli_rs",
                model: "gpt-5.6-orbit",
                tokenEvents: [TokenEvent(input: 5, output: 2, total: 7)]
            )
        }

        let result = makeScanner(fixture).scan(since: nil)

        XCTAssertEqual(result.records.count, 1)
        XCTAssertEqual(result.records[0].id, "shared-session-1")
        XCTAssertEqual(result.records[0].usage.totalTokens, 7)
        XCTAssertEqual(result.summary.duplicateEventsSkipped, 1)
    }

    func testIndexedFileGrowthIsReparsedAndIncludesAppendedEvents() throws {
        let fixture = try makeFixture()
        let fileURL = fixture.root.appendingPathComponent("growing.jsonl")
        try writeSession(
            at: fileURL,
            sessionID: "growing-session",
            provider: "openai",
            originator: "codex_cli_rs",
            model: "gpt-5.6-terra",
            tokenEvents: [TokenEvent(input: 1, output: 1, total: 2)]
        )

        let scanner = makeScanner(fixture)
        let first = scanner.scan(since: nil)
        XCTAssertEqual(first.records.count, 1)

        let appended = "{\"timestamp\":\"2026-08-17T00:00:02Z\",\"type\":\"event_msg\",\"payload\":{\"type\":\"token_count\",\"info\":{\"last_token_usage\":{\"input_tokens\":2,\"cached_input_tokens\":0,\"output_tokens\":2,\"reasoning_output_tokens\":0,\"total_tokens\":4},\"total_token_usage\":{\"input_tokens\":3,\"cached_input_tokens\":0,\"output_tokens\":3,\"reasoning_output_tokens\":0,\"total_tokens\":6}}}}\n"
        try append(Data(appended.utf8), to: fileURL)

        let second = scanner.scan(since: nil)
        XCTAssertEqual(second.records.count, 2)
        XCTAssertEqual(second.records.map(\.usage.totalTokens), [2, 4])
        XCTAssertEqual(CodexLocalUsageIndexStore(directoryURL: fixture.indexDirectory).load().files.count, 1)
    }

    func testOpenAICacheMigrationRebuildsAnExistingEmptyCacheUntilV6Completes() {
        XCTAssertTrue(AppPreferences.shouldRebuildOpenAIUsageCache(hasLoadedCache: true, backfillDone: false))
        XCTAssertFalse(AppPreferences.shouldRebuildOpenAIUsageCache(hasLoadedCache: true, backfillDone: true))
        XCTAssertFalse(AppPreferences.shouldRebuildOpenAIUsageCache(hasLoadedCache: false, backfillDone: false))
    }

    private func makeScanner(_ fixture: Fixture) -> AzureUsageScanner {
        AzureUsageScanner(
            provider: .openai,
            logRoots: [fixture.root],
            metadataURLs: [],
            codexLocalUsageIndexStore: CodexLocalUsageIndexStore(directoryURL: fixture.indexDirectory)
        )
    }

    private func makeFixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-usage-scanner-\(UUID().uuidString)", isDirectory: true)
        let indexDirectory = root.appendingPathComponent("index", isDirectory: true)
        let projectDirectory = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: indexDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: projectDirectory, withIntermediateDirectories: true)
        return Fixture(root: root, indexDirectory: indexDirectory, projectPath: projectDirectory.path)
    }

    private func writeSession(
        at url: URL,
        sessionID: String,
        provider: String,
        originator: String?,
        model: String,
        tokenEvents: [TokenEvent],
        metaTimestamp: String = "2026-08-17T00:00:00Z",
        forkedFromID: String? = nil
    ) throws {
        let originatorField = originator.map { ",\"originator\":\"\($0)\"" } ?? ""
        let forkedFromField = forkedFromID.map { ",\"forked_from_id\":\"\($0)\"" } ?? ""
        let projectPath = url.deletingLastPathComponent().appendingPathComponent("project").path
        var lines = [
            "{\"timestamp\":\"\(metaTimestamp)\",\"type\":\"session_meta\",\"payload\":{\"id\":\"\(sessionID)\",\"cwd\":\"\(projectPath)\",\"model_provider\":\"\(provider)\"\(originatorField)\(forkedFromField)}}",
            "{\"timestamp\":\"2026-08-17T00:00:01Z\",\"type\":\"turn_context\",\"payload\":{\"model\":\"\(model)\"}}"
        ]
        for (offset, event) in tokenEvents.enumerated() {
            let seconds = String(format: "%02d", offset + 2)
            lines.append("{\"timestamp\":\"2026-08-17T00:00:\(seconds)Z\",\"type\":\"event_msg\",\"payload\":{\"type\":\"token_count\",\"info\":{\"last_token_usage\":{\"input_tokens\":\(event.input),\"cached_input_tokens\":0,\"output_tokens\":\(event.output),\"reasoning_output_tokens\":0,\"total_tokens\":\(event.total)},\"total_token_usage\":{\"input_tokens\":\(event.input),\"cached_input_tokens\":0,\"output_tokens\":\(event.output),\"reasoning_output_tokens\":0,\"total_tokens\":\(event.total)}}}}")
        }
        try Data(lines.joined(separator: "\n").appending("\n").utf8).write(to: url, options: [.atomic])
    }

    private func append(_ data: Data, to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
    }

    private struct Fixture {
        let root: URL
        let indexDirectory: URL
        let projectPath: String
    }

    private struct TokenEvent {
        let input: Int
        let output: Int
        let total: Int
    }
}
