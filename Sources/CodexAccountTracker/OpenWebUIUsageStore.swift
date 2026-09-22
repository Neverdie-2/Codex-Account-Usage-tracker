import Foundation
import SQLite3

/// Reads Open WebUI's local SQLite database (the private Qwen Image Editor
/// install under ~/Projects/Qwen-Image-2.1) and turns every assistant turn that
/// carries a `usage` object into a usage record for the Open WebUI dashboard.
///
/// The chat assistant behind Open WebUI is a local llama-server, so nothing here
/// is billed; the dashboard prices the tokens at the base model's cloud rate as
/// estimated savings, like the LM Studio panel. Prompt and reply text are never
/// read into a record — only ids, timestamps and token counts.
final class OpenWebUIUsageStore {
    private let databaseURL: URL
    private let assistantStateURL: URL

    init(
        databaseURL: URL = OpenWebUIUsageStore.defaultDatabaseURL(),
        assistantStateURL: URL = OpenWebUIUsageStore.defaultAssistantStateURL()
    ) {
        self.databaseURL = databaseURL
        self.assistantStateURL = assistantStateURL
    }

    static let endpoint = "Open WebUI"
    static let chatProject = "Open WebUI chats"
    static let unknownModel = "unknown local model"

    func scan() -> AzureUsageScanResult {
        var result = AzureUsageScanResult(provider: .openWebUI)
        guard FileManager.default.fileExists(atPath: databaseURL.path) else {
            return result // Open WebUI not installed / data folder moved — empty, no warnings.
        }
        guard let rows = readChatRows() else {
            result.summary.warnings.append("Could not read Open WebUI database at \(databaseURL.path).")
            return result
        }

        let modelLabel = Self.modelLabel(fromStateFileAt: assistantStateURL)
        for row in rows {
            guard let object = try? JSONSerialization.jsonObject(with: Data(row.chat.utf8)) as? [String: Any] else {
                result.summary.malformedEventsSkipped += 1
                continue
            }
            let records = Self.records(
                fromChat: object,
                chatID: row.id,
                filePath: databaseURL.path,
                modelLabel: modelLabel
            )
            for record in records {
                result.records.append(record)
                result.summary.eventsCounted += 1
                result.summary.earliestEvent = Self.minDate(result.summary.earliestEvent, record.timestamp)
                result.summary.latestEvent = Self.maxDate(result.summary.latestEvent, record.timestamp)
            }
        }

        if !result.records.isEmpty {
            result.summary.filesScanned = 1
            result.summary.sessionsScanned = Set(result.records.map(\.sessionID)).count
            result.summary.providerSessions = result.summary.sessionsScanned
            result.records.sort { $0.timestamp < $1.timestamp }
        }
        return result
    }

    /// Pure mapping from one chat's JSON to usage records: one record per
    /// assistant message in `history.messages` that carries a `usage` object.
    /// Turns without usage are aborted/failed turns (no inference finished) and
    /// are skipped.
    ///
    /// Open WebUI's `merge_usage` SUMS `input_tokens`/`output_tokens`/`total_tokens`
    /// across the tool-call rounds of one turn but keeps only the LAST round's
    /// llama.cpp fields (`prompt_tokens`, `completion_tokens`, `cache_n`). So the
    /// summed fields are the turn's real totals, and `cache_n` is only trusted
    /// when the turn had a single round.
    static func records(
        fromChat chat: [String: Any],
        chatID: String,
        filePath: String,
        modelLabel: String?
    ) -> [AzureUsageRecord] {
        guard let history = chat["history"] as? [String: Any],
              let messages = history["messages"] as? [String: Any]
        else { return [] }

        var records: [AzureUsageRecord] = []
        for (messageID, value) in messages {
            guard let message = value as? [String: Any],
                  (message["role"] as? String) == "assistant",
                  let usage = message["usage"] as? [String: Any]
            else { continue }

            let summedInput = intValue(usage["input_tokens"])
            let lastRoundInput = intValue(usage["prompt_tokens"])
            let input = summedInput > 0 ? summedInput : lastRoundInput
            let summedOutput = intValue(usage["output_tokens"])
            let output = summedOutput > 0 ? summedOutput : intValue(usage["completion_tokens"])
            guard input > 0 || output > 0 else { continue }

            let singleRound = lastRoundInput == 0 || lastRoundInput == input
            let cached = singleRound ? min(intValue(usage["cache_n"]), input) : 0
            let summedTotal = intValue(usage["total_tokens"])
            let total = summedTotal > 0 ? summedTotal : input + output

            // A turn we can't date is invisible in every relative window — skip it.
            guard let seconds = (message["timestamp"] as? NSNumber)?.doubleValue, seconds > 0 else { continue }
            let timestamp = Date(timeIntervalSince1970: seconds)

            let profile = (message["model"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            let model = modelLabel ?? profile ?? unknownModel

            let tokenUsage = AzureTokenUsage(
                inputTokens: input,
                cachedInputTokens: cached,
                cacheCreationInputTokens: 0,
                outputTokens: output,
                reasoningOutputTokens: 0,
                totalTokens: total
            )
            records.append(AzureUsageRecord(
                id: "open-webui-\(chatID)-\(messageID)",
                sessionID: chatID,
                filePath: filePath,
                timestamp: timestamp,
                endpoint: endpoint,
                resource: profile ?? "chat",
                deployment: model,
                model: model,
                projectPath: chatProject,
                usage: tokenUsage
            ))
        }
        return records.sorted { $0.timestamp < $1.timestamp }
    }

    /// The llama-server behind Open WebUI answers under an alias
    /// ("qwen-local-assistant"), which says nothing about the real model. The
    /// launcher's state file records the server's argv, and the GGUF file name
    /// after `--model` names the model — that is the label pricing can match.
    static func modelLabel(fromStateFileAt url: URL) -> String? {
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let argv = object["argv"] as? [String]
        else { return nil }
        return modelLabel(fromArgv: argv)
    }

    static func modelLabel(fromArgv argv: [String]) -> String? {
        guard let index = argv.firstIndex(of: "--model"), index + 1 < argv.count else { return nil }
        let name = URL(fileURLWithPath: argv[index + 1]).deletingPathExtension().lastPathComponent
        return name.isEmpty ? nil : name.lowercased()
    }

    // MARK: - SQLite read

    private struct ChatRow {
        let id: String
        let chat: String
    }

    private func readChatRows() -> [ChatRow]? {
        // Read-only in place sees the freshest committed data (including WAL).
        // If that fails (e.g. the -shm/-wal sidecars aren't accessible), fall back
        // to an immutable open that reads the main file only — slightly stale but
        // never blocked by Open WebUI holding the database open.
        readChatRows(uri: databaseURL.path, flags: SQLITE_OPEN_READONLY)
            ?? readChatRows(uri: immutableURI(for: databaseURL), flags: SQLITE_OPEN_READONLY | SQLITE_OPEN_URI)
    }

    private func readChatRows(uri: String, flags: Int32) -> [ChatRow]? {
        var db: OpaquePointer?
        guard sqlite3_open_v2(uri, &db, flags, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return nil
        }
        defer { sqlite3_close(db) }

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT id, chat FROM chat", -1, &statement, nil) == SQLITE_OK else {
            sqlite3_finalize(statement)
            return nil
        }
        defer { sqlite3_finalize(statement) }

        var rows: [ChatRow] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let idC = sqlite3_column_text(statement, 0),
                  let chatC = sqlite3_column_text(statement, 1)
            else { continue }
            rows.append(ChatRow(id: String(cString: idC), chat: String(cString: chatC)))
        }
        return rows
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

    static func defaultDataDirectoryURL() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Projects/Qwen-Image-2.1", isDirectory: true)
    }

    static func defaultDatabaseURL() -> URL {
        defaultDataDirectoryURL().appendingPathComponent("open-webui/data/webui.db", isDirectory: false)
    }

    static func defaultAssistantStateURL() -> URL {
        defaultDataDirectoryURL().appendingPathComponent("runtime/chat-assistant-server.json", isDirectory: false)
    }
}
