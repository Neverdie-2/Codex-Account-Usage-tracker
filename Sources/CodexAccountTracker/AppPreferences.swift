import Foundation

struct AppPreferences {
    private enum Keys {
        static let endpoint = "codexAccountTracker.endpoint"
        static let openAIAPIUsageWindow = "codexAccountTracker.openAIAPIUsageWindow"
        static let claudeCodeFoundryBackfillDone = "codexAccountTracker.claudeCodeFoundryBackfillDone"
        static let claudeCodeProjectRootBackfillDone = "codexAccountTracker.claudeCodeProjectRootBackfillDone.v1"
        static let openAICodexForkReplayBackfillDone = "codexAccountTracker.openAICodexForkReplayBackfillDone.v5"
        static let azureCodexForkReplayBackfillDone = "codexAccountTracker.azureCodexForkReplayBackfillDone.v5"
    }

    static let privateEndpoint = "ws://127.0.0.1:14567"

    static var endpoint: String {
        get {
            let stored = UserDefaults.standard.string(forKey: Keys.endpoint)
            return stored ?? privateEndpoint
        }
        set {
            UserDefaults.standard.set(newValue, forKey: Keys.endpoint)
        }
    }

    static var openAIAPIUsageWindow: OpenAIAPIUsageWindow {
        get {
            guard let rawValue = UserDefaults.standard.string(forKey: Keys.openAIAPIUsageWindow),
                  let window = OpenAIAPIUsageWindow(rawValue: rawValue)
            else { return .last30Days }
            return window
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: Keys.openAIAPIUsageWindow)
        }
    }

    /// One-shot marker: once a Claude Code refresh has scanned the ~/.claude-foundry
    /// roots in full, we don't need to force a `since: nil` backfill again. Avoids
    /// re-paying full-scan cost every refresh on machines that have no foundry data.
    static var claudeCodeFoundryBackfillDone: Bool {
        get { UserDefaults.standard.bool(forKey: Keys.claudeCodeFoundryBackfillDone) }
        set { UserDefaults.standard.set(newValue, forKey: Keys.claudeCodeFoundryBackfillDone) }
    }

    /// One-shot marker for the Claude Code project-root attribution rebuild. Older
    /// caches grouped rows by per-event cwd, splitting one session across subfolders.
    static var claudeCodeProjectRootBackfillDone: Bool {
        get { UserDefaults.standard.bool(forKey: Keys.claudeCodeProjectRootBackfillDone) }
        set { UserDefaults.standard.set(newValue, forKey: Keys.claudeCodeProjectRootBackfillDone) }
    }

    /// One-shot marker for scanner upgrades that changed local Codex indexing or
    /// fork replay suppression. Existing cached rows need a full rebuild once so
    /// copied pre-fork token rows are removed from OpenAI local usage.
    static var openAICodexForkReplayBackfillDone: Bool {
        get { UserDefaults.standard.bool(forKey: Keys.openAICodexForkReplayBackfillDone) }
        set { UserDefaults.standard.set(newValue, forKey: Keys.openAICodexForkReplayBackfillDone) }
    }

    /// One-shot marker for scanner upgrades that changed local Codex indexing or
    /// fork replay suppression. Existing cached rows need a full rebuild once so
    /// copied pre-fork token rows are removed from Azure local usage.
    static var azureCodexForkReplayBackfillDone: Bool {
        get { UserDefaults.standard.bool(forKey: Keys.azureCodexForkReplayBackfillDone) }
        set { UserDefaults.standard.set(newValue, forKey: Keys.azureCodexForkReplayBackfillDone) }
    }
}
