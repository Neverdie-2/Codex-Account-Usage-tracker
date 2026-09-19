import Foundation
import XCTest
@testable import CodexAccountTracker

/// Claude Code writes some assistant records straight from the `message_start` snapshot:
/// `stop_reason` is absent and `output_tokens` is a 1-5 token placeholder, even when the
/// response holds tens of thousands of real tokens. This mostly hits subagent transcripts
/// (`agent-*.jsonl`). Input / cache-read / cache-write are correct on those records; only the
/// output count is lost, and it is never written anywhere else on disk.
///
/// The estimator recovers an approximate output count for those records by calibrating a
/// tokens-per-character ratio from the records in the same scan that *do* carry final usage.
final class ClaudeCodeOutputEstimatorTests: XCTestCase {

    private func sample(
        _ id: String,
        session: String = "s1",
        model: String = "claude-opus-5",
        characters: Int,
        measured: Int?
    ) -> ClaudeCodeOutputEstimator.Sample {
        ClaudeCodeOutputEstimator.Sample(
            id: id,
            sessionID: session,
            model: model,
            contentCharacters: characters,
            measuredOutputTokens: measured
        )
    }

    func testRecordsWithFinalUsageAreNeverAltered() {
        let samples = [
            sample("a", characters: 2_000, measured: 1_000),
            sample("b", characters: 4_000, measured: 2_000)
        ]

        let report = ClaudeCodeOutputEstimator.estimate(samples: samples)

        XCTAssertTrue(report.estimatedOutputTokensByID.isEmpty)
        XCTAssertEqual(report.measuredOutputTokens, 3_000)
        XCTAssertEqual(report.estimatedOutputTokens, 0)
        XCTAssertEqual(report.incompleteEventCount, 0)
        XCTAssertEqual(report.totalEventCount, 2)
    }

    func testIncompleteRecordIsEstimatedFromSameSessionRatio() {
        // Calibration from the session: 3,000 chars -> 1,500 tokens = 0.5 tokens/char.
        let samples = [
            sample("complete", characters: 3_000, measured: 1_500),
            sample("placeholder", characters: 10_000, measured: nil)
        ]

        let report = ClaudeCodeOutputEstimator.estimate(samples: samples)

        XCTAssertEqual(report.estimatedOutputTokensByID["placeholder"], 5_000)
        XCTAssertEqual(report.measuredOutputTokens, 1_500)
        XCTAssertEqual(report.estimatedOutputTokens, 5_000)
        XCTAssertEqual(report.incompleteEventCount, 1)
        XCTAssertEqual(report.totalEventCount, 2)
    }

    func testSessionRatioIsPreferredOverGlobalRatio() {
        // Session "wordy" runs at 1.0 tokens/char; session "terse" at 0.25 tokens/char.
        // The placeholder in "terse" must use its own session's ratio, not the blended one.
        let samples = [
            sample("w1", session: "wordy", characters: 40_000, measured: 40_000),
            sample("t1", session: "terse", characters: 20_000, measured: 5_000),
            sample("t2", session: "terse", characters: 8_000, measured: nil)
        ]

        let report = ClaudeCodeOutputEstimator.estimate(samples: samples)

        XCTAssertEqual(report.estimatedOutputTokensByID["t2"], 2_000)
    }

    func testFallsBackToModelRatioWhenSessionHasNoCalibration() {
        // Session "lonely" has no complete records, so the per-model ratio must be used.
        let samples = [
            sample("m1", session: "other", model: "claude-opus-5", characters: 10_000, measured: 5_000),
            sample("x1", session: "lonely", model: "claude-opus-5", characters: 4_000, measured: nil)
        ]

        let report = ClaudeCodeOutputEstimator.estimate(samples: samples)

        XCTAssertEqual(report.estimatedOutputTokensByID["x1"], 2_000)
    }

    func testFallsBackToGlobalRatioWhenModelHasNoCalibration() {
        let samples = [
            sample("m1", session: "a", model: "claude-opus-5", characters: 10_000, measured: 5_000),
            sample("x1", session: "b", model: "claude-sonnet-5", characters: 4_000, measured: nil)
        ]

        let report = ClaudeCodeOutputEstimator.estimate(samples: samples)

        XCTAssertEqual(report.estimatedOutputTokensByID["x1"], 2_000)
    }

    func testThinCalibrationSampleIsIgnored() {
        // A session whose only complete record is tiny would produce a wild ratio; require a
        // minimum amount of observed content before trusting a scope.
        let samples = [
            sample("tiny", session: "thin", characters: 12, measured: 900),
            sample("bulk", session: "other", characters: 100_000, measured: 50_000),
            sample("target", session: "thin", characters: 10_000, measured: nil)
        ]

        let report = ClaudeCodeOutputEstimator.estimate(samples: samples)

        // Falls through to the global ratio (0.5 tokens/char), not the 75 tokens/char outlier.
        XCTAssertEqual(report.estimatedOutputTokensByID["target"], 5_000)
    }

    func testRatioIsClampedToPlausibleRange() {
        // A degenerate calibration must not extrapolate into nonsense.
        let samples = [
            sample("weird", session: "s1", characters: 10_000, measured: 900_000),
            sample("target", session: "s1", characters: 10_000, measured: nil)
        ]

        let report = ClaudeCodeOutputEstimator.estimate(samples: samples)

        let estimate = report.estimatedOutputTokensByID["target"] ?? 0
        XCTAssertLessThanOrEqual(estimate, 10_000 * 2)
        XCTAssertGreaterThan(estimate, 0)
    }

    func testFallsBackToDefaultRatioWhenNothingIsCalibratable() {
        let samples = [sample("only", characters: 8_000, measured: nil)]

        let report = ClaudeCodeOutputEstimator.estimate(samples: samples)

        let estimate = report.estimatedOutputTokensByID["only"] ?? 0
        XCTAssertGreaterThan(estimate, 0)
        XCTAssertLessThanOrEqual(estimate, 8_000)
    }

    func testRecordWithoutContentIsNotEstimated() {
        // No content to measure means no defensible estimate; leave it alone.
        let samples = [
            sample("complete", characters: 3_000, measured: 1_500),
            sample("empty", characters: 0, measured: nil)
        ]

        let report = ClaudeCodeOutputEstimator.estimate(samples: samples)

        XCTAssertNil(report.estimatedOutputTokensByID["empty"])
        XCTAssertEqual(report.incompleteEventCount, 1)
        XCTAssertEqual(report.estimatedOutputTokens, 0)
    }

    func testFinalisedRecordReportingZeroOutputIsTreatedAsIncomplete() {
        // Claude Code writes a handful of `stop_sequence` records carrying real content but
        // `output_tokens: 0`. Those are as unusable as a placeholder and must be estimated.
        let samples = [
            sample("complete", characters: 3_000, measured: 1_500),
            sample("zeroed", characters: 10_000, measured: 0)
        ]

        let report = ClaudeCodeOutputEstimator.estimate(samples: samples)

        XCTAssertEqual(report.estimatedOutputTokensByID["zeroed"], 5_000)
        XCTAssertEqual(report.measuredOutputTokens, 1_500)
        XCTAssertEqual(report.incompleteEventCount, 1)
    }

    /// Regression guard for the real-world shape that started this investigation: a subagent
    /// response holding 116,444 characters recorded as `output_tokens: 3`.
    func testLargePlaceholderResponseIsRecoveredToRealisticMagnitude() {
        var samples = [ClaudeCodeOutputEstimator.Sample]()
        // 415 complete requests: 1,539,279 chars -> 760,260 tokens (the oracle session's ratio).
        for index in 0..<415 {
            samples.append(sample("c\(index)", characters: 3_709, measured: 1_832))
        }
        samples.append(sample("huge", characters: 116_444, measured: nil))

        let report = ClaudeCodeOutputEstimator.estimate(samples: samples)
        let estimate = report.estimatedOutputTokensByID["huge"] ?? 0

        // Anything in the tens of thousands beats the 3 tokens Claude Code recorded.
        XCTAssertGreaterThan(estimate, 40_000)
        XCTAssertLessThan(estimate, 90_000)
    }
}
