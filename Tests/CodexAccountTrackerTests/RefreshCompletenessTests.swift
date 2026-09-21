import Foundation
import XCTest
@testable import CodexAccountTracker

/// Covers the rule every usage refresh now follows: whatever is still on disk is re-derived
/// from scratch, whatever has vanished from disk is kept as it was cached. See
/// docs/plans/2026-09-21-refresh-completeness-and-pricing.md, Batch 1.
@MainActor
final class RefreshCompletenessTests: XCTestCase {

    // MARK: - Scanner: a late-written but early-stamped event is still counted

    /// File B holds the newest event in the whole scan; file A then gains an event stamped
    /// BEFORE it. The old refresh cutoff (newest event across all files) skipped exactly this
    /// record forever. Scanning with `since: nil` counts it.
    func testEventStampedBeforeAnotherFilesNewestEventIsStillCounted() throws {
        let fixture = try makeFixture()
        let fileA = fixture.root.appendingPathComponent("agent-a.jsonl")
        let fileB = fixture.root.appendingPathComponent("agent-b.jsonl")

        try writeSession(
            at: fileA,
            sessionID: "agent-a",
            eventTimestamps: ["2026-08-17T00:00:02Z"],
            inputTokens: 1
        )
        try writeSession(
            at: fileB,
            sessionID: "agent-b",
            eventTimestamps: ["2026-08-17T00:00:09Z"],
            inputTokens: 2
        )

        let scanner = makeScanner(fixture)
        let first = scanner.scan(since: nil)
        XCTAssertEqual(first.records.count, 2)
        XCTAssertEqual(first.summary.latestEvent, isoDate("2026-08-17T00:00:09Z"))

        // Written now, but stamped earlier than file B's newest event.
        let lateLine = tokenEventLine(timestamp: "2026-08-17T00:00:05Z", inputTokens: 7).appending("\n")
        try append(Data(lateLine.utf8), to: fileA)

        let second = scanner.scan(since: nil)
        XCTAssertEqual(second.records.count, 3)
        XCTAssertTrue(second.records.contains { $0.timestamp == isoDate("2026-08-17T00:00:05Z") })
    }

    // MARK: - Merge: vanished files are kept, present files are re-derived

    func testRecordsFromVanishedFilesAreKept() {
        let previous = result(provider: .claudeCode, records: [
            record(id: "gone-1", filePath: "/tmp/deleted.jsonl", seconds: 1),
            record(id: "gone-2", filePath: "/tmp/deleted.jsonl", seconds: 2)
        ])
        let fresh = result(provider: .claudeCode, records: [
            record(id: "live-1", filePath: "/tmp/live.jsonl", seconds: 3)
        ])

        let merged = AccountTrackerViewModel.mergedPreservingVanishedFiles(
            previous: previous,
            fresh: fresh
        )

        XCTAssertEqual(merged.records.map(\.id), ["gone-1", "gone-2", "live-1"])
        // Input cardinality: every fresh record plus every kept vanished record, nothing else.
        XCTAssertEqual(merged.records.count, fresh.records.count + 2)
    }

    func testRecordsTheFreshScanNoLongerProducesAreKeptEvenWhenTheirFileStillExists() {
        let previous = result(provider: .claudeCode, records: [
            record(id: "stale-1", filePath: "/tmp/live.jsonl", seconds: 1)
        ])
        let fresh = result(provider: .claudeCode, records: [
            record(id: "live-1", filePath: "/tmp/live.jsonl", seconds: 3)
        ])

        let merged = AccountTrackerViewModel.mergedPreservingVanishedFiles(
            previous: previous,
            fresh: fresh
        )

        // Codex rewrites its own rollout files, so a record missing from a fresh scan of a file
        // that still exists is not proof the usage never happened. A refresh never drops.
        XCTAssertEqual(merged.records.map(\.id), ["stale-1", "live-1"])
        XCTAssertEqual(merged.records.count, previous.records.count + fresh.records.count)
    }

    func testMixedPresentAndVanishedPaths() {
        let previous = result(provider: .claudeCode, records: [
            record(id: "gone-1", filePath: "/tmp/deleted.jsonl", seconds: 1),
            record(id: "stale-1", filePath: "/tmp/live.jsonl", seconds: 2)
        ])
        let fresh = result(provider: .claudeCode, records: [
            record(id: "live-1", filePath: "/tmp/live.jsonl", seconds: 3)
        ])

        let merged = AccountTrackerViewModel.mergedPreservingVanishedFiles(
            previous: previous,
            fresh: fresh
        )

        XCTAssertEqual(merged.records.map(\.id), ["gone-1", "stale-1", "live-1"])
        XCTAssertEqual(merged.records.count, fresh.records.count + 2)
    }

    // MARK: - Merge: guards and sticky labels

    func testEmptyFreshScanReturnsThePreviousResultUnchanged() {
        let previous = result(provider: .claudeCode, records: [
            record(id: "kept-1", filePath: "/tmp/live.jsonl", seconds: 1)
        ])

        let merged = AccountTrackerViewModel.mergedPreservingVanishedFiles(
            previous: previous,
            fresh: AzureUsageScanResult(provider: .claudeCode)
        )

        XCTAssertEqual(merged, previous)
    }

    func testEmptyPreviousResultReturnsTheFreshScan() {
        let fresh = result(provider: .openai, records: [
            record(id: "live-1", filePath: "/tmp/live.jsonl", seconds: 1)
        ])

        let merged = AccountTrackerViewModel.mergedPreservingVanishedFiles(
            previous: AzureUsageScanResult(provider: .openai),
            fresh: fresh
        )

        XCTAssertEqual(merged, fresh)
    }

    func testAzureEndpointLabelsStayStickyAcrossARescan() {
        let previous = result(provider: .azure, records: [
            record(
                id: "shared-1",
                filePath: "/tmp/live.jsonl",
                seconds: 1,
                endpoint: "old-endpoint",
                resource: "old-resource",
                deployment: "old-deployment"
            )
        ])
        let fresh = result(provider: .azure, records: [
            record(
                id: "shared-1",
                filePath: "/tmp/live.jsonl",
                seconds: 1,
                endpoint: "new-endpoint",
                resource: "new-resource",
                deployment: "new-deployment"
            )
        ])

        let merged = AccountTrackerViewModel.mergedPreservingVanishedFiles(
            previous: previous,
            fresh: fresh
        )

        XCTAssertEqual(merged.records.count, 1)
        XCTAssertEqual(merged.records[0].endpoint, "old-endpoint")
        XCTAssertEqual(merged.records[0].resource, "old-resource")
        XCTAssertEqual(merged.records[0].deployment, "old-deployment")
    }

    func testNonAzureProvidersTakeTheFreshRecordWholesale() {
        let previous = result(provider: .openai, records: [
            record(id: "shared-1", filePath: "/tmp/live.jsonl", seconds: 1, endpoint: "old-endpoint")
        ])
        let fresh = result(provider: .openai, records: [
            record(id: "shared-1", filePath: "/tmp/live.jsonl", seconds: 1, endpoint: "new-endpoint")
        ])

        let merged = AccountTrackerViewModel.mergedPreservingVanishedFiles(
            previous: previous,
            fresh: fresh
        )

        XCTAssertEqual(merged.records.map(\.endpoint), ["new-endpoint"])
    }

    // MARK: - Helpers

    private func result(provider: CodexLogUsageProvider, records: [AzureUsageRecord]) -> AzureUsageScanResult {
        var result = AzureUsageScanResult(provider: provider)
        result.records = records
        result.summary.eventsCounted = records.count
        result.summary.earliestEvent = records.map(\.timestamp).min()
        result.summary.latestEvent = records.map(\.timestamp).max()
        return result
    }

    private func record(
        id: String,
        filePath: String,
        seconds: TimeInterval,
        endpoint: String = "endpoint",
        resource: String = "resource",
        deployment: String = "deployment"
    ) -> AzureUsageRecord {
        AzureUsageRecord(
            id: id,
            sessionID: "session",
            filePath: filePath,
            timestamp: Date(timeIntervalSince1970: seconds),
            endpoint: endpoint,
            resource: resource,
            deployment: deployment,
            model: "gpt-5.6-luna",
            projectPath: "/tmp/project",
            usage: AzureTokenUsage(
                inputTokens: 10,
                cachedInputTokens: 0,
                outputTokens: 5,
                reasoningOutputTokens: 0,
                totalTokens: 15
            )
        )
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
            .appendingPathComponent("refresh-completeness-\(UUID().uuidString)", isDirectory: true)
        let indexDirectory = root.appendingPathComponent("index", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: indexDirectory, withIntermediateDirectories: true)
        return Fixture(root: root, indexDirectory: indexDirectory)
    }

    private func writeSession(
        at url: URL,
        sessionID: String,
        eventTimestamps: [String],
        inputTokens: Int
    ) throws {
        let projectPath = url.deletingLastPathComponent().appendingPathComponent("project").path
        var lines = [
            "{\"timestamp\":\"2026-08-17T00:00:00Z\",\"type\":\"session_meta\",\"payload\":{\"id\":\"\(sessionID)\",\"cwd\":\"\(projectPath)\",\"model_provider\":\"openai\",\"originator\":\"codex_cli_rs\"}}",
            "{\"timestamp\":\"2026-08-17T00:00:01Z\",\"type\":\"turn_context\",\"payload\":{\"model\":\"gpt-5.6-terra\"}}"
        ]
        for timestamp in eventTimestamps {
            lines.append(tokenEventLine(timestamp: timestamp, inputTokens: inputTokens))
        }
        try Data(lines.joined(separator: "\n").appending("\n").utf8).write(to: url, options: [.atomic])
    }

    private func tokenEventLine(timestamp: String, inputTokens: Int) -> String {
        "{\"timestamp\":\"\(timestamp)\",\"type\":\"event_msg\",\"payload\":{\"type\":\"token_count\",\"info\":{\"last_token_usage\":{\"input_tokens\":\(inputTokens),\"cached_input_tokens\":0,\"output_tokens\":1,\"reasoning_output_tokens\":0,\"total_tokens\":\(inputTokens + 1)},\"total_token_usage\":{\"input_tokens\":\(inputTokens),\"cached_input_tokens\":0,\"output_tokens\":1,\"reasoning_output_tokens\":0,\"total_tokens\":\(inputTokens + 1)}}}}"
    }

    private func append(_ data: Data, to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
    }

    private func isoDate(_ value: String) -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        guard let date = formatter.date(from: value) else {
            XCTFail("bad fixture timestamp \(value)")
            return Date(timeIntervalSince1970: 0)
        }
        return date
    }

    private struct Fixture {
        let root: URL
        let indexDirectory: URL
    }
}
