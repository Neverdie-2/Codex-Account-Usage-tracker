import Foundation

struct AppPreferences {
    private enum Keys {
        static let endpoint = "codexAccountTracker.endpoint"
        static let openAIAPIUsageWindow = "codexAccountTracker.openAIAPIUsageWindow"
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
}
