import Foundation

final class CursorUsageIndexStore {
    static let currentVersion = 1

    private let directoryURL: URL
    private let fileManager: FileManager

    init(
        directoryURL: URL = AzureUsageCacheStore.defaultDirectoryURL(),
        fileManager: FileManager = .default
    ) {
        self.directoryURL = directoryURL
        self.fileManager = fileManager
    }

    func load() -> CursorUsageIndex {
        let url = fileURL()
        guard fileManager.fileExists(atPath: url.path) else {
            return CursorUsageIndex(version: Self.currentVersion)
        }

        do {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let index = try decoder.decode(CursorUsageIndex.self, from: data)
            guard index.version == Self.currentVersion else {
                return CursorUsageIndex(version: Self.currentVersion)
            }
            return index
        } catch {
            print("Failed to load Cursor usage index: \(error)")
            return CursorUsageIndex(version: Self.currentVersion)
        }
    }

    func save(_ index: CursorUsageIndex) {
        do {
            try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            let data = try encoder.encode(index)
            try data.write(to: fileURL(), options: [.atomic])
        } catch {
            print("Failed to save Cursor usage index: \(error)")
        }
    }

    private func fileURL() -> URL {
        directoryURL.appendingPathComponent("cursor-usage-index.json")
    }
}

struct CursorUsageIndex: Codable, Equatable {
    var version: Int
    var fingerprint: CodexLocalUsageFileFingerprint?

    init(version: Int) {
        self.version = version
        self.fingerprint = nil
    }
}
