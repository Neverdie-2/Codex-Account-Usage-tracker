import Foundation

final class CodexLocalUsageIndexStore {
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

    func load() -> CodexLocalUsageIndex {
        let url = fileURL()
        guard fileManager.fileExists(atPath: url.path) else {
            return CodexLocalUsageIndex(version: Self.currentVersion)
        }

        do {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let header = try decoder.decode(CodexLocalUsageIndexHeader.self, from: data)
            guard header.version == Self.currentVersion else {
                return CodexLocalUsageIndex(version: Self.currentVersion)
            }
            return try decoder.decode(CodexLocalUsageIndex.self, from: data)
        } catch {
            print("Failed to load Codex local usage index: \(error)")
            return CodexLocalUsageIndex(version: Self.currentVersion)
        }
    }

    func save(_ index: CodexLocalUsageIndex) {
        do {
            try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            let data = try encoder.encode(index)
            try data.write(to: fileURL(), options: [.atomic])
        } catch {
            print("Failed to save Codex local usage index: \(error)")
        }
    }

    private func fileURL() -> URL {
        directoryURL.appendingPathComponent("codex-local-usage-index.json")
    }
}

private struct CodexLocalUsageIndexHeader: Decodable {
    var version: Int

    private enum CodingKeys: String, CodingKey {
        case compactVersion = "v"
        case legacyVersion = "version"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decodeIfPresent(Int.self, forKey: .compactVersion)
            ?? container.decode(Int.self, forKey: .legacyVersion)
    }
}

struct CodexLocalUsageIndex: Codable, Equatable {
    var version: Int
    var files: [String: CodexLocalUsageIndexedFile] = [:]

    private enum CodingKeys: String, CodingKey {
        case version = "v"
        case files = "f"
    }
}

struct CodexLocalUsageIndexedFile: Codable, Equatable {
    var fingerprint: CodexLocalUsageFileFingerprint
    var session: CodexLocalUsageIndexedSession

    private enum CodingKeys: String, CodingKey {
        case fingerprint = "fp"
        case session = "s"
    }
}

struct CodexLocalUsageFileFingerprint: Codable, Equatable {
    var path: String
    var fileSize: Int64
    var modificationTimeNanoseconds: Int64?

    private enum CodingKeys: String, CodingKey {
        case path = "p"
        case fileSize = "z"
        case modificationTimeNanoseconds = "m"
    }

    static func make(fileURL: URL, fileManager: FileManager = .default) -> CodexLocalUsageFileFingerprint? {
        guard let values = try? fileURL.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]) else {
            return nil
        }
        return CodexLocalUsageFileFingerprint(
            path: fileURL.path,
            fileSize: Int64(values.fileSize ?? 0),
            modificationTimeNanoseconds: values.contentModificationDate.map { date in
                Int64((date.timeIntervalSince1970 * 1_000_000_000).rounded())
            }
        )
    }
}

struct CodexLocalUsageIndexedSession: Codable, Equatable {
    var filePath: String
    var sessionID: String
    var provider: String
    var originator: String?
    var metaTimestamp: Date?
    var forkedFromID: String?
    var projectPath: String
    var events: [CodexLocalUsageIndexedEvent]

    private enum CodingKeys: String, CodingKey {
        case filePath = "p"
        case sessionID = "i"
        case provider = "pr"
        case originator = "o"
        case metaTimestamp = "mt"
        case forkedFromID = "f"
        case projectPath = "pp"
        case events = "e"
    }
}

struct CodexLocalUsageIndexedEvent: Codable, Equatable {
    var recordID: String
    var timestamp: Date
    var model: String
    var lastUsage: AzureTokenUsage
    var replayKey: String?
    var sessionDedupeKey: String?

    init(
        recordID: String,
        timestamp: Date,
        model: String,
        lastUsage: AzureTokenUsage,
        replayKey: String?,
        sessionDedupeKey: String?
    ) {
        self.recordID = recordID
        self.timestamp = timestamp
        self.model = model
        self.lastUsage = lastUsage
        self.replayKey = replayKey
        self.sessionDedupeKey = sessionDedupeKey
    }

    private enum CodingKeys: String, CodingKey {
        case recordID = "i"
        case timestamp = "t"
        case model = "m"
        case lastUsage = "u"
        case replayKey = "r"
        case sessionDedupeKey = "d"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        recordID = try container.decode(String.self, forKey: .recordID)
        timestamp = try container.decode(Date.self, forKey: .timestamp)
        model = try container.decode(String.self, forKey: .model)
        let usage = try container.decode([Int].self, forKey: .lastUsage)
        lastUsage = AzureTokenUsage(
            inputTokens: usage[safe: 0] ?? 0,
            cachedInputTokens: usage[safe: 1] ?? 0,
            cacheCreationInputTokens: usage[safe: 2] ?? 0,
            outputTokens: usage[safe: 3] ?? 0,
            reasoningOutputTokens: usage[safe: 4] ?? 0,
            totalTokens: usage[safe: 5] ?? 0
        )
        replayKey = try container.decodeIfPresent(String.self, forKey: .replayKey)
        sessionDedupeKey = try container.decodeIfPresent(String.self, forKey: .sessionDedupeKey)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(recordID, forKey: .recordID)
        try container.encode(timestamp, forKey: .timestamp)
        try container.encode(model, forKey: .model)
        try container.encode([
            lastUsage.inputTokens,
            lastUsage.cachedInputTokens,
            lastUsage.cacheCreationInputTokens,
            lastUsage.outputTokens,
            lastUsage.reasoningOutputTokens,
            lastUsage.totalTokens
        ], forKey: .lastUsage)
        try container.encodeIfPresent(replayKey, forKey: .replayKey)
        try container.encodeIfPresent(sessionDedupeKey, forKey: .sessionDedupeKey)
    }
}

private extension Array {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
