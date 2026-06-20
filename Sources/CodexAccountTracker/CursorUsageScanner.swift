import Foundation

/// Core TABLE-1 extraction for Cursor usage. The authoritative conversation list
/// lives in `composerData:<id>` rows; `composer.composerHeaders` only surfaces a
/// recent subset, so it is used purely to enrich (name / workspace / reset of the
/// display metadata). Bubbles join on the `bubbleId:<composerId>:<uuid>` key.
/// Never persists raw message text — counts, models, line deltas, and activity
/// windows only. Mirrors the dashboard(from:window:now:) shape of `AzureUsageScanner`.
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

        // Display metadata (name / workspace / lastUpdatedAt / filesChanged /
        // contextPct), available only for conversations Cursor keeps in headers.
        let headerMap = Self.headerMap(connection: connection)

        // The authoritative conversation list: composerData:<id> rows.
        var metaByID: [String: CursorComposerMetaRow] = [:]
        for row in connection.composerMetadataRows() {
            metaByID[row.composerId] = row
        }

        // Bubbles grouped by owning composer (key form bubbleId:<composerId>:<uuid>).
        var bubblesByComposer: [String: [CursorBubbleRow]] = [:]
        let allBubbles = connection.bubbleRows()
        for bubble in allBubbles {
            bubblesByComposer[bubble.composerId, default: []].append(bubble)
        }
        summary.bubblesScanned = allBubbles.count

        // Conversation set = composerData ids ∪ header ids. Orphan bubbles (no
        // composerData and no header) are ignored so a stray row can't fabricate
        // a conversation.
        var conversationIDs = Set(metaByID.keys)
        conversationIDs.formUnion(headerMap.keys)

        var recordsByID: [String: CursorUsageRecord] = [:]
        // (model, bubbleCreatedAt) across known conversations, for the today rollup.
        var todayModelCandidates: [(model: String, createdAt: Date)] = []

        for composerId in conversationIDs {
            let meta = metaByID[composerId]
            let header = headerMap[composerId]
            let bubbles = bubblesByComposer[composerId] ?? []

            var userCount = 0
            var assistantCount = 0
            var modelsUsed: [String] = []
            var seenModels = Set<String>()
            var earliestBubble: Date?
            var latestBubble: Date?
            var bubbleWorkspaceDir: String?

            for bubble in bubbles {
                if bubble.type == 1 {
                    userCount += 1
                } else if bubble.type == 2 {
                    assistantCount += 1
                }

                // Both user and assistant bubbles can carry the served model name;
                // the assistant bubble's value is the authoritative served model.
                if let model = bubble.modelName, !model.isEmpty {
                    if seenModels.insert(model).inserted {
                        modelsUsed.append(model)
                    }
                    if let date = CursorAccountRecord.parseISO8601(bubble.createdAt) {
                        todayModelCandidates.append((model: model, createdAt: date))
                    }
                }

                if let date = CursorAccountRecord.parseISO8601(bubble.createdAt) {
                    earliestBubble = Self.minDate(earliestBubble, date)
                    latestBubble = Self.maxDate(latestBubble, date)
                }
                if bubbleWorkspaceDir == nil, let dir = bubble.workspaceProjectDir, !dir.isEmpty {
                    bubbleWorkspaceDir = dir
                }
            }

            let messageCount = bubbles.count
            let metaLinesAdded = meta?.linesAdded ?? 0
            let metaLinesRemoved = meta?.linesRemoved ?? 0
            let linesAdded = metaLinesAdded != 0 ? metaLinesAdded : Self.intValue(header?["totalLinesAdded"])
            let linesRemoved = metaLinesRemoved != 0 ? metaLinesRemoved : Self.intValue(header?["totalLinesRemoved"])

            // Drop empty drafts: no bubbles, no line deltas, and not surfaced in headers.
            if messageCount == 0, linesAdded == 0, linesRemoved == 0, header == nil {
                continue
            }

            let workspace = Self.workspace(header: header, bubbleProjectDir: bubbleWorkspaceDir)
            let title = Self.title(header: header, composerId: composerId)
            let mode = meta?.unifiedMode
                ?? meta?.forceMode
                ?? Self.stringValue(header?["unifiedMode"])
                ?? "unknown"
            let filesChanged = Self.intValue(header?["filesChangedCount"])
            let contextUsagePct = Self.doubleValue(header?["contextUsagePercent"])

            let composerCreatedAt = meta?.createdAtMs.map { Date(timeIntervalSince1970: $0 / 1000) }
            let headerUpdatedAt = Self.msEpochDate(header?["lastUpdatedAt"])

            let firstActivity = Self.minDate(composerCreatedAt, earliestBubble)
            let lastActivity = Self.maxDate(Self.maxDate(headerUpdatedAt, latestBubble), composerCreatedAt)

            let recordID = "cursor-composer-\(composerId)"
            recordsByID[recordID] = CursorUsageRecord(
                id: recordID,
                conversationId: composerId,
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
        }

        summary.composersScanned = recordsByID.count

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

    // MARK: - Header enrichment

    /// `composer.composerHeaders.allComposers` keyed by composerId, for display
    /// metadata that the `composerData:` rows don't carry.
    private static func headerMap(connection: CursorStateDBConnection) -> [String: [String: Any]] {
        guard let headers = connection.itemValue(key: "composer.composerHeaders"),
              let object = jsonObject(from: headers),
              let allComposers = object["allComposers"] as? [Any]
        else {
            return [:]
        }

        var map: [String: [String: Any]] = [:]
        for case let composer as [String: Any] in allComposers {
            guard let composerId = stringValue(composer["composerId"]), !composerId.isEmpty else { continue }
            map[composerId] = composer
        }
        return map
    }

    private static func workspace(header: [String: Any]?, bubbleProjectDir: String?) -> CursorWorkspaceProject {
        if let identifier = header?["workspaceIdentifier"] as? [String: Any] {
            let path = stringValue((identifier["uri"] as? [String: Any])?["path"])
            let id = stringValue(identifier["id"])
            if path != nil || id != nil {
                return CursorWorkspaceProject(path: path, id: id)
            }
        }
        if let bubbleProjectDir, !bubbleProjectDir.isEmpty {
            return CursorWorkspaceProject(path: bubbleProjectDir, id: nil)
        }
        return CursorWorkspaceProject(path: nil, id: nil)
    }

    private static func title(header: [String: Any]?, composerId: String) -> String {
        if let name = stringValue(header?["name"]),
           !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return name
        }
        if let subtitle = stringValue(header?["subtitle"]),
           !subtitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return subtitle
        }
        // Privacy: never derive a title from bubble text (it would be cached).
        return "Conversation \(composerId.prefix(8))"
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

    /// Millisecond-epoch number → `Date`.
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
