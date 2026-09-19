import Foundation

/// Recovers approximate output-token counts for Claude Code assistant records whose usage was
/// never finalised on disk.
///
/// Claude Code appends an assistant record when a response *starts*, carrying the `message_start`
/// usage snapshot: input / cache-read / cache-write are already final at that point, but
/// `output_tokens` is a 1-5 token placeholder and `stop_reason` is absent. Normally a finalised
/// record follows and wins deduplication. For a large share of subagent responses
/// (`agent-*.jsonl`) that finalised record is never written, so the real output count is absent
/// from disk entirely — it exists in no other file, and no later scan can recover it.
///
/// Rather than reporting those responses as ~3 output tokens, we estimate them from the size of
/// the content the model actually produced, using a tokens-per-character ratio calibrated from
/// the records in the same scan that *do* carry final usage. Calibration prefers the narrowest
/// scope with enough evidence (session+model, then model, then everything) because the ratio
/// varies a lot with workload — dense tool-call JSON tokenises very differently from prose.
///
/// Estimates are approximate and are reported separately from measured tokens so the UI can
/// label them; validation against held-out complete records put the aggregate within ~7%, while
/// any single request can be off by tens of percent.
enum ClaudeCodeOutputEstimator {

    struct Sample: Equatable {
        /// Stable identity of the deduplicated request (the scanner's billing key).
        var id: String
        var sessionID: String
        var model: String
        /// Characters of model-produced content: thinking, text, and tool-call arguments.
        var contentCharacters: Int
        /// Final output tokens, or `nil` when only a `message_start` placeholder was recorded.
        var measuredOutputTokens: Int?
    }

    struct Report: Equatable {
        /// Estimated output tokens keyed by `Sample.id`, for incomplete records only.
        var estimatedOutputTokensByID: [String: Int] = [:]
        var measuredOutputTokens = 0
        var estimatedOutputTokens = 0
        var incompleteEventCount = 0
        var totalEventCount = 0

        var hasEstimates: Bool { estimatedOutputTokens > 0 }
    }

    /// A response this short is dominated by fixed overhead, so its ratio says nothing useful
    /// about longer ones. Excluded from calibration (but still estimated if incomplete).
    private static let minimumCalibrationCharacters = 200
    /// A calibration scope needs at least this much observed content before we trust its ratio.
    private static let minimumScopeCharacters = 2_000
    /// Observed range across real transcripts sits near 0.5; clamp well outside it but still
    /// far from the absurd, so one degenerate record cannot distort a whole scan.
    private static let minimumRatio = 0.15
    private static let maximumRatio = 2.0
    /// Used only when a scan contains no finalised record at all to calibrate against.
    private static let defaultRatio = 0.5

    static func estimate(samples: [Sample]) -> Report {
        var report = Report()
        report.totalEventCount = samples.count

        var bySessionModel: [String: Calibration] = [:]
        var byModel: [String: Calibration] = [:]
        var global = Calibration()

        for sample in samples {
            // A finalised record that still reports zero output (Claude Code writes a few of
            // these on `stop_sequence`) is as unusable as a placeholder: treat it as incomplete.
            guard let measured = sample.measuredOutputTokens, measured > 0 else { continue }
            report.measuredOutputTokens += measured
            guard sample.contentCharacters >= minimumCalibrationCharacters else { continue }
            bySessionModel[scopeKey(sample), default: Calibration()].add(sample.contentCharacters, measured)
            byModel[sample.model, default: Calibration()].add(sample.contentCharacters, measured)
            global.add(sample.contentCharacters, measured)
        }

        for sample in samples where (sample.measuredOutputTokens ?? 0) <= 0 {
            report.incompleteEventCount += 1
            guard sample.contentCharacters > 0 else { continue }

            let ratio = bySessionModel[scopeKey(sample)]?.ratio
                ?? byModel[sample.model]?.ratio
                ?? global.ratio
                ?? defaultRatio
            let clamped = min(max(ratio, minimumRatio), maximumRatio)
            let estimated = max(1, Int((Double(sample.contentCharacters) * clamped).rounded()))

            report.estimatedOutputTokensByID[sample.id] = estimated
            report.estimatedOutputTokens += estimated
        }

        return report
    }

    private static func scopeKey(_ sample: Sample) -> String {
        "\(sample.sessionID)\u{1}\(sample.model)"
    }

    private struct Calibration {
        var characters = 0
        var tokens = 0

        mutating func add(_ characters: Int, _ tokens: Int) {
            self.characters += characters
            self.tokens += tokens
        }

        /// `nil` until the scope has seen enough content to be worth trusting.
        var ratio: Double? {
            guard characters >= ClaudeCodeOutputEstimator.minimumScopeCharacters, tokens > 0 else { return nil }
            return Double(tokens) / Double(characters)
        }
    }
}
