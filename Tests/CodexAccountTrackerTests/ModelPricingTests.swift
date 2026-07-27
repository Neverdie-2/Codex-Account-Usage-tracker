import XCTest
@testable import CodexAccountTracker

/// Verifies the curated pricing table covers every current GPT and Claude
/// family, using rates cross-checked against the LiteLLM community price file
/// (2026-07). `in/out` are per-1M-token USD.
final class ModelPricingTests: XCTestCase {
    private func price(_ model: String, _ provider: CodexLogUsageProvider = .openai) -> AzureModelPricing {
        AzureModelPricing.defaultPricing(for: model, provider: provider)
    }

    private func assertRates(
        _ p: AzureModelPricing,
        pattern: String,
        input: Double,
        output: Double,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertTrue(p.isKnown, "\(pattern) should be known", file: file, line: line)
        XCTAssertEqual(p.modelPattern, pattern, file: file, line: line)
        XCTAssertEqual(p.inputPerMillionUSD, input, accuracy: 0.0001, "\(pattern) input", file: file, line: line)
        XCTAssertEqual(p.outputPerMillionUSD, output, accuracy: 0.0001, "\(pattern) output", file: file, line: line)
    }

    // MARK: GPT-5 families

    func testGPT5Families() {
        assertRates(price("gpt-5"), pattern: "gpt-5", input: 1.25, output: 10.00)
        assertRates(price("gpt-5.1"), pattern: "gpt-5", input: 1.25, output: 10.00)
        assertRates(price("gpt-5-codex"), pattern: "gpt-5", input: 1.25, output: 10.00)
        assertRates(price("gpt-5.1-codex-max"), pattern: "gpt-5", input: 1.25, output: 10.00)
        assertRates(price("gpt-5-mini"), pattern: "gpt-5-mini", input: 0.25, output: 2.00)
        assertRates(price("gpt-5.1-codex-mini"), pattern: "gpt-5-mini", input: 0.25, output: 2.00)
        assertRates(price("gpt-5-nano"), pattern: "gpt-5-nano", input: 0.05, output: 0.40)
        assertRates(price("gpt-5-pro"), pattern: "gpt-5-pro", input: 15.00, output: 120.00)

        assertRates(price("gpt-5.2"), pattern: "gpt-5.2", input: 1.75, output: 14.00)
        assertRates(price("gpt-5.2-codex"), pattern: "gpt-5.2", input: 1.75, output: 14.00)
        assertRates(price("gpt-5.2-pro"), pattern: "gpt-5.2-pro", input: 21.00, output: 168.00)

        assertRates(price("gpt-5.3-codex"), pattern: "gpt-5.3", input: 1.75, output: 14.00)
        assertRates(price("gpt-5.3-chat-latest"), pattern: "gpt-5.3", input: 1.75, output: 14.00)

        assertRates(price("gpt-5.4"), pattern: "gpt-5.4", input: 2.50, output: 15.00)
        assertRates(price("gpt-5.4-mini"), pattern: "gpt-5.4-mini", input: 0.75, output: 4.50)
        assertRates(price("gpt-5.4-nano"), pattern: "gpt-5.4-nano", input: 0.20, output: 1.25)
        assertRates(price("gpt-5.4-pro"), pattern: "gpt-5.4-pro", input: 30.00, output: 180.00)

        assertRates(price("gpt-5.5"), pattern: "gpt-5.5", input: 5.00, output: 30.00)
        assertRates(price("gpt-5.5-pro"), pattern: "gpt-5.5-pro", input: 30.00, output: 180.00)
        // gpt-5.5-pro cached read is 3.00, not the old 30.00 bug.
        XCTAssertEqual(price("gpt-5.5-pro").cachedInputPerMillionUSD, 3.00, accuracy: 0.0001)

        assertRates(price("gpt-5.6-sol"), pattern: "gpt-5.6-sol", input: 5.00, output: 30.00)
        assertRates(price("gpt-5.6-terra"), pattern: "gpt-5.6-terra", input: 2.50, output: 15.00)
        assertRates(price("gpt-5.6-luna"), pattern: "gpt-5.6-luna", input: 1.00, output: 6.00)
    }

    func testGPTNonHyphenatedAliases() {
        // These bare aliases appear verbatim in Codex session logs.
        assertRates(price("gpt-55"), pattern: "gpt-5.5", input: 5.00, output: 30.00)
        assertRates(price("gpt-56"), pattern: "gpt-5.6-sol", input: 5.00, output: 30.00)
        assertRates(price("gpt-52"), pattern: "gpt-5.2", input: 1.75, output: 14.00)
    }

    func testCodexAutoReviewIsFree() {
        let p = price("codex-auto-review")
        XCTAssertTrue(p.isKnown)
        XCTAssertEqual(p.modelPattern, "codex-auto-review")
        XCTAssertEqual(p.inputPerMillionUSD, 0, accuracy: 0.0001)
        XCTAssertEqual(p.outputPerMillionUSD, 0, accuracy: 0.0001)
    }

    // MARK: Claude families

    func testClaudeFamilies() {
        assertRates(price("claude-fable-5", .claudeCode), pattern: "claude-fable-5", input: 10.00, output: 50.00)

        assertRates(price("claude-opus-4-8", .claudeCode), pattern: "claude-opus-4-5-plus", input: 5.00, output: 25.00)
        // The 1M-context beta flag Claude Code appends must not change the rate.
        assertRates(price("claude-opus-4-8[1m]", .claudeCode), pattern: "claude-opus-4-5-plus", input: 5.00, output: 25.00)
        assertRates(price("claude-opus-4-5", .claudeCode), pattern: "claude-opus-4-5-plus", input: 5.00, output: 25.00)

        assertRates(price("claude-opus-4-1-20250805", .claudeCode), pattern: "claude-opus-4-1", input: 15.00, output: 75.00)
        assertRates(price("claude-4-opus-20250514", .claudeCode), pattern: "claude-opus-4-1", input: 15.00, output: 75.00)
        assertRates(price("claude-3-opus-20240229", .claudeCode), pattern: "claude-opus-4-1", input: 15.00, output: 75.00)

        assertRates(price("claude-sonnet-5", .claudeCode), pattern: "claude-sonnet-5", input: 2.00, output: 10.00)
        assertRates(price("claude-sonnet-4-6", .claudeCode), pattern: "claude-sonnet-4", input: 3.00, output: 15.00)
        assertRates(price("claude-3-7-sonnet-20250219", .claudeCode), pattern: "claude-sonnet-4", input: 3.00, output: 15.00)

        assertRates(price("claude-haiku-4-5-20251001", .claudeCode), pattern: "claude-haiku-4-5", input: 1.00, output: 5.00)
        assertRates(price("claude-3-haiku-20240307", .claudeCode), pattern: "claude-3-haiku", input: 0.25, output: 1.25)
    }

    func testClaudeBareAliases() {
        assertRates(price("opus", .claudeCode), pattern: "claude-opus-4-5-plus", input: 5.00, output: 25.00)
        assertRates(price("sonnet", .claudeCode), pattern: "claude-sonnet-4", input: 3.00, output: 15.00)
        assertRates(price("haiku", .claudeCode), pattern: "claude-haiku-4-5", input: 1.00, output: 5.00)
        assertRates(price("fable", .claudeCode), pattern: "claude-fable-5", input: 10.00, output: 50.00)
    }

    func testCacheWriteRatesForNewerModels() {
        // 5.6 and current Claude models carry an explicit cache-write premium.
        XCTAssertEqual(price("gpt-5.6-terra").cacheWritePerMillionUSD ?? 0, 3.125, accuracy: 0.0001)
        XCTAssertEqual(price("claude-sonnet-5", .claudeCode).cacheWritePerMillionUSD ?? 0, 2.50, accuracy: 0.0001)
        XCTAssertEqual(price("claude-opus-4-8", .claudeCode).cacheWritePerMillionUSD ?? 0, 6.25, accuracy: 0.0001)
    }
}
