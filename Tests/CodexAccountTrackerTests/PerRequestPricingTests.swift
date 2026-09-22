import Foundation
import XCTest
@testable import CodexAccountTracker

/// Per-request pricing: the long-context tier, Fast mode, and the 1-hour cache write.
///
/// Every expected number below is typed from the vendor's own pricing page, not read back
/// from the implementation's constants:
///   OpenAI     — https://developers.openai.com/api/docs/pricing (read 2026-09-21)
///   Anthropic  — https://platform.claude.com/docs/en/about-claude/pricing (read 2026-09-21)
///   Fast mode  — learn.chatgpt.com/docs/agent-configuration/speed (read 2026-09-21):
///                "Fast mode consumes credits at 2.5x the Standard rate"
final class PerRequestPricingTests: XCTestCase {
    private func price(_ model: String, _ provider: CodexLogUsageProvider = .openai) -> AzureModelPricing {
        AzureModelPricing.defaultPricing(for: model, provider: provider)
    }

    private func usage(
        input: Int,
        cached: Int = 0,
        cacheWrite: Int = 0,
        cacheWrite1h: Int = 0,
        output: Int = 0,
        speed: AzureUsageSpeed = .standard
    ) -> AzureTokenUsage {
        AzureTokenUsage(
            inputTokens: input,
            cachedInputTokens: cached,
            cacheCreationInputTokens: cacheWrite,
            cacheCreation1hInputTokens: cacheWrite1h,
            outputTokens: output,
            reasoningOutputTokens: 0,
            totalTokens: input + output,
            speed: speed
        )
    }

    // MARK: - Long context

    func testAstraLongContextBoundaryIs272000() {
        let astra = price("gpt-6-astra")
        // 272,000 input tokens still bills short: 272,000 / 1M * $10 = $2.72.
        XCTAssertEqual(astra.estimatedCost(for: usage(input: 272_000)), 2.72, accuracy: 0.000001)
        // 272,001 puts the WHOLE request on the long tier: 272,001 / 1M * $20 = $5.44002.
        XCTAssertEqual(astra.estimatedCost(for: usage(input: 272_001)), 5.44002, accuracy: 0.000001)
    }

    func testAstraShortAndLongComponentsAndMixedTotals() {
        let astra = price("gpt-6-astra")

        // Short request, 200,000 input = 50,000 uncached + 50,000 cache-write + 100,000 cached,
        // plus 10,000 output. Short rates 10 / 1 / 12.50 / 50:
        // 0.50 + 0.625 + 0.10 + 0.50 = $1.725.
        let shortUsage = usage(input: 200_000, cached: 100_000, cacheWrite: 50_000, output: 10_000)
        XCTAssertEqual(astra.estimatedCost(for: shortUsage), 1.725, accuracy: 0.000001)

        // Long request, 300,000 input = 150,000 uncached + 50,000 cache-write + 100,000 cached,
        // plus 10,000 output. Long rates 20 / 2 / 25 / 75:
        // 3.00 + 1.25 + 0.20 + 0.75 = $5.20.
        let longUsage = usage(input: 300_000, cached: 100_000, cacheWrite: 50_000, output: 10_000)
        XCTAssertEqual(astra.estimatedCost(for: longUsage), 5.20, accuracy: 0.000001)

        // The two tiers mix inside one window: $1.725 + $5.20 = $6.925.
        var totals = AzureUsageTokenTotals()
        totals.add(shortUsage, pricing: astra)
        totals.add(longUsage, pricing: astra)
        XCTAssertEqual(totals.eventCount, 2)
        XCTAssertEqual(totals.estimatedCostUSD, 6.925, accuracy: 0.000001)
    }

    func testLongContextRatesForTheGPT56Family() {
        // Long tiers (> 272K input), USD/1M: input / cached / cache-write / output.
        let expected: [(String, Double, Double, Double?, Double)] = [
            ("gpt-5.6-sol", 8.00, 0.80, 10.00, 30.00),
            ("gpt-5.6-terra", 4.00, 0.40, 5.00, 18.00),
            ("gpt-5.6-luna", 0.40, 0.04, 0.50, 1.80),
            ("gpt-5.5", 10.00, 1.00, nil, 45.00),
            ("gpt-5.4", 5.00, 0.50, nil, 22.50)
        ]
        for (model, input, cached, cacheWrite, output) in expected {
            guard let long = price(model).longContext else {
                XCTFail("\(model) should carry a long-context tier")
                continue
            }
            XCTAssertEqual(long.thresholdInputTokens, 272_000, "\(model) threshold")
            XCTAssertEqual(long.inputPerMillionUSD, input, accuracy: 0.0001, "\(model) long input")
            XCTAssertEqual(long.cachedInputPerMillionUSD, cached, accuracy: 0.0001, "\(model) long cached")
            XCTAssertEqual(long.outputPerMillionUSD, output, accuracy: 0.0001, "\(model) long output")
            if let cacheWrite {
                XCTAssertEqual(long.cacheWritePerMillionUSD ?? 0, cacheWrite, accuracy: 0.0001, "\(model) long cache-write")
            }
        }
        // GPT-5.5 pro's long tier: 60 / 6.00 (assumed — the page lists no cached price) / 270.
        let pro = price("gpt-5.5-pro").longContext
        XCTAssertEqual(pro?.inputPerMillionUSD ?? 0, 60.00, accuracy: 0.0001)
        XCTAssertEqual(pro?.cachedInputPerMillionUSD ?? 0, 6.00, accuracy: 0.0001)
        XCTAssertEqual(pro?.outputPerMillionUSD ?? 0, 270.00, accuracy: 0.0001)
    }

    func testClaudeHasNoLongContextTier() {
        // "Claude 4.6 and later models … include the full 1M token context window at
        // standard pricing", so a 1M-token Claude request bills at the base rate.
        for model in ["claude-fable-5-1", "claude-opus-4-8", "claude-sonnet-5"] {
            XCTAssertNil(price(model, .claudeCode).longContext, model)
        }
    }

    // MARK: - Fast mode

    func testFastModeIsBilledOnCodexButNotOnAzure() {
        let request = usage(input: 200_000, cached: 100_000, cacheWrite: 50_000, output: 10_000, speed: .fast)
        // Standard cost of this request is $1.725; Fast mode on the ChatGPT plan is 2.5x.
        XCTAssertEqual(price("gpt-6-astra", .openai).estimatedCost(for: request), 4.3125, accuracy: 0.000001)
        // Azure Foundry is not known to bill the priority tier, so it stays at 1x.
        XCTAssertEqual(price("gpt-6-astra", .azure).estimatedCost(for: request), 1.725, accuracy: 0.000001)
        XCTAssertNil(price("gpt-6-astra", .azure).fastModeMultiplier)
    }

    func testFastModeStacksOnTopOfLongContextRates() {
        // 300,000 uncached input + 1,000,000 output, all at Astra's long rates
        // ($20 in, $75 out): $6.00 + $75.00 = $81.00, then 2.5x for Fast = $202.50.
        let request = usage(input: 300_000, output: 1_000_000, speed: .fast)
        XCTAssertEqual(price("gpt-6-astra", .openai).estimatedCost(for: request), 202.50, accuracy: 0.000001)
    }

    func testGPT54FastModeIsTwoTimes() {
        // 100,000 uncached input at GPT-5.4's short rate of $2.50/M = $0.25; Fast is 2x here.
        let request = usage(input: 100_000, speed: .fast)
        XCTAssertEqual(price("gpt-5.4", .openai).estimatedCost(for: request), 0.50, accuracy: 0.000001)
        XCTAssertEqual(price("gpt-5.4", .openai).fastModeMultiplier ?? 0, 2.0, accuracy: 0.0001)
    }

    func testEstimatedCostIfFastPricesAStandardRequestAtTheFastRate() {
        let request = usage(input: 100_000, speed: .standard)
        let astra = price("gpt-6-astra", .openai)
        // 100,000 / 1M * $10 = $1.00 standard, $2.50 if it had run in Fast mode.
        XCTAssertEqual(astra.estimatedCost(for: request), 1.00, accuracy: 0.000001)
        XCTAssertEqual(astra.estimatedCostIfFast(for: request), 2.50, accuracy: 0.000001)
        // A model with no known surcharge is unchanged by the Fast variant.
        let claude = price("claude-sonnet-5", .claudeCode)
        XCTAssertEqual(claude.estimatedCostIfFast(for: request), claude.estimatedCost(for: request), accuracy: 0.000001)
    }

    // MARK: - GPT-5.6 short prices

    func testGPT56ShortPrices() {
        // USD/1M: input / cached / cache-write / output.
        let expected: [(String, Double, Double, Double, Double)] = [
            ("gpt-5.6-sol", 4.00, 0.40, 5.00, 20.00),
            ("gpt-5.6-terra", 2.00, 0.20, 2.50, 12.00),
            ("gpt-5.6-luna", 0.20, 0.02, 0.25, 1.20),
            // The bare alias routes to Sol.
            ("gpt-5.6", 4.00, 0.40, 5.00, 20.00)
        ]
        for (model, input, cached, cacheWrite, output) in expected {
            let rates = price(model)
            XCTAssertEqual(rates.inputPerMillionUSD, input, accuracy: 0.0001, "\(model) input")
            XCTAssertEqual(rates.cachedInputPerMillionUSD, cached, accuracy: 0.0001, "\(model) cached")
            XCTAssertEqual(rates.cacheWritePerMillionUSD ?? 0, cacheWrite, accuracy: 0.0001, "\(model) cache-write")
            XCTAssertEqual(rates.outputPerMillionUSD, output, accuracy: 0.0001, "\(model) output")
        }
    }

    // MARK: - Claude cache writes

    func testFable51CacheWriteSplit() {
        let fable = price("claude-fable-5.1", .claudeCode)
        // 1M tokens written to the 1-hour cache at 2x base input ($20/M) = $20.00.
        XCTAssertEqual(
            fable.estimatedCost(for: usage(input: 1_000_000, cacheWrite: 1_000_000, cacheWrite1h: 1_000_000)),
            20.00,
            accuracy: 0.000001
        )
        // The same 1M written to the 5-minute cache at 1.25x base input ($12.50/M) = $12.50.
        XCTAssertEqual(
            fable.estimatedCost(for: usage(input: 1_000_000, cacheWrite: 1_000_000)),
            12.50,
            accuracy: 0.000001
        )
        // Mixed: 600K one-hour ($12.00) + 400K five-minute ($5.00) = $17.00.
        XCTAssertEqual(
            fable.estimatedCost(for: usage(input: 1_000_000, cacheWrite: 1_000_000, cacheWrite1h: 600_000)),
            17.00,
            accuracy: 0.000001
        )
    }

    func testOneHourCacheWriteRateIsTwiceBaseInputForEveryClaudePreset() {
        // "1-hour cache write | 2x base input price".
        let expected: [(String, Double)] = [
            ("claude-fable-5-1", 20.00),
            ("claude-mythos-5-1", 20.00),
            ("claude-opus-4-8", 10.00),
            ("claude-opus-5", 10.00),
            ("claude-opus-4-20250514", 30.00),
            ("claude-sonnet-5", 4.00),
            ("claude-sonnet-4-6", 6.00),
            ("claude-haiku-4-5", 2.00),
            ("claude-3-5-haiku-20241022", 1.60),
            ("claude-3-haiku-20240307", 0.50)
        ]
        for (model, rate) in expected {
            XCTAssertEqual(
                price(model, .claudeCode).cacheWrite1hPerMillionUSD ?? 0,
                rate,
                accuracy: 0.0001,
                "\(model) 1-hour cache write"
            )
        }
    }

    func testFable51CacheReadIsCheaperThanFable5() {
        // Fable 5.1 / Mythos 5.1 read at 0.025x base input ($0.25/M); the 5.0 line reads at
        // 0.1x ($1.00/M). 1M cached tokens, nothing else.
        let cachedRequest = usage(input: 1_000_000, cached: 1_000_000)
        XCTAssertEqual(price("claude-fable-5.1", .claudeCode).estimatedCost(for: cachedRequest), 0.25, accuracy: 0.000001)
        XCTAssertEqual(price("claude-mythos-5.1", .claudeCode).estimatedCost(for: cachedRequest), 0.25, accuracy: 0.000001)
        XCTAssertEqual(price("claude-fable-5", .claudeCode).estimatedCost(for: cachedRequest), 1.00, accuracy: 0.000001)
        XCTAssertEqual(price("claude-mythos-5", .claudeCode).estimatedCost(for: cachedRequest), 1.00, accuracy: 0.000001)
    }

    func testMythosSharesFableRates() {
        // "mythos" was not matched at all before; it prices like Fable.
        let mythos = price("claude-mythos-5", .claudeCode)
        XCTAssertTrue(mythos.isKnown)
        XCTAssertEqual(mythos.inputPerMillionUSD, 10.00, accuracy: 0.0001)
        XCTAssertEqual(mythos.cacheWritePerMillionUSD ?? 0, 12.50, accuracy: 0.0001)
        XCTAssertEqual(mythos.outputPerMillionUSD, 50.00, accuracy: 0.0001)
    }

    func testDatedOpus4IsLegacyButVersionedOpus4IsNot() {
        // 15 / 1.50 / 18.75 / 75 for Opus 4.0 and 4.1, dated snapshots included.
        for model in ["claude-opus-4-20250514", "claude-opus-4", "claude-opus-4-1-20250805"] {
            let legacy = price(model, .claudeCode)
            XCTAssertEqual(legacy.inputPerMillionUSD, 15.00, accuracy: 0.0001, model)
            XCTAssertEqual(legacy.cachedInputPerMillionUSD, 1.50, accuracy: 0.0001, model)
            XCTAssertEqual(legacy.cacheWritePerMillionUSD ?? 0, 18.75, accuracy: 0.0001, model)
            XCTAssertEqual(legacy.outputPerMillionUSD, 75.00, accuracy: 0.0001, model)
        }
        // 5 / 25 for 4.5 through 4.8 and Opus 5, dated snapshots included.
        for model in ["claude-opus-4-5", "claude-opus-4-8", "claude-opus-4-5-20251101", "claude-opus-5"] {
            let modern = price(model, .claudeCode)
            XCTAssertEqual(modern.inputPerMillionUSD, 5.00, accuracy: 0.0001, model)
            XCTAssertEqual(modern.outputPerMillionUSD, 25.00, accuracy: 0.0001, model)
        }
    }

    func testHaiku35IsCheckedBeforeHaiku3() {
        // Haiku 3.5: 0.80 / 0.08 / 1.00 / 4.
        for model in ["claude-haiku-3-5", "claude-3-5-haiku-20241022"] {
            let haiku35 = price(model, .claudeCode)
            XCTAssertEqual(haiku35.inputPerMillionUSD, 0.80, accuracy: 0.0001, model)
            XCTAssertEqual(haiku35.cachedInputPerMillionUSD, 0.08, accuracy: 0.0001, model)
            XCTAssertEqual(haiku35.cacheWritePerMillionUSD ?? 0, 1.00, accuracy: 0.0001, model)
            XCTAssertEqual(haiku35.outputPerMillionUSD, 4.00, accuracy: 0.0001, model)
        }
        // Haiku 3 keeps its own, much cheaper rates.
        XCTAssertEqual(price("claude-3-haiku-20240307", .claudeCode).inputPerMillionUSD, 0.25, accuracy: 0.0001)
    }

    // MARK: - Decoding old caches

    func testTokenUsageWrittenBeforeTheNewFieldsStillDecodes() throws {
        // Shape of a record in the live usage cache written by the previous build.
        let json = """
        {"inputTokens":1000,"cachedInputTokens":200,"cacheCreationInputTokens":300,\
        "outputTokens":50,"reasoningOutputTokens":10,"totalTokens":1050}
        """
        let decoded = try JSONDecoder().decode(AzureTokenUsage.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.inputTokens, 1000)
        XCTAssertEqual(decoded.cacheCreationInputTokens, 300)
        XCTAssertEqual(decoded.cacheCreation1hInputTokens, 0)
        XCTAssertEqual(decoded.speed, .unknown)
        // The dedupe keys must read exactly as they did before the upgrade.
        XCTAssertEqual(decoded.signature, "1000,200,300,50,10,1050")
        XCTAssertFalse(decoded.isZero)
    }

    func testModelPricingWrittenBeforeTheNewFieldsStillDecodes() throws {
        let json = """
        {"modelPattern":"gpt-6-astra","displayName":"GPT-6 Astra","inputPerMillionUSD":10,\
        "cachedInputPerMillionUSD":1,"cacheWritePerMillionUSD":12.5,"outputPerMillionUSD":50,\
        "isKnown":true}
        """
        let decoded = try JSONDecoder().decode(AzureModelPricing.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.modelPattern, "gpt-6-astra")
        XCTAssertNil(decoded.longContext)
        XCTAssertNil(decoded.fastModeMultiplier)
        XCTAssertNil(decoded.cacheWrite1hPerMillionUSD)
        XCTAssertEqual(decoded.outputPerMillionUSD, 50.00, accuracy: 0.0001)
    }

    func testTokenUsageRoundTripsTheNewFields() throws {
        let original = usage(input: 100, cacheWrite: 40, cacheWrite1h: 25, output: 5, speed: .fast)
        let data = try JSONEncoder().encode(original)
        XCTAssertEqual(try JSONDecoder().decode(AzureTokenUsage.self, from: data), original)
    }

    // MARK: - Dashboard warnings

    func testUnknownSpeedWarningCountsRequestsAndTheirFastModeGap() {
        // Each request: 100,000 uncached input ($1.00) + 10,000 output ($0.50) = $1.50.
        // Fast would be 2.5x, so each unknown request could be $2.25 more; two of them = $4.50.
        let unknown = usage(input: 100_000, output: 10_000, speed: .unknown)
        let known = usage(input: 100_000, output: 10_000, speed: .standard)
        var result = AzureUsageScanResult(provider: .openai)
        result.records = [
            record(id: "a", model: "gpt-6-astra", usage: unknown, timestamp: Date(timeIntervalSince1970: 1_780_000_000)),
            record(id: "b", model: "gpt-6-astra", usage: unknown, timestamp: Date(timeIntervalSince1970: 1_780_000_001)),
            record(id: "c", model: "gpt-6-astra", usage: known, timestamp: Date(timeIntervalSince1970: 1_780_000_002))
        ]

        let dashboard = AzureUsageScanner.dashboard(from: result, window: .allTime, customStartDate: Date())
        let warning = dashboard.summary.warnings.first { $0.contains("no recorded speed setting") }
        XCTAssertEqual(
            warning,
            "2 requests have no recorded speed setting and are priced at Standard; "
            + "if all of them ran in Fast mode the estimate would be $4.50 higher."
        )
        // The three requests are still counted and priced at Standard.
        XCTAssertEqual(dashboard.summary.eventsCounted, 3)
        XCTAssertEqual(dashboard.totals.estimatedCostUSD, 4.50, accuracy: 0.000001)
    }

    func testUnknownSpeedWarningIsAbsentWhenThePresetHasNoFastRate() {
        var result = AzureUsageScanResult(provider: .claudeCode)
        result.records = [
            record(
                id: "a",
                model: "claude-sonnet-5",
                usage: usage(input: 100_000, output: 10_000, speed: .unknown),
                timestamp: Date(timeIntervalSince1970: 1_780_000_000)
            )
        ]
        let dashboard = AzureUsageScanner.dashboard(from: result, window: .allTime, customStartDate: Date())
        XCTAssertNil(dashboard.summary.warnings.first { $0.contains("no recorded speed setting") })
    }

    func testSolPromotionalPricingWarningFiresOnlyAfterNovember21() {
        func warnings(at timestamp: Date) -> [String] {
            var result = AzureUsageScanResult(provider: .openai)
            result.records = [
                record(id: "sol", model: "gpt-5.6-sol", usage: usage(input: 10, output: 1), timestamp: timestamp)
            ]
            return AzureUsageScanner.dashboard(from: result, window: .allTime, customStartDate: Date()).summary.warnings
        }

        let expected = "GPT-5.6 Sol is priced at its promotional rate, which OpenAI guaranteed only through November 21, 2026 — check the current price."
        let beforeEnd = ISO8601DateFormatter().date(from: "2026-11-21T12:00:00Z")!
        let afterEnd = ISO8601DateFormatter().date(from: "2026-11-22T00:00:01Z")!
        XCTAssertFalse(warnings(at: beforeEnd).contains(expected))
        XCTAssertTrue(warnings(at: afterEnd).contains(expected))
    }

    private func record(id: String, model: String, usage: AzureTokenUsage, timestamp: Date) -> AzureUsageRecord {
        AzureUsageRecord(
            id: id,
            sessionID: "session",
            filePath: "/tmp/\(id).jsonl",
            timestamp: timestamp,
            endpoint: "OpenAI",
            resource: "Codex local logs",
            deployment: model,
            model: model,
            projectPath: "/tmp/project",
            usage: usage
        )
    }
}

// MARK: - Cost breakdown (base / long-context / Fast mode)

extension PerRequestPricingTests {
    func testCostBreakdownSplitsBaseLongContextAndFastAndAddsUpToTheTotal() {
        // Astra, https://developers.openai.com/api/docs/pricing (read 2026-09-21):
        // short $10 in / $50 out; long (>272,000 input) $20 in / $75 out; Codex Fast = 2.5x.
        // a) 100,000 in + 10,000 out, standard        → $1.00 + $0.50 = $1.50 base, no uplifts
        // b) 300,000 in + 10,000 out, standard        → base $3.00 + $0.50 = $3.50; long $6.00 + $0.75 = $6.75 → +$3.25
        // c) 300,000 in + 10,000 out, FAST            → long $6.75, fast $16.875 → long +$3.25, fast +$10.125
        // d) 100,000 in + 10,000 out, speed unknown   → $1.50 base; fast would add $2.25
        let mk: (Int, AzureUsageSpeed) -> AzureTokenUsage = { input, speed in
            self.usage(input: input, output: 10_000, speed: speed)
        }
        var result = AzureUsageScanResult(provider: .openai)
        result.records = [
            record(id: "a", model: "gpt-6-astra", usage: mk(100_000, .standard), timestamp: Date(timeIntervalSince1970: 1_780_000_000)),
            record(id: "b", model: "gpt-6-astra", usage: mk(300_000, .standard), timestamp: Date(timeIntervalSince1970: 1_780_000_001)),
            record(id: "c", model: "gpt-6-astra", usage: mk(300_000, .fast), timestamp: Date(timeIntervalSince1970: 1_780_000_002)),
            record(id: "d", model: "gpt-6-astra", usage: mk(100_000, .unknown), timestamp: Date(timeIntervalSince1970: 1_780_000_003))
        ]

        let b = AzureUsageScanner.dashboard(from: result, window: .allTime, customStartDate: Date()).costBreakdown
        XCTAssertEqual(b.baseUSD, 1.50 + 3.50 + 3.50 + 1.50, accuracy: 0.000001)
        XCTAssertEqual(b.longContextRequestCount, 2)
        XCTAssertEqual(b.longContextExtraUSD, 3.25 + 3.25, accuracy: 0.000001)
        XCTAssertEqual(b.fastModeRequestCount, 1)
        XCTAssertEqual(b.fastModeExtraUSD, 10.125, accuracy: 0.000001)
        XCTAssertEqual(b.unknownSpeedRequestCount, 1)
        XCTAssertEqual(b.unknownSpeedExtraUSD, 2.25, accuracy: 0.000001)
        // Input cardinality: the three parts reproduce the dashboard total exactly.
        let total = AzureUsageScanner.dashboard(from: result, window: .allTime, customStartDate: Date()).totals.estimatedCostUSD
        XCTAssertEqual(b.baseUSD + b.longContextExtraUSD + b.fastModeExtraUSD, total, accuracy: 0.000001)
        XCTAssertEqual(total, 1.50 + 6.75 + 16.875 + 1.50, accuracy: 0.000001)
        XCTAssertTrue(b.hasUplifts)
    }

    func testCostBreakdownHasNoUpliftsForProvidersWithoutThem() {
        // Claude Code presets carry no long-context tier and no Fast multiplier.
        var result = AzureUsageScanResult(provider: .claudeCode)
        result.records = [
            record(id: "a", model: "claude-fable-5-1", usage: usage(input: 400_000, output: 10_000, speed: .standard), timestamp: Date(timeIntervalSince1970: 1_780_000_000))
        ]
        let b = AzureUsageScanner.dashboard(from: result, window: .allTime, customStartDate: Date()).costBreakdown
        XCTAssertFalse(b.hasUplifts)
        XCTAssertEqual(b.baseUSD, 4.00 + 0.50, accuracy: 0.000001)
    }

    func testCostBreakdownDecodesFromJSONWithoutTheNewKeys() throws {
        let decoded = try JSONDecoder().decode(AzureUsageCostBreakdown.self, from: Data("{}".utf8))
        XCTAssertEqual(decoded, AzureUsageCostBreakdown())
    }
}
