import XCTest
@testable import CodexAccountTracker

final class GPT56PricingTests: XCTestCase {
    func testSolRates() {
        let sol = AzureModelPricing.defaultPricing(for: "gpt-5.6-sol", provider: .openai)
        XCTAssertTrue(sol.isKnown)
        XCTAssertEqual(sol.modelPattern, "gpt-5.6-sol")
        XCTAssertEqual(sol.inputPerMillionUSD, 5.00, accuracy: 0.0001)
        XCTAssertEqual(sol.cachedInputPerMillionUSD, 0.50, accuracy: 0.0001)
        XCTAssertEqual(sol.cacheWritePerMillionUSD ?? 0, 6.25, accuracy: 0.0001)
        XCTAssertEqual(sol.outputPerMillionUSD, 30.00, accuracy: 0.0001)
    }

    func testTerraRates() {
        let terra = AzureModelPricing.defaultPricing(for: "gpt-5.6-terra", provider: .openai)
        XCTAssertTrue(terra.isKnown)
        XCTAssertEqual(terra.modelPattern, "gpt-5.6-terra")
        XCTAssertEqual(terra.inputPerMillionUSD, 2.50, accuracy: 0.0001)
        XCTAssertEqual(terra.cachedInputPerMillionUSD, 0.25, accuracy: 0.0001)
        XCTAssertEqual(terra.cacheWritePerMillionUSD ?? 0, 3.125, accuracy: 0.0001)
        XCTAssertEqual(terra.outputPerMillionUSD, 15.00, accuracy: 0.0001)
    }

    func testLunaRates() {
        let luna = AzureModelPricing.defaultPricing(for: "gpt-5.6-luna", provider: .openai)
        XCTAssertTrue(luna.isKnown)
        XCTAssertEqual(luna.modelPattern, "gpt-5.6-luna")
        XCTAssertEqual(luna.inputPerMillionUSD, 1.00, accuracy: 0.0001)
        XCTAssertEqual(luna.cachedInputPerMillionUSD, 0.10, accuracy: 0.0001)
        XCTAssertEqual(luna.cacheWritePerMillionUSD ?? 0, 1.25, accuracy: 0.0001)
        XCTAssertEqual(luna.outputPerMillionUSD, 6.00, accuracy: 0.0001)
    }

    func testBareAliasRoutesToSolRates() {
        // OpenAI routes the bare `gpt-5.6` alias to Sol.
        let bare = AzureModelPricing.defaultPricing(for: "gpt-5.6", provider: .openai)
        XCTAssertEqual(bare.modelPattern, "gpt-5.6-sol")
        XCTAssertEqual(bare.inputPerMillionUSD, 5.00, accuracy: 0.0001)
        XCTAssertEqual(bare.outputPerMillionUSD, 30.00, accuracy: 0.0001)
    }

    func testDatedSnapshotStillMatches() {
        let dated = AzureModelPricing.defaultPricing(for: "gpt-5.6-terra-2026-07-09", provider: .openai)
        XCTAssertEqual(dated.modelPattern, "gpt-5.6-terra")
    }

    func testOlderGPT5FamiliesUnaffected() {
        XCTAssertEqual(AzureModelPricing.defaultPricing(for: "gpt-5.5", provider: .openai).modelPattern, "gpt-5.5")
        XCTAssertEqual(AzureModelPricing.defaultPricing(for: "gpt-5.4-mini", provider: .openai).modelPattern, "gpt-5.4-mini")
        XCTAssertEqual(AzureModelPricing.defaultPricing(for: "gpt-5", provider: .openai).modelPattern, "gpt-5")
    }
}
