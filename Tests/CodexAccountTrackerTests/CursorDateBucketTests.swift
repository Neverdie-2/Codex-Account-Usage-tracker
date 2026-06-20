import XCTest
@testable import CodexAccountTracker

final class CursorDateBucketTests: XCTestCase {
    // MARK: Millisecond epoch

    func testMillisecondEpochConvertsToFractionalSeconds() {
        let date = Date(timeIntervalSince1970: 1750409004081 / 1000)
        XCTAssertEqual(date.timeIntervalSince1970, 1750409004.081, accuracy: 0.001)
    }

    // MARK: ISO8601 parsing

    func testParseISO8601WithFractionalSecondsMatchesReference() {
        let parsed = CursorAccountRecord.parseISO8601("2026-06-20T07:43:24.081Z")
        let unwrapped = try! XCTUnwrap(parsed)

        let reference = ISO8601DateFormatter()
        reference.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let referenceDate = try! XCTUnwrap(reference.date(from: "2026-06-20T07:43:24.081Z"))

        XCTAssertEqual(
            unwrapped.timeIntervalSince1970,
            referenceDate.timeIntervalSince1970,
            accuracy: 0.001
        )
    }

    func testParseISO8601WithoutFractionalSecondsIsNonNil() {
        XCTAssertNotNil(CursorAccountRecord.parseISO8601("2026-06-20T07:43:24Z"))
    }

    // MARK: Local-day bucketing

    func testSameLocalDayShareStartOfDay() {
        let timestamp = iso("2026-06-20T23:30:00Z")
        let now = iso("2026-06-20T12:00:00Z")
        XCTAssertEqual(
            utcCalendar.startOfDay(for: timestamp),
            utcCalendar.startOfDay(for: now)
        )
    }

    func testNextDayHasDifferentStartOfDay() {
        let timestamp = iso("2026-06-21T00:30:00Z")
        let now = iso("2026-06-20T12:00:00Z")
        XCTAssertNotEqual(
            utcCalendar.startOfDay(for: timestamp),
            utcCalendar.startOfDay(for: now)
        )
    }

    // MARK: Countdown formatting

    func testFormatCountdownZero() {
        XCTAssertEqual(CursorAccountRecord.formatCountdown(0), "0d 00h 00m")
    }

    func testFormatCountdownDayHourMinute() {
        XCTAssertEqual(CursorAccountRecord.formatCountdown(90061), "1d 01h 01m")
    }

    func testFormatCountdownSingleHour() {
        XCTAssertEqual(CursorAccountRecord.formatCountdown(3600), "0d 01h 00m")
    }
}
