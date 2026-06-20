import XCTest
@testable import CodexAccountTracker

final class CursorLimitsParsingTests: XCTestCase {
    func testDecodesUsageSummary() throws {
        let summary = try JSONDecoder().decode(
            UsageSummaryResponse.self,
            from: CursorFixtures.data("usage-summary.sample.json")
        )

        let plan = try XCTUnwrap(summary.individualUsage?.plan)
        XCTAssertEqual(plan.totalPercentUsed, 3.5)

        let breakdown = try XCTUnwrap(plan.breakdown)
        XCTAssertEqual(breakdown.included, 0)
        XCTAssertEqual(breakdown.bonus, 7)
        XCTAssertEqual(breakdown.total, 7)

        let onDemand = try XCTUnwrap(summary.individualUsage?.onDemand)
        XCTAssertEqual(onDemand.enabled, false)
        XCTAssertNil(onDemand.limit)
        XCTAssertNil(onDemand.remaining)
    }

    func testDecodesAuthMe() throws {
        let me = try JSONDecoder().decode(
            AuthMeResponse.self,
            from: CursorFixtures.data("auth-me.sample.json")
        )
        XCTAssertEqual(me.email, "angeldanielov9@gmail.com")
        XCTAssertEqual(me.sub, "user_01ABCDEF")
    }

    func testDecodesAuthStripe() throws {
        let stripe = try JSONDecoder().decode(
            AuthStripeResponse.self,
            from: CursorFixtures.data("auth-stripe.sample.json")
        )
        XCTAssertEqual(stripe.membershipType, "free")
        XCTAssertEqual(stripe.subscriptionStatus, "canceled")
        XCTAssertNil(stripe.pendingCancellationDate)
    }

    func testMakeBuildsRecordFromDecodedResponses() throws {
        let decoder = JSONDecoder()
        let summary = try decoder.decode(
            UsageSummaryResponse.self,
            from: CursorFixtures.data("usage-summary.sample.json")
        )
        let me = try decoder.decode(
            AuthMeResponse.self,
            from: CursorFixtures.data("auth-me.sample.json")
        )
        let stripe = try decoder.decode(
            AuthStripeResponse.self,
            from: CursorFixtures.data("auth-stripe.sample.json")
        )

        let record = CursorAccountRecord.make(
            email: "angeldanielov9@gmail.com",
            summary: summary,
            me: me,
            stripe: stripe,
            subFromJWT: "user_01ABCDEF",
            lastSeenAt: "x"
        )

        XCTAssertEqual(record.totalPercentUsed, 3.5)
        XCTAssertEqual(record.pctRemaining, 96.5)
        XCTAssertFalse(record.isUnlimited)
        XCTAssertEqual(record.membershipType, "free")
    }

    func testResetCountdownAndFormatting() throws {
        let summary = try JSONDecoder().decode(
            UsageSummaryResponse.self,
            from: CursorFixtures.data("usage-summary.sample.json")
        )
        let record = CursorAccountRecord.make(
            email: "angeldanielov9@gmail.com",
            summary: summary,
            me: nil,
            stripe: nil,
            subFromJWT: "user_01ABCDEF",
            lastSeenAt: "x"
        )

        XCTAssertEqual(record.billingCycleEnd, "2026-06-20T11:57:07.800Z")

        let nowD = CursorAccountRecord.parseISO8601("2026-06-19T11:57:07.800Z")!
        let countdown = try XCTUnwrap(record.resetCountdown(now: nowD))
        XCTAssertEqual(countdown, 86400, accuracy: 1)

        XCTAssertEqual(CursorAccountRecord.formatCountdown(86400), "1d 00h 00m")
    }

    func testUnlimitedVariant() throws {
        let json = """
        { "membershipType":"pro", "isUnlimited":true,
          "individualUsage":{ "plan":{ "totalPercentUsed":0 } } }
        """
        let summary = try JSONDecoder().decode(
            UsageSummaryResponse.self,
            from: Data(json.utf8)
        )
        let record = CursorAccountRecord.make(
            email: "angeldanielov9@gmail.com",
            summary: summary,
            me: nil,
            stripe: nil,
            subFromJWT: nil,
            lastSeenAt: "x"
        )
        XCTAssertTrue(record.isUnlimited)
    }
}
