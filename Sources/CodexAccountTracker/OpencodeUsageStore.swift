import Foundation
import SQLite3

/// Reads opencode's local SQLite database (~/.local/share/opencode/opencode.db)
/// and turns assistant turns served by the local LM Studio server
/// (providerID == "lmstudio") into usage records for the LM Studio dashboard.
///
/// opencode talks to the LM Studio server at localhost:1234, so this is where
/// the real local-model usage lives — the LM Studio chat-app conversation files
/// only capture chats typed inside the app itself.
final class OpencodeUsageStore {
    private let databaseURL: URL

    init(databaseURL: URL = OpencodeUsageStore.defaultDatabaseURL()) {
        self.databaseURL = databaseURL
    }

    /// opencode's providerID for the local LM Studio server backend.
    static let lmStudioProviderID = "lmstudio"
    static let unknownModel = "unknown local model"
    static let unknownProject = "opencode"

    func scan() -> AzureUsageScanResult {
        var result = AzureUsageScanResult(provider: .lmStudio)
        guard FileManager.default.fileExists(atPath: databaseURL.path) else {
            return result // opencode not installed / never run — empty, no warnings.
        }
        guard let rows = readMessageRows() else {
            result.summary.warnings.append("Could not read opencode usage database at \(databaseURL.path).")
            return result
        }

        for row in rows {
            guard let record = Self.record(
                messageID: row.id,
                sessionID: row.sessionID,
                data: row.data,
                filePath: databaseURL.path
            ) else { continue }
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

    /// Pure mapping from one opencode message row to a usage record. Returns nil
    /// for anything that isn't a billable local-model assistant turn.
    static func record(messageID: String, sessionID: String, data: String, filePath: String) -> AzureUsageRecord? {
        guard let object = try? JSONSerialization.jsonObject(with: Data(data.utf8)) as? [String: Any],
              (object["role"] as? String) == "assistant",
              (object["providerID"] as? String) == lmStudioProviderID,
              let tokens = object["tokens"] as? [String: Any]
        else { return nil }

        let input = intValue(tokens["input"])
        let output = intValue(tokens["output"])
        let reasoning = intValue(tokens["reasoning"])
        let cache = tokens["cache"] as? [String: Any]
        let cacheRead = intValue(cache?["read"])
        let cacheWrite = intValue(cache?["write"])
        // Errored turns (e.g. context-exceeded) carry zero usage — skip them.
        guard input > 0 || output > 0 || reasoning > 0 else { return nil }

        // A turn we can't date is invisible in every relative window — skip it.
        guard let time = object["time"] as? [String: Any],
              let createdMs = (time["created"] as? NSNumber)?.doubleValue
        else { return nil }
        let timestamp = Date(timeIntervalSince1970: createdMs / 1000)

        let model = (object["modelID"] as? String) ?? unknownModel
        let cwd = (object["path"] as? [String: Any])?["cwd"] as? String
        let projectPath = (cwd?.isEmpty == false) ? cwd! : unknownProject

        let usage = AzureTokenUsage(
            inputTokens: input + cacheRead + cacheWrite,
            cachedInputTokens: cacheRead,
            cacheCreationInputTokens: cacheWrite,
            // opencode reports reasoning separately from output; fold it in so it
            // is billed like the output tokens it is.
            outputTokens: output + reasoning,
            reasoningOutputTokens: reasoning,
            totalTokens: input + cacheRead + cacheWrite + output + reasoning
        )

        return AzureUsageRecord(
            id: "opencode-\(messageID)",
            sessionID: sessionID,
            filePath: filePath,
            timestamp: timestamp,
            endpoint: "LM Studio",
            resource: "opencode",
            deployment: model,
            model: model,
            projectPath: projectPath,
            usage: usage
        )
    }

    // MARK: - SQLite read

    private struct MessageRow {
        let id: String
        let sessionID: String
        let data: String
    }

    private func readMessageRows() -> [MessageRow]? {
        // Read-only in place sees the freshest committed data (including WAL).
        // If that fails (e.g. the -shm/-wal sidecars aren't accessible), fall back
        // to an immutable open that reads the main file only — slightly stale but
        // never blocked by opencode holding the database open.
        readMessageRows(uri: databaseURL.path, flags: SQLITE_OPEN_READONLY)
            ?? readMessageRows(uri: immutableURI(for: databaseURL), flags: SQLITE_OPEN_READONLY | SQLITE_OPEN_URI)
    }

    private func readMessageRows(uri: String, flags: Int32) -> [MessageRow]? {
        var db: OpaquePointer?
        guard sqlite3_open_v2(uri, &db, flags, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return nil
        }
        defer { sqlite3_close(db) }

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT id, session_id, data FROM message", -1, &statement, nil) == SQLITE_OK else {
            sqlite3_finalize(statement)
            return nil
        }
        defer { sqlite3_finalize(statement) }

        var rows: [MessageRow] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let idC = sqlite3_column_text(statement, 0),
                  let sessionC = sqlite3_column_text(statement, 1),
                  let dataC = sqlite3_column_text(statement, 2)
            else { continue }
            rows.append(MessageRow(
                id: String(cString: idC),
                sessionID: String(cString: sessionC),
                data: String(cString: dataC)
            ))
        }
        return rows
    }

    private func immutableURI(for url: URL) -> String {
        let encoded = url.path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? url.path
        return "file:\(encoded)?immutable=1"
    }

    // MARK: - Helpers

    /// NSNumber bridging survives both integer and float JSON serialization,
    /// where `as? Int` would return nil for a float.
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
            .appendingPathComponent(".local/share/opencode/opencode.db", isDirectory: false)
    }
}
