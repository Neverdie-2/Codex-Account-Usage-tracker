import Foundation

enum AzureUsageTimeWindow: String, CaseIterable, Identifiable, Codable {
    case last24Hours
    case last3Days
    case last7Days
    case last14Days
    case last30Days
    case sinceDate
    case allTime

    var id: String { rawValue }

    var label: String {
        switch self {
        case .last24Hours:
            return "Last 24h"
        case .last3Days:
            return "Last 3d"
        case .last7Days:
            return "Last 7d"
        case .last14Days:
            return "Last 14d"
        case .last30Days:
            return "Last 30d"
        case .sinceDate:
            return "Custom"
        case .allTime:
            return "All time"
        }
    }

    func startDate(now: Date, customStartDate: Date) -> Date? {
        switch self {
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
        case .sinceDate:
            return customStartDate
        case .allTime:
            return nil
        }
    }
}

enum CodexLogUsageProvider: String, Equatable, Codable {
    case azure
    case openai

    var displayName: String {
        switch self {
        case .azure: return "Azure"
        case .openai: return "Codex"
        }
    }

    var sessionCounterLabel: String {
        switch self {
        case .azure: return "Azure sessions"
        case .openai: return "Codex sessions"
        }
    }

    var unknownEndpointWarning: String {
        switch self {
        case .azure:
            return "Azure endpoint/resource could not be reliably discovered from local logs or safe config metadata; grouped as unknown endpoint."
        case .openai:
            return "OpenAI Codex usage excludes Azure sessions; Azure usage remains in the separate Azure dashboard."
        }
    }
}

enum CodexUsageScanMode: String, CaseIterable, Identifiable, Codable {
    case recent24Hours
    case recent3Days
    case recent7Days
    case recent14Days
    case recent30Days
    case sinceDate
    case allTime

    var id: String { rawValue }

    var label: String {
        switch self {
        case .recent24Hours: return "Last 24h"
        case .recent3Days: return "Last 3d"
        case .recent7Days: return "Last 7d"
        case .recent14Days: return "Last 14d"
        case .recent30Days: return "Last 30d"
        case .sinceDate: return "Custom"
        case .allTime: return "All time"
        }
    }

    func startDate(now: Date, customStartDate: Date) -> Date? {
        switch self {
        case .recent24Hours:
            return now.addingTimeInterval(-24 * 60 * 60)
        case .recent3Days:
            return now.addingTimeInterval(-3 * 24 * 60 * 60)
        case .recent7Days:
            return now.addingTimeInterval(-7 * 24 * 60 * 60)
        case .recent14Days:
            return now.addingTimeInterval(-14 * 24 * 60 * 60)
        case .recent30Days:
            return now.addingTimeInterval(-30 * 24 * 60 * 60)
        case .sinceDate:
            return customStartDate
        case .allTime:
            return nil
        }
    }

    var requiresConfirmation: Bool {
        self == .allTime
    }

    var usageWindow: AzureUsageTimeWindow {
        switch self {
        case .recent24Hours: return .last24Hours
        case .recent3Days: return .last3Days
        case .recent7Days: return .last7Days
        case .recent14Days: return .last14Days
        case .recent30Days: return .last30Days
        case .sinceDate: return .sinceDate
        case .allTime: return .allTime
        }
    }
}

struct AzureUsageTokenTotals: Equatable, Codable {
    var inputTokens = 0
    var cachedInputTokens = 0
    var uncachedInputTokens = 0
    var outputTokens = 0
    var reasoningOutputTokens = 0
    var totalTokens = 0
    var eventCount = 0
    var estimatedCostUSD = 0.0

    var isEmpty: Bool {
        eventCount == 0
    }

    mutating func add(_ usage: AzureTokenUsage) {
        add(usage, pricing: AzureModelPricing.defaultPricing(for: nil))
    }

    mutating func add(_ usage: AzureTokenUsage, pricing: AzureModelPricing) {
        inputTokens += usage.inputTokens
        cachedInputTokens += usage.cachedInputTokens
        uncachedInputTokens += usage.uncachedInputTokens
        outputTokens += usage.outputTokens
        reasoningOutputTokens += usage.reasoningOutputTokens
        totalTokens += usage.totalTokens
        eventCount += 1
        estimatedCostUSD += pricing.estimatedCost(for: usage)
    }
}

struct AzureModelPricing: Equatable, Codable {
    var modelPattern: String
    var displayName: String
    var inputPerMillionUSD: Double
    var cachedInputPerMillionUSD: Double
    var outputPerMillionUSD: Double
    var isKnown: Bool

    func estimatedCost(for usage: AzureTokenUsage) -> Double {
        let uncachedCost = Double(usage.uncachedInputTokens) / 1_000_000 * inputPerMillionUSD
        let cachedCost = Double(usage.cachedInputTokens) / 1_000_000 * cachedInputPerMillionUSD
        let outputCost = Double(usage.outputTokens) / 1_000_000 * outputPerMillionUSD
        return uncachedCost + cachedCost + outputCost
    }

    var rateSummary: String {
        guard isKnown else { return "pricing unknown" }
        return "in \(Self.usd(inputPerMillionUSD))/M · cached \(Self.usd(cachedInputPerMillionUSD))/M · out \(Self.usd(outputPerMillionUSD))/M"
    }

    static func defaultPricing(for model: String?, provider: CodexLogUsageProvider = .azure) -> AzureModelPricing {
        if provider == .openai {
            return AzureModelPricing(
                modelPattern: "openai-gpt55",
                displayName: "GPT-5.5 equivalent estimate",
                inputPerMillionUSD: 5.00,
                cachedInputPerMillionUSD: 0.50,
                outputPerMillionUSD: 30.00,
                isKnown: true
            )
        }

        let normalized = (model ?? "").lowercased()
            .replacingOccurrences(of: "_", with: "-")
            .replacingOccurrences(of: ".", with: "-")

        if normalized.contains("gpt-5-5-pro") {
            return AzureModelPricing(
                modelPattern: "gpt-5.5-pro",
                displayName: "GPT-5.5 pro estimate",
                inputPerMillionUSD: 30.00,
                cachedInputPerMillionUSD: 30.00,
                outputPerMillionUSD: 180.00,
                isKnown: true
            )
        }

        if normalized == "gpt-55" || normalized.contains("gpt-5-5") {
            return AzureModelPricing(
                modelPattern: "gpt-5.5",
                displayName: "GPT-5.5 estimate",
                inputPerMillionUSD: 5.00,
                cachedInputPerMillionUSD: 0.50,
                outputPerMillionUSD: 30.00,
                isKnown: true
            )
        }

        if normalized.contains("gpt-5-4-mini") || normalized.contains("gpt-54-mini") {
            return AzureModelPricing(
                modelPattern: "gpt-5.4-mini",
                displayName: "GPT-5.4 mini estimate",
                inputPerMillionUSD: 0.75,
                cachedInputPerMillionUSD: 0.075,
                outputPerMillionUSD: 4.50,
                isKnown: true
            )
        }

        if normalized.contains("gpt-5-4") || normalized.contains("gpt-54") {
            return AzureModelPricing(
                modelPattern: "gpt-5.4",
                displayName: "GPT-5.4 estimate",
                inputPerMillionUSD: 2.50,
                cachedInputPerMillionUSD: 0.25,
                outputPerMillionUSD: 15.00,
                isKnown: true
            )
        }

        if provider == .openai, normalized.contains("codex-auto") {
            return AzureModelPricing(
                modelPattern: "codex-auto-review",
                displayName: "Codex auto-review",
                inputPerMillionUSD: 0,
                cachedInputPerMillionUSD: 0,
                outputPerMillionUSD: 0,
                isKnown: true
            )
        }

        if provider == .openai, normalized.contains("gpt-5") {
            return AzureModelPricing(
                modelPattern: "gpt-5",
                displayName: "GPT-5 estimate",
                inputPerMillionUSD: 1.25,
                cachedInputPerMillionUSD: 0.125,
                outputPerMillionUSD: 10.00,
                isKnown: true
            )
        }

        return AzureModelPricing(
            modelPattern: model ?? "unknown",
            displayName: "Unknown pricing",
            inputPerMillionUSD: 0,
            cachedInputPerMillionUSD: 0,
            outputPerMillionUSD: 0,
            isKnown: false
        )
    }

    private static func usd(_ value: Double) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencySymbol = "$"
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 2
        return formatter.string(from: NSNumber(value: value)) ?? "$\(String(format: "%.2f", value))"
    }
}

struct AzureTokenUsage: Equatable, Hashable, Codable {
    var inputTokens: Int
    var cachedInputTokens: Int
    var outputTokens: Int
    var reasoningOutputTokens: Int
    var totalTokens: Int

    var uncachedInputTokens: Int {
        max(0, inputTokens - cachedInputTokens)
    }

    var isZero: Bool {
        inputTokens == 0 && cachedInputTokens == 0 && outputTokens == 0 && reasoningOutputTokens == 0
    }

    var signature: String {
        "\(inputTokens),\(cachedInputTokens),\(outputTokens),\(reasoningOutputTokens),\(totalTokens)"
    }
}

struct AzureUsageRecord: Equatable, Identifiable, Codable {
    var id: String
    var sessionID: String
    var filePath: String
    var timestamp: Date
    var endpoint: String
    var resource: String
    var deployment: String
    var model: String
    var projectPath: String
    var projectName: String
    var usage: AzureTokenUsage

    init(
        id: String,
        sessionID: String,
        filePath: String,
        timestamp: Date,
        endpoint: String,
        resource: String,
        deployment: String,
        model: String,
        projectPath: String,
        projectName: String? = nil,
        usage: AzureTokenUsage
    ) {
        self.id = id
        self.sessionID = sessionID
        self.filePath = filePath
        self.timestamp = timestamp
        self.endpoint = endpoint
        self.resource = resource
        self.deployment = deployment
        self.model = model
        self.projectPath = Self.normalizedProjectPath(projectPath)
        self.projectName = Self.normalizedProjectName(projectName, projectPath: self.projectPath)
        self.usage = usage
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        sessionID = try container.decode(String.self, forKey: .sessionID)
        filePath = try container.decode(String.self, forKey: .filePath)
        timestamp = try container.decode(Date.self, forKey: .timestamp)
        endpoint = try container.decode(String.self, forKey: .endpoint)
        resource = try container.decode(String.self, forKey: .resource)
        deployment = try container.decode(String.self, forKey: .deployment)
        model = try container.decode(String.self, forKey: .model)
        projectPath = Self.normalizedProjectPath(try container.decodeIfPresent(String.self, forKey: .projectPath))
        projectName = Self.normalizedProjectName(try container.decodeIfPresent(String.self, forKey: .projectName), projectPath: projectPath)
        usage = try container.decode(AzureTokenUsage.self, forKey: .usage)
    }

    static let unknownProject = "unknown project"
    static let chatProject = "Codex chats"

    static func normalizedProjectPath(_ value: String?) -> String {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? unknownProject : trimmed
    }

    static func projectName(for projectPath: String) -> String {
        guard projectPath != unknownProject else { return unknownProject }
        let trimmed = projectPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !trimmed.isEmpty else { return projectPath }
        return URL(fileURLWithPath: trimmed).lastPathComponent
    }

    private static func normalizedProjectName(_ value: String?, projectPath: String) -> String {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? projectName(for: projectPath) : trimmed
    }
}

struct AzureUsageGroup: Equatable, Identifiable, Codable {
    var id: String { key }
    var key: String
    var endpoint: String
    var resource: String
    var deployment: String
    var model: String
    var pricing: AzureModelPricing
    var totals: AzureUsageTokenTotals
}

struct AzureUsageProjectModelGroup: Equatable, Identifiable, Codable {
    var id: String { model }
    var model: String
    var pricing: AzureModelPricing
    var totals: AzureUsageTokenTotals
}

struct AzureUsageProjectSessionGroup: Equatable, Identifiable, Codable {
    var id: String { sessionID }
    var sessionID: String
    var filePath: String
    var models: [String]
    var totals: AzureUsageTokenTotals
    var earliestActivity: Date?
    var latestActivity: Date?

    var shortSessionID: String {
        String(sessionID.prefix(8))
    }

    var primaryModel: String {
        models.first ?? AzureUsageScanner.unknownModel
    }

    var modelSummary: String {
        if models.isEmpty { return AzureUsageScanner.unknownModel }
        if models.count == 1 { return models[0] }
        return "\(models[0]) +\(models.count - 1)"
    }

    var sourceFileName: String {
        URL(fileURLWithPath: filePath).lastPathComponent
    }
}

struct AzureUsageProjectGroup: Equatable, Identifiable, Codable {
    var id: String { projectPath }
    var projectPath: String
    var projectName: String
    var totals: AzureUsageTokenTotals
    var sessionCount: Int
    var earliestActivity: Date?
    var latestActivity: Date?
    var byModel: [AzureUsageProjectModelGroup]
    var sessions: [AzureUsageProjectSessionGroup]

    var isChatGroup: Bool {
        projectPath == AzureUsageRecord.unknownProject || projectPath == AzureUsageRecord.chatProject
    }
}

struct AzureUsageScanSummary: Equatable, Codable {
    var filesScanned = 0
    var sessionsScanned = 0
    var providerSessions = 0
    var eventsCounted = 0
    var duplicateEventsSkipped = 0
    var startupReplayEventsSkipped = 0
    var malformedEventsSkipped = 0
    var earliestEvent: Date?
    var latestEvent: Date?
    var warnings: [String] = []

    var azureSessions: Int {
        get { providerSessions }
        set { providerSessions = newValue }
    }
}

struct AzureUsageScanResult: Equatable, Codable {
    var provider: CodexLogUsageProvider = .azure
    var records: [AzureUsageRecord] = []
    var summary = AzureUsageScanSummary()

    static let empty = AzureUsageScanResult()
}

struct AzureUsageDashboard: Equatable, Codable {
    var totals = AzureUsageTokenTotals()
    var byEndpointDeployment: [AzureUsageGroup] = []
    var byModel: [AzureUsageGroup] = []
    var byProject: [AzureUsageProjectGroup] = []
    var summary = AzureUsageScanSummary()

    static let empty = AzureUsageDashboard()
}
