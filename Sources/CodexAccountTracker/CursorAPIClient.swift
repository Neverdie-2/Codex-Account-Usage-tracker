import Foundation

/// Thin async client over Cursor's web API. Authentication is carried entirely
/// by the `WorkosCursorSessionToken` cookie (built by `CursorAuth`), so every
/// request sets a `Cookie` header rather than a bearer token. Errors are mapped
/// onto `CursorAPIError` so callers never see raw `URLError`/decoding failures.
final class CursorAPIClient {
    private let session: URLSession
    private let baseURL: URL

    init(session: URLSession = CursorAPIClient.makeEphemeralSession(),
         baseURL: URL = URL(string: "https://cursor.com")!) {
        self.session = session
        self.baseURL = baseURL
    }

    /// Ephemeral so no cookies/credentials are persisted between launches; a
    /// 10s request timeout keeps a hung refresh from blocking the UI.
    static func makeEphemeralSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 10
        return URLSession(configuration: config)
    }

    /// `GET /api/usage-summary` — the primary feed for the limits table.
    func fetchUsageSummary(cookie: String) async throws -> UsageSummaryResponse {
        try await request(path: "api/usage-summary", cookie: cookie)
    }

    /// `GET /api/auth/me` — identity.
    func fetchAuthMe(cookie: String) async throws -> AuthMeResponse {
        try await request(path: "api/auth/me", cookie: cookie)
    }

    /// `GET /api/auth/stripe` — plan/subscription detail.
    func fetchAuthStripe(cookie: String) async throws -> AuthStripeResponse {
        try await request(path: "api/auth/stripe", cookie: cookie)
    }

    /// `GET /api/usage?user=<sub>` — deprecated legacy premium-request counters.
    func fetchLegacyUsage(cookie: String, sub: String) async throws -> LegacyUsageResponse {
        try await request(
            path: "api/usage",
            queryItems: [URLQueryItem(name: "user", value: sub)],
            cookie: cookie
        )
    }

    private func request<T: Decodable>(path: String,
                                       queryItems: [URLQueryItem] = [],
                                       cookie: String) async throws -> T {
        var components = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)
        if !queryItems.isEmpty {
            components?.queryItems = queryItems
        }
        guard let url = components?.url else { throw CursorAPIError.invalidURL }

        var urlRequest = URLRequest(url: url, timeoutInterval: 10)
        urlRequest.setValue(cookie, forHTTPHeaderField: "Cookie")
        urlRequest.setValue("CodexAccountTracker/1.0", forHTTPHeaderField: "User-Agent")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: urlRequest)
        } catch {
            throw CursorAPIError.network
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw CursorAPIError.network
        }
        let status = httpResponse.statusCode
        if status == 401 || status == 403 {
            throw CursorAPIError.unauthorized
        }
        guard (200..<300).contains(status) else {
            throw CursorAPIError.httpStatus(status)
        }

        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw CursorAPIError.decoding
        }
    }
}
