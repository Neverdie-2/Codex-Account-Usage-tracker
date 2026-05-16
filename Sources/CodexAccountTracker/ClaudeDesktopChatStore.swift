import Foundation

/// Snapshots the Claude desktop chat app's ~/Library/Application Support/Claude/buddy-tokens.json
/// so daily totals are not lost when the file rolls over at midnight.
/// Aggregates synthetic AzureUsageRecord entries for the Claude Code dashboard.
final class ClaudeDesktopChatStore {
    private let buddyTokensURL: URL
    private let cacheURL: URL

    init(
        buddyTokensURL: URL = ClaudeDesktopChatStore.defaultBuddyTokensURL(),
        cacheDirectoryURL: URL = AzureUsageCacheStore.defaultDirectoryURL()
    ) {
        self.buddyTokensURL = buddyTokensURL
        self.cacheURL = cacheDirectoryURL.appendingPathComponent("claude-desktop-chat-cache.json")
    }

    /// Read the latest buddy-tokens.json, merge into the cache (keeping the daily max),
    /// and return all known daily entries.
    @discardableResult
    func refreshAndLoad() -> [DailyEntry] {
        var entries = loadCache()

        if let snapshot = readCurrentBuddyTokens() {
            let existing = entries.first { $0.date == snapshot.date }?.tokens ?? 0
            // The buddy counter resets daily; within the same date it grows monotonically.
            let newTokens = max(existing, snapshot.tokens)
            entries.removeAll { $0.date == snapshot.date }
            entries.append(DailyEntry(date: snapshot.date, tokens: newTokens))
            saveCache(entries)
        }

        return entries.sorted { $0.date < $1.date }
    }

    func loadCachedRecords() -> [AzureUsageRecord] {
        recordsFromEntries(loadCache())
    }

    func recordsFromEntries(_ entries: [DailyEntry]) -> [AzureUsageRecord] {
        entries.compactMap { entry in
            guard entry.tokens > 0, let timestamp = dateFromString(entry.date) else { return nil }
            // Chat traffic is heavy on context; estimate 90/10 input/output to keep cost conservative-ish.
            let outputTokens = max(1, entry.tokens / 10)
            let inputTokens = entry.tokens - outputTokens
            let usage = AzureTokenUsage(
                inputTokens: inputTokens,
                cachedInputTokens: 0,
                cacheCreationInputTokens: 0,
                outputTokens: outputTokens,
                reasoningOutputTokens: 0,
                totalTokens: entry.tokens
            )
            return AzureUsageRecord(
                id: "claude-desktop-chat-\(entry.date)",
                sessionID: "claude-desktop-chat-\(entry.date)",
                filePath: buddyTokensURL.path,
                timestamp: timestamp,
                endpoint: "Anthropic (chat)",
                resource: "Claude Desktop chat",
                deployment: "claude-opus-4-7",
                model: "claude-opus-4-7",
                projectPath: "Claude Desktop chat",
                projectName: "Claude Desktop chat",
                usage: usage
            )
        }
    }

    struct DailyEntry: Codable, Equatable {
        var date: String   // "yyyy-MM-dd"
        var tokens: Int
    }

    private struct CacheFile: Codable {
        var byDate: [String: Int]
    }

    private struct BuddySnapshot {
        var date: String
        var tokens: Int
    }

    private func readCurrentBuddyTokens() -> BuddySnapshot? {
        guard let data = try? Data(contentsOf: buddyTokensURL),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let today = obj["tokens-today"] as? [String: Any],
              let date = today["date"] as? String,
              let tokens = today["tokens"] as? Int
        else { return nil }
        return BuddySnapshot(date: date, tokens: tokens)
    }

    private func loadCache() -> [DailyEntry] {
        guard let data = try? Data(contentsOf: cacheURL),
              let decoded = try? JSONDecoder().decode(CacheFile.self, from: data)
        else { return [] }
        return decoded.byDate.map { DailyEntry(date: $0.key, tokens: $0.value) }
    }

    private func saveCache(_ entries: [DailyEntry]) {
        let cache = CacheFile(byDate: Dictionary(uniqueKeysWithValues: entries.map { ($0.date, $0.tokens) }))
        guard let data = try? JSONEncoder().encode(cache) else { return }
        try? FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: cacheURL, options: [.atomic])
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        return f
    }()

    private func dateFromString(_ s: String) -> Date? {
        // End of *local* day so the synthetic record buckets onto the right calendar day
        // and sorts after real Claude Code events from the same day.
        guard let day = Self.dateFormatter.date(from: s) else { return nil }
        return Calendar.current.date(bySettingHour: 23, minute: 59, second: 59, of: day) ?? day
    }

    static func defaultBuddyTokensURL() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Claude/buddy-tokens.json")
    }
}
