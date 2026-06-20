import Foundation
import SQLite3

/// `sqlite3_bind_text` keeps a pointer to the bound string; SQLITE_TRANSIENT tells
/// SQLite to copy it so it stays valid after the bind call returns.
private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Reads Cursor's optional AI-code-tracking SQLite database
/// (~/.cursor/ai-tracking/ai-code-tracking.db). This database is best-effort
/// telemetry that may be missing entirely, or present with empty/absent tables,
/// so every read degrades gracefully to nil/zero — it never crashes or throws.
final class CursorAITrackingDBReader {
    /// Composer-attributed line totals summed across every scored commit.
    struct ScoredCommitTotals: Equatable {
        var composerLinesAdded: Int
        var composerLinesDeleted: Int
    }

    private let databaseURL: URL

    init(databaseURL: URL = CursorAITrackingDBReader.defaultDatabaseURL()) {
        self.databaseURL = databaseURL
    }

    /// SUM of `composerLinesAdded`/`composerLinesDeleted` over `scored_commits`.
    /// Returns nil when the database or table is unavailable.
    func scoredCommitTotals() -> ScoredCommitTotals? {
        // Read-only in place sees the freshest committed data (including WAL).
        // If that fails (e.g. the -shm/-wal sidecars aren't accessible), fall back
        // to an immutable open that reads the main file only — slightly stale but
        // never blocked by Cursor holding the database open.
        scoredCommitTotals(uri: databaseURL.path, flags: SQLITE_OPEN_READONLY)
            ?? scoredCommitTotals(uri: immutableURI(for: databaseURL), flags: SQLITE_OPEN_READONLY | SQLITE_OPEN_URI)
    }

    /// `title` of one conversation from `conversation_summaries`. Returns nil when
    /// the row is missing, the title is empty, or the table/db is unavailable.
    /// This table is empty on most installs.
    func conversationTitle(conversationId: String) -> String? {
        conversationTitle(conversationId: conversationId, uri: databaseURL.path, flags: SQLITE_OPEN_READONLY)
            ?? conversationTitle(conversationId: conversationId, uri: immutableURI(for: databaseURL), flags: SQLITE_OPEN_READONLY | SQLITE_OPEN_URI)
    }

    // MARK: - SQLite read

    private func scoredCommitTotals(uri: String, flags: Int32) -> ScoredCommitTotals? {
        guard FileManager.default.fileExists(atPath: databaseURL.path) else { return nil }

        var db: OpaquePointer?
        guard sqlite3_open_v2(uri, &db, flags, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return nil
        }
        defer { sqlite3_close(db) }

        var statement: OpaquePointer?
        let sql = "SELECT COALESCE(SUM(composerLinesAdded), 0), COALESCE(SUM(composerLinesDeleted), 0) FROM scored_commits"
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            sqlite3_finalize(statement)
            return nil
        }
        defer { sqlite3_finalize(statement) }

        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        let added = Int(sqlite3_column_int64(statement, 0))
        let deleted = Int(sqlite3_column_int64(statement, 1))
        return ScoredCommitTotals(composerLinesAdded: added, composerLinesDeleted: deleted)
    }

    private func conversationTitle(conversationId: String, uri: String, flags: Int32) -> String? {
        guard FileManager.default.fileExists(atPath: databaseURL.path) else { return nil }

        var db: OpaquePointer?
        guard sqlite3_open_v2(uri, &db, flags, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return nil
        }
        defer { sqlite3_close(db) }

        var statement: OpaquePointer?
        let sql = "SELECT title FROM conversation_summaries WHERE conversationId = ? LIMIT 1"
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            sqlite3_finalize(statement)
            return nil
        }
        defer { sqlite3_finalize(statement) }

        guard sqlite3_bind_text(statement, 1, conversationId, -1, SQLITE_TRANSIENT) == SQLITE_OK else { return nil }
        guard sqlite3_step(statement) == SQLITE_ROW,
              let titleC = sqlite3_column_text(statement, 0)
        else { return nil }

        let title = String(cString: titleC).trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? nil : title
    }

    private func immutableURI(for url: URL) -> String {
        let encoded = url.path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? url.path
        return "file:\(encoded)?immutable=1"
    }

    static func defaultDatabaseURL() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cursor/ai-tracking/ai-code-tracking.db", isDirectory: false)
    }
}
