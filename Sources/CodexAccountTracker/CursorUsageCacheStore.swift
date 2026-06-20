import Foundation

final class CursorUsageCacheStore {
    private let directoryURL: URL

    init(directoryURL: URL = AzureUsageCacheStore.defaultDirectoryURL()) {
        self.directoryURL = directoryURL
    }

    func load() -> CursorUsageCacheEntry? {
        let url = fileURL()
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }

        do {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(CursorUsageCacheEntry.self, from: data)
        } catch {
            print("Failed to load Cursor usage cache: \(error)")
            return nil
        }
    }

    func save(_ result: CursorUsageScanResult, scannedAt: Date) {
        do {
            try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            let entry = CursorUsageCacheEntry(scannedAt: scannedAt, result: result)
            let data = try encoder.encode(entry)
            try data.write(to: fileURL(), options: [.atomic])
        } catch {
            print("Failed to save Cursor usage cache: \(error)")
        }
    }

    var path: String {
        directoryURL.path
    }

    private func fileURL() -> URL {
        directoryURL.appendingPathComponent("cursor-usage-cache.json")
    }
}

struct CursorUsageCacheEntry: Codable, Equatable {
    var scannedAt: Date
    var result: CursorUsageScanResult
}
