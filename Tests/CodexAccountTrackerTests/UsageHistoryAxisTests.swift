import Foundation
import XCTest
@testable import CodexAccountTracker

final class UsageHistoryAxisTests: XCTestCase {
    private let enUS = Locale(identifier: "en_US")

    private func series(_ id: String, _ values: [Double]) -> UsageHistorySeries {
        let start = Date(timeIntervalSince1970: 0)
        return UsageHistorySeries(
            id: id,
            name: id,
            totals: AzureUsageTokenTotals(),
            points: values.enumerated().map { index, value in
                UsageHistoryPoint(
                    date: start.addingTimeInterval(Double(index) * 3_600),
                    totals: AzureUsageTokenTotals(),
                    value: value
                )
            }
        )
    }

    // The bug this guards: the y scale used to be the tallest single point, so a
    // stack of series drew straight past the top of the plot.
    func testStackedMaximumSumsSeriesInEachBucket() {
        let maximum = UsageHistoryAxis.stackedMaximum(of: [
            series("a", [10, 2, 5]),
            series("b", [1, 3, 5]),
            series("c", [0, 1, 5])
        ])
        XCTAssertEqual(maximum, 15, accuracy: 0.0001)
    }

    func testStackedMaximumExceedsTallestSinglePoint() {
        let all = [series("a", [10, 0]), series("b", [9, 0])]
        let tallestPoint = all.flatMap(\.points).map(\.value).max() ?? 0
        XCTAssertGreaterThan(UsageHistoryAxis.stackedMaximum(of: all), tallestPoint)
    }

    func testStackedMaximumHandlesEmptyAndRaggedInput() {
        XCTAssertEqual(UsageHistoryAxis.stackedMaximum(of: []), 0)
        XCTAssertEqual(UsageHistoryAxis.stackedMaximum(of: [series("a", [])]), 0)
        XCTAssertEqual(
            UsageHistoryAxis.stackedMaximum(of: [series("a", [1, 2, 3]), series("b", [4])]),
            5,
            accuracy: 0.0001
        )
    }

    func testUpperBoundLeavesHeadroomAboveTheStack() {
        XCTAssertGreaterThan(UsageHistoryAxis.upperBound(for: 100), 100)
        XCTAssertEqual(UsageHistoryAxis.upperBound(for: 100), 105, accuracy: 0.0001)
    }

    func testUpperBoundIsPositiveForDegenerateInput() {
        XCTAssertEqual(UsageHistoryAxis.upperBound(for: 0), 1)
        XCTAssertEqual(UsageHistoryAxis.upperBound(for: -5), 1)
        XCTAssertEqual(UsageHistoryAxis.upperBound(for: .nan), 1)
        XCTAssertEqual(UsageHistoryAxis.upperBound(for: .infinity), 1)
    }

    func testCompactValueUsesMagnitudeSuffixes() {
        XCTAssertEqual(UsageHistoryAxis.compactValue(0, locale: enUS), "0")
        XCTAssertEqual(UsageHistoryAxis.compactValue(950, locale: enUS), "950")
        XCTAssertEqual(UsageHistoryAxis.compactValue(1_500, locale: enUS), "1.5K")
        XCTAssertEqual(UsageHistoryAxis.compactValue(2_000_000, locale: enUS), "2M")
        XCTAssertEqual(UsageHistoryAxis.compactValue(77_991_825, locale: enUS), "78M")
        XCTAssertEqual(UsageHistoryAxis.compactValue(1_200_000_000, locale: enUS), "1.2B")
    }

    func testCompactCostIsPrefixed() {
        XCTAssertEqual(UsageHistoryAxis.compactCost(913.19, locale: enUS), "$913.2")
        XCTAssertEqual(UsageHistoryAxis.compactCost(1_250, locale: enUS), "$1.3K")
    }

    // The bug this guards: colours used to come from a hash of the series name,
    // so two of up to nine series almost always collided on one colour.
    func testSlotAssignmentsAreUniqueAndOrdered() {
        let all = (1...8).map { series("s\($0)", [1]) } + [series("other", [1])]
        let slots = UsageHistorySeriesPalette.slotAssignments(for: all)

        XCTAssertEqual(slots["s1"], 0)
        XCTAssertEqual(slots["s8"], 7)
        XCTAssertEqual(slots["other"], UsageHistorySeriesPalette.otherSlot)

        let categorical = all
            .filter { $0.id != UsageHistorySeriesPalette.otherSeriesID }
            .compactMap { slots[$0.id] }
        XCTAssertEqual(Set(categorical).count, categorical.count, "two series shared a colour slot")
    }

    func testSlotAssignmentsSurviveHidingASeries() {
        let all = [series("a", [1]), series("b", [1]), series("c", [1])]
        let slots = UsageHistorySeriesPalette.slotAssignments(for: all)
        // The view always assigns from the full result, so the survivors of a
        // legend toggle keep the colours they already had.
        XCTAssertEqual(slots["c"], 2)
    }
}
