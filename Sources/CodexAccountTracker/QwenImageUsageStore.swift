import Foundation
import SQLite3

/// Reads Open WebUI's local SQLite database (the private Qwen Image Editor
/// install under ~/Projects/Qwen-Image-2.1) and turns every picture finished by
/// the Qwen Image 2.1 engine into one usage record for the Qwen Image dashboard.
///
/// The image model produces no token counts anywhere (ComfyUI logs only a run
/// time), and cloud hosts price it per image, so the unit here is images. The
/// dashboard prices each one at the Qwen Image API reference rate as estimated
/// savings, like the LM Studio panel. Prompt text is never read into a record —
/// only the file id, time, resolution, steps and model name.
final class QwenImageUsageStore {
    private let databaseURL: URL

    init(databaseURL: URL = QwenImageUsageStore.defaultDatabaseURL()) {
        self.databaseURL = databaseURL
    }

    static let endpoint = "Open WebUI"
    static let chatProject = "Qwen Image chats"
    static let unknownModel = "unknown image model"
    static let unlinkedSession = "unlinked"
    /// Open WebUI stores every picture returned by the image engine under this name;
    /// user uploads keep their own names ("image.png"), so this is the generated set.
    static let generatedFileName = "generated-image.png"

    func scan() -> AzureUsageScanResult {
        var result = AzureUsageScanResult(provider: .qwenImage)
        guard FileManager.default.fileExists(atPath: databaseURL.path) else {
            return result // Open WebUI not installed / data folder moved — empty, no warnings.
        }
        guard let rows = readRows() else {
            result.summary.warnings.append("Could not read Open WebUI database at \(databaseURL.path).")
            return result
        }

        let chatByFileID = Self.chatIDsByFileID(fromChatRows: rows.chats)
        for row in rows.files {
            guard let record = Self.record(
                fileID: row.id,
                fileName: row.fileName,
                createdAt: row.createdAt,
                meta: row.meta,
                chatID: chatByFileID[row.id],
                filePath: databaseURL.path
            ) else {
                if row.fileName == Self.generatedFileName { result.summary.malformedEventsSkipped += 1 }
                continue
            }
            result.records.append(record)
            result.summary.eventsCounted += 1
            result.summary.earliestEvent = Self.minDate(result.summary.earliestEvent, record.timestamp)
            result.summary.latestEvent = Self.maxDate(result.summary.latestEvent, record.timestamp)
        }

        if !result.records.isEmpty {
            result.summary.filesScanned = 1
            result.summary.sessionsScanned = Set(result.records.map(\.sessionID)).count
            result.summary.providerSessions = result.summary.sessionsScanned
            result.records.sort { $0.timestamp < $1.timestamp }
        }
        return result
    }

    /// Pure mapping from one `file` row to a usage record. Returns nil for anything
    /// that is not a finished picture from the image engine (uploads, sidecars, rows
    /// whose metadata cannot be read).
    static func record(
        fileID: String,
        fileName: String,
        createdAt: Double,
        meta: String,
        chatID: String?,
        filePath: String
    ) -> AzureUsageRecord? {
        guard fileName == generatedFileName, createdAt > 0,
              let object = try? JSONSerialization.jsonObject(with: Data(meta.utf8)) as? [String: Any]
        else { return nil }
        let data = object["data"] as? [String: Any] ?? [:]

        // The workflow is the ComfyUI graph Open WebUI submitted, stored as a JSON string.
        // Only the model file name and step count are taken from it; the prompt node is
        // never read.
        var model = unknownModel
        var steps = 0
        if let workflowBox = data["workflow"] as? [String: Any],
           let graph = Self.graph(from: workflowBox["workflow"]) {
            for node in graph.values {
                guard let node = node as? [String: Any],
                      let inputs = node["inputs"] as? [String: Any] else { continue }
                switch node["class_type"] as? String {
                case "UnetLoaderGGUF", "UNETLoader":
                    if let name = inputs["unet_name"] as? String, !name.isEmpty { model = name }
                case "KSampler":
                    steps = intValue(inputs["steps"])
                default:
                    continue
                }
            }
        }

        let width = intValue(data["width"])
        let height = intValue(data["height"])
        // An edit carries the source picture ("image"); a generation from text does not.
        let kind = data["image"] != nil ? "edit" : "generate"
        var details: [String] = [kind]
        if width > 0, height > 0 { details.append("\(width)×\(height)") }
        if steps > 0 { details.append("\(steps) steps") }

        return AzureUsageRecord(
            id: "qwen-image-\(fileID)",
            sessionID: chatID ?? unlinkedSession,
            filePath: filePath,
            timestamp: Date(timeIntervalSince1970: createdAt),
            endpoint: endpoint,
            resource: details.joined(separator: " · "),
            deployment: model,
            model: model,
            projectPath: chatProject,
            usage: AzureTokenUsage(
                inputTokens: 0, cachedInputTokens: 0, outputTokens: 0,
                reasoningOutputTokens: 0, totalTokens: 0, imageCount: 1
            )
        )
    }

    /// Open WebUI's `chat_file` table is not filled for generated pictures, so the
    /// chat a picture belongs to is found through the chat history: each assistant
    /// message lists its files by id.
    static func chatIDsByFileID(fromChatRows rows: [(id: String, chat: String)]) -> [String: String] {
        var map: [String: String] = [:]
        for row in rows {
            guard let object = try? JSONSerialization.jsonObject(with: Data(row.chat.utf8)) as? [String: Any],
                  let history = object["history"] as? [String: Any],
                  let messages = history["messages"] as? [String: Any]
            else { continue }
            for message in messages.values {
                guard let message = message as? [String: Any],
                      let files = message["files"] as? [[String: Any]] else { continue }
                for file in files {
                    if let id = file["id"] as? String, !id.isEmpty { map[id] = row.id }
                }
            }
        }
        return map
    }

    private static func graph(from value: Any?) -> [String: Any]? {
        if let graph = value as? [String: Any] { return graph }
        guard let text = value as? String,
              let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
        else { return nil }
        return object
    }

    // MARK: - SQLite read

    private struct FileRow {
        let id: String
        let fileName: String
        let createdAt: Double
        let meta: String
    }

    private struct Rows {
        let files: [FileRow]
        let chats: [(id: String, chat: String)]
    }

    private func readRows() -> Rows? {
        // Read-only in place sees the freshest committed data (including WAL).
        // If that fails (e.g. the -shm/-wal sidecars aren't accessible), fall back
        // to an immutable open that reads the main file only — slightly stale but
        // never blocked by Open WebUI holding the database open.
        readRows(uri: databaseURL.path, flags: SQLITE_OPEN_READONLY)
            ?? readRows(uri: immutableURI(for: databaseURL), flags: SQLITE_OPEN_READONLY | SQLITE_OPEN_URI)
    }

    private func readRows(uri: String, flags: Int32) -> Rows? {
        var db: OpaquePointer?
        guard sqlite3_open_v2(uri, &db, flags, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return nil
        }
        defer { sqlite3_close(db) }

        var files: [FileRow] = []
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT id, filename, created_at, meta FROM file", -1, &statement, nil) == SQLITE_OK else {
            sqlite3_finalize(statement)
            return nil
        }
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let idC = sqlite3_column_text(statement, 0),
                  let nameC = sqlite3_column_text(statement, 1),
                  let metaC = sqlite3_column_text(statement, 3)
            else { continue }
            files.append(FileRow(
                id: String(cString: idC),
                fileName: String(cString: nameC),
                createdAt: sqlite3_column_double(statement, 2),
                meta: String(cString: metaC)
            ))
        }
        sqlite3_finalize(statement)

        var chats: [(id: String, chat: String)] = []
        statement = nil
        guard sqlite3_prepare_v2(db, "SELECT id, chat FROM chat", -1, &statement, nil) == SQLITE_OK else {
            sqlite3_finalize(statement)
            return nil
        }
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let idC = sqlite3_column_text(statement, 0),
                  let chatC = sqlite3_column_text(statement, 1)
            else { continue }
            chats.append((id: String(cString: idC), chat: String(cString: chatC)))
        }
        sqlite3_finalize(statement)
        return Rows(files: files, chats: chats)
    }

    private func immutableURI(for url: URL) -> String {
        let encoded = url.path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? url.path
        return "file:\(encoded)?immutable=1"
    }

    // MARK: - Helpers

    private static func intValue(_ value: Any?) -> Int {
        (value as? NSNumber)?.intValue ?? 0
    }

    private static func minDate(_ a: Date?, _ b: Date) -> Date {
        guard let a else { return b }
        return min(a, b)
    }

    private static func maxDate(_ a: Date?, _ b: Date) -> Date {
        guard let a else { return b }
        return max(a, b)
    }

    static func defaultDatabaseURL() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Projects/Qwen-Image-2.1/open-webui/data/webui.db", isDirectory: false)
    }
}
