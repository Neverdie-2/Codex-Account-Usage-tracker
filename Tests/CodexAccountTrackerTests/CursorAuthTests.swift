import XCTest
@testable import CodexAccountTracker

final class CursorAuthTests: XCTestCase {
    func testDecodesValidJWTPayload() throws {
        let auth = CursorAuth()
        let payload = try auth.decode(jwt: CursorTestJWT.valid)
        XCTAssertEqual(payload.sub, "google-oauth2|user_01ABCDEF")
        XCTAssertEqual(payload.aud, "https://cursor.com")
        XCTAssertEqual(payload.exp, 4102444800)
    }

    func testCookieHeaderValueKeepsPrefixAndDoubleColonSeparator() throws {
        let auth = CursorAuth()
        let payload = try auth.decode(jwt: CursorTestJWT.valid)
        let cookie = auth.cookieHeaderValue(sub: payload.sub, jwt: CursorTestJWT.valid)
        XCTAssertEqual(
            cookie,
            "WorkosCursorSessionToken=google-oauth2|user_01ABCDEF::\(CursorTestJWT.valid)"
        )
    }

    func testIsExpiredForValidAndExpiredPayloads() throws {
        let auth = CursorAuth()
        let valid = try auth.decode(jwt: CursorTestJWT.valid)
        XCTAssertFalse(auth.isExpired(valid, now: Date()))

        let expired = try auth.decode(jwt: CursorTestJWT.expired)
        XCTAssertTrue(auth.isExpired(expired, now: Date()))
    }

    func testDecodeThrowsOnMalformedJWT() {
        let auth = CursorAuth()
        XCTAssertThrowsError(try auth.decode(jwt: "abc"))
    }
}
