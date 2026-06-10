import XCTest
@testable import CodexAccountTracker

final class LMStudioPricingTests: XCTestCase {
    func testLMStudioProviderLabels() {
        XCTAssertEqual(CodexLogUsageProvider.lmStudio.rawValue, "lm-studio")
        XCTAssertEqual(CodexLogUsageProvider.lmStudio.displayName, "LM Studio")
        XCTAssertEqual(CodexLogUsageProvider.lmStudio.sessionCounterLabel, "LM Studio chats")
        XCTAssertEqual(CodexLogUsageProvider.lmStudio.costLabel, "Est. saved")
        XCTAssertEqual(CodexLogUsageProvider.claudeCode.costLabel, "Est. cost")
    }

    func testLMStudioPricingUsesSonnetReferenceRates() {
        let pricing = AzureModelPricing.defaultPricing(
            for: "qwen3.6-27b-uncensored-hauhaucs-balanced",
            provider: .lmStudio
        )
        XCTAssertTrue(pricing.isKnown)
        XCTAssertEqual(pricing.inputPerMillionUSD, 3.00)
        XCTAssertEqual(pricing.outputPerMillionUSD, 15.00)
    }

    func testLMStudioSavingsEstimate() {
        let pricing = AzureModelPricing.defaultPricing(for: "any-local-model", provider: .lmStudio)
        let usage = AzureTokenUsage(
            inputTokens: 1_000_000,
            cachedInputTokens: 0,
            outputTokens: 1_000_000,
            reasoningOutputTokens: 0,
            totalTokens: 2_000_000
        )
        XCTAssertEqual(pricing.estimatedCost(for: usage), 18.00, accuracy: 0.001)
    }
}
