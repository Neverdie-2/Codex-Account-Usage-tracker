import Foundation

final class AccountStore {
    private let fileURL: URL

    init(fileURL: URL = AccountStore.defaultFileURL()) {
        self.fileURL = fileURL
    }

    var path: String {
        fileURL.path
    }

    func load() -> [AccountRecord] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return []
        }

        do {
            let data = try Data(contentsOf: fileURL)
            return try JSONDecoder().decode([AccountRecord].self, from: data)
        } catch {
            print("Failed to load accounts.json: \(error)")
            return []
        }
    }

    func save(_ accounts: [AccountRecord]) {
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            let data = try encoder.encode(accounts.sorted { $0.email.localizedCaseInsensitiveCompare($1.email) == .orderedAscending })
            try data.write(to: fileURL, options: [.atomic])
        } catch {
            print("Failed to save accounts.json: \(error)")
        }
    }

    static func defaultFileURL() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("CodexAccountTracker", isDirectory: true)
            .appendingPathComponent("accounts.json")
    }
}
