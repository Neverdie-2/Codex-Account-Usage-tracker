import Foundation

struct AppPreferences {
    private enum Keys {
        static let endpoint = "codexAccountTracker.endpoint"
    }

    static let defaultEndpoint = "ws://127.0.0.1:49731"
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
}
