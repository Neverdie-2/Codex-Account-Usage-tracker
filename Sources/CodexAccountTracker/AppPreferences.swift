import Foundation

struct AppPreferences {
    private enum Keys {
        static let endpoint = "codexAccountTracker.endpoint"
        static let openAIAPIUsageWindow = "codexAccountTracker.openAIAPIUsageWindow"
        static let claudeCodeFoundryBackfillDone = "codexAccountTracker.claudeCodeFoundryBackfillDone"
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
}
