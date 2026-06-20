import Foundation

final class CursorAccountStore {
    private let fileURL: URL

    init(fileURL: URL = CursorAccountStore.defaultFileURL()) {
        self.fileURL = fileURL
    }

    var path: String {
        fileURL.path
    }

    func load() -> [CursorAccountRecord] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return []
        }

        do {
            let data = try Data(contentsOf: fileURL)
            return try JSONDecoder().decode([CursorAccountRecord].self, from: data)
        } catch {
            print("Failed to load cursor-accounts.json: \(error)")
            return []
        }
    }

    func save(_ accounts: [CursorAccountRecord]) {
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
            print("Failed to save cursor-accounts.json: \(error)")
        }
    }

    static func defaultFileURL() -> URL {
        AzureUsageCacheStore.defaultDirectoryURL()
            .appendingPathComponent("cursor-accounts.json")
    }
}
