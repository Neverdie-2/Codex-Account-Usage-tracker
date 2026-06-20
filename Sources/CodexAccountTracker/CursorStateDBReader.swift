import Foundation
import SQLite3

/// SQLite text bindings must be copied (not pointed-at) because the bound Swift
/// String can be deallocated before `sqlite3_step` runs.
private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

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

    /// `SELECT key, value FROM cursorDiskKV WHERE key LIKE <prefix>%`. The
    /// caller-provided prefix already includes its trailing hyphen so the match
    /// anchors to the start of the key.
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
