import XCTest
@testable import CodexAccountTracker

/// Rates typed from https://developers.openai.com/api/docs/pricing (read 2026-09-21),
/// USD per 1M tokens as input / cached / cache-write / output.
final class GPT56PricingTests: XCTestCase {
    func testSolRates() {
        // Sol is on promotional pricing: 4 / 0.40 / 5 / 20.
        let sol = AzureModelPricing.defaultPricing(for: "gpt-5.6-sol", provider: .openai)
        XCTAssertTrue(sol.isKnown)
        XCTAssertEqual(sol.modelPattern, "gpt-5.6-sol")
        XCTAssertEqual(sol.inputPerMillionUSD, 4.00, accuracy: 0.0001)
        XCTAssertEqual(sol.cachedInputPerMillionUSD, 0.40, accuracy: 0.0001)
        XCTAssertEqual(sol.cacheWritePerMillionUSD ?? 0, 5.00, accuracy: 0.0001)
        XCTAssertEqual(sol.outputPerMillionUSD, 20.00, accuracy: 0.0001)
    }

    func testTerraRates() {
        // Terra: 2 / 0.20 / 2.50 / 12.
        let terra = AzureModelPricing.defaultPricing(for: "gpt-5.6-terra", provider: .openai)
        XCTAssertTrue(terra.isKnown)
        XCTAssertEqual(terra.modelPattern, "gpt-5.6-terra")
        XCTAssertEqual(terra.inputPerMillionUSD, 2.00, accuracy: 0.0001)
        XCTAssertEqual(terra.cachedInputPerMillionUSD, 0.20, accuracy: 0.0001)
        XCTAssertEqual(terra.cacheWritePerMillionUSD ?? 0, 2.50, accuracy: 0.0001)
        XCTAssertEqual(terra.outputPerMillionUSD, 12.00, accuracy: 0.0001)
    }

    func testLunaRates() {
        // Luna: 0.20 / 0.02 / 0.25 / 1.20.
        let luna = AzureModelPricing.defaultPricing(for: "gpt-5.6-luna", provider: .openai)
        XCTAssertTrue(luna.isKnown)
        XCTAssertEqual(luna.modelPattern, "gpt-5.6-luna")
        XCTAssertEqual(luna.inputPerMillionUSD, 0.20, accuracy: 0.0001)
        XCTAssertEqual(luna.cachedInputPerMillionUSD, 0.02, accuracy: 0.0001)
        XCTAssertEqual(luna.cacheWritePerMillionUSD ?? 0, 0.25, accuracy: 0.0001)
        XCTAssertEqual(luna.outputPerMillionUSD, 1.20, accuracy: 0.0001)
    }

    func testBareAliasRoutesToSolRates() {
        // OpenAI routes the bare `gpt-5.6` alias to Sol.
        let bare = AzureModelPricing.defaultPricing(for: "gpt-5.6", provider: .openai)
        XCTAssertEqual(bare.modelPattern, "gpt-5.6-sol")
        XCTAssertEqual(bare.inputPerMillionUSD, 4.00, accuracy: 0.0001)
        XCTAssertEqual(bare.outputPerMillionUSD, 20.00, accuracy: 0.0001)
    }

    func testDatedSnapshotStillMatches() {
        let dated = AzureModelPricing.defaultPricing(for: "gpt-5.6-terra-2026-07-09", provider: .openai)
        XCTAssertEqual(dated.modelPattern, "gpt-5.6-terra")
    }

    func testGPT6AstraRatesMatchOnBothCodexAndAzure() {
        // OpenAI list price and Azure Foundry Global Standard are identical for Astra.
        for provider in [CodexLogUsageProvider.openai, .azure] {
            for name in ["gpt-6-astra", "gpt-6-astra-2026-09-03"] {
                let astra = AzureModelPricing.defaultPricing(for: name, provider: provider)
                XCTAssertTrue(astra.isKnown)
                XCTAssertEqual(astra.modelPattern, "gpt-6-astra")
                XCTAssertEqual(astra.inputPerMillionUSD, 10.00, accuracy: 0.0001)
                XCTAssertEqual(astra.cachedInputPerMillionUSD, 1.00, accuracy: 0.0001)
                XCTAssertEqual(astra.cacheWritePerMillionUSD ?? 0, 12.50, accuracy: 0.0001)
                XCTAssertEqual(astra.outputPerMillionUSD, 50.00, accuracy: 0.0001)
            }
        }
    }

    func testOlderGPT5FamiliesUnaffected() {
        XCTAssertEqual(AzureModelPricing.defaultPricing(for: "gpt-5.5", provider: .openai).modelPattern, "gpt-5.5")
        XCTAssertEqual(AzureModelPricing.defaultPricing(for: "gpt-5.4-mini", provider: .openai).modelPattern, "gpt-5.4-mini")
        XCTAssertEqual(AzureModelPricing.defaultPricing(for: "gpt-5", provider: .openai).modelPattern, "gpt-5")
    }
}
