import Foundation

/// Core TABLE-1 extraction for Cursor usage. Reads `composer.composerHeaders`
/// and the per-composer `bubbleId:` rows out of Cursor's `state.vscdb`, never
/// touching raw message text — counts, models, line deltas, and activity windows
/// only. Mirrors the dashboard(from:window:now:) shape of `AzureUsageScanner`.
final class CursorUsageScanner {
    private let reader: CursorStateDBReader
    private let rendererLogReader: CursorRendererLogReader

    init(
        reader: CursorStateDBReader = CursorStateDBReader(),
        rendererLogReader: CursorRendererLogReader = CursorRendererLogReader()
    ) {
        self.reader = reader
        self.rendererLogReader = rendererLogReader
    }

    func scan(now: Date = Date(), calendar: Calendar = .current) -> CursorUsageScanResult {
        guard let connection = reader.open() else {
            var summary = CursorUsageSummary()
            summary.databaseFound = false
            summary.warnings.append("Cursor state database not found at \(reader.databasePath).")
            return CursorUsageScanResult(records: [], summary: summary)
        }
        defer { connection.close() }

        var summary = CursorUsageSummary()
        summary.databaseFound = true

        let composers = parseComposers(connection: connection)
        summary.composersScanned = composers.count

        var recordsByID: [String: CursorUsageRecord] = [:]
        var bubblesScanned = 0
        // (modelName, bubbleCreatedAt) pairs across every composer; used to roll up
        // the "models used today" chip row against the local day of `now`.
        var todayModelCandidates: [(model: String, createdAt: Date)] = []

        for composer in composers {
            guard let composerId = Self.stringValue(composer["composerId"]), !composerId.isEmpty else {
                continue
            }

            let conversationId = composerId
            let recordID = "cursor-composer-\(composerId)"

            let workspace = Self.workspace(from: composer["workspaceIdentifier"])
            let title = Self.title(from: composer)
            let mode = Self.stringValue(composer["unifiedMode"])
                ?? Self.stringValue(composer["forceMode"])
                ?? "unknown"

            let linesAdded = Self.intValue(composer["totalLinesAdded"])
            let linesRemoved = Self.intValue(composer["totalLinesRemoved"])
            let filesChanged = Self.intValue(composer["filesChangedCount"])
            let contextUsagePct = Self.doubleValue(composer["contextUsagePercent"])

            let composerCreatedAt = Self.msEpochDate(composer["createdAt"])
            let composerUpdatedAt = Self.msEpochDate(composer["lastUpdatedAt"])

            // Per-composer bubble rows: cursorDiskKV keys "bubbleId:<composerId>-<bubbleId>".
            let bubbleRows = connection.cursorDiskKVValues(likePrefix: "bubbleId:\(composerId)-")
            bubblesScanned += bubbleRows.count

            var userCount = 0
            var assistantCount = 0
            var modelsUsed: [String] = []
            var seenModels = Set<String>()
            var earliestBubble: Date?
            var latestBubble: Date?

            for row in bubbleRows {
                guard let bubble = Self.jsonObject(from: row.value) else { continue }
                let type = Self.intValue(bubble["type"])
                let bubbleDate = CursorAccountRecord.parseISO8601(Self.stringValue(bubble["createdAt"]))

                if type == 1 {
                    userCount += 1
                } else if type == 2 {
                    assistantCount += 1
                }

                let modelName = Self.stringValue((bubble["modelInfo"] as? [String: Any])?["modelName"])

                if type == 1, let modelName, !modelName.isEmpty {
                    if seenModels.insert(modelName).inserted {
                        modelsUsed.append(modelName)
                    }
                    if let bubbleDate {
                        todayModelCandidates.append((model: modelName, createdAt: bubbleDate))
                    }
                }

                if let bubbleDate {
                    earliestBubble = Self.minDate(earliestBubble, bubbleDate)
                    latestBubble = Self.maxDate(latestBubble, bubbleDate)
                }
            }

            let messageCount = bubbleRows.count

            let firstActivity = Self.minDate(composerCreatedAt, earliestBubble)
            let lastActivity = Self.maxDate(composerUpdatedAt, latestBubble)

            let record = CursorUsageRecord(
                id: recordID,
                conversationId: conversationId,
                workspace: workspace,
                title: title,
                mode: mode,
                modelsUsed: modelsUsed,
                userCount: userCount,
                assistantCount: assistantCount,
                messageCount: messageCount,
                linesAdded: linesAdded,
                linesRemoved: linesRemoved,
                filesChanged: filesChanged,
                contextUsagePct: contextUsagePct,
                firstActivity: firstActivity,
                lastActivity: lastActivity
            )
            // Dedupe by id, last wins.
            recordsByID[recordID] = record
        }

        summary.bubblesScanned = bubblesScanned

        let todayStart = calendar.startOfDay(for: now)
        var todaySeen = Set<String>()
        var modelsUsedToday: [String] = []
        for candidate in todayModelCandidates where calendar.startOfDay(for: candidate.createdAt) == todayStart {
            if todaySeen.insert(candidate.model).inserted {
                modelsUsedToday.append(candidate.model)
            }
        }
        summary.modelsUsedToday = modelsUsedToday

        let records = Self.sortedByLastActivityDescending(Array(recordsByID.values))
        return CursorUsageScanResult(records: records, summary: summary)
    }

    func currentFingerprint() -> CodexLocalUsageFileFingerprint? {
        reader.fingerprint()
    }

    static func dashboard(
        from result: CursorUsageScanResult,
        window: CursorUsageTimeWindow,
        now: Date,
        calendar: Calendar = .current
    ) -> CursorUsageDashboard {
        let start = window.startDate(now: now, calendar: calendar)
        let filtered = result.records.filter { record in
            guard let start else { return true }
            guard let lastActivity = record.lastActivity else { return false }
            return lastActivity >= start
        }

        return CursorUsageDashboard(
            records: sortedByLastActivityDescending(filtered),
            modelsUsedToday: result.summary.modelsUsedToday,
            summary: result.summary
        )
    }

    // MARK: - Composer parsing

    private func parseComposers(connection: CursorStateDBConnection) -> [[String: Any]] {
        guard let headers = connection.itemValue(key: "composer.composerHeaders"),
              let object = Self.jsonObject(from: headers),
              let allComposers = object["allComposers"] as? [Any]
        else {
            return []
        }
        return allComposers.compactMap { $0 as? [String: Any] }
    }

    private static func workspace(from value: Any?) -> CursorWorkspaceProject {
        guard let identifier = value as? [String: Any] else {
            return CursorWorkspaceProject(path: nil, id: nil)
        }
        let path = stringValue((identifier["uri"] as? [String: Any])?["path"])
        let id = stringValue(identifier["id"])
        return CursorWorkspaceProject(path: path, id: id)
    }

    private static func title(from composer: [String: Any]) -> String {
        if let name = stringValue(composer["name"]),
           !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return name
        }
        if let subtitle = stringValue(composer["subtitle"]),
           !subtitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return subtitle
        }
        return "Untitled"
    }

    // MARK: - Sorting

    private static func sortedByLastActivityDescending(_ records: [CursorUsageRecord]) -> [CursorUsageRecord] {
        records.sorted { lhs, rhs in
            let lhsDate = lhs.lastActivity ?? .distantPast
            let rhsDate = rhs.lastActivity ?? .distantPast
            if lhsDate != rhsDate { return lhsDate > rhsDate }
            return lhs.id.localizedCaseInsensitiveCompare(rhs.id) == .orderedAscending
        }
    }

    // MARK: - JSON helpers

    private static func jsonObject(from string: String) -> [String: Any]? {
        guard let data = string.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return nil
        }
        return object
    }

    private static func stringValue(_ value: Any?) -> String? {
        value as? String
    }

    /// NSNumber bridging survives both integer and float JSON serialization,
    /// where `as? Int` would return nil for a float.
    private static func intValue(_ value: Any?) -> Int {
        (value as? NSNumber)?.intValue ?? 0
    }

    private static func doubleValue(_ value: Any?) -> Double? {
        (value as? NSNumber)?.doubleValue
    }

    /// `createdAt` / `lastUpdatedAt` are millisecond-epoch numbers.
    private static func msEpochDate(_ value: Any?) -> Date? {
        guard let ms = (value as? NSNumber)?.doubleValue, ms > 0 else { return nil }
        return Date(timeIntervalSince1970: ms / 1000)
    }

    private static func minDate(_ lhs: Date?, _ rhs: Date?) -> Date? {
        switch (lhs, rhs) {
        case let (lhs?, rhs?): return min(lhs, rhs)
        case let (lhs?, nil): return lhs
        case let (nil, rhs?): return rhs
        case (nil, nil): return nil
        }
    }

    private static func maxDate(_ lhs: Date?, _ rhs: Date?) -> Date? {
        switch (lhs, rhs) {
        case let (lhs?, rhs?): return max(lhs, rhs)
        case let (lhs?, nil): return lhs
        case let (nil, rhs?): return rhs
        case (nil, nil): return nil
        }
    }
}
