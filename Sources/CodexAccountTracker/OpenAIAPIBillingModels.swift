import Foundation

enum OpenAIAPIUsageWindow: String, CaseIterable, Identifiable, Codable {
    case last1Hour
    case last3Hours
    case last6Hours
    case last12Hours
    case last24Hours
    case last3Days
    case last7Days
    case last14Days
    case last30Days
    case last3Months
    case last6Months
    case last1Year
    case sinceDate

    var id: String { rawValue }

    var label: String {
        switch self {
        case .last1Hour: return "Last 1h"
        case .last3Hours: return "Last 3h"
        case .last6Hours: return "Last 6h"
        case .last12Hours: return "Last 12h"
        case .last24Hours: return "Last 24h"
        case .last3Days: return "Last 3d"
        case .last7Days: return "Last 7d"
        case .last14Days: return "Last 14d"
        case .last30Days: return "Last 30d"
        case .last3Months: return "Last 3mo"
        case .last6Months: return "Last 6mo"
        case .last1Year: return "Last 1y"
        case .sinceDate: return "Custom"
        }
    }

    func startDate(now: Date, customStartDate: Date) -> Date {
        switch self {
        case .last1Hour:
            return now.addingTimeInterval(-60 * 60)
        case .last3Hours:
            return now.addingTimeInterval(-3 * 60 * 60)
        case .last6Hours:
            return now.addingTimeInterval(-6 * 60 * 60)
        case .last12Hours:
            return now.addingTimeInterval(-12 * 60 * 60)
        case .last24Hours:
            return now.addingTimeInterval(-24 * 60 * 60)
        case .last3Days:
            return now.addingTimeInterval(-3 * 24 * 60 * 60)
        case .last7Days:
            return now.addingTimeInterval(-7 * 24 * 60 * 60)
        case .last14Days:
            return now.addingTimeInterval(-14 * 24 * 60 * 60)
        case .last30Days:
            return now.addingTimeInterval(-30 * 24 * 60 * 60)
        case .last3Months:
            return now.addingTimeInterval(-90 * 24 * 60 * 60)
        case .last6Months:
            return now.addingTimeInterval(-180 * 24 * 60 * 60)
        case .last1Year:
            return now.addingTimeInterval(-365 * 24 * 60 * 60)
        case .sinceDate:
            return customStartDate
        }
    }
}

struct OpenAIAPIBillingResult: Equatable, Codable {
    var usageRecords: [OpenAIAPIUsageRecord] = []
    var costRecords: [OpenAIAPICostRecord] = []
    var summary = OpenAIAPIBillingSummary()

    static let empty = OpenAIAPIBillingResult()
}

struct OpenAIAPIUsageRecord: Equatable, Identifiable, Codable {
    var id: String
    var startTime: Date
    var endTime: Date
    var projectID: String
    var apiKeyID: String
    var model: String
    var inputTokens: Int
    var cachedInputTokens: Int
    var outputTokens: Int
    var requestCount: Int

    var totalTokens: Int {
        inputTokens + outputTokens
    }
}

struct OpenAIAPICostRecord: Equatable, Identifiable, Codable {
    var id: String
    var startTime: Date
    var endTime: Date
    var projectID: String
    var apiKeyID: String
    var lineItem: String
    var amountUSD: Double
    var currency: String
}

struct OpenAIAPIBillingSummary: Equatable, Codable {
    var bucketsFetched = 0
    var usageRows = 0
    var costRows = 0
    var earliestBucket: Date?
    var latestBucket: Date?
    var warnings: [String] = []
}

struct OpenAIAPIBillingDashboard: Equatable {
    var totalCostUSD = 0.0
    var inputTokens = 0
    var cachedInputTokens = 0
    var outputTokens = 0
    var totalTokens = 0
    var requestCount = 0
    var byModel: [OpenAIAPIUsageGroup] = []
    var byProject: [OpenAIAPICostGroup] = []
    var byAPIKey: [OpenAIAPICostGroup] = []
    var byLineItem: [OpenAIAPICostGroup] = []
    var summary = OpenAIAPIBillingSummary()

    static let empty = OpenAIAPIBillingDashboard()

    static func make(from result: OpenAIAPIBillingResult) -> OpenAIAPIBillingDashboard {
        var dashboard = OpenAIAPIBillingDashboard()
        dashboard.summary = result.summary
        dashboard.totalCostUSD = result.costRecords.reduce(0) { $0 + $1.amountUSD }

        var modelGroups: [String: OpenAIAPIUsageGroup] = [:]
        for record in result.usageRecords {
            dashboard.inputTokens += record.inputTokens
            dashboard.cachedInputTokens += record.cachedInputTokens
            dashboard.outputTokens += record.outputTokens
            dashboard.totalTokens += record.totalTokens
            dashboard.requestCount += record.requestCount

            var group = modelGroups[record.model] ?? OpenAIAPIUsageGroup(
                key: record.model,
                inputTokens: 0,
                cachedInputTokens: 0,
                outputTokens: 0,
                totalTokens: 0,
                requestCount: 0
            )
            group.inputTokens += record.inputTokens
            group.cachedInputTokens += record.cachedInputTokens
            group.outputTokens += record.outputTokens
            group.totalTokens += record.totalTokens
            group.requestCount += record.requestCount
            modelGroups[record.model] = group
        }

        dashboard.byModel = modelGroups.values.sorted { lhs, rhs in
            if lhs.totalTokens != rhs.totalTokens { return lhs.totalTokens > rhs.totalTokens }
            return lhs.key.localizedCaseInsensitiveCompare(rhs.key) == .orderedAscending
        }
        dashboard.byProject = costGroups(from: result.costRecords, keyPath: \.projectID)
        dashboard.byAPIKey = costGroups(from: result.costRecords, keyPath: \.apiKeyID)
        dashboard.byLineItem = costGroups(from: result.costRecords, keyPath: \.lineItem)
        return dashboard
    }

    private static func costGroups(from records: [OpenAIAPICostRecord], keyPath: KeyPath<OpenAIAPICostRecord, String>) -> [OpenAIAPICostGroup] {
        var groups: [String: Double] = [:]
        for record in records {
            groups[record[keyPath: keyPath], default: 0] += record.amountUSD
        }
        return groups.map { key, value in
            OpenAIAPICostGroup(key: key, label: key, amountUSD: value)
        }
        .sorted { lhs, rhs in
            if lhs.amountUSD != rhs.amountUSD { return lhs.amountUSD > rhs.amountUSD }
            return lhs.label.localizedCaseInsensitiveCompare(rhs.label) == .orderedAscending
        }
    }
}

struct OpenAIAPIUsageGroup: Equatable, Identifiable {
    var id: String { key }
    var key: String
    var inputTokens: Int
    var cachedInputTokens: Int
    var outputTokens: Int
    var totalTokens: Int
    var requestCount: Int
}

struct OpenAIAPICostGroup: Equatable, Identifiable {
    var id: String { key }
    var key: String
    var label: String
    var amountUSD: Double
}
