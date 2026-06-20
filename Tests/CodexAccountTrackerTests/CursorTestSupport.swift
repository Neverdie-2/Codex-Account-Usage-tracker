import XCTest
import SQLite3
import Foundation
@testable import CodexAccountTracker

// SQLite needs to know whether a bound string is transient (copy it) or static.
// The C macro SQLITE_TRANSIENT isn't imported into Swift, so re-declare it.
private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Loads bundled `Fixtures/*.sample.*` resources for the Cursor tests.
enum CursorFixtures {
    static func url(_ name: String) -> URL {
        let dotIndex = name.lastIndex(of: ".")
        let base: String
        let ext: String
        if let dotIndex {
            base = String(name[name.startIndex..<dotIndex])
            ext = String(name[name.index(after: dotIndex)...])
        } else {
            base = name
            ext = ""
        }
        return Bundle.module.url(forResource: base, withExtension: ext, subdirectory: "Fixtures")!
    }

    static func data(_ name: String) -> Data {
        try! Data(contentsOf: url(name))
    }

    static func string(_ name: String) -> String {
        String(decoding: data(name), as: UTF8.self)
    }
}

/// Synthetic 3-segment JWTs (alg "none"). The middle segment base64url-decodes to
/// `{"sub":"google-oauth2|user_01ABCDEF","aud":"https://cursor.com","exp":...}`.
enum CursorTestJWT {
    /// `exp` 4102444800 — valid through the year 2100.
    static let valid = "eyJhbGciOiJub25lIiwidHlwIjoiSldUIn0.eyJzdWIiOiJnb29nbGUtb2F1dGgyfHVzZXJfMDFBQkNERUYiLCJhdWQiOiJodHRwczovL2N1cnNvci5jb20iLCJleHAiOjQxMDI0NDQ4MDB9.sig"
    /// `exp` 1000000000 — already expired (year 2001).
    static let expired = "eyJhbGciOiJub25lIiwidHlwIjoiSldUIn0.eyJzdWIiOiJnb29nbGUtb2F1dGgyfHVzZXJfMDFBQkNERUYiLCJhdWQiOiJodHRwczovL2N1cnNvci5jb20iLCJleHAiOjEwMDAwMDAwMDB9.sig"
}

/// Builds a `state.vscdb`-shaped SQLite fixture in a fresh temp dir via the C API,
/// mirroring `Fixtures/make_sample_vscdb.sql`, and returns the db file URL.
func makeSampleStateDB() -> URL {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        .appendingPathComponent("cursor-state-db-\(UUID().uuidString)", isDirectory: true)
    try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let dbURL = dir.appendingPathComponent("state.vscdb")

    var db: OpaquePointer?
    let openResult = sqlite3_open_v2(
        dbURL.path,
        &db,
        SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE,
        nil
    )
    precondition(openResult == SQLITE_OK, "failed to open sample state.vscdb")
    defer { sqlite3_close(db) }

    func exec(_ sql: String) {
        var errorMessage: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(db, sql, nil, nil, &errorMessage)
        if result != SQLITE_OK {
            let detail = errorMessage.map { String(cString: $0) } ?? "unknown error"
            sqlite3_free(errorMessage)
            preconditionFailure("sqlite3_exec failed: \(detail)")
        }
    }

    func insert(into table: String, key: String, value: String) {
        var statement: OpaquePointer?
        let sql = "INSERT INTO \(table)(key, value) VALUES(?, ?);"
        precondition(sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK,
                     "failed to prepare insert into \(table)")
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, key, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(statement, 2, value, -1, SQLITE_TRANSIENT)
        precondition(sqlite3_step(statement) == SQLITE_DONE,
                     "failed to insert key \(key) into \(table)")
    }

    exec("CREATE TABLE ItemTable(key TEXT, value TEXT);")
    exec("CREATE TABLE cursorDiskKV(key TEXT, value TEXT);")

    insert(into: "ItemTable", key: "composer.composerHeaders",
           value: CursorFixtures.string("composerHeaders.sample.json"))
    insert(into: "ItemTable", key: "cursor/lastSingleModelPreference",
           value: "{\"composer\":\"gemini-3-flash\"}")
    insert(into: "ItemTable", key: "cursorAuth/cachedEmail",
           value: "angeldanielov9@gmail.com")
    insert(into: "ItemTable", key: "cursorAuth/stripeMembershipType",
           value: "free")
    insert(into: "ItemTable", key: "cursorAuth/stripeSubscriptionStatus",
           value: "canceled")
    insert(into: "ItemTable", key: "cursorAuth/accessToken",
           value: CursorTestJWT.valid)

    // The authoritative conversation list lives in composerData:<id> rows.
    insert(into: "cursorDiskKV",
           key: "composerData:11111111-2222-3333-4444-555555555555",
           value: "{\"composerId\":\"11111111-2222-3333-4444-555555555555\",\"createdAt\":1750405404081,\"unifiedMode\":\"agent\",\"forceMode\":\"agent\",\"totalLinesAdded\":128,\"totalLinesRemoved\":17}")
    insert(into: "cursorDiskKV",
           key: "composerData:aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee",
           value: "{\"composerId\":\"aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee\",\"createdAt\":1749000000000,\"unifiedMode\":\"chat\",\"totalLinesAdded\":0,\"totalLinesRemoved\":0}")

    // Bubbles join on the colon-separated key bubbleId:<composerId>:<bubbleUuid>.
    // Conversation A's served model is claude; the token counts live on a SEPARATE
    // null-model bubble (b4) — the scanner attributes them to the conversation's model.
    insert(into: "cursorDiskKV",
           key: "bubbleId:11111111-2222-3333-4444-555555555555:b1",
           value: "{\"type\":1,\"text\":\"refactor this\",\"modelInfo\":{\"modelName\":\"claude-4.5-opus-high-thinking\"},\"createdAt\":\"2026-06-20T07:43:24.081Z\",\"tokenCount\":{\"inputTokens\":0,\"outputTokens\":0}}")
    insert(into: "cursorDiskKV",
           key: "bubbleId:11111111-2222-3333-4444-555555555555:b2",
           value: "{\"type\":2,\"text\":\"done\",\"modelInfo\":null,\"createdAt\":\"2026-06-20T07:43:30.000Z\",\"tokenCount\":{\"inputTokens\":0,\"outputTokens\":0}}")
    insert(into: "cursorDiskKV",
           key: "bubbleId:11111111-2222-3333-4444-555555555555:b3",
           value: "{\"type\":1,\"text\":\"now tests\",\"modelInfo\":{\"modelName\":\"claude-4.5-opus-high-thinking\"},\"createdAt\":\"2026-06-20T08:10:00.000Z\",\"tokenCount\":{\"inputTokens\":0,\"outputTokens\":0}}")
    // Two assistant turns whose inputTokens are CUMULATIVE context (800k then 1M);
    // the conversation's input is the peak (1M, not the 1.8M sum). Output is per-turn.
    insert(into: "cursorDiskKV",
           key: "bubbleId:11111111-2222-3333-4444-555555555555:b4",
           value: "{\"type\":2,\"text\":\"\",\"modelInfo\":null,\"createdAt\":\"2026-06-20T08:11:00.000Z\",\"tokenCount\":{\"inputTokens\":800000,\"outputTokens\":120000}}")
    insert(into: "cursorDiskKV",
           key: "bubbleId:11111111-2222-3333-4444-555555555555:b5",
           value: "{\"type\":2,\"text\":\"\",\"modelInfo\":null,\"createdAt\":\"2026-06-20T08:12:00.000Z\",\"tokenCount\":{\"inputTokens\":1000000,\"outputTokens\":80000}}")
    // Prefix-colliding ORPHAN decoy (composerId ...555555555555X has no
    // composerData/header) — must NOT leak into composer 1111… or fabricate a row.
    insert(into: "cursorDiskKV",
           key: "bubbleId:11111111-2222-3333-4444-555555555555X:WRONG",
           value: "{\"type\":1,\"text\":\"decoy\",\"modelInfo\":{\"modelName\":\"decoy-model\"},\"createdAt\":\"2026-06-20T09:00:00.000Z\",\"tokenCount\":{\"inputTokens\":500,\"outputTokens\":50}}")

    return dbURL
}

/// Removes the temp directory that contains `url` (the dir created by `makeSampleStateDB`).
func removeTempDB(_ url: URL) {
    try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
}

/// A `URLProtocol` stub that answers requests from a static responder closure,
/// so `CursorAPIClient` can be exercised without real network access.
final class StubURLProtocol: URLProtocol {
    static var responder: ((URLRequest) -> (status: Int, body: Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let responder = StubURLProtocol.responder else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        let result = responder(request)
        let response = HTTPURLResponse(
            url: request.url ?? URL(string: "https://cursor.com")!,
            statusCode: result.status,
            httpVersion: nil,
            headerFields: nil
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: result.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    /// A session whose configuration routes every request through `StubURLProtocol`.
    static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: configuration)
    }
}

/// A fixed UTC Gregorian calendar so day-boundary assertions are deterministic.
let utcCalendar: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return calendar
}()

/// Parses an ISO8601 timestamp into a `Date` for test setup. Force-unwraps —
/// tests should only pass well-formed literals.
func iso(_ s: String) -> Date {
    CursorAccountRecord.parseISO8601(s)!
}
