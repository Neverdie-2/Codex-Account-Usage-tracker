import XCTest
@testable import CodexAccountTracker

final class CursorUsageScannerTests: XCTestCase {
    private var dbURL: URL!
    private var rendererDir: URL!
    private var scanner: CursorUsageScanner!

    private let composerA = "11111111-2222-3333-4444-555555555555"
    private let composerB = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"

    override func setUp() {
        super.setUp()
        dbURL = makeSampleStateDB()
        let reader = CursorStateDBReader(databaseURL: dbURL)
        // Point the renderer reader at a fresh, empty temp dir so the scan stays
        // hermetic and never touches the real ~/Library Cursor logs.
        rendererDir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("cursor-renderer-logs-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: rendererDir, withIntermediateDirectories: true)
        let rendererReader = CursorRendererLogReader(logsDirectory: rendererDir)
        scanner = CursorUsageScanner(reader: reader, rendererLogReader: rendererReader)
    }

    override func tearDown() {
        if let dbURL { removeTempDB(dbURL) }
        if let rendererDir { try? FileManager.default.removeItem(at: rendererDir) }
        dbURL = nil
        rendererDir = nil
        scanner = nil
        super.tearDown()
    }

    func testScanProducesCursorProviderResult() {
        XCTAssertEqual(scanner.scan().provider, .cursor)
    }

    /// The null-model token bubble's tokens are attributed to the conversation's
    /// served (primary) model — claude — and tagged with the conversation's mode.
    func testAttributesNoModelTokensToPrimaryModel() throws {
        let result = scanner.scan()
        let aRecords = result.records.filter { $0.sessionID == composerA }
        let claude = try XCTUnwrap(aRecords.first { $0.model == "claude-4.5-opus-high-thinking" })
        XCTAssertEqual(claude.usage.inputTokens, 1_000_000)
        XCTAssertEqual(claude.usage.outputTokens, 200_000)
        XCTAssertEqual(claude.usage.totalTokens, 1_200_000)
        XCTAssertEqual(claude.endpoint, "Cursor")
        XCTAssertEqual(claude.resource, "agent")
    }

    /// A chat conversation with no bubbles logs no token events, so it produces
    /// no usage records (matching the other token dashboards).
    func testConversationWithoutBubblesProducesNoRecords() {
        let result = scanner.scan()
        XCTAssertTrue(result.records.filter { $0.sessionID == composerB }.isEmpty)
    }

    /// The orphan decoy bubble (no composerData / header) is ignored.
    func testOrphanDecoyBubbleIgnored() {
        let result = scanner.scan()
        XCTAssertFalse(result.records.contains { $0.model == "decoy-model" })
        XCTAssertFalse(result.records.contains { $0.sessionID.hasSuffix("X") })
    }

    func testDashboardTotalsModelProjectAndCost() throws {
        let result = scanner.scan()
        let now = CursorAccountRecord.parseISO8601("2026-06-21T00:00:00Z")!
        let dashboard = AzureUsageScanner.dashboard(from: result, window: .allTime, customStartDate: now, now: now)

        XCTAssertEqual(dashboard.totals.totalTokens, 1_200_000)
        // claude-opus-4.5+ preset: $5/M input, $25/M output → 5 + 5 = $10.
        XCTAssertEqual(dashboard.totals.estimatedCostUSD, 10.0, accuracy: 0.001)
        XCTAssertTrue(dashboard.byModel.contains { $0.model == "claude-4.5-opus-high-thinking" })

        let project = try XCTUnwrap(dashboard.byProject.first { $0.projectName == "MyProject" })
        XCTAssertEqual(project.sessionCount, 1)
        XCTAssertTrue(project.sessions.contains { $0.sessionID == composerA })
    }

    func testWindowFilteringExcludesOldActivity() {
        let result = scanner.scan()
        // 5 days after the fixture bubbles → the last-24h window has no events.
        let now = CursorAccountRecord.parseISO8601("2026-06-25T00:00:00Z")!
        let dashboard = AzureUsageScanner.dashboard(from: result, window: .last24Hours, customStartDate: now, now: now)
        XCTAssertEqual(dashboard.totals.totalTokens, 0)
    }
}
