import Foundation

/// Cursor usage extraction. Produces an `AzureUsageScanResult(provider: .cursor)`
/// so Cursor renders through the SAME dashboard engine as Codex / Claude Code /
/// LM Studio — token totals, by-model, and a by-project view with collapsible
/// sessions and an est. cost column.
///
/// Cursor's local data has two quirks the extraction handles:
///  - Conversations live in `composerData:<id>` rows; `composer.composerHeaders`
///    only surfaces a recent subset (used here to enrich name / workspace / mode).
///  - Per-message tokens are logged sparsely and usually on a *separate* bubble
///    whose `modelInfo` is null, so the served model and the token counts live on
///    different bubbles of the same conversation. We attribute a conversation's
///    no-model token bubbles to that conversation's primary (most-used) model.
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

    func scan() -> AzureUsageScanResult {
        var result = AzureUsageScanResult(provider: .cursor)

        guard let connection = reader.open() else {
            if reader.databaseExists {
                result.summary.warnings.append("Could not read the Cursor state database at \(reader.databasePath).")
            }
            // Missing Cursor install / never run — empty, no warning.
            return result
        }
        defer { connection.close() }

        let headerMap = Self.headerMap(connection: connection)

        var metaByID: [String: CursorComposerMetaRow] = [:]
        for row in connection.composerMetadataRows() {
            metaByID[row.composerId] = row
        }

        var bubblesByComposer: [String: [CursorBubbleRow]] = [:]
        for bubble in connection.bubbleRows() {
            bubblesByComposer[bubble.composerId, default: []].append(bubble)
        }

        // Conversations = composerData ids ∪ header ids. Only conversations that
        // actually have bubbles produce token events (orphan bubbles are ignored).
        var conversationIDs = Set(metaByID.keys)
        conversationIDs.formUnion(headerMap.keys)

        var sessionCount = 0
        let sourcePath = reader.databasePath

        for composerId in conversationIDs {
            let bubbles = bubblesByComposer[composerId] ?? []
            guard !bubbles.isEmpty else { continue }

            let header = headerMap[composerId]
            let meta = metaByID[composerId]

            let mode = meta?.unifiedMode
                ?? meta?.forceMode
                ?? Self.stringValue(header?["unifiedMode"])
                ?? "unknown"
            let projectPath = Self.projectPath(header: header, bubbles: bubbles)
            let primaryModel = Self.primaryModel(of: bubbles)

            let composerCreatedAt = meta?.createdAtMs.map { Date(timeIntervalSince1970: $0 / 1000) }
            let headerUpdatedAt = Self.msEpochDate(header?["lastUpdatedAt"])
            var conversationLatest = Self.maxDate(headerUpdatedAt, composerCreatedAt)

            // Accumulate tokens per attributed model. Cursor logs `inputTokens` as
            // the CUMULATIVE context at each assistant turn (it grows turn over
            // turn), so the conversation's input is the PEAK value — summing it
            // would re-count the re-sent context many times. `outputTokens` is
            // per-turn, so it is summed.
            var perModel: [String: ModelAccumulator] = [:]
            var modelOrder: [String] = []
            for bubble in bubbles {
                let model = (bubble.modelName?.isEmpty == false) ? bubble.modelName! : primaryModel
                if perModel[model] == nil { modelOrder.append(model) }
                var accumulator = perModel[model] ?? ModelAccumulator()
                // Input = peak context, drawn from whichever signal Cursor recorded
                // (tokenCount.inputTokens or contextWindowStatusAtCreation.tokensUsed).
                accumulator.inputTokens = Swift.max(accumulator.inputTokens, bubble.inputTokens, bubble.contextTokens)
                accumulator.outputTokens += bubble.outputTokens
                if let date = CursorAccountRecord.parseISO8601(bubble.createdAt) {
                    accumulator.latest = Self.maxDate(accumulator.latest, date)
                    conversationLatest = Self.maxDate(conversationLatest, date)
                }
                perModel[model] = accumulator
            }

            let fallbackTimestamp = conversationLatest ?? Date(timeIntervalSince1970: 0)
            for model in modelOrder {
                guard let accumulator = perModel[model] else { continue }
                let usage = AzureTokenUsage(
                    inputTokens: accumulator.inputTokens,
                    cachedInputTokens: 0,
                    outputTokens: accumulator.outputTokens,
                    reasoningOutputTokens: 0,
                    totalTokens: accumulator.inputTokens + accumulator.outputTokens
                )
                let record = AzureUsageRecord(
                    id: "cursor-\(composerId)-\(model)",
                    sessionID: composerId,
                    filePath: sourcePath,
                    timestamp: accumulator.latest ?? fallbackTimestamp,
                    endpoint: "Cursor",
                    resource: mode,
                    deployment: model,
                    model: model,
                    projectPath: projectPath,
                    usage: usage
                )
                result.records.append(record)
                result.summary.eventsCounted += 1
                result.summary.earliestEvent = Self.minDate(result.summary.earliestEvent, record.timestamp)
                result.summary.latestEvent = Self.maxDate(result.summary.latestEvent, record.timestamp)
            }
            sessionCount += 1
        }

        result.records.sort { lhs, rhs in
            if lhs.timestamp != rhs.timestamp { return lhs.timestamp < rhs.timestamp }
            return lhs.id.localizedCaseInsensitiveCompare(rhs.id) == .orderedAscending
        }
        result.summary.sessionsScanned = sessionCount
        result.summary.providerSessions = sessionCount
        return result
    }

    // MARK: - Per-conversation helpers

    private struct ModelAccumulator {
        var inputTokens = 0
        var outputTokens = 0
        var latest: Date?
    }

    /// The most-used non-empty model across a conversation's bubbles (first-seen
    /// wins on a tie). Falls back to the shared "unknown" model.
    private static func primaryModel(of bubbles: [CursorBubbleRow]) -> String {
        var counts: [String: Int] = [:]
        var order: [String] = []
        for bubble in bubbles {
            guard let model = bubble.modelName, !model.isEmpty else { continue }
            if counts[model] == nil { order.append(model) }
            counts[model, default: 0] += 1
        }
        var best = 0
        var primary = AzureUsageScanner.unknownModel
        for model in order where counts[model, default: 0] > best {
            best = counts[model, default: 0]
            primary = model
        }
        return primary
    }

    private static func projectPath(header: [String: Any]?, bubbles: [CursorBubbleRow]) -> String {
        if let identifier = header?["workspaceIdentifier"] as? [String: Any],
           let path = stringValue((identifier["uri"] as? [String: Any])?["path"]),
           !path.isEmpty {
            return path
        }
        if let dir = bubbles.compactMap({ $0.workspaceProjectDir }).first(where: { !$0.isEmpty }) {
            return dir
        }
        return AzureUsageRecord.unknownProject
    }

    // MARK: - Header enrichment

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
