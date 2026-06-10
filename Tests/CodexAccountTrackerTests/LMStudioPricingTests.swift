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

    func testPricesAgainstBaseQwenModels() {
        let moe30b = AzureModelPricing.defaultPricing(for: "qwen/qwen3-30b-a3b-2507", provider: .lmStudio)
        XCTAssertTrue(moe30b.isKnown)
        XCTAssertEqual(moe30b.inputPerMillionUSD, 0.0482, accuracy: 0.0001)
        XCTAssertEqual(moe30b.outputPerMillionUSD, 0.1931, accuracy: 0.0001)

        let moe35b = AzureModelPricing.defaultPricing(for: "huihui-qwen3.6-35b-a3b-abliterated-mtp", provider: .lmStudio)
        XCTAssertTrue(moe35b.isKnown)
        XCTAssertEqual(moe35b.inputPerMillionUSD, 0.14, accuracy: 0.0001)
        XCTAssertEqual(moe35b.outputPerMillionUSD, 1.00, accuracy: 0.0001)

        let dense27b = AzureModelPricing.defaultPricing(for: "qwen3.6-27b-uncensored-hauhaucs-balanced:2", provider: .lmStudio)
        XCTAssertTrue(dense27b.isKnown)
        XCTAssertEqual(dense27b.inputPerMillionUSD, 0.289, accuracy: 0.0001)
        XCTAssertEqual(dense27b.outputPerMillionUSD, 2.40, accuracy: 0.0001)
    }

    func testUnknownLocalModelHasNoEstimate() {
        let pricing = AzureModelPricing.defaultPricing(for: "some-random-llama-finetune", provider: .lmStudio)
        XCTAssertFalse(pricing.isKnown)
        let usage = AzureTokenUsage(
            inputTokens: 1_000_000, cachedInputTokens: 0,
            outputTokens: 1_000_000, reasoningOutputTokens: 0, totalTokens: 2_000_000
        )
        XCTAssertEqual(pricing.estimatedCost(for: usage), 0.0, accuracy: 0.0001)
    }

    func test30bSavingsEstimate() {
        let pricing = AzureModelPricing.defaultPricing(for: "qwen/qwen3-30b-a3b-2507", provider: .lmStudio)
        let usage = AzureTokenUsage(
            inputTokens: 1_000_000, cachedInputTokens: 0,
            outputTokens: 1_000_000, reasoningOutputTokens: 0, totalTokens: 2_000_000
        )
        // 1M input * 0.0482 + 1M output * 0.1931
        XCTAssertEqual(pricing.estimatedCost(for: usage), 0.2413, accuracy: 0.0001)
    }
}
