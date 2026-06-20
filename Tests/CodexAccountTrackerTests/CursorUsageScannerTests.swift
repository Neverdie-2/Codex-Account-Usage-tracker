import XCTest
@testable import CodexAccountTracker

final class CursorUsageScannerTests: XCTestCase {
    private var dbURL: URL!
    private var rendererDir: URL!
    private var scanner: CursorUsageScanner!

    private let now = CursorAccountRecord.parseISO8601("2026-06-20T12:00:00Z")!
    private let cal = utcCalendar

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

    private func record(in result: CursorUsageScanResult, id: String) -> CursorUsageRecord? {
        result.records.first { $0.id == id }
    }

    func testAgentComposerCountsModelsAndDeltas() {
        let result = scanner.scan(now: now, calendar: cal)

        let agent = try! XCTUnwrap(
            record(in: result, id: "cursor-composer-11111111-2222-3333-4444-555555555555")
        )
        XCTAssertEqual(agent.modelsUsed, ["composer-2.5", "claude-4.5-opus-high-thinking"])
        XCTAssertEqual(agent.messageCount, 3)
        XCTAssertEqual(agent.userCount, 2)
        XCTAssertEqual(agent.assistantCount, 1)
        XCTAssertEqual(agent.linesAdded, 128)
        XCTAssertEqual(agent.linesRemoved, 17)
        XCTAssertEqual(agent.filesChanged, 4)
        XCTAssertEqual(agent.workspace.name, "MyProject")
    }

    func testUnscopedChatComposer() {
        let result = scanner.scan(now: now, calendar: cal)

        let chat = try! XCTUnwrap(
            record(in: result, id: "cursor-composer-aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")
        )
        XCTAssertEqual(chat.workspace.name, "Unscoped")
        XCTAssertEqual(chat.title, "quick question")
        XCTAssertEqual(chat.mode, "chat")
    }

    func testModelsUsedTodayRollup() {
        let result = scanner.scan(now: now, calendar: cal)

        XCTAssertTrue(result.summary.modelsUsedToday.contains("composer-2.5"))
        XCTAssertTrue(result.summary.modelsUsedToday.contains("claude-4.5-opus-high-thinking"))
        // gemini-3-flash only lives in a preference key, never a today bubble.
        XCTAssertFalse(result.summary.modelsUsedToday.contains("gemini-3-flash"))
        // decoy-model belongs to a prefix-colliding key under a different conversation.
        XCTAssertFalse(result.summary.modelsUsedToday.contains("decoy-model"))
    }

    func testTodayWindowFiltersByLastActivity() {
        let result = scanner.scan(now: now, calendar: cal)
        let dash = CursorUsageScanner.dashboard(from: result, window: .today, now: now, calendar: cal)

        let ids = dash.records.map(\.id)
        XCTAssertTrue(ids.contains("cursor-composer-11111111-2222-3333-4444-555555555555"))
        XCTAssertFalse(ids.contains("cursor-composer-aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"))
    }

    func testScanningTwiceDedupesRecords() {
        let first = scanner.scan(now: now, calendar: cal)
        let second = scanner.scan(now: now, calendar: cal)
        XCTAssertEqual(first.records.count, second.records.count)
    }
}
