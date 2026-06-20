import XCTest
@testable import CodexAccountTracker

final class CursorStateDBReaderTests: XCTestCase {
    /// `open()` yields a connection whose `itemValue` reads back an ItemTable row.
    func testOpenAndItemValueReadsComposerHeaders() throws {
        let dbURL = makeSampleStateDB()
        defer { removeTempDB(dbURL) }

        let reader = CursorStateDBReader(databaseURL: dbURL)
        let connection = try XCTUnwrap(reader.open())
        defer { connection.close() }

        let value = try XCTUnwrap(connection.itemValue(key: "composer.composerHeaders"))
        XCTAssertTrue(value.contains("allComposers"),
                      "composer.composerHeaders should contain the allComposers array")
    }

    /// The anchored `LIKE` join with a trailing colon returns exactly the three
    /// bubbles under the conversation and excludes the prefix-colliding decoy.
    func testCursorDiskKVAnchoredLikeExcludesDecoy() throws {
        let dbURL = makeSampleStateDB()
        defer { removeTempDB(dbURL) }

        let reader = CursorStateDBReader(databaseURL: dbURL)
        let connection = try XCTUnwrap(reader.open())
        defer { connection.close() }

        let rows = connection.cursorDiskKVValues(
            likePrefix: "bubbleId:11111111-2222-3333-4444-555555555555:"
        )

        XCTAssertEqual(rows.count, 4, "anchored prefix should match exactly the four bubbles")
        XCTAssertFalse(rows.contains { $0.key.contains("WRONG") },
                       "trailing-colon anchoring must exclude the prefix-colliding decoy")
    }

    /// composerData rows and colon-joined bubbles are extracted via SQL json_extract.
    func testComposerMetadataAndBubbleRows() throws {
        let dbURL = makeSampleStateDB()
        defer { removeTempDB(dbURL) }

        let reader = CursorStateDBReader(databaseURL: dbURL)
        let connection = try XCTUnwrap(reader.open())
        defer { connection.close() }

        let metas = connection.composerMetadataRows()
        XCTAssertEqual(metas.count, 2)
        let agentMeta = try XCTUnwrap(metas.first { $0.composerId == "11111111-2222-3333-4444-555555555555" })
        XCTAssertEqual(agentMeta.unifiedMode, "agent")
        XCTAssertEqual(agentMeta.linesAdded, 128)
        XCTAssertEqual(agentMeta.linesRemoved, 17)

        let bubbles = connection.bubbleRows()
        let agentBubbles = bubbles.filter { $0.composerId == "11111111-2222-3333-4444-555555555555" }
        XCTAssertEqual(agentBubbles.count, 4, "colon-keyed bubbles parse the composerId from segment 2")
        XCTAssertEqual(Set(agentBubbles.compactMap(\.modelName)), ["claude-4.5-opus-high-thinking"])
        // Tokens are logged on a separate null-model bubble.
        XCTAssertEqual(agentBubbles.map(\.inputTokens).reduce(0, +), 1_000_000)
        XCTAssertEqual(agentBubbles.map(\.outputTokens).reduce(0, +), 200_000)
        // The orphan decoy parses to a different composerId and never joins composer 1111….
        XCTAssertTrue(bubbles.contains { $0.composerId == "11111111-2222-3333-4444-555555555555X" })
    }

    /// The token stored in ItemTable round-trips through the convenience accessor.
    func testItemValueRoundTripsAccessToken() {
        let dbURL = makeSampleStateDB()
        defer { removeTempDB(dbURL) }

        let reader = CursorStateDBReader(databaseURL: dbURL)
        XCTAssertEqual(reader.itemValue(key: "cursorAuth/accessToken"), CursorTestJWT.valid)
    }
}
