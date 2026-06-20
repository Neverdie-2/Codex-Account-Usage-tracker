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

    /// The anchored `LIKE` join with a trailing hyphen returns exactly the three
    /// bubbles under the conversation and excludes the prefix-colliding decoy.
    func testCursorDiskKVAnchoredLikeExcludesDecoy() throws {
        let dbURL = makeSampleStateDB()
        defer { removeTempDB(dbURL) }

        let reader = CursorStateDBReader(databaseURL: dbURL)
        let connection = try XCTUnwrap(reader.open())
        defer { connection.close() }

        let rows = connection.cursorDiskKVValues(
            likePrefix: "bubbleId:11111111-2222-3333-4444-555555555555-"
        )

        XCTAssertEqual(rows.count, 3, "anchored prefix should match exactly the three bubbles")
        XCTAssertFalse(rows.contains { $0.key.contains("WRONG") },
                       "trailing-hyphen anchoring must exclude the prefix-colliding decoy")
    }

    /// The token stored in ItemTable round-trips through the convenience accessor.
    func testItemValueRoundTripsAccessToken() {
        let dbURL = makeSampleStateDB()
        defer { removeTempDB(dbURL) }

        let reader = CursorStateDBReader(databaseURL: dbURL)
        XCTAssertEqual(reader.itemValue(key: "cursorAuth/accessToken"), CursorTestJWT.valid)
    }
}
