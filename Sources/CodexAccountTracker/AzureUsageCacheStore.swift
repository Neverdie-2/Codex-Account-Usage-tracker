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
            var entry = try decoder.decode(AzureUsageCacheEntry.self, from: data)
            if enrichLegacyProjectMetadata(in: &entry) {
                save(entry.result, scannedAt: entry.scannedAt)
            }
            return entry
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

    private func enrichLegacyProjectMetadata(in entry: inout AzureUsageCacheEntry) -> Bool {
        var projectPathByFilePath: [String: String] = [:]
        var didChange = false

        for index in entry.result.records.indices {
            guard entry.result.records[index].projectPath == AzureUsageRecord.unknownProject else { continue }
            let filePath = entry.result.records[index].filePath
            let projectPath = projectPathByFilePath[filePath] ?? Self.projectPathFromSessionLog(at: filePath)
            projectPathByFilePath[filePath] = projectPath
            guard projectPath != AzureUsageRecord.unknownProject else { continue }

            entry.result.records[index].projectPath = projectPath
            entry.result.records[index].projectName = AzureUsageRecord.projectName(for: projectPath)
            didChange = true
        }

        return didChange
    }

    private static func projectPathFromSessionLog(at filePath: String) -> String {
        guard let lineData = firstSessionMetaLineData(at: filePath),
              let object = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
              let payload = object["payload"] as? [String: Any],
              let cwd = payload["cwd"] as? String
        else {
            return AzureUsageRecord.unknownProject
        }

        return AzureUsageRecord.normalizedProjectPath(cwd)
    }

    private static func firstSessionMetaLineData(at filePath: String) -> Data? {
        guard FileManager.default.fileExists(atPath: filePath),
              let fileHandle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: filePath))
        else { return nil }
        defer { try? fileHandle.close() }

        var buffer = Data()
        while true {
            let chunk = fileHandle.readData(ofLength: 64 * 1024)
            guard !chunk.isEmpty else { return nil }
            buffer.append(chunk)

            while let newlineRange = buffer.firstRange(of: Data([0x0A])) {
                let lineData = buffer[..<newlineRange.lowerBound]
                if lineData.contains(Data("\"session_meta\"".utf8)) {
                    return Data(lineData)
                }
                buffer.removeSubrange(...newlineRange.lowerBound)
            }
        }
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
