import Foundation

enum AzureUsageTimeWindow: String, CaseIterable, Identifiable, Codable {
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
    case allTime

    var id: String { rawValue }

    var label: String {
        switch self {
        case .last1Hour:
            return "Last 1h"
        case .last3Hours:
            return "Last 3h"
        case .last6Hours:
            return "Last 6h"
        case .last12Hours:
            return "Last 12h"
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
        case .last3Months:
            return "Last 3mo"
        case .last6Months:
            return "Last 6mo"
        case .last1Year:
            return "Last 1y"
        case .sinceDate:
            return "Custom"
        case .allTime:
            return "All time"
        }
    }

    func startDate(now: Date, customStartDate: Date) -> Date? {
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
        case .allTime:
            return nil
        }
    }
}

enum CodexLogUsageProvider: String, Equatable, Codable {
    case azure
    case openai
    case claudeCode = "claude-code"
    case lmStudio = "lm-studio"
    case claudeAzure = "claude-azure"

    var displayName: String {
        switch self {
        case .azure: return "Azure"
        case .openai: return "Codex"
        case .claudeCode: return "Claude Code"
        case .lmStudio: return "LM Studio"
        case .claudeAzure: return "Claude Azure"
        }
    }

    var sessionCounterLabel: String {
        switch self {
        case .azure: return "Azure sessions"
        case .openai: return "Codex sessions"
        case .claudeCode: return "Claude Code sessions"
        case .lmStudio: return "LM Studio chats"
        case .claudeAzure: return "Claude Azure requests"
        }
    }

    /// Title for the money column. Local models cost nothing to run, so the
    /// LM Studio dashboard shows what the same tokens would have cost on a
    /// cloud model instead of an actual spend.
    var costLabel: String {
        switch self {
        case .azure, .openai, .claudeCode, .claudeAzure: return "Est. cost"
        case .lmStudio: return "Est. saved"
        }
    }

    /// Compact form of `costLabel` for table column headers and report rows.
    var costShortLabel: String {
        switch self {
        case .azure, .openai, .claudeCode, .claudeAzure: return "Est."
        case .lmStudio: return "Saved"
        }
    }

    var unknownEndpointWarning: String {
        switch self {
        case .azure:
            return "Azure endpoint/resource could not be reliably discovered from local logs or safe config metadata; grouped as unknown endpoint."
        case .openai:
            return "OpenAI Codex usage excludes Azure sessions; Azure usage remains in the separate Azure dashboard."
        case .claudeCode, .lmStudio, .claudeAzure:
            return ""
        }
    }
}

enum CodexUsageScanMode: String, CaseIterable, Identifiable, Codable {
    case recent1Hour
    case recent3Hours
    case recent6Hours
    case recent12Hours
    case recent24Hours
    case recent3Days
    case recent7Days
    case recent14Days
    case recent30Days
    case recent3Months
    case recent6Months
    case recent1Year
    case sinceDate
    case allTime

    var id: String { rawValue }

    var label: String {
        switch self {
        case .recent1Hour: return "Last 1h"
        case .recent3Hours: return "Last 3h"
        case .recent6Hours: return "Last 6h"
        case .recent12Hours: return "Last 12h"
        case .recent24Hours: return "Last 24h"
        case .recent3Days: return "Last 3d"
        case .recent7Days: return "Last 7d"
        case .recent14Days: return "Last 14d"
        case .recent30Days: return "Last 30d"
        case .recent3Months: return "Last 3mo"
        case .recent6Months: return "Last 6mo"
        case .recent1Year: return "Last 1y"
        case .sinceDate: return "Custom"
        case .allTime: return "All time"
        }
    }

    func startDate(now: Date, customStartDate: Date) -> Date? {
        switch self {
        case .recent1Hour:
            return now.addingTimeInterval(-60 * 60)
        case .recent3Hours:
            return now.addingTimeInterval(-3 * 60 * 60)
        case .recent6Hours:
            return now.addingTimeInterval(-6 * 60 * 60)
        case .recent12Hours:
            return now.addingTimeInterval(-12 * 60 * 60)
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
        case .recent3Months:
            return now.addingTimeInterval(-90 * 24 * 60 * 60)
        case .recent6Months:
            return now.addingTimeInterval(-180 * 24 * 60 * 60)
        case .recent1Year:
            return now.addingTimeInterval(-365 * 24 * 60 * 60)
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
        case .recent1Hour: return .last1Hour
        case .recent3Hours: return .last3Hours
        case .recent6Hours: return .last6Hours
        case .recent12Hours: return .last12Hours
        case .recent24Hours: return .last24Hours
        case .recent3Days: return .last3Days
        case .recent7Days: return .last7Days
        case .recent14Days: return .last14Days
        case .recent30Days: return .last30Days
        case .recent3Months: return .last3Months
        case .recent6Months: return .last6Months
        case .recent1Year: return .last1Year
        case .sinceDate: return .sinceDate
        case .allTime: return .allTime
        }
    }
}

struct AzureUsageTokenTotals: Equatable, Codable {
    var inputTokens = 0
    var cachedInputTokens = 0
    var cacheCreationInputTokens = 0
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
        cacheCreationInputTokens += usage.cacheCreationInputTokens
        uncachedInputTokens += usage.uncachedInputTokens
        outputTokens += usage.outputTokens
        reasoningOutputTokens += usage.reasoningOutputTokens
        totalTokens += usage.totalTokens
        eventCount += 1
        estimatedCostUSD += pricing.estimatedCost(for: usage)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        inputTokens = try container.decodeIfPresent(Int.self, forKey: .inputTokens) ?? 0
        cachedInputTokens = try container.decodeIfPresent(Int.self, forKey: .cachedInputTokens) ?? 0
        cacheCreationInputTokens = try container.decodeIfPresent(Int.self, forKey: .cacheCreationInputTokens) ?? 0
        uncachedInputTokens = try container.decodeIfPresent(Int.self, forKey: .uncachedInputTokens) ?? 0
        outputTokens = try container.decodeIfPresent(Int.self, forKey: .outputTokens) ?? 0
        reasoningOutputTokens = try container.decodeIfPresent(Int.self, forKey: .reasoningOutputTokens) ?? 0
        totalTokens = try container.decodeIfPresent(Int.self, forKey: .totalTokens) ?? 0
        eventCount = try container.decodeIfPresent(Int.self, forKey: .eventCount) ?? 0
        estimatedCostUSD = try container.decodeIfPresent(Double.self, forKey: .estimatedCostUSD) ?? 0
    }

    init() {}
}

struct AzureModelPricing: Equatable, Codable {
    var modelPattern: String
    var displayName: String
    var inputPerMillionUSD: Double
    var cachedInputPerMillionUSD: Double
    var cacheWritePerMillionUSD: Double?
    var outputPerMillionUSD: Double
    var isKnown: Bool

    var effectiveCacheWritePerMillionUSD: Double {
        cacheWritePerMillionUSD ?? inputPerMillionUSD
    }

    func estimatedCost(for usage: AzureTokenUsage) -> Double {
        let uncachedCost = Double(usage.uncachedInputTokens) / 1_000_000 * inputPerMillionUSD
        let cacheWriteCost = Double(usage.cacheCreationInputTokens) / 1_000_000 * effectiveCacheWritePerMillionUSD
        let cachedCost = Double(usage.cachedInputTokens) / 1_000_000 * cachedInputPerMillionUSD
        let outputCost = Double(usage.outputTokens) / 1_000_000 * outputPerMillionUSD
        return uncachedCost + cacheWriteCost + cachedCost + outputCost
    }

    var rateSummary: String {
        guard isKnown else { return "pricing unknown" }
        var parts: [String] = ["in \(Self.usd(inputPerMillionUSD))/M"]
        if let cacheWritePerMillionUSD, cacheWritePerMillionUSD != inputPerMillionUSD {
            parts.append("write \(Self.usd(cacheWritePerMillionUSD))/M")
        }
        parts.append("cached \(Self.usd(cachedInputPerMillionUSD))/M")
        parts.append("out \(Self.usd(outputPerMillionUSD))/M")
        return parts.joined(separator: " · ")
    }

    init(
        modelPattern: String,
        displayName: String,
        inputPerMillionUSD: Double,
        cachedInputPerMillionUSD: Double,
        cacheWritePerMillionUSD: Double? = nil,
        outputPerMillionUSD: Double,
        isKnown: Bool
    ) {
        self.modelPattern = modelPattern
        self.displayName = displayName
        self.inputPerMillionUSD = inputPerMillionUSD
        self.cachedInputPerMillionUSD = cachedInputPerMillionUSD
        self.cacheWritePerMillionUSD = cacheWritePerMillionUSD
        self.outputPerMillionUSD = outputPerMillionUSD
        self.isKnown = isKnown
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        modelPattern = try container.decode(String.self, forKey: .modelPattern)
        displayName = try container.decode(String.self, forKey: .displayName)
        inputPerMillionUSD = try container.decode(Double.self, forKey: .inputPerMillionUSD)
        cachedInputPerMillionUSD = try container.decode(Double.self, forKey: .cachedInputPerMillionUSD)
        cacheWritePerMillionUSD = try container.decodeIfPresent(Double.self, forKey: .cacheWritePerMillionUSD)
        outputPerMillionUSD = try container.decode(Double.self, forKey: .outputPerMillionUSD)
        isKnown = try container.decode(Bool.self, forKey: .isKnown)
    }

    static func defaultPricing(for model: String?, provider: CodexLogUsageProvider = .azure) -> AzureModelPricing {
        let normalized = (model ?? "").lowercased()
            .replacingOccurrences(of: "_", with: "-")
            .replacingOccurrences(of: ".", with: "-")

        if provider == .lmStudio {
            // These are community fine-tunes with no API pricing of their own.
            // Estimate savings against the OpenRouter list price of the base
            // model each is derived from. Models with no API equivalent are left
            // unknown ($0) rather than guessed.
            if normalized.contains("30b-a3b") {
                return AzureModelPricing(
                    modelPattern: "qwen3-30b-a3b-2507",
                    displayName: "Qwen3-30B-A3B-2507 API reference",
                    inputPerMillionUSD: 0.0482,
                    cachedInputPerMillionUSD: 0.0048,
                    cacheWritePerMillionUSD: 0.0482,
                    outputPerMillionUSD: 0.1931,
                    isKnown: true
                )
            }
            if normalized.contains("35b-a3b") {
                return AzureModelPricing(
                    modelPattern: "qwen3.6-35b-a3b",
                    displayName: "Qwen3.6 35B A3B API reference",
                    inputPerMillionUSD: 0.14,
                    cachedInputPerMillionUSD: 0.014,
                    cacheWritePerMillionUSD: 0.14,
                    outputPerMillionUSD: 1.00,
                    isKnown: true
                )
            }
            if normalized.contains("27b") {
                return AzureModelPricing(
                    modelPattern: "qwen3.6-27b",
                    displayName: "Qwen3.6 27B API reference",
                    inputPerMillionUSD: 0.289,
                    cachedInputPerMillionUSD: 0.029,
                    cacheWritePerMillionUSD: 0.289,
                    outputPerMillionUSD: 2.40,
                    isKnown: true
                )
            }
            return AzureModelPricing(
                modelPattern: "lm-studio-local",
                displayName: "Local model (no API equivalent)",
                inputPerMillionUSD: 0,
                cachedInputPerMillionUSD: 0,
                cacheWritePerMillionUSD: nil,
                outputPerMillionUSD: 0,
                isKnown: false
            )
        }

        if provider == .claudeCode || provider == .claudeAzure || normalized.contains("claude-") {
            if normalized.contains("fable") {
                return AzureModelPricing(
                    modelPattern: "claude-fable-5",
                    displayName: "Claude Fable 5",
                    inputPerMillionUSD: 10.00,
                    cachedInputPerMillionUSD: 1.00,
                    cacheWritePerMillionUSD: 12.50,
                    outputPerMillionUSD: 50.00,
                    isKnown: true
                )
            }
            if normalized.contains("opus") {
                let isLegacyOpus = normalized.contains("opus-4-1") || normalized == "claude-opus-4"
                if isLegacyOpus {
                    return AzureModelPricing(
                        modelPattern: "claude-opus-4-1",
                        displayName: "Claude Opus 4.1 (legacy rates)",
                        inputPerMillionUSD: 15.00,
                        cachedInputPerMillionUSD: 1.50,
                        cacheWritePerMillionUSD: 18.75,
                        outputPerMillionUSD: 75.00,
                        isKnown: true
                    )
                }
                return AzureModelPricing(
                    modelPattern: "claude-opus-4-5-plus",
                    displayName: "Claude Opus 4.5+",
                    inputPerMillionUSD: 5.00,
                    cachedInputPerMillionUSD: 0.50,
                    cacheWritePerMillionUSD: 6.25,
                    outputPerMillionUSD: 25.00,
                    isKnown: true
                )
            }
            if normalized.contains("sonnet") {
                return AzureModelPricing(
                    modelPattern: "claude-sonnet-4",
                    displayName: "Claude Sonnet 4.x",
                    inputPerMillionUSD: 3.00,
                    cachedInputPerMillionUSD: 0.30,
                    cacheWritePerMillionUSD: 3.75,
                    outputPerMillionUSD: 15.00,
                    isKnown: true
                )
            }
            if normalized.contains("haiku") {
                return AzureModelPricing(
                    modelPattern: "claude-haiku-4-5",
                    displayName: "Claude Haiku 4.5",
                    inputPerMillionUSD: 1.00,
                    cachedInputPerMillionUSD: 0.10,
                    cacheWritePerMillionUSD: 1.25,
                    outputPerMillionUSD: 5.00,
                    isKnown: true
                )
            }
            if provider == .claudeCode || provider == .claudeAzure {
                return AzureModelPricing(
                    modelPattern: model ?? "claude-unknown",
                    displayName: "Unknown Claude pricing",
                    inputPerMillionUSD: 0,
                    cachedInputPerMillionUSD: 0,
                    cacheWritePerMillionUSD: nil,
                    outputPerMillionUSD: 0,
                    isKnown: false
                )
            }
        }

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

        if normalized.contains("gpt-5-3-codex") || normalized.contains("gpt-53-codex") {
            return AzureModelPricing(
                modelPattern: "gpt-5.3-codex",
                displayName: "GPT-5.3 Codex estimate",
                inputPerMillionUSD: 1.75,
                cachedInputPerMillionUSD: 0.175,
                outputPerMillionUSD: 14.00,
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

        if normalized.contains("gpt-5-2") || normalized.contains("gpt-52") {
            return AzureModelPricing(
                modelPattern: "gpt-5.2",
                displayName: "GPT-5.2 estimate",
                inputPerMillionUSD: 1.75,
                cachedInputPerMillionUSD: 0.175,
                outputPerMillionUSD: 14.00,
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
    var cacheCreationInputTokens: Int
    var outputTokens: Int
    var reasoningOutputTokens: Int
    var totalTokens: Int

    var uncachedInputTokens: Int {
        max(0, inputTokens - cachedInputTokens - cacheCreationInputTokens)
    }

    var isZero: Bool {
        inputTokens == 0 && cachedInputTokens == 0 && cacheCreationInputTokens == 0 && outputTokens == 0 && reasoningOutputTokens == 0
    }

    var signature: String {
        "\(inputTokens),\(cachedInputTokens),\(cacheCreationInputTokens),\(outputTokens),\(reasoningOutputTokens),\(totalTokens)"
    }

    init(
        inputTokens: Int,
        cachedInputTokens: Int,
        cacheCreationInputTokens: Int = 0,
        outputTokens: Int,
        reasoningOutputTokens: Int,
        totalTokens: Int
    ) {
        self.inputTokens = inputTokens
        self.cachedInputTokens = cachedInputTokens
        self.cacheCreationInputTokens = cacheCreationInputTokens
        self.outputTokens = outputTokens
        self.reasoningOutputTokens = reasoningOutputTokens
        self.totalTokens = totalTokens
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        inputTokens = try container.decode(Int.self, forKey: .inputTokens)
        cachedInputTokens = try container.decode(Int.self, forKey: .cachedInputTokens)
        cacheCreationInputTokens = try container.decodeIfPresent(Int.self, forKey: .cacheCreationInputTokens) ?? 0
        outputTokens = try container.decode(Int.self, forKey: .outputTokens)
        reasoningOutputTokens = try container.decode(Int.self, forKey: .reasoningOutputTokens)
        totalTokens = try container.decode(Int.self, forKey: .totalTokens)
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
        projectPath == AzureUsageRecord.unknownProject
            || projectPath == AzureUsageRecord.chatProject
            || projectPath == LMStudioConversationStore.chatProject
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
