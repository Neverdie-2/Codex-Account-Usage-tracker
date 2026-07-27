import Foundation

/// Correlates Claude Azure gateway usage (one record per request, from
/// `~/.opus-gateway/usage.jsonl`) with Claude Code transcript usage (one record per
/// assistant message, from `~/.claude/projects`) so the app can:
///
///   1. **Attribute** each gateway request to the project/session that made it. The
///      gateway log has no project field — the gateway only sees an API request, not
///      the working directory — so without this every request collapses into a single
///      "Claude Azure" bucket.
///   2. **Exclude** gateway sessions from the Claude Code dashboard. A `claude-azure`
///      session is still Claude Code and writes a normal transcript to
///      `~/.claude/projects`, so its usage would otherwise be counted twice: once from
///      the transcript (Claude Code) and once from the gateway log (Claude Azure).
///
/// Join key: the per-request token fingerprint `(cache_read, cache_creation, output)`
/// plus timestamp proximity. Both sources record the SAME Anthropic usage numbers for
/// a given request, and that triple is highly distinctive (six-figure cache reads), so
/// real requests match exactly — hundreds of live requests correlated with zero
/// cross-project collisions in testing. Requests with no transcript twin (Claude
/// Code's background classification/quota calls, which never reach the transcript)
/// fall back to the enclosing azure session's active time window.
struct ClaudeAzureTranscriptCorrelator {
    /// How far apart a gateway request and its transcript twin may be timestamped. The
    /// token fingerprint is the real key; the window only guards against the same
    /// fingerprint recurring in an unrelated session much later.
    private static let matchWindow: TimeInterval = 180

    /// Padding around an azure session's first/last transcript turn, used to place
    /// background requests (which can fire slightly before/after visible turns).
    private static let intervalPadding: TimeInterval = 180

    /// Sentinel project for gateway requests that cannot be attributed to exactly one
    /// project (e.g. a background request fired while two azure sessions in different
    /// projects were both active).
    static let unattributedProjectPath = "Claude Azure · unattributed"
    static let unattributedProjectName = "Unattributed"

    private struct Signature: Hashable {
        let cached: Int
        let cacheCreation: Int
        let output: Int
    }

    private struct Candidate {
        let timestamp: Date
        let sessionID: String
        let projectPath: String
        let projectName: String
    }

    private struct SessionSpan {
        let projectPath: String
        let projectName: String
        var start: Date
        var end: Date
    }

    private let candidatesBySignature: [Signature: [Candidate]]
    private let azureSessionSpans: [SessionSpan]

    /// Transcript session IDs judged to be Claude Azure (gateway) sessions.
    let azureSessionIDs: Set<String>

    init(claudeCodeRecords: [AzureUsageRecord], gatewayRecords: [AzureUsageRecord]) {
        // --- index transcript records by token fingerprint, and summarise sessions ---
        var bySignature: [Signature: [Candidate]] = [:]
        var spanByID: [String: SessionSpan] = [:]
        var recordCountByID: [String: Int] = [:]

        for record in claudeCodeRecords {
            let signature = Signature(
                cached: record.usage.cachedInputTokens,
                cacheCreation: record.usage.cacheCreationInputTokens,
                output: record.usage.outputTokens
            )
            bySignature[signature, default: []].append(
                Candidate(
                    timestamp: record.timestamp,
                    sessionID: record.sessionID,
                    projectPath: record.projectPath,
                    projectName: record.projectName
                )
            )
            recordCountByID[record.sessionID, default: 0] += 1
            if var span = spanByID[record.sessionID] {
                if record.timestamp < span.start { span.start = record.timestamp }
                if record.timestamp > span.end { span.end = record.timestamp }
                spanByID[record.sessionID] = span
            } else {
                spanByID[record.sessionID] = SessionSpan(
                    projectPath: record.projectPath,
                    projectName: record.projectName,
                    start: record.timestamp,
                    end: record.timestamp
                )
            }
        }
        candidatesBySignature = bySignature

        // --- classify which transcript sessions are gateway (claude-azure) sessions ---
        // A gateway request whose fingerprint+time resolves to exactly ONE transcript
        // session is a confident hit for that session. A session is judged azure when it
        // collects >= 2 such hits, OR when its hits are a majority of its turns (covers
        // tiny 1-2 turn sessions). Requiring >= 2 (or a majority) means a single
        // accidental fingerprint coincidence can never mis-flag a native session.
        var hitsByID: [String: Int] = [:]
        for gateway in gatewayRecords {
            let signature = Signature(
                cached: gateway.usage.cachedInputTokens,
                cacheCreation: gateway.usage.cacheCreationInputTokens,
                output: gateway.usage.outputTokens
            )
            guard let candidates = bySignature[signature] else { continue }
            let near = candidates.filter {
                abs($0.timestamp.timeIntervalSince(gateway.timestamp)) <= Self.matchWindow
            }
            let sessions = Set(near.map(\.sessionID))
            if sessions.count == 1, let sessionID = sessions.first {
                hitsByID[sessionID, default: 0] += 1
            }
        }

        var azureIDs = Set<String>()
        for (sessionID, hits) in hitsByID {
            let total = recordCountByID[sessionID] ?? hits
            if hits >= 2 || hits * 2 >= total {
                azureIDs.insert(sessionID)
            }
        }
        azureSessionIDs = azureIDs
        azureSessionSpans = azureIDs.compactMap { spanByID[$0] }
    }

    /// True when the given Claude Code transcript session is actually a Claude Azure
    /// (gateway) session and should be dropped from the Claude Code dashboard.
    func isAzureSession(_ sessionID: String) -> Bool {
        azureSessionIDs.contains(sessionID)
    }

    /// Best-effort project for a gateway request: its transcript twin's project when one
    /// exists, else the azure session whose active window encloses it. Returns nil when
    /// neither is unambiguous (e.g. a background request fired while two concurrent
    /// azure sessions in different projects were active).
    func attributedProject(for gatewayRecord: AzureUsageRecord) -> (path: String, name: String)? {
        let signature = Signature(
            cached: gatewayRecord.usage.cachedInputTokens,
            cacheCreation: gatewayRecord.usage.cacheCreationInputTokens,
            output: gatewayRecord.usage.outputTokens
        )
        if let candidates = candidatesBySignature[signature] {
            let near = candidates.filter {
                abs($0.timestamp.timeIntervalSince(gatewayRecord.timestamp)) <= Self.matchWindow
            }
            let projects = Set(near.map(\.projectPath))
            if projects.count == 1, let candidate = near.first {
                return (candidate.projectPath, candidate.projectName)
            }
        }

        // Fallback: the azure session whose (padded) active window encloses this request.
        let timestamp = gatewayRecord.timestamp
        let enclosing = azureSessionSpans.filter {
            timestamp >= $0.start.addingTimeInterval(-Self.intervalPadding)
                && timestamp <= $0.end.addingTimeInterval(Self.intervalPadding)
        }
        if Set(enclosing.map(\.projectPath)).count == 1, let span = enclosing.first {
            return (span.projectPath, span.projectName)
        }
        return nil
    }
}
