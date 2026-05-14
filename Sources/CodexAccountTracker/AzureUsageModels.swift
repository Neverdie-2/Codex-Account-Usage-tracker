import Foundation

enum AzureUsageTimeWindow: String, CaseIterable, Identifiable {
    case last24Hours
    case last7Days
    case sinceDate
    case allTime

    var id: String { rawValue }

    var label: String {
        switch self {
        case .last24Hours:
            return "Last 24h"
        case .last7Days:
            return "Last 7d"
        case .sinceDate:
            return "Since date"
        case .allTime:
            return "All time"
        }
    }

    func startDate(now: Date, customStartDate: Date) -> Date? {
        switch self {
        case .last24Hours:
            return now.addingTimeInterval(-24 * 60 * 60)
        case .last7Days:
            return now.addingTimeInterval(-7 * 24 * 60 * 60)
        case .sinceDate:
            return customStartDate
        case .allTime:
            return nil
        }
    }
}

enum CodexLogUsageProvider: String, Equatable {
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

enum CodexUsageScanMode: String, CaseIterable, Identifiable {
    case recent24Hours
    case recent7Days
    case allTime

    var id: String { rawValue }

    var label: String {
        switch self {
        case .recent24Hours: return "Last 24h"
        case .recent7Days: return "Last 7d"
        case .allTime: return "All time"
        }
    }

    func startDate(now: Date) -> Date? {
        switch self {
        case .recent24Hours:
            return now.addingTimeInterval(-24 * 60 * 60)
        case .recent7Days:
            return now.addingTimeInterval(-7 * 24 * 60 * 60)
        case .allTime:
            return nil
        }
    }

    var requiresConfirmation: Bool {
        self == .allTime
    }
}

struct AzureUsageTokenTotals: Equatable {
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

struct AzureModelPricing: Equatable {
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
        value.formatted(.currency(code: "USD").precision(.fractionLength(2)))
    }
}

struct AzureTokenUsage: Equatable, Hashable {
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

struct AzureUsageRecord: Equatable, Identifiable {
    var id: String
    var sessionID: String
    var filePath: String
    var timestamp: Date
    var endpoint: String
    var resource: String
    var deployment: String
    var model: String
    var usage: AzureTokenUsage
}

struct AzureUsageGroup: Equatable, Identifiable {
    var id: String { key }
    var key: String
    var endpoint: String
    var resource: String
    var deployment: String
    var model: String
    var pricing: AzureModelPricing
    var totals: AzureUsageTokenTotals
}

struct AzureUsageScanSummary: Equatable {
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

struct AzureUsageScanResult: Equatable {
    var provider: CodexLogUsageProvider = .azure
    var records: [AzureUsageRecord] = []
    var summary = AzureUsageScanSummary()

    static let empty = AzureUsageScanResult()
}

struct AzureUsageDashboard: Equatable {
    var totals = AzureUsageTokenTotals()
    var byEndpointDeployment: [AzureUsageGroup] = []
    var byModel: [AzureUsageGroup] = []
    var summary = AzureUsageScanSummary()

    static let empty = AzureUsageDashboard()
}
