import Foundation

final class ClaudeCodeUsageIndexStore {
    static let currentVersion = 2

    private let directoryURL: URL
    private let fileManager: FileManager

    init(
        directoryURL: URL = AzureUsageCacheStore.defaultDirectoryURL(),
        fileManager: FileManager = .default
    ) {
        self.directoryURL = directoryURL
        self.fileManager = fileManager
    }

    func load() -> ClaudeCodeUsageIndex {
        let url = fileURL()
        guard fileManager.fileExists(atPath: url.path) else {
            return ClaudeCodeUsageIndex(version: Self.currentVersion)
        }

        do {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let index = try decoder.decode(ClaudeCodeUsageIndex.self, from: data)
            guard index.version == Self.currentVersion else {
                return ClaudeCodeUsageIndex(version: Self.currentVersion)
            }
            return index
        } catch {
            print("Failed to load Claude Code usage index: \(error)")
            return ClaudeCodeUsageIndex(version: Self.currentVersion)
        }
    }

    func save(_ index: ClaudeCodeUsageIndex) {
        do {
            try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            let data = try encoder.encode(index)
            try data.write(to: fileURL(), options: [.atomic])
        } catch {
            print("Failed to save Claude Code usage index: \(error)")
        }
    }

    private func fileURL() -> URL {
        directoryURL.appendingPathComponent("claude-code-usage-index.json")
    }
}

struct ClaudeCodeUsageIndex: Codable, Equatable {
    var version: Int
    var files: [String: ClaudeCodeUsageIndexedFile] = [:]
}

struct ClaudeCodeUsageIndexedFile: Codable, Equatable {
    var fingerprint: CodexLocalUsageFileFingerprint
    var sawAssistantLine: Bool
    var malformedEventsSkipped: Int
    var rows: [ClaudeCodeUsageIndexedRow]
}

struct ClaudeCodeUsageIndexedRow: Codable, Equatable {
    var sessionID: String
    var filePath: String
    var timestamp: Date
    var endpoint: String?
    var resource: String?
    var deployment: String?
    var model: String
    var usage: AzureTokenUsage
    var projectPath: String
    var messageID: String
    var requestID: String?
    var isSidechain: Bool
    var isSubagent: Bool
}
