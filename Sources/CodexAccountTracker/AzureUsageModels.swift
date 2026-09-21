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

/// Speed setting a single request ran at. Codex on the ChatGPT plan can run a turn in
/// "Fast" mode, which bills at a multiple of the Standard rate. `.unknown` means the log
/// recorded no setting for that request (older logs), not that Standard was chosen.
enum AzureUsageSpeed: String, Equatable, Hashable, Codable {
    case standard
    case fast
    case unknown
}

/// Rates that replace the base rates once a single request's input exceeds
/// `thresholdInputTokens`. The whole request bills at these rates; OpenAI does not split
/// one request across the two tiers.
struct AzureLongContextRates: Equatable, Codable {
    var thresholdInputTokens: Int
    var inputPerMillionUSD: Double
    var cachedInputPerMillionUSD: Double
    var cacheWritePerMillionUSD: Double?
    var outputPerMillionUSD: Double

    init(
        thresholdInputTokens: Int,
        inputPerMillionUSD: Double,
        cachedInputPerMillionUSD: Double,
        cacheWritePerMillionUSD: Double? = nil,
        outputPerMillionUSD: Double
    ) {
        self.thresholdInputTokens = thresholdInputTokens
        self.inputPerMillionUSD = inputPerMillionUSD
        self.cachedInputPerMillionUSD = cachedInputPerMillionUSD
        self.cacheWritePerMillionUSD = cacheWritePerMillionUSD
        self.outputPerMillionUSD = outputPerMillionUSD
    }
}

/// OpenAI's long-context tier starts above 272,000 input tokens: 272,000 still bills at
/// the short rate, 272,001 bills the whole request at the long rate.
/// Source: https://developers.openai.com/api/docs/pricing (read 2026-09-21).
let azureLongContextThresholdInputTokens = 272_000

struct AzureModelPricing: Equatable, Codable {
    var modelPattern: String
    var displayName: String
    var inputPerMillionUSD: Double
    var cachedInputPerMillionUSD: Double
    var cacheWritePerMillionUSD: Double?
    var outputPerMillionUSD: Double
    /// Rate for the part of a cache write that goes to the 1-hour cache. Anthropic charges
    /// 2x base input for it; the 5-minute cache write keeps `cacheWritePerMillionUSD`.
    var cacheWrite1hPerMillionUSD: Double?
    var longContext: AzureLongContextRates?
    /// Set only where a Fast-mode surcharge is known to apply (Codex on the ChatGPT plan).
    var fastModeMultiplier: Double?
    var isKnown: Bool

    var effectiveCacheWritePerMillionUSD: Double {
        cacheWritePerMillionUSD ?? inputPerMillionUSD
    }

    func estimatedCost(for usage: AzureTokenUsage) -> Double {
        estimatedCost(for: usage, forcingFastMode: usage.speed == .fast)
    }

    /// The same request priced as if it had run in Fast mode. Used to show how much the
    /// requests with no recorded speed setting could be under-counted.
    func estimatedCostIfFast(for usage: AzureTokenUsage) -> Double {
        estimatedCost(for: usage, forcingFastMode: true)
    }

    private func estimatedCost(for usage: AzureTokenUsage, forcingFastMode: Bool) -> Double {
        let inputRate: Double
        let cachedRate: Double
        let cacheWriteRate: Double
        let outputRate: Double
        if let longContext, usage.inputTokens > longContext.thresholdInputTokens {
            inputRate = longContext.inputPerMillionUSD
            cachedRate = longContext.cachedInputPerMillionUSD
            cacheWriteRate = longContext.cacheWritePerMillionUSD ?? longContext.inputPerMillionUSD
            outputRate = longContext.outputPerMillionUSD
        } else {
            inputRate = inputPerMillionUSD
            cachedRate = cachedInputPerMillionUSD
            cacheWriteRate = effectiveCacheWritePerMillionUSD
            outputRate = outputPerMillionUSD
        }

        let oneHourWriteTokens = min(max(usage.cacheCreation1hInputTokens, 0), usage.cacheCreationInputTokens)
        let fiveMinuteWriteTokens = usage.cacheCreationInputTokens - oneHourWriteTokens
        let oneHourWriteRate = cacheWrite1hPerMillionUSD ?? cacheWriteRate

        var cost = Double(usage.uncachedInputTokens) / 1_000_000 * inputRate
        cost += Double(fiveMinuteWriteTokens) / 1_000_000 * cacheWriteRate
        cost += Double(oneHourWriteTokens) / 1_000_000 * oneHourWriteRate
        cost += Double(usage.cachedInputTokens) / 1_000_000 * cachedRate
        cost += Double(usage.outputTokens) / 1_000_000 * outputRate

        if forcingFastMode, let fastModeMultiplier {
            cost *= fastModeMultiplier
        }
        return cost
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
        cacheWrite1hPerMillionUSD: Double? = nil,
        longContext: AzureLongContextRates? = nil,
        fastModeMultiplier: Double? = nil,
        isKnown: Bool
    ) {
        self.modelPattern = modelPattern
        self.displayName = displayName
        self.inputPerMillionUSD = inputPerMillionUSD
        self.cachedInputPerMillionUSD = cachedInputPerMillionUSD
        self.cacheWritePerMillionUSD = cacheWritePerMillionUSD
        self.outputPerMillionUSD = outputPerMillionUSD
        self.cacheWrite1hPerMillionUSD = cacheWrite1hPerMillionUSD
        self.longContext = longContext
        self.fastModeMultiplier = fastModeMultiplier
        self.isKnown = isKnown
    }

    /// Decoded key by key: cached dashboards written before a field existed must keep
    /// decoding, otherwise a whole cached scan is dropped on upgrade.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        modelPattern = try container.decode(String.self, forKey: .modelPattern)
        displayName = try container.decode(String.self, forKey: .displayName)
        inputPerMillionUSD = try container.decode(Double.self, forKey: .inputPerMillionUSD)
        cachedInputPerMillionUSD = try container.decode(Double.self, forKey: .cachedInputPerMillionUSD)
        cacheWritePerMillionUSD = try container.decodeIfPresent(Double.self, forKey: .cacheWritePerMillionUSD)
        outputPerMillionUSD = try container.decode(Double.self, forKey: .outputPerMillionUSD)
        cacheWrite1hPerMillionUSD = try container.decodeIfPresent(Double.self, forKey: .cacheWrite1hPerMillionUSD)
        longContext = try container.decodeIfPresent(AzureLongContextRates.self, forKey: .longContext)
        fastModeMultiplier = try container.decodeIfPresent(Double.self, forKey: .fastModeMultiplier)
        isKnown = try container.decode(Bool.self, forKey: .isKnown)
    }

    static func defaultPricing(for model: String?, provider: CodexLogUsageProvider = .azure) -> AzureModelPricing {
        let normalized = (model ?? "").lowercased()
            .replacingOccurrences(of: "_", with: "-")
            .replacingOccurrences(of: ".", with: "-")

        // DeepSeek (Azure AI Foundry, served through the gateway as claude-deepseek). Placed
        // FIRST so it matches regardless of `provider` — the claude-azure store passes
        // .claudeAzure, which would otherwise fall through to the "Unknown Claude pricing" ($0)
        // branch. Rates = DeepSeek's public deepseek-chat reference ($0.27 in / $0.07 cached /
        // $1.10 out). PROVISIONAL: the host is raising prices — revisit and bump these. Token
        // counts are the gateway's local-tokenizer ESTIMATE (Azure returns usage:null), so the
        // cost shown here is an estimate too.
        if normalized.contains("deepseek") {
            return AzureModelPricing(
                modelPattern: "deepseek-v4-flash",
                displayName: "DeepSeek v4-flash (Azure Foundry)",
                inputPerMillionUSD: 0.27,
                cachedInputPerMillionUSD: 0.07,
                cacheWritePerMillionUSD: nil,
                outputPerMillionUSD: 1.10,
                isKnown: true
            )
        }

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

        // Anthropic rates below are from https://platform.claude.com/docs/en/about-claude/pricing
        // (read 2026-09-21). Two rules from that page drive the shape of these entries:
        //   "1-hour cache write | 2x base input price" — hence cacheWrite1hPerMillionUSD on every
        //   preset, while cacheWritePerMillionUSD stays the 5-minute (1.25x) rate.
        //   "Claude 4.6 and later models … include the full 1M token context window at standard
        //   pricing" — so no Claude preset carries a long-context tier.
        if provider == .claudeCode || provider == .claudeAzure || normalized.contains("claude-") {
            if normalized.contains("fable") || normalized.contains("mythos") {
                // Fable 5.1 and Mythos 5.1 cut the cache-hit rate to 0.025x base input
                // ($0.25/M); the 5.0 generation still reads at 0.1x ($1.00/M).
                let isCheapCacheRead = normalized.contains("fable-5-1") || normalized.contains("mythos-5-1")
                return AzureModelPricing(
                    modelPattern: isCheapCacheRead ? "claude-fable-5-1" : "claude-fable-5",
                    displayName: isCheapCacheRead ? "Claude Fable 5.1 / Mythos 5.1" : "Claude Fable 5 / Mythos 5",
                    inputPerMillionUSD: 10.00,
                    cachedInputPerMillionUSD: isCheapCacheRead ? 0.25 : 1.00,
                    cacheWritePerMillionUSD: 12.50,
                    outputPerMillionUSD: 50.00,
                    cacheWrite1hPerMillionUSD: 20.00,
                    isKnown: true
                )
            }
            if normalized.contains("opus") {
                // Opus 3, Opus 4.0, and Opus 4.1 all bill at the legacy $15/$75 tier.
                // Opus 4.5 through 4.8 and Opus 5 dropped to $5/$25. A dated Opus 4.0
                // snapshot id (`claude-opus-4-20250514`) is legacy too, which a plain
                // equality check against "claude-opus-4" misses.
                let isLegacyOpus = normalized.contains("opus-4-1")
                    || isDatedOrBareOpus4(normalized)
                    || normalized.contains("opus-3")
                    || normalized.contains("3-opus")
                    || normalized.contains("4-opus")
                if isLegacyOpus {
                    return AzureModelPricing(
                        modelPattern: "claude-opus-4-1",
                        displayName: "Claude Opus 4.1 / legacy (4.0, 3)",
                        inputPerMillionUSD: 15.00,
                        cachedInputPerMillionUSD: 1.50,
                        cacheWritePerMillionUSD: 18.75,
                        outputPerMillionUSD: 75.00,
                        cacheWrite1hPerMillionUSD: 30.00,
                        isKnown: true
                    )
                }
                return AzureModelPricing(
                    modelPattern: "claude-opus-4-5-plus",
                    displayName: "Claude Opus 4.5–4.8",
                    inputPerMillionUSD: 5.00,
                    cachedInputPerMillionUSD: 0.50,
                    cacheWritePerMillionUSD: 6.25,
                    outputPerMillionUSD: 25.00,
                    cacheWrite1hPerMillionUSD: 10.00,
                    isKnown: true
                )
            }
            if normalized.contains("sonnet") {
                // Sonnet 5 is cheaper than the 4.x line ($2/$10 vs $3/$15).
                if normalized.contains("sonnet-5") {
                    return AzureModelPricing(
                        modelPattern: "claude-sonnet-5",
                        displayName: "Claude Sonnet 5",
                        inputPerMillionUSD: 2.00,
                        cachedInputPerMillionUSD: 0.20,
                        cacheWritePerMillionUSD: 2.50,
                        outputPerMillionUSD: 10.00,
                        cacheWrite1hPerMillionUSD: 4.00,
                        isKnown: true
                    )
                }
                return AzureModelPricing(
                    modelPattern: "claude-sonnet-4",
                    displayName: "Claude Sonnet 4.x / 3.7",
                    inputPerMillionUSD: 3.00,
                    cachedInputPerMillionUSD: 0.30,
                    cacheWritePerMillionUSD: 3.75,
                    outputPerMillionUSD: 15.00,
                    cacheWrite1hPerMillionUSD: 6.00,
                    isKnown: true
                )
            }
            if normalized.contains("haiku") {
                // Checked before the Haiku 3 branch: "haiku-3-5" also contains "haiku-3".
                if normalized.contains("haiku-3-5") || normalized.contains("3-5-haiku") {
                    return AzureModelPricing(
                        modelPattern: "claude-3-5-haiku",
                        displayName: "Claude Haiku 3.5",
                        inputPerMillionUSD: 0.80,
                        cachedInputPerMillionUSD: 0.08,
                        cacheWritePerMillionUSD: 1.00,
                        outputPerMillionUSD: 4.00,
                        cacheWrite1hPerMillionUSD: 1.60,
                        isKnown: true
                    )
                }
                if normalized.contains("haiku-3") || normalized.contains("3-haiku") {
                    return AzureModelPricing(
                        modelPattern: "claude-3-haiku",
                        displayName: "Claude Haiku 3",
                        inputPerMillionUSD: 0.25,
                        cachedInputPerMillionUSD: 0.03,
                        cacheWritePerMillionUSD: 0.30,
                        outputPerMillionUSD: 1.25,
                        cacheWrite1hPerMillionUSD: 0.50,
                        isKnown: true
                    )
                }
                return AzureModelPricing(
                    modelPattern: "claude-haiku-4-5",
                    displayName: "Claude Haiku 4.5",
                    inputPerMillionUSD: 1.00,
                    cachedInputPerMillionUSD: 0.10,
                    cacheWritePerMillionUSD: 1.25,
                    outputPerMillionUSD: 5.00,
                    cacheWrite1hPerMillionUSD: 2.00,
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

        // Fast mode is a ChatGPT-plan setting on the Codex path; whether Azure Foundry honours
        // or bills `service_tier: priority` is unverified, so no Azure entry carries a
        // multiplier. Source for the rate: learn.chatgpt.com/docs/agent-configuration/speed —
        // "Fast mode consumes credits at 2.5x the Standard rate" (read 2026-09-21).
        let fastMultiplier: Double? = provider == .openai ? 2.5 : nil

        // GPT-6 Astra, short-context Standard rates. OpenAI's list price and Azure Foundry's
        // Global Standard price are identical, so one entry serves both the Codex and Azure
        // dashboards. (Azure US Data Zone deployments bill 10% higher: $11 / $1.10 / $13.75 / $55.)
        // Requests above 272K input tokens do happen on this path (476 of them in September),
        // so the long-context tier is priced rather than assumed unreachable.
        // Source: https://developers.openai.com/api/docs/pricing (read 2026-09-21).
        if normalized.contains("gpt-6-astra") || normalized.contains("gpt6-astra") || normalized == "gpt-6" {
            return AzureModelPricing(
                modelPattern: "gpt-6-astra",
                displayName: "GPT-6 Astra",
                inputPerMillionUSD: 10.00,
                cachedInputPerMillionUSD: 1.00,
                cacheWritePerMillionUSD: 12.50,
                outputPerMillionUSD: 50.00,
                longContext: AzureLongContextRates(
                    thresholdInputTokens: azureLongContextThresholdInputTokens,
                    inputPerMillionUSD: 20.00,
                    cachedInputPerMillionUSD: 2.00,
                    cacheWritePerMillionUSD: 25.00,
                    outputPerMillionUSD: 75.00
                ),
                fastModeMultiplier: fastMultiplier,
                isKnown: true
            )
        }

        if normalized.contains("gpt-5-6-terra") || normalized.contains("gpt-56-terra") {
            return AzureModelPricing(
                modelPattern: "gpt-5.6-terra",
                displayName: "GPT-5.6 Terra",
                inputPerMillionUSD: 2.00,
                cachedInputPerMillionUSD: 0.20,
                cacheWritePerMillionUSD: 2.50,
                outputPerMillionUSD: 12.00,
                longContext: AzureLongContextRates(
                    thresholdInputTokens: azureLongContextThresholdInputTokens,
                    inputPerMillionUSD: 4.00,
                    cachedInputPerMillionUSD: 0.40,
                    cacheWritePerMillionUSD: 5.00,
                    outputPerMillionUSD: 18.00
                ),
                fastModeMultiplier: fastMultiplier,
                isKnown: true
            )
        }

        if normalized.contains("gpt-5-6-luna") || normalized.contains("gpt-56-luna") {
            return AzureModelPricing(
                modelPattern: "gpt-5.6-luna",
                displayName: "GPT-5.6 Luna",
                inputPerMillionUSD: 0.20,
                cachedInputPerMillionUSD: 0.02,
                cacheWritePerMillionUSD: 0.25,
                outputPerMillionUSD: 1.20,
                longContext: AzureLongContextRates(
                    thresholdInputTokens: azureLongContextThresholdInputTokens,
                    inputPerMillionUSD: 0.40,
                    cachedInputPerMillionUSD: 0.04,
                    cacheWritePerMillionUSD: 0.50,
                    outputPerMillionUSD: 1.80
                ),
                fastModeMultiplier: fastMultiplier,
                isKnown: true
            )
        }

        // The bare `gpt-5.6` alias routes to Sol, the flagship tier, so it shares Sol's rates.
        // Sol is on promotional pricing and the page lists no regular price:
        // "GPT-5.6 Sol's promotional pricing is available at least through November 21, 2026."
        // Nothing is invented for the period after that date — the dashboard warns instead
        // (see AzureUsageScanner.dashboard).
        if normalized.contains("gpt-5-6") || normalized == "gpt-56" {
            return AzureModelPricing(
                modelPattern: "gpt-5.6-sol",
                displayName: "GPT-5.6 Sol",
                inputPerMillionUSD: 4.00,
                cachedInputPerMillionUSD: 0.40,
                cacheWritePerMillionUSD: 5.00,
                outputPerMillionUSD: 20.00,
                longContext: AzureLongContextRates(
                    thresholdInputTokens: azureLongContextThresholdInputTokens,
                    inputPerMillionUSD: 8.00,
                    cachedInputPerMillionUSD: 0.80,
                    cacheWritePerMillionUSD: 10.00,
                    outputPerMillionUSD: 30.00
                ),
                fastModeMultiplier: fastMultiplier,
                isKnown: true
            )
        }

        if normalized.contains("gpt-5-5-pro") || normalized.contains("gpt-55-pro") {
            return AzureModelPricing(
                modelPattern: "gpt-5.5-pro",
                displayName: "GPT-5.5 pro",
                inputPerMillionUSD: 30.00,
                cachedInputPerMillionUSD: 3.00,
                outputPerMillionUSD: 180.00,
                longContext: AzureLongContextRates(
                    thresholdInputTokens: azureLongContextThresholdInputTokens,
                    inputPerMillionUSD: 60.00,
                    // ASSUMED: the pricing page lists no cached rate for the pro long-context
                    // tier. Kept at the same 0.1x ratio the short tier uses.
                    cachedInputPerMillionUSD: 6.00,
                    outputPerMillionUSD: 270.00
                ),
                isKnown: true
            )
        }

        if normalized == "gpt-55" || normalized.contains("gpt-5-5") {
            return AzureModelPricing(
                modelPattern: "gpt-5.5",
                displayName: "GPT-5.5",
                inputPerMillionUSD: 5.00,
                cachedInputPerMillionUSD: 0.50,
                outputPerMillionUSD: 30.00,
                longContext: AzureLongContextRates(
                    thresholdInputTokens: azureLongContextThresholdInputTokens,
                    inputPerMillionUSD: 10.00,
                    cachedInputPerMillionUSD: 1.00,
                    outputPerMillionUSD: 45.00
                ),
                fastModeMultiplier: fastMultiplier,
                isKnown: true
            )
        }

        if normalized.contains("gpt-5-4-pro") || normalized.contains("gpt-54-pro") {
            return AzureModelPricing(
                modelPattern: "gpt-5.4-pro",
                displayName: "GPT-5.4 pro",
                inputPerMillionUSD: 30.00,
                cachedInputPerMillionUSD: 3.00,
                outputPerMillionUSD: 180.00,
                isKnown: true
            )
        }

        if normalized.contains("gpt-5-4-mini") || normalized.contains("gpt-54-mini") {
            return AzureModelPricing(
                modelPattern: "gpt-5.4-mini",
                displayName: "GPT-5.4 mini",
                inputPerMillionUSD: 0.75,
                cachedInputPerMillionUSD: 0.075,
                outputPerMillionUSD: 4.50,
                isKnown: true
            )
        }

        if normalized.contains("gpt-5-4-nano") || normalized.contains("gpt-54-nano") {
            return AzureModelPricing(
                modelPattern: "gpt-5.4-nano",
                displayName: "GPT-5.4 nano",
                inputPerMillionUSD: 0.20,
                cachedInputPerMillionUSD: 0.02,
                outputPerMillionUSD: 1.25,
                isKnown: true
            )
        }

        // GPT-5.4's Fast-mode surcharge is 2x, not the 2.5x the newer families carry.
        if normalized.contains("gpt-5-4") || normalized.contains("gpt-54") {
            return AzureModelPricing(
                modelPattern: "gpt-5.4",
                displayName: "GPT-5.4",
                inputPerMillionUSD: 2.50,
                cachedInputPerMillionUSD: 0.25,
                outputPerMillionUSD: 15.00,
                longContext: AzureLongContextRates(
                    thresholdInputTokens: azureLongContextThresholdInputTokens,
                    inputPerMillionUSD: 5.00,
                    cachedInputPerMillionUSD: 0.50,
                    outputPerMillionUSD: 22.50
                ),
                fastModeMultiplier: provider == .openai ? 2.0 : nil,
                isKnown: true
            )
        }

        // GPT-5.3 (codex + chat variants) shares GPT-5.2 rates.
        if normalized.contains("gpt-5-3") || normalized.contains("gpt-53") {
            return AzureModelPricing(
                modelPattern: "gpt-5.3",
                displayName: "GPT-5.3",
                inputPerMillionUSD: 1.75,
                cachedInputPerMillionUSD: 0.175,
                outputPerMillionUSD: 14.00,
                isKnown: true
            )
        }

        if normalized.contains("gpt-5-2-pro") || normalized.contains("gpt-52-pro") {
            return AzureModelPricing(
                modelPattern: "gpt-5.2-pro",
                displayName: "GPT-5.2 pro",
                inputPerMillionUSD: 21.00,
                cachedInputPerMillionUSD: 2.10,
                outputPerMillionUSD: 168.00,
                isKnown: true
            )
        }

        if normalized.contains("gpt-5-2") || normalized.contains("gpt-52") {
            return AzureModelPricing(
                modelPattern: "gpt-5.2",
                displayName: "GPT-5.2",
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

        // GPT-5 / 5.1 base line and its mini/nano/pro tiers. All 5.2+ families
        // are handled above, so only the 5.0/5.1 generation reaches here.
        if provider == .openai, normalized.contains("gpt-5") {
            if normalized.contains("pro") {
                return AzureModelPricing(
                    modelPattern: "gpt-5-pro",
                    displayName: "GPT-5 pro",
                    inputPerMillionUSD: 15.00,
                    cachedInputPerMillionUSD: 1.50,
                    outputPerMillionUSD: 120.00,
                    isKnown: true
                )
            }
            if normalized.contains("mini") {
                return AzureModelPricing(
                    modelPattern: "gpt-5-mini",
                    displayName: "GPT-5 mini",
                    inputPerMillionUSD: 0.25,
                    cachedInputPerMillionUSD: 0.025,
                    outputPerMillionUSD: 2.00,
                    isKnown: true
                )
            }
            if normalized.contains("nano") {
                return AzureModelPricing(
                    modelPattern: "gpt-5-nano",
                    displayName: "GPT-5 nano",
                    inputPerMillionUSD: 0.05,
                    cachedInputPerMillionUSD: 0.005,
                    outputPerMillionUSD: 0.40,
                    isKnown: true
                )
            }
            return AzureModelPricing(
                modelPattern: "gpt-5",
                displayName: "GPT-5 / 5.1",
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

    /// True when the id names Opus 4.0 itself: `opus-4` at the end of the id, or followed by
    /// a dated snapshot suffix (`-` + 8 digits, e.g. `claude-opus-4-20250514`). A version
    /// suffix such as `opus-4-5` or `opus-4-8` is a different, cheaper model and must not match.
    private static func isDatedOrBareOpus4(_ normalized: String) -> Bool {
        var searchStart = normalized.startIndex
        while let range = normalized.range(of: "opus-4", range: searchStart..<normalized.endIndex) {
            let tail = normalized[range.upperBound...]
            if tail.isEmpty {
                return true
            }
            if tail.hasPrefix("-") {
                let afterDash = tail.dropFirst()
                let digits = afterDash.prefix(8)
                let rest = afterDash.dropFirst(8)
                if digits.count == 8,
                   digits.allSatisfy(\.isNumber),
                   rest.first?.isNumber != true {
                    return true
                }
            }
            searchStart = range.upperBound
        }
        return false
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
    /// The part of `cacheCreationInputTokens` written to the 1-hour cache, which bills at a
    /// higher rate than the 5-minute one. 0 when the log recorded no split.
    var cacheCreation1hInputTokens: Int
    var outputTokens: Int
    var reasoningOutputTokens: Int
    var totalTokens: Int
    /// Speed setting this request ran at. `.unknown` for records parsed from logs that
    /// predate the setting being recorded.
    var speed: AzureUsageSpeed

    var uncachedInputTokens: Int {
        max(0, inputTokens - cachedInputTokens - cacheCreationInputTokens)
    }

    // `isZero` and `signature` are dedupe keys: the same request must keep producing the same
    // signature across app versions, so neither ever gains a field.
    var isZero: Bool {
        inputTokens == 0 && cachedInputTokens == 0 && cacheCreationInputTokens == 0 && outputTokens == 0 && reasoningOutputTokens == 0
    }

    var signature: String {
        "\(inputTokens),\(cachedInputTokens),\(cacheCreationInputTokens),\(outputTokens),\(reasoningOutputTokens),\(totalTokens)"
    }

    /// Replaces the output count, keeping `totalTokens` consistent. Used when a Claude Code
    /// record only ever stored a `message_start` placeholder and the output had to be estimated.
    func replacingOutputTokens(with newOutputTokens: Int) -> AzureTokenUsage {
        AzureTokenUsage(
            inputTokens: inputTokens,
            cachedInputTokens: cachedInputTokens,
            cacheCreationInputTokens: cacheCreationInputTokens,
            cacheCreation1hInputTokens: cacheCreation1hInputTokens,
            outputTokens: newOutputTokens,
            reasoningOutputTokens: reasoningOutputTokens,
            totalTokens: inputTokens + newOutputTokens,
            speed: speed
        )
    }

    init(
        inputTokens: Int,
        cachedInputTokens: Int,
        cacheCreationInputTokens: Int = 0,
        cacheCreation1hInputTokens: Int = 0,
        outputTokens: Int,
        reasoningOutputTokens: Int,
        totalTokens: Int,
        speed: AzureUsageSpeed = .standard
    ) {
        self.inputTokens = inputTokens
        self.cachedInputTokens = cachedInputTokens
        self.cacheCreationInputTokens = cacheCreationInputTokens
        self.cacheCreation1hInputTokens = cacheCreation1hInputTokens
        self.outputTokens = outputTokens
        self.reasoningOutputTokens = reasoningOutputTokens
        self.totalTokens = totalTokens
        self.speed = speed
    }

    /// The new per-request fields are decoded with `decodeIfPresent`: the live usage caches are
    /// large JSON files written before these keys existed, and a throwing decode there would
    /// drop the entire cached history, including records whose source log file is gone.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        inputTokens = try container.decode(Int.self, forKey: .inputTokens)
        cachedInputTokens = try container.decode(Int.self, forKey: .cachedInputTokens)
        cacheCreationInputTokens = try container.decodeIfPresent(Int.self, forKey: .cacheCreationInputTokens) ?? 0
        cacheCreation1hInputTokens = try container.decodeIfPresent(Int.self, forKey: .cacheCreation1hInputTokens) ?? 0
        outputTokens = try container.decode(Int.self, forKey: .outputTokens)
        reasoningOutputTokens = try container.decode(Int.self, forKey: .reasoningOutputTokens)
        totalTokens = try container.decode(Int.self, forKey: .totalTokens)
        speed = try container.decodeIfPresent(AzureUsageSpeed.self, forKey: .speed) ?? .unknown
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
    /// Claude Code requests whose final `output_tokens` never reached disk (only a
    /// `message_start` placeholder was recorded). Mostly subagent transcripts.
    var incompleteOutputEvents = 0
    /// Output tokens contributed by estimation rather than measurement, for those requests.
    var estimatedOutputTokens = 0
    var earliestEvent: Date?
    var latestEvent: Date?
    var warnings: [String] = []

    var azureSessions: Int {
        get { providerSessions }
        set { providerSessions = newValue }
    }

    init() {}

    /// Decoded field-by-field so that adding a counter never invalidates an existing cache file.
    /// The synthesised decoder would throw on the first missing key and silently drop the whole
    /// cached scan, forcing a full rescan for every provider.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        filesScanned = try container.decodeIfPresent(Int.self, forKey: .filesScanned) ?? 0
        sessionsScanned = try container.decodeIfPresent(Int.self, forKey: .sessionsScanned) ?? 0
        providerSessions = try container.decodeIfPresent(Int.self, forKey: .providerSessions) ?? 0
        eventsCounted = try container.decodeIfPresent(Int.self, forKey: .eventsCounted) ?? 0
        duplicateEventsSkipped = try container.decodeIfPresent(Int.self, forKey: .duplicateEventsSkipped) ?? 0
        startupReplayEventsSkipped = try container.decodeIfPresent(Int.self, forKey: .startupReplayEventsSkipped) ?? 0
        malformedEventsSkipped = try container.decodeIfPresent(Int.self, forKey: .malformedEventsSkipped) ?? 0
        incompleteOutputEvents = try container.decodeIfPresent(Int.self, forKey: .incompleteOutputEvents) ?? 0
        estimatedOutputTokens = try container.decodeIfPresent(Int.self, forKey: .estimatedOutputTokens) ?? 0
        earliestEvent = try container.decodeIfPresent(Date.self, forKey: .earliestEvent)
        latestEvent = try container.decodeIfPresent(Date.self, forKey: .latestEvent)
        warnings = try container.decodeIfPresent([String].self, forKey: .warnings) ?? []
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
