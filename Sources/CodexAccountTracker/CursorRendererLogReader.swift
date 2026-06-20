import Foundation

/// A single `[buildRequestedModel]` mention parsed out of a Cursor `renderer.log`.
/// `localTimestamp` is the leading timestamp portion of the log line; `modelName`
/// is the token logged immediately after the marker.
struct CursorRendererModelMention: Equatable {
    var localTimestamp: String
    var modelName: String
}

/// Reads Cursor's per-session `renderer.log` files to recover the models the
/// editor actually requested via `[buildRequestedModel]` log lines. The state DB
/// records which models a composer *can* use; the renderer log is the only place
/// the build-time model selection is observable.
final class CursorRendererLogReader {
    /// Marker emitted by Cursor right before the requested model name.
    private static let marker = "[buildRequestedModel]"

    private let logsDirectory: URL
    private let fileManager: FileManager

    init(logsDirectory: URL = CursorRendererLogReader.defaultLogsDirectory()) {
        self.logsDirectory = logsDirectory
        self.fileManager = .default
    }

    /// `~/Library/Application Support/Cursor/logs`.
    static func defaultLogsDirectory() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Cursor/logs", isDirectory: true)
    }

    /// Parse every `[buildRequestedModel]` mention from the newest log session.
    ///
    /// Cursor stores one timestamped subdirectory per launch; within each there
    /// are `window*` subdirectories that hold a `renderer.log`. We pick the
    /// newest session by modification date and concatenate the mentions from each
    /// of its window logs in file order. A missing logs dir / no sessions yields
    /// an empty array; this never throws or crashes.
    func buildRequestedModels() -> [CursorRendererModelMention] {
        guard let session = newestSessionDirectory() else { return [] }

        let windows = (try? fileManager.contentsOfDirectory(
            at: session,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        var mentions: [CursorRendererModelMention] = []
        for window in windows.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            guard window.lastPathComponent.hasPrefix("window"),
                  isDirectory(window) else { continue }

            let logURL = window.appendingPathComponent("renderer.log", isDirectory: false)
            guard let contents = try? String(contentsOf: logURL, encoding: .utf8) else { continue }
            mentions.append(contentsOf: Self.parseBuildRequestedModels(from: contents))
        }
        return mentions
    }

    /// Pure parser over the raw log text. For every line containing the
    /// `[buildRequestedModel]` marker, the model name is the trimmed token
    /// following the marker and the local timestamp is everything before the
    /// first " [". Lines without the marker or without a trailing model token are
    /// skipped. Mentions are returned in file order.
    static func parseBuildRequestedModels(from logContents: String) -> [CursorRendererModelMention] {
        var mentions: [CursorRendererModelMention] = []
        let lines = logContents.split(separator: "\n", omittingEmptySubsequences: false)

        for line in lines {
            guard let markerRange = line.range(of: marker) else { continue }

            let modelName = line[markerRange.upperBound...]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !modelName.isEmpty else { continue }

            let timestamp: String
            if let bracketRange = line.range(of: " [") {
                timestamp = line[line.startIndex..<bracketRange.lowerBound]
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            } else {
                timestamp = ""
            }

            mentions.append(CursorRendererModelMention(localTimestamp: timestamp, modelName: modelName))
        }
        return mentions
    }

    // MARK: - Helpers

    /// Newest immediate subdirectory of `logsDirectory` by content-modification
    /// date, or `nil` when the logs dir is absent or holds no subdirectories.
    private func newestSessionDirectory() -> URL? {
        let entries = (try? fileManager.contentsOfDirectory(
            at: logsDirectory,
            includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        var newest: URL?
        var newestDate = Date.distantPast
        for entry in entries {
            guard isDirectory(entry) else { continue }
            let modified = (try? entry.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? Date.distantPast
            if newest == nil || modified > newestDate {
                newest = entry
                newestDate = modified
            }
        }
        return newest
    }

    private func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
    }
}
