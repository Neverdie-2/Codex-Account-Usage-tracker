import Foundation
import SQLite3

/// SQLite text bindings must be copied (not pointed-at) because the bound Swift
/// String can be deallocated before `sqlite3_step` runs.
private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Scalar metadata for one `composerData:<id>` conversation row.
struct CursorComposerMetaRow: Equatable {
    let composerId: String
    let createdAtMs: Double?
    let unifiedMode: String?
    let forceMode: String?
    let linesAdded: Int
    let linesRemoved: Int
}

/// Scalar fields of one `bubbleId:<composerId>:<uuid>` row.
struct CursorBubbleRow: Equatable {
    let composerId: String
    let type: Int
    let modelName: String?
    let createdAt: String?
    let workspaceProjectDir: String?
}

/// Reads Cursor's `state.vscdb` (a WAL-mode SQLite database Cursor holds open
/// while running). To get a consistent read without racing Cursor's writes, we
/// copy the live main file plus any `-wal`/`-shm` sidecars into a private temp
/// directory and open the copy read-only. The temp directory is removed when the
/// connection closes.
final class CursorStateDBReader {
    private let databaseURL: URL

    init(databaseURL: URL = CursorStateDBReader.defaultDatabaseURL()) {
        self.databaseURL = databaseURL
    }

    static func defaultDatabaseURL() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(
                "Library/Application Support/Cursor/User/globalStorage/state.vscdb",
                isDirectory: false
            )
    }

    /// True when the live main database file exists on disk.
    var databaseExists: Bool {
        FileManager.default.fileExists(atPath: databaseURL.path)
    }

    /// Filesystem path of the live `state.vscdb` (for diagnostics/empty-state UI).
    var databasePath: String {
        databaseURL.path
    }

    /// Fingerprint of the live main file (size + mtime) for change detection.
    func fingerprint() -> CodexLocalUsageFileFingerprint? {
        CodexLocalUsageFileFingerprint.make(fileURL: databaseURL)
    }

    /// Copy the live db (+ existing sidecars) to a temp dir and open the copy
    /// read-only. Returns nil if the main file is missing or the copy/open fails.
    func open() -> CursorStateDBConnection? {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: databaseURL.path) else { return nil }

        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("cursor-state-\(UUID().uuidString)", isDirectory: true)
        do {
            try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
        } catch {
            return nil
        }

        let copiedMainURL = tempDir.appendingPathComponent(databaseURL.lastPathComponent, isDirectory: false)
        do {
            try fileManager.copyItem(at: databaseURL, to: copiedMainURL)
        } catch {
            try? fileManager.removeItem(at: tempDir)
            return nil
        }

        // Copy the WAL/SHM sidecars only if they exist; a missing sidecar is fine.
        for suffix in ["-wal", "-shm"] {
            let sidecarSource = URL(
                fileURLWithPath: databaseURL.path + suffix,
                isDirectory: false
            )
            guard fileManager.fileExists(atPath: sidecarSource.path) else { continue }
            let sidecarDest = URL(
                fileURLWithPath: copiedMainURL.path + suffix,
                isDirectory: false
            )
            try? fileManager.copyItem(at: sidecarSource, to: sidecarDest)
        }

        var db: OpaquePointer?
        guard sqlite3_open_v2(copiedMainURL.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
              let handle = db
        else {
            sqlite3_close(db)
            try? fileManager.removeItem(at: tempDir)
            return nil
        }

        sqlite3_exec(handle, "PRAGMA query_only=ON;", nil, nil, nil)

        return CursorStateDBConnection(db: handle, tempDirectoryURL: tempDir)
    }

    /// Convenience: open, read one ItemTable value, close.
    func itemValue(key: String) -> String? {
        guard let connection = open() else { return nil }
        defer { connection.close() }
        return connection.itemValue(key: key)
    }
}

/// An open, read-only connection to a copied `state.vscdb`. Owns the SQLite
/// handle and the temp directory; both are released by `close()` (also called
/// from `deinit` as a safety net).
final class CursorStateDBConnection {
    private var db: OpaquePointer?
    private let tempDirectoryURL: URL
    private var isClosed = false

    init(db: OpaquePointer, tempDirectoryURL: URL) {
        self.db = db
        self.tempDirectoryURL = tempDirectoryURL
    }

    deinit {
        close()
    }

    /// `SELECT value FROM ItemTable WHERE key = ? LIMIT 1` — first value or nil.
    func itemValue(key: String) -> String? {
        guard let db else { return nil }

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(
            db,
            "SELECT value FROM ItemTable WHERE key = ? LIMIT 1",
            -1,
            &statement,
            nil
        ) == SQLITE_OK else {
            sqlite3_finalize(statement)
            return nil
        }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_text(statement, 1, key, -1, SQLITE_TRANSIENT)

        guard sqlite3_step(statement) == SQLITE_ROW,
              let valueC = sqlite3_column_text(statement, 0)
        else { return nil }
        return String(cString: valueC)
    }

    /// Per-conversation metadata pulled straight from the `composerData:<id>`
    /// rows with SQL `json_extract`, so the (often large) conversation blobs are
    /// never materialised in Swift. This is the authoritative conversation list
    /// (Cursor keeps far more here than `composer.composerHeaders` exposes).
    func composerMetadataRows() -> [CursorComposerMetaRow] {
        guard let db else { return [] }

        let sql = """
        SELECT substr(key, 14),
               json_extract(value, '$.createdAt'),
               json_extract(value, '$.unifiedMode'),
               json_extract(value, '$.forceMode'),
               json_extract(value, '$.totalLinesAdded'),
               json_extract(value, '$.totalLinesRemoved')
        FROM cursorDiskKV WHERE key LIKE 'composerData:%'
        """

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            sqlite3_finalize(statement)
            return []
        }
        defer { sqlite3_finalize(statement) }

        var rows: [CursorComposerMetaRow] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let composerIdC = sqlite3_column_text(statement, 0) else { continue }
            let composerId = String(cString: composerIdC)
            guard !composerId.isEmpty else { continue }
            rows.append(CursorComposerMetaRow(
                composerId: composerId,
                createdAtMs: Self.optionalDouble(statement, 1),
                unifiedMode: Self.optionalText(statement, 2),
                forceMode: Self.optionalText(statement, 3),
                linesAdded: Int(Self.optionalDouble(statement, 4) ?? 0),
                linesRemoved: Int(Self.optionalDouble(statement, 5) ?? 0)
            ))
        }
        return rows
    }

    /// All bubbles across all conversations, with only the scalar fields the
    /// usage scan needs (`type`, served `modelName`, `createdAt`, workspace dir)
    /// extracted via SQL — the full bubble JSON (code blocks, diffs, thinking…)
    /// is left in SQLite. `composerId` is parsed from the
    /// `bubbleId:<composerId>:<bubbleUuid>` key.
    func bubbleRows() -> [CursorBubbleRow] {
        guard let db else { return [] }

        let sql = """
        SELECT key,
               json_extract(value, '$.type'),
               json_extract(value, '$.modelInfo.modelName'),
               json_extract(value, '$.createdAt'),
               json_extract(value, '$.workspaceProjectDir')
        FROM cursorDiskKV WHERE key LIKE 'bubbleId:%'
        """

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            sqlite3_finalize(statement)
            return []
        }
        defer { sqlite3_finalize(statement) }

        var rows: [CursorBubbleRow] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let keyC = sqlite3_column_text(statement, 0) else { continue }
            let key = String(cString: keyC)
            // bubbleId:<composerId>:<bubbleUuid> — composerId is the 2nd segment.
            let parts = key.components(separatedBy: ":")
            guard parts.count >= 3, !parts[1].isEmpty else { continue }
            rows.append(CursorBubbleRow(
                composerId: parts[1],
                type: Int(Self.optionalDouble(statement, 1) ?? 0),
                modelName: Self.optionalText(statement, 2),
                createdAt: Self.optionalText(statement, 3),
                workspaceProjectDir: Self.optionalText(statement, 4)
            ))
        }
        return rows
    }

    private static func optionalText(_ statement: OpaquePointer?, _ index: Int32) -> String? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL,
              let c = sqlite3_column_text(statement, index) else { return nil }
        return String(cString: c)
    }

    private static func optionalDouble(_ statement: OpaquePointer?, _ index: Int32) -> Double? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL else { return nil }
        return sqlite3_column_double(statement, index)
    }

    /// `SELECT key, value FROM cursorDiskKV WHERE key LIKE <prefix>%`. The
    /// caller-provided prefix already includes its trailing separator so the
    /// match anchors to the start of the key.
    func cursorDiskKVValues(likePrefix: String) -> [(key: String, value: String)] {
        guard let db else { return [] }

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(
            db,
            "SELECT key, value FROM cursorDiskKV WHERE key LIKE ?",
            -1,
            &statement,
            nil
        ) == SQLITE_OK else {
            sqlite3_finalize(statement)
            return []
        }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_text(statement, 1, likePrefix + "%", -1, SQLITE_TRANSIENT)

        var results: [(key: String, value: String)] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let keyC = sqlite3_column_text(statement, 0),
                  let valueC = sqlite3_column_text(statement, 1)
            else { continue }
            results.append((key: String(cString: keyC), value: String(cString: valueC)))
        }
        return results
    }

    /// Finalize/close the handle and remove the temp directory. Idempotent.
    func close() {
        guard !isClosed else { return }
        isClosed = true
        if let db {
            sqlite3_close(db)
            self.db = nil
        }
        try? FileManager.default.removeItem(at: tempDirectoryURL)
    }
}
