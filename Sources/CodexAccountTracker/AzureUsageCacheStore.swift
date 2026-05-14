import Foundation

final class AzureUsageCacheStore {
    private let directoryURL: URL

    init(directoryURL: URL = AzureUsageCacheStore.defaultDirectoryURL()) {
        self.directoryURL = directoryURL
    }

    func load(provider: CodexLogUsageProvider) -> AzureUsageCacheEntry? {
        let url = fileURL(for: provider)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }

        do {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(AzureUsageCacheEntry.self, from: data)
        } catch {
            print("Failed to load \(provider.displayName) usage cache: \(error)")
            return nil
        }
    }

    func save(_ result: AzureUsageScanResult, scannedAt: Date) {
        do {
            try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            let entry = AzureUsageCacheEntry(scannedAt: scannedAt, result: result)
            let data = try encoder.encode(entry)
            try data.write(to: fileURL(for: result.provider), options: [.atomic])
        } catch {
            print("Failed to save \(result.provider.displayName) usage cache: \(error)")
        }
    }

    var path: String {
        directoryURL.path
    }

    private func fileURL(for provider: CodexLogUsageProvider) -> URL {
        directoryURL.appendingPathComponent("\(provider.rawValue)-usage-cache.json")
    }

    static func defaultDirectoryURL() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("CodexAccountTracker", isDirectory: true)
    }
}

struct AzureUsageCacheEntry: Codable, Equatable {
    var scannedAt: Date
    var result: AzureUsageScanResult
}
