import Foundation

struct OpenAIAPIBillingClient {
    private let session: URLSession
    private let baseURL = URL(string: "https://api.openai.com/v1")!

    init(session: URLSession = .shared) {
        self.session = session
    }

    func fetch(adminKey: String, startDate: Date, endDate: Date = Date()) async throws -> OpenAIAPIBillingResult {
        let trimmedKey = adminKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else { throw OpenAIAPIBillingError.missingAdminKey }

        async let usageRecords = fetchUsageRecords(adminKey: trimmedKey, startDate: startDate, endDate: endDate)
        async let costRecords = fetchCostRecords(adminKey: trimmedKey, startDate: startDate, endDate: endDate)

        var result = OpenAIAPIBillingResult()
        result.usageRecords = try await usageRecords
        result.costRecords = try await costRecords
        result.summary = Self.summary(usageRecords: result.usageRecords, costRecords: result.costRecords)
        return result
    }

    private func fetchUsageRecords(adminKey: String, startDate: Date, endDate: Date) async throws -> [OpenAIAPIUsageRecord] {
        var records: [OpenAIAPIUsageRecord] = []
        var page: String?

        repeat {
            var queryItems = commonQueryItems(startDate: startDate, endDate: endDate, limit: 31, page: page)
            queryItems.append(URLQueryItem(name: "bucket_width", value: "1d"))
            queryItems.append(URLQueryItem(name: "group_by", value: "model"))
            queryItems.append(URLQueryItem(name: "group_by", value: "project_id"))
            queryItems.append(URLQueryItem(name: "group_by", value: "api_key_id"))

            let response: UsagePageResponse = try await request(
                path: "organization/usage/completions",
                queryItems: queryItems,
                adminKey: adminKey
            )
            records.append(contentsOf: response.data.flatMap { bucket in
                bucket.results.enumerated().map { index, row in
                    let start = Date(timeIntervalSince1970: TimeInterval(bucket.startTime))
                    let end = Date(timeIntervalSince1970: TimeInterval(bucket.endTime))
                    let projectID = normalized(row.projectID, fallback: "unknown project")
                    let apiKeyID = normalized(row.apiKeyID, fallback: "unknown key")
                    let model = normalized(row.model, fallback: "unknown model")
                    return OpenAIAPIUsageRecord(
                        id: "usage-\(bucket.startTime)-\(bucket.endTime)-\(projectID)-\(apiKeyID)-\(model)-\(index)",
                        startTime: start,
                        endTime: end,
                        projectID: projectID,
                        apiKeyID: apiKeyID,
                        model: model,
                        inputTokens: row.inputTokens ?? 0,
                        cachedInputTokens: row.inputCachedTokens ?? 0,
                        outputTokens: row.outputTokens ?? 0,
                        requestCount: row.numModelRequests ?? 0
                    )
                }
            })
            page = response.nextPage
        } while page?.isEmpty == false

        return records
    }

    private func fetchCostRecords(adminKey: String, startDate: Date, endDate: Date) async throws -> [OpenAIAPICostRecord] {
        var records: [OpenAIAPICostRecord] = []
        var page: String?

        repeat {
            var queryItems = commonQueryItems(startDate: startDate, endDate: endDate, limit: 180, page: page)
            queryItems.append(URLQueryItem(name: "group_by", value: "line_item"))
            queryItems.append(URLQueryItem(name: "group_by", value: "project_id"))
            queryItems.append(URLQueryItem(name: "group_by", value: "api_key_id"))

            let response: CostPageResponse = try await request(
                path: "organization/costs",
                queryItems: queryItems,
                adminKey: adminKey
            )
            records.append(contentsOf: response.data.flatMap { bucket in
                bucket.results.enumerated().map { index, row in
                    let start = Date(timeIntervalSince1970: TimeInterval(bucket.startTime))
                    let end = Date(timeIntervalSince1970: TimeInterval(bucket.endTime))
                    let projectID = normalized(row.projectID, fallback: "unknown project")
                    let apiKeyID = normalized(row.apiKeyID, fallback: "unknown key")
                    let lineItem = normalized(row.lineItem, fallback: "unclassified")
                    let currency = row.amount?.currency.lowercased() ?? "usd"
                    return OpenAIAPICostRecord(
                        id: "cost-\(bucket.startTime)-\(bucket.endTime)-\(projectID)-\(apiKeyID)-\(lineItem)-\(index)",
                        startTime: start,
                        endTime: end,
                        projectID: projectID,
                        apiKeyID: apiKeyID,
                        lineItem: lineItem,
                        amountUSD: currency == "usd" ? (row.amount?.value ?? 0) : 0,
                        currency: currency
                    )
                }
            })
            page = response.nextPage
        } while page?.isEmpty == false

        return records
    }

    private func commonQueryItems(startDate: Date, endDate: Date, limit: Int, page: String?) -> [URLQueryItem] {
        var items = [
            URLQueryItem(name: "start_time", value: String(Int(startDate.timeIntervalSince1970))),
            URLQueryItem(name: "end_time", value: String(Int(endDate.timeIntervalSince1970))),
            URLQueryItem(name: "limit", value: String(limit))
        ]
        if let page, !page.isEmpty {
            items.append(URLQueryItem(name: "page", value: page))
        }
        return items
    }

    private func request<Response: Decodable>(path: String, queryItems: [URLQueryItem], adminKey: String) async throws -> Response {
        var components = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)
        components?.queryItems = queryItems
        guard let url = components?.url else { throw OpenAIAPIBillingError.invalidURL }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(adminKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw OpenAIAPIBillingError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            let message = Self.errorMessage(from: data) ?? HTTPURLResponse.localizedString(forStatusCode: httpResponse.statusCode)
            throw OpenAIAPIBillingError.http(statusCode: httpResponse.statusCode, message: message)
        }

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(Response.self, from: data)
    }

    private static func summary(usageRecords: [OpenAIAPIUsageRecord], costRecords: [OpenAIAPICostRecord]) -> OpenAIAPIBillingSummary {
        var summary = OpenAIAPIBillingSummary()
        summary.bucketsFetched = Set(usageRecords.map(\.startTime) + costRecords.map(\.startTime)).count
        summary.usageRows = usageRecords.count
        summary.costRows = costRecords.count
        let dates = usageRecords.flatMap { [$0.startTime, $0.endTime] } + costRecords.flatMap { [$0.startTime, $0.endTime] }
        summary.earliestBucket = dates.min()
        summary.latestBucket = dates.max()

        if costRecords.contains(where: { $0.currency != "usd" }) {
            summary.warnings.append("Some non-USD OpenAI API cost rows were ignored because the dashboard currently totals USD only.")
        }
        if costRecords.isEmpty {
            summary.warnings.append("No billed cost rows returned for this window. The key may lack organization usage permissions or there may be no API spend.")
        }
        return summary
    }

    private static func errorMessage(from data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let error = object["error"] as? [String: Any], let message = error["message"] as? String {
            return message
        }
        return object["message"] as? String
    }

    private func normalized(_ value: String?, fallback: String) -> String {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? fallback : trimmed
    }
}

enum OpenAIAPIBillingError: LocalizedError {
    case missingAdminKey
    case invalidURL
    case invalidResponse
    case http(statusCode: Int, message: String)

    var errorDescription: String? {
        switch self {
        case .missingAdminKey:
            return "Add an OpenAI Admin API key in Settings before refreshing API billing."
        case .invalidURL:
            return "Could not build the OpenAI API billing URL."
        case .invalidResponse:
            return "OpenAI API billing returned an invalid response."
        case .http(let statusCode, let message):
            return "OpenAI API billing request failed (HTTP \(statusCode)): \(message)"
        }
    }
}

private struct UsagePageResponse: Decodable {
    var data: [UsageBucketResponse]
    var nextPage: String?
}

private struct UsageBucketResponse: Decodable {
    var startTime: Int
    var endTime: Int
    var results: [UsageResultResponse]
}

private struct UsageResultResponse: Decodable {
    var inputTokens: Int?
    var outputTokens: Int?
    var inputCachedTokens: Int?
    var numModelRequests: Int?
    var projectID: String?
    var apiKeyID: String?
    var model: String?

    enum CodingKeys: String, CodingKey {
        case inputTokens = "input_tokens"
        case outputTokens = "output_tokens"
        case inputCachedTokens = "input_cached_tokens"
        case numModelRequests = "num_model_requests"
        case projectID = "project_id"
        case apiKeyID = "api_key_id"
        case model
    }
}

private struct CostPageResponse: Decodable {
    var data: [CostBucketResponse]
    var nextPage: String?
}

private struct CostBucketResponse: Decodable {
    var startTime: Int
    var endTime: Int
    var results: [CostResultResponse]
}

private struct CostResultResponse: Decodable {
    var amount: CostAmountResponse?
    var lineItem: String?
    var projectID: String?
    var apiKeyID: String?

    enum CodingKeys: String, CodingKey {
        case amount
        case lineItem = "line_item"
        case projectID = "project_id"
        case apiKeyID = "api_key_id"
    }
}

private struct CostAmountResponse: Decodable {
    var value: Double
    var currency: String
}
