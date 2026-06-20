import Foundation

/// Decoded claims of a Cursor `accessToken` JWT. Only the fields we need:
/// `sub` (the `google-oauth2|…` user id), `aud`, and `exp` (Unix seconds).
struct CursorJWTPayload: Equatable {
    let sub: String
    let aud: String
    let exp: Int
}

/// One read of the four `ItemTable cursorAuth/*` keys from `state.vscdb`.
/// `accessTokenJWT` is the only secret here and must never be logged or persisted;
/// the cached identity/plan fields back the "stale" fallback when the API is down.
struct CursorAuthSnapshot: Equatable {
    var accessTokenJWT: String?
    var cachedEmail: String?
    var cachedMembershipType: String?
    var cachedSubscriptionStatus: String?
}

enum CursorAuthError: Error, Equatable {
    case tokenMissing
    case malformedJWT
}

/// Pure JWT/cookie logic plus a single snapshot read of Cursor's auth state.
/// Builds the `WorkosCursorSessionToken` cookie value that authenticates the
/// limits API calls. The cookie value is a secret and is never logged or stored.
final class CursorAuth {
    private let reader: CursorStateDBReader

    init(reader: CursorStateDBReader = CursorStateDBReader()) {
        self.reader = reader
    }

    /// Open the state DB once, read the four `cursorAuth/*` ItemTable keys, and
    /// close. Returns an all-nil snapshot if the database can't be opened.
    func readSnapshot() -> CursorAuthSnapshot {
        guard let connection = reader.open() else {
            return CursorAuthSnapshot()
        }
        defer { connection.close() }
        return CursorAuthSnapshot(
            accessTokenJWT: connection.itemValue(key: "cursorAuth/accessToken"),
            cachedEmail: connection.itemValue(key: "cursorAuth/cachedEmail"),
            cachedMembershipType: connection.itemValue(key: "cursorAuth/stripeMembershipType"),
            cachedSubscriptionStatus: connection.itemValue(key: "cursorAuth/stripeSubscriptionStatus")
        )
    }

    /// Decode the middle (payload) segment of a JWT. Tolerant of base64url
    /// without padding; throws `malformedJWT` on any structural/decode failure.
    func decode(jwt: String) throws -> CursorJWTPayload {
        let segments = jwt.components(separatedBy: ".")
        guard segments.count >= 2 else {
            throw CursorAuthError.malformedJWT
        }

        var base64 = segments[1]
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 {
            base64.append("=")
        }

        guard let data = Data(base64Encoded: base64) else {
            throw CursorAuthError.malformedJWT
        }

        do {
            let raw = try JSONDecoder().decode(RawPayload.self, from: data)
            return CursorJWTPayload(
                sub: raw.sub ?? "",
                aud: raw.aud ?? "",
                exp: raw.exp ?? 0
            )
        } catch {
            throw CursorAuthError.malformedJWT
        }
    }

    /// True once the token's `exp` (Unix seconds) has reached or passed `now`.
    func isExpired(_ payload: CursorJWTPayload, now: Date) -> Bool {
        payload.exp <= Int(now.timeIntervalSince1970)
    }

    /// The `WorkosCursorSessionToken` cookie value: `sub::jwt`, where `sub`
    /// keeps its `google-oauth2|` prefix and the separator is a literal `::`.
    /// SECRET — never log or persist the return value.
    func cookieHeaderValue(sub: String, jwt: String) -> String {
        "WorkosCursorSessionToken=\(sub)::\(jwt)"
    }

    /// Minimal, forgiving decode target for the JWT payload claims we read.
    /// All fields optional, so the synthesized decode treats missing keys as nil.
    private struct RawPayload: Decodable {
        let sub: String?
        let aud: String?
        let exp: Int?
    }
}
