import Foundation

final class AzureUsageScanner {
    private let fileManager: FileManager
    private let logRoots: [URL]
    private let metadataURLs: [URL]
    private let provider: CodexLogUsageProvider

    init(
        provider: CodexLogUsageProvider = .azure,
        fileManager: FileManager = .default,
        logRoots: [URL] = AzureUsageScanner.defaultLogRoots(),
        metadataURLs: [URL] = AzureUsageScanner.defaultMetadataURLs()
    ) {
        self.provider = provider
        self.fileManager = fileManager
        self.logRoots = logRoots
        self.metadataURLs = metadataURLs
    }

    func scan(since startDate: Date? = nil) -> AzureUsageScanResult {
        let metadata: AzureUsageDetectedMetadata
        switch provider {
        case .azure:
            metadata = AzureUsageMetadataDetector(fileManager: fileManager, urls: metadataURLs).detect()
        case .openai:
            metadata = AzureUsageDetectedMetadata(endpoint: "OpenAI", resource: "Codex local logs", deployment: nil, warnings: [])
        case .claudeCode:
            metadata = AzureUsageDetectedMetadata(endpoint: "Anthropic", resource: "Claude Code transcripts", deployment: nil, warnings: [])
        }
        var result = AzureUsageScanResult(provider: provider)
        var state = AzureUsageScanState()
        var warnings = metadata.warnings
        let fileURLs = jsonlFileURLs(since: startDate)
        result.summary.filesScanned = fileURLs.count

        switch provider {
        case .openai:
            scanOpenAISessions(fileURLs: fileURLs, eventCutoff: startDate, result: &result, state: &state)
        case .claudeCode:
            scanClaudeCodeSessions(fileURLs: fileURLs, eventCutoff: startDate, result: &result, state: &state)
        case .azure:
            for fileURL in fileURLs {
                let rootURL = logRoots.first { fileURL.path.hasPrefix($0.path) }
                scan(fileURL: fileURL, rootURL: rootURL, metadata: metadata, eventCutoff: startDate, result: &result, state: &state)
            }
        }

        if result.records.contains(where: { $0.endpoint == AzureUsageScanner.unknownEndpoint }) {
            let warning = provider.unknownEndpointWarning
            if !warning.isEmpty {
                warnings.append(warning)
            }
        }
        if result.records.contains(where: { $0.model == AzureUsageScanner.unknownModel }) {
            warnings.append("Some \(provider.displayName) token events had no preceding turn_context model and are grouped as unknown model.")
        }

        result.summary.warnings = Array(Set(warnings)).sorted()
        return result
    }

    static func dashboard(
        from result: AzureUsageScanResult,
        window: AzureUsageTimeWindow,
        customStartDate: Date,
        now: Date = Date()
    ) -> AzureUsageDashboard {
        let startDate = window.startDate(now: now, customStartDate: customStartDate)
        let records = result.records.filter { record in
            guard let startDate else { return true }
            return record.timestamp >= startDate
        }

        var dashboard = AzureUsageDashboard()
        dashboard.summary = result.summary
        dashboard.summary.eventsCounted = 0
        dashboard.summary.earliestEvent = nil
        dashboard.summary.latestEvent = nil

        var endpointGroups: [String: AzureUsageGroup] = [:]
        var modelGroups: [String: AzureUsageGroup] = [:]

        for record in records {
            let pricing = AzureModelPricing.defaultPricing(for: record.model, provider: result.provider)
            dashboard.totals.add(record.usage, pricing: pricing)
            dashboard.summary.eventsCounted += 1
            dashboard.summary.earliestEvent = minDate(dashboard.summary.earliestEvent, record.timestamp)
            dashboard.summary.latestEvent = maxDate(dashboard.summary.latestEvent, record.timestamp)

            let endpointKey = [record.endpoint, record.resource, record.deployment].joined(separator: "|")
            var endpointGroup = endpointGroups[endpointKey] ?? AzureUsageGroup(
                key: endpointKey,
                endpoint: record.endpoint,
                resource: record.resource,
                deployment: record.deployment,
                model: record.model,
                pricing: pricing,
                totals: AzureUsageTokenTotals()
            )
            endpointGroup.totals.add(record.usage, pricing: pricing)
            endpointGroups[endpointKey] = endpointGroup

            let modelKey = record.model
            var modelGroup = modelGroups[modelKey] ?? AzureUsageGroup(
                key: modelKey,
                endpoint: record.endpoint,
                resource: record.resource,
                deployment: record.deployment,
                model: record.model,
                pricing: pricing,
                totals: AzureUsageTokenTotals()
            )
            modelGroup.totals.add(record.usage, pricing: pricing)
            modelGroups[modelKey] = modelGroup
        }

        if records.contains(where: { !AzureModelPricing.defaultPricing(for: $0.model, provider: result.provider).isKnown }) {
            dashboard.summary.warnings.append("\(result.provider.displayName) cost is estimated only for recognized pricing presets; unknown models show $0 estimated cost until rates are configured.")
        }

        dashboard.byEndpointDeployment = endpointGroups.values.sorted { lhs, rhs in
            if lhs.totals.totalTokens != rhs.totals.totalTokens {
                return lhs.totals.totalTokens > rhs.totals.totalTokens
            }
            return lhs.key.localizedCaseInsensitiveCompare(rhs.key) == .orderedAscending
        }
        dashboard.byModel = modelGroups.values.sorted { lhs, rhs in
            if lhs.totals.totalTokens != rhs.totals.totalTokens {
                return lhs.totals.totalTokens > rhs.totals.totalTokens
            }
            return lhs.model.localizedCaseInsensitiveCompare(rhs.model) == .orderedAscending
        }
        dashboard.byProject = projectGroups(from: records, provider: result.provider)

        return dashboard
    }

    private static func projectGroups(from records: [AzureUsageRecord], provider: CodexLogUsageProvider) -> [AzureUsageProjectGroup] {
        Dictionary(grouping: records, by: projectGroupingKey(for:)).values.map { projectRecords in
            let firstRecord = projectRecords[0]
            let groupProjectPath = projectGroupingKey(for: firstRecord)
            let groupProjectName = groupProjectPath == AzureUsageRecord.chatProject ? "Chats" : firstRecord.projectName
            var totals = AzureUsageTokenTotals()
            var sessionIDs = Set<String>()
            var earliestActivity: Date?
            var latestActivity: Date?
            var modelGroups: [String: AzureUsageProjectModelGroup] = [:]
            var sessionGroups: [String: AzureUsageProjectSessionAccumulator] = [:]

            for record in projectRecords {
                let pricing = AzureModelPricing.defaultPricing(for: record.model, provider: provider)
                totals.add(record.usage, pricing: pricing)
                sessionIDs.insert(record.sessionID)
                earliestActivity = minDate(earliestActivity, record.timestamp)
                latestActivity = maxDate(latestActivity, record.timestamp)

                var modelGroup = modelGroups[record.model] ?? AzureUsageProjectModelGroup(
                    model: record.model,
                    pricing: pricing,
                    totals: AzureUsageTokenTotals()
                )
                modelGroup.totals.add(record.usage, pricing: pricing)
                modelGroups[record.model] = modelGroup

                var sessionGroup = sessionGroups[record.sessionID] ?? AzureUsageProjectSessionAccumulator(
                    sessionID: record.sessionID,
                    filePath: record.filePath
                )
                sessionGroup.add(record, pricing: pricing)
                sessionGroups[record.sessionID] = sessionGroup
            }

            return AzureUsageProjectGroup(
                projectPath: groupProjectPath,
                projectName: groupProjectName,
                totals: totals,
                sessionCount: sessionIDs.count,
                earliestActivity: earliestActivity,
                latestActivity: latestActivity,
                byModel: modelGroups.values.sorted(by: sortProjectModels),
                sessions: sessionGroups.values.map(\.group).sorted(by: sortProjectSessions)
            )
        }
        .sorted { lhs, rhs in
            if lhs.totals.totalTokens != rhs.totals.totalTokens {
                return lhs.totals.totalTokens > rhs.totals.totalTokens
            }
            return lhs.projectPath.localizedCaseInsensitiveCompare(rhs.projectPath) == .orderedAscending
        }
    }

    private static func projectGroupingKey(for record: AzureUsageRecord) -> String {
        isCodexChatFolder(record.projectPath) ? AzureUsageRecord.chatProject : record.projectPath
    }

    private static func isCodexChatFolder(_ projectPath: String) -> Bool {
        let components = URL(fileURLWithPath: projectPath).pathComponents
        guard let documentsIndex = components.firstIndex(of: "Documents"),
              documentsIndex + 2 < components.count,
              components[documentsIndex + 1] == "Codex"
        else {
            return false
        }

        return dateOnlyFormatter.date(from: components[documentsIndex + 2]) != nil
    }

    private static func sortProjectModels(_ lhs: AzureUsageProjectModelGroup, _ rhs: AzureUsageProjectModelGroup) -> Bool {
        if lhs.totals.totalTokens != rhs.totals.totalTokens {
            return lhs.totals.totalTokens > rhs.totals.totalTokens
        }
        return lhs.model.localizedCaseInsensitiveCompare(rhs.model) == .orderedAscending
    }

    private static func sortProjectSessions(_ lhs: AzureUsageProjectSessionGroup, _ rhs: AzureUsageProjectSessionGroup) -> Bool {
        if lhs.totals.totalTokens != rhs.totals.totalTokens {
            return lhs.totals.totalTokens > rhs.totals.totalTokens
        }
        let lhsDate = lhs.latestActivity ?? .distantPast
        let rhsDate = rhs.latestActivity ?? .distantPast
        if lhsDate != rhsDate { return lhsDate > rhsDate }
        return lhs.sessionID.localizedCaseInsensitiveCompare(rhs.sessionID) == .orderedAscending
    }

    static func defaultLogRoots() -> [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [
            home.appendingPathComponent(".codex/sessions", isDirectory: true),
            home.appendingPathComponent(".codex/archived_sessions", isDirectory: true)
        ]
    }

    static func defaultClaudeCodeLogRoots() -> [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [
            home.appendingPathComponent(".claude/projects", isDirectory: true),
            home.appendingPathComponent(".claude-foundry/projects", isDirectory: true),
            home.appendingPathComponent(".claude-foundry/projects-archive", isDirectory: true)
        ]
    }

    static func claudeCodeFoundryRootPaths() -> [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        // Trailing slash so hasPrefix(".../projects/") can't match ".../projects-archive/...".
        return [
            home.appendingPathComponent(".claude-foundry/projects", isDirectory: true)
                .standardizedFileURL.path + "/",
            home.appendingPathComponent(".claude-foundry/projects-archive", isDirectory: true)
                .standardizedFileURL.path + "/"
        ]
    }

    static func defaultActiveSessionLogRoots() -> [URL] {
        [
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".codex/sessions", isDirectory: true)
        ]
    }

    static func defaultMetadataURLs() -> [URL] {
        // /opt/homebrew/bin/codex-azure is the user's wrapper script. It tells us the
        // currently-configured Azure base_url, which is the only available endpoint
        // signal — session_meta payloads don't record base_url. The "label drift" risk
        // when the wrapper changes is mitigated by the sticky-merge logic in
        // AccountTrackerViewModel.mergedUsageResult: existing Azure records keep their
        // endpoint/resource/deployment across scans, so historical labels never get
        // retroactively rewritten by a newer wrapper.
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [
            home.appendingPathComponent(".codex/config.toml"),
            URL(fileURLWithPath: "/opt/homebrew/bin/codex-azure")
        ]
    }

    private func jsonlFileURLs(since startDate: Date? = nil, shouldPruneDatedPaths: Bool = true) -> [URL] {
        var urls: [URL] = []

        for root in logRoots where fileManager.fileExists(atPath: root.path) {
            guard let enumerator = fileManager.enumerator(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles]
            ) else {
                continue
            }

            for case let url as URL in enumerator {
                if shouldPruneDatedPaths,
                   let startDate,
                   isDatedDirectory(url, before: startDate) {
                    enumerator.skipDescendants()
                    continue
                }

                guard url.pathExtension == "jsonl" else { continue }
                if let startDate, shouldSkip(url: url, before: startDate, shouldPruneDatedPaths: shouldPruneDatedPaths) {
                    continue
                }
                urls.append(url)
            }
        }

        return urls.sorted { $0.path.localizedCaseInsensitiveCompare($1.path) == .orderedAscending }
    }

    private func isDatedDirectory(_ url: URL, before startDate: Date) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .contentModificationDateKey]),
              values.isDirectory == true,
              let pathDate = Self.dateFromPath(url)
        else { return false }

        guard Calendar.current.startOfDay(for: pathDate) < Calendar.current.startOfDay(for: startDate) else {
            return false
        }

        if let modificationDate = values.contentModificationDate,
           modificationDate >= startDate {
            return false
        }

        return true
    }

    private func shouldSkip(url: URL, before startDate: Date, shouldPruneDatedPaths: Bool) -> Bool {
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey])
        if shouldPruneDatedPaths,
           let pathDate = Self.dateFromPath(url),
           Calendar.current.startOfDay(for: pathDate) < Calendar.current.startOfDay(for: startDate) {
            if let modificationDate = values?.contentModificationDate,
               modificationDate >= startDate {
                return false
            }
            return true
        }

        if Self.dateFromPath(url) == nil,
           let modificationDate = values?.contentModificationDate,
           modificationDate < startDate {
            return true
        }

        return false
    }

    private static func dateFromPath(_ url: URL) -> Date? {
        let parts = url.pathComponents
        if let yearIndex = parts.firstIndex(where: { $0.count == 4 && Int($0) != nil }),
           parts.indices.contains(yearIndex + 2),
           let year = Int(parts[yearIndex]),
           let month = Int(parts[yearIndex + 1]),
           let day = Int(parts[yearIndex + 2]) {
            return Calendar(identifier: .gregorian).date(from: DateComponents(year: year, month: month, day: day))
        }

        let filename = url.lastPathComponent
        guard let rolloutRange = filename.range(of: "rollout-"),
              filename.distance(from: rolloutRange.upperBound, to: filename.endIndex) >= 10
        else { return nil }

        let dateStart = rolloutRange.upperBound
        let dateEnd = filename.index(dateStart, offsetBy: 10)
        let dateParts = filename[dateStart..<dateEnd].split(separator: "-")
        guard dateParts.count == 3,
              let year = Int(dateParts[0]),
              let month = Int(dateParts[1]),
              let day = Int(dateParts[2])
        else { return nil }

        return Calendar(identifier: .gregorian).date(from: DateComponents(year: year, month: month, day: day))
    }

    private func scan(
        fileURL: URL,
        rootURL: URL?,
        metadata: AzureUsageDetectedMetadata,
        eventCutoff: Date?,
        result: inout AzureUsageScanResult,
        state: inout AzureUsageScanState
    ) {
        scanAzureFile(fileURL: fileURL, rootURL: rootURL, metadata: metadata, eventCutoff: eventCutoff, result: &result)
    }

    private func scanAzureFile(fileURL: URL, rootURL: URL?, metadata: AzureUsageDetectedMetadata, eventCutoff: Date?, result: inout AzureUsageScanResult) {
        guard let lineReader = LineReader(url: fileURL) else {
            return
        }

        var sessionID = Self.sessionID(for: fileURL, rootURL: rootURL)
        var isTargetProviderSession = false
        var didCountProviderSession = false
        var currentModel: String?
        var projectPath = AzureUsageRecord.unknownProject
        var seenCumulativeUsages = Set<AzureTokenUsage>()
        var eventIndex = 0
        result.summary.sessionsScanned += 1

        while let lineData = lineReader.nextLineData() {
            guard !lineData.isEmpty else { continue }

            if lineData.containsASCII(Self.sessionMetaBytes) {
                guard let line = String(data: lineData, encoding: .utf8) else { continue }
                if let id = Self.extractStringValue(named: "id", from: line), !id.isEmpty {
                    sessionID = id
                }
                isTargetProviderSession = Self.extractStringValue(named: "model_provider", from: line) == provider.rawValue
                if !isTargetProviderSession {
                    break
                }
                projectPath = Self.extractProjectPath(from: line)
                continue
            }

            if lineData.containsASCII(Self.turnContextBytes) {
                guard isTargetProviderSession, let line = String(data: lineData, encoding: .utf8) else { continue }
                if let model = Self.extractModel(from: line), !model.isEmpty {
                    currentModel = model
                }
                continue
            }

            guard isTargetProviderSession,
                  lineData.containsASCII(Self.tokenCountBytes),
                  let line = String(data: lineData, encoding: .utf8)
            else { continue }

            guard let lastUsage = Self.extractTokenUsage(named: "last_token_usage", from: line, allowingMissingFields: false) else {
                result.summary.malformedEventsSkipped += 1
                continue
            }

            if let totalUsage = Self.extractTokenUsage(named: "total_token_usage", from: line, allowingMissingFields: false) {
                if seenCumulativeUsages.contains(totalUsage) {
                    result.summary.duplicateEventsSkipped += 1
                    continue
                }
                seenCumulativeUsages.insert(totalUsage)
            }

            guard let timestamp = Self.date(from: Self.extractStringValue(named: "timestamp", from: line)) else {
                result.summary.malformedEventsSkipped += 1
                continue
            }

            eventIndex += 1
            if let eventCutoff, timestamp <= eventCutoff {
                continue
            }
            if !didCountProviderSession {
                result.summary.providerSessions += 1
                didCountProviderSession = true
            }
            let model = currentModel ?? Self.unknownModel
            appendRecord(
                sessionID: sessionID,
                recordID: "\(sessionID)-\(eventIndex)",
                fileURL: fileURL,
                timestamp: timestamp,
                metadata: metadata,
                model: model,
                usage: lastUsage,
                projectPath: projectPath,
                result: &result
            )
        }
    }

    private func scanOpenAISessions(
        fileURLs: [URL],
        eventCutoff: Date?,
        result: inout AzureUsageScanResult,
        state: inout AzureUsageScanState
    ) {
        var sessions: [AzureUsageParsedSession] = []
        for fileURL in fileURLs {
            let rootURL = logRoots.first { fileURL.path.hasPrefix($0.path) }
            if let session = parseOpenAIFile(fileURL: fileURL, rootURL: rootURL) {
                sessions.append(session)
            }
        }

        sessions.sort { lhs, rhs in
            let lhsDate = lhs.metaTimestamp ?? Date.distantPast
            let rhsDate = rhs.metaTimestamp ?? Date.distantPast
            if lhsDate != rhsDate { return lhsDate < rhsDate }
            return lhs.filePath.localizedCaseInsensitiveCompare(rhs.filePath) == .orderedAscending
        }

        result.summary.sessionsScanned = sessions.count
        result.summary.providerSessions = sessions.count
        for session in sessions {
            processOpenAISession(session, eventCutoff: eventCutoff, result: &result, state: &state)
        }
    }

    private func parseOpenAIFile(fileURL: URL, rootURL: URL?) -> AzureUsageParsedSession? {
        let fileSessionID = Self.sessionID(for: fileURL, rootURL: rootURL)
        var sessionID = fileSessionID
        var metaTimestamp: Date?
        var forkedFromID: String?
        var projectPath = AzureUsageRecord.unknownProject
        var isTargetProviderSession = false
        var currentModel: String?
        var parsedEvents: [AzureUsageParsedTokenEvent] = []
        var eventIndex = 0

        func consume(_ lineData: Data) -> Bool {
            guard !lineData.isEmpty else { return true }

            if lineData.containsASCII(Self.sessionMetaBytes) {
                guard let line = String(data: lineData, encoding: .utf8) else { return false }
                let sessionProvider = Self.extractStringValue(named: "model_provider", from: line)
                let originator = Self.extractStringValue(named: "originator", from: line)
                isTargetProviderSession = sessionProvider == provider.rawValue && originator == "Codex Desktop"
                guard isTargetProviderSession else { return false }
                if let id = Self.extractStringValue(named: "id", from: line), !id.isEmpty {
                    sessionID = id
                }
                metaTimestamp = Self.date(from: Self.extractStringValue(named: "timestamp", from: line))
                forkedFromID = Self.extractStringValue(named: "forked_from_id", from: line)
                projectPath = Self.extractProjectPath(from: line)
                return true
            }

            guard isTargetProviderSession else { return true }

            if lineData.containsASCII(Self.turnContextBytes) {
                guard let line = String(data: lineData, encoding: .utf8) else { return true }
                if let model = Self.extractModel(from: line), !model.isEmpty {
                    currentModel = model
                }
                return true
            }

            guard lineData.containsASCII(Self.tokenCountBytes),
                  let line = String(data: lineData, encoding: .utf8),
                  let timestamp = Self.date(from: Self.extractStringValue(named: "timestamp", from: line)),
                  let lastUsage = Self.extractTokenUsage(named: "last_token_usage", from: line, allowingMissingFields: true)
            else { return true }

            let totalUsage = Self.extractTokenUsage(named: "total_token_usage", from: line, allowingMissingFields: true)
            eventIndex += 1
            parsedEvents.append(AzureUsageParsedTokenEvent(
                recordID: "\(fileSessionID)-\(eventIndex)",
                timestamp: timestamp,
                model: currentModel ?? Self.unknownModel,
                lastUsage: lastUsage,
                totalUsage: totalUsage
            ))
            return true
        }

        if let relevantLines = Self.filteredRelevantLineData(fileURL: fileURL) {
            for lineData in relevantLines {
                guard consume(lineData) else { return nil }
            }
        } else {
            guard let lineReader = LineReader(url: fileURL) else {
                return nil
            }
            while let lineData = lineReader.nextLineData() {
                guard consume(lineData) else { return nil }
            }
        }

        guard isTargetProviderSession else { return nil }
        return AzureUsageParsedSession(
            filePath: fileURL.path,
            fileURL: fileURL,
            sessionID: sessionID,
            metaTimestamp: metaTimestamp,
            forkedFromID: forkedFromID,
            projectPath: projectPath,
            events: parsedEvents
        )
    }

    private func processOpenAISession(
        _ session: AzureUsageParsedSession,
        eventCutoff: Date?,
        result: inout AzureUsageScanResult,
        state: inout AzureUsageScanState
    ) {
        let replayCutoff = startupReplayCutoff(for: session)
        for event in session.events {
            if let eventCutoff, event.timestamp <= eventCutoff {
                if let totalUsage = event.totalUsage {
                    state.openAIDedupeKeys.insert("\(session.sessionID)|\(totalUsage.signature)")
                }
                continue
            }

            if let replayCutoff, event.timestamp <= replayCutoff {
                result.summary.startupReplayEventsSkipped += 1
                continue
            }

            if let totalUsage = event.totalUsage {
                let dedupeKey = "\(session.sessionID)|\(totalUsage.signature)"
                guard state.openAIDedupeKeys.insert(dedupeKey).inserted else {
                    result.summary.duplicateEventsSkipped += 1
                    continue
                }
            }

            appendRecord(
                sessionID: session.sessionID,
                recordID: event.recordID,
                fileURL: session.fileURL,
                timestamp: event.timestamp,
                metadata: AzureUsageDetectedMetadata(endpoint: "OpenAI", resource: "Codex local logs", deployment: nil, warnings: []),
                model: event.model,
                usage: event.lastUsage,
                projectPath: session.projectPath,
                result: &result
            )
        }
    }

    private func startupReplayCutoff(for session: AzureUsageParsedSession) -> Date? {
        guard session.forkedFromID?.isEmpty == false, !session.events.isEmpty else {
            return nil
        }
        let start = session.metaTimestamp ?? session.events.map(\.timestamp).min()
        guard let start else { return nil }
        let burstEnd = start.addingTimeInterval(5)
        let burstEvents = session.events.filter { event in
            event.timestamp >= start && event.timestamp <= burstEnd
        }
        guard burstEvents.count >= 5 else { return nil }
        return burstEvents.map(\.timestamp).max()
    }

    private func scanClaudeCodeSessions(
        fileURLs: [URL],
        eventCutoff: Date?,
        result: inout AzureUsageScanResult,
        state: inout AzureUsageScanState
    ) {
        let anthropicMetadata = AzureUsageDetectedMetadata(
            endpoint: "Anthropic",
            resource: "Claude Code transcripts",
            deployment: nil,
            warnings: []
        )
        let foundryMetadata = AzureUsageDetectedMetadata(
            endpoint: "Azure Foundry",
            resource: "Claude Code via Foundry",
            deployment: nil,
            warnings: []
        )
        let anthropicDesktopMetadata = AzureUsageDetectedMetadata(
            endpoint: "Anthropic",
            resource: "Claude Desktop app",
            deployment: nil,
            warnings: []
        )
        let foundryRootPaths = Self.claudeCodeFoundryRootPaths()

        for fileURL in fileURLs {
            let standardizedPath = fileURL.standardizedFileURL.path
            let isFoundry = foundryRootPaths.contains { standardizedPath.hasPrefix($0) }
            // Default metadata; per-event entrypoint can override for Foundry-dir files written
            // by the macOS Claude desktop app's embedded Claude Code (entrypoint=claude-desktop).
            let defaultMetadata = isFoundry ? foundryMetadata : anthropicMetadata
            let sessionID = fileURL.deletingPathExtension().lastPathComponent
            var sawAssistantLine = false
            var didCountProviderSession = false

            guard let lineReader = LineReader(url: fileURL) else { continue }
            result.summary.sessionsScanned += 1
            var eventIndex = 0

            while let lineData = lineReader.nextLineData() {
                guard !lineData.isEmpty else { continue }
                guard lineData.containsASCII(Self.assistantTypeBytes) else { continue }

                guard let object = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                      (object["type"] as? String) == "assistant",
                      let message = object["message"] as? [String: Any],
                      let usageDict = message["usage"] as? [String: Any]
                else { continue }

                sawAssistantLine = true

                guard let messageID = message["id"] as? String, !messageID.isEmpty else {
                    result.summary.malformedEventsSkipped += 1
                    continue
                }

                guard let timestamp = Self.date(from: object["timestamp"]) else {
                    result.summary.malformedEventsSkipped += 1
                    continue
                }

                let model = (object["model"] as? String)
                    ?? (message["model"] as? String)
                    ?? Self.unknownModel
                if model == "<synthetic>" { continue }
                let cwd = object["cwd"] as? String
                let entrypoint = (object["entrypoint"] as? String) ?? ""
                let metadata = (isFoundry && entrypoint == "claude-desktop")
                    ? anthropicDesktopMetadata
                    : defaultMetadata

                let usage = Self.claudeCodeTokenUsage(from: usageDict)
                if usage.isZero { continue }

                if !state.claudeCodeMessageKeys.insert(messageID).inserted {
                    result.summary.duplicateEventsSkipped += 1
                    continue
                }

                eventIndex += 1
                if let eventCutoff, timestamp <= eventCutoff {
                    continue
                }

                if !didCountProviderSession {
                    result.summary.providerSessions += 1
                    didCountProviderSession = true
                }

                appendRecord(
                    sessionID: sessionID,
                    recordID: "\(sessionID)-\(eventIndex)",
                    fileURL: fileURL,
                    timestamp: timestamp,
                    metadata: metadata,
                    model: model,
                    usage: usage,
                    projectPath: AzureUsageRecord.normalizedProjectPath(cwd),
                    result: &result
                )
            }

            if !sawAssistantLine {
                result.summary.sessionsScanned -= 1
            }
        }
    }

    private static func claudeCodeTokenUsage(from usage: [String: Any]) -> AzureTokenUsage {
        let input = intValue(usage["input_tokens"]) ?? 0
        let cacheCreation = intValue(usage["cache_creation_input_tokens"]) ?? 0
        let cacheRead = intValue(usage["cache_read_input_tokens"]) ?? 0
        let output = intValue(usage["output_tokens"]) ?? 0
        let totalInput = input + cacheCreation + cacheRead
        return AzureTokenUsage(
            inputTokens: totalInput,
            cachedInputTokens: cacheRead,
            cacheCreationInputTokens: cacheCreation,
            outputTokens: output,
            reasoningOutputTokens: 0,
            totalTokens: totalInput + output
        )
    }

    private func appendRecord(
        sessionID: String,
        recordID: String,
        fileURL: URL,
        timestamp: Date,
        metadata: AzureUsageDetectedMetadata,
        model: String,
        usage: AzureTokenUsage,
        projectPath: String,
        result: inout AzureUsageScanResult
    ) {
        let endpoint: String
        let resource: String
        switch provider {
        case .azure:
            endpoint = metadata.endpoint ?? Self.unknownEndpoint
            resource = metadata.resource ?? Self.unknownResource
        case .openai:
            endpoint = "OpenAI"
            resource = "Codex local logs"
        case .claudeCode:
            endpoint = metadata.endpoint ?? "Anthropic"
            resource = metadata.resource ?? "Claude Code transcripts"
        }
        let deployment = model == Self.unknownModel ? (metadata.deployment ?? Self.unknownDeployment) : model
        let record = AzureUsageRecord(
            id: recordID,
            sessionID: sessionID,
            filePath: fileURL.path,
            timestamp: timestamp,
            endpoint: endpoint,
            resource: resource,
            deployment: deployment,
            model: model,
            projectPath: projectPath,
            usage: usage
        )
        result.records.append(record)
        result.summary.eventsCounted += 1
        result.summary.earliestEvent = Self.minDate(result.summary.earliestEvent, timestamp)
        result.summary.latestEvent = Self.maxDate(result.summary.latestEvent, timestamp)
    }

    private static func sessionID(for fileURL: URL, rootURL: URL?) -> String {
        guard let rootURL else {
            return fileURL.deletingPathExtension().lastPathComponent
        }
        let rootPath = rootURL.standardizedFileURL.path
        let filePath = fileURL.standardizedFileURL.deletingPathExtension().path
        guard filePath.hasPrefix(rootPath) else {
            return fileURL.deletingPathExtension().lastPathComponent
        }
        var relative = String(filePath.dropFirst(rootPath.count))
        if relative.hasPrefix("/") {
            relative.removeFirst()
        }
        return relative.isEmpty ? fileURL.deletingPathExtension().lastPathComponent : relative
    }

    private static func subtract(_ current: AzureTokenUsage, _ previous: AzureTokenUsage?) -> AzureTokenUsage {
        AzureTokenUsage(
            inputTokens: max(current.inputTokens - (previous?.inputTokens ?? 0), 0),
            cachedInputTokens: max(current.cachedInputTokens - (previous?.cachedInputTokens ?? 0), 0),
            outputTokens: max(current.outputTokens - (previous?.outputTokens ?? 0), 0),
            reasoningOutputTokens: max(current.reasoningOutputTokens - (previous?.reasoningOutputTokens ?? 0), 0),
            totalTokens: max(current.totalTokens - (previous?.totalTokens ?? 0), 0)
        )
    }

    private static func extractModel(from line: String) -> String? {
        extractStringValue(named: "model", from: line)
            ?? extractStringValue(named: "model_name", from: line)
    }

    private static func extractProjectPath(from line: String) -> String {
        if let payload = jsonObject(from: line)?["payload"] as? [String: Any],
           let cwd = payload["cwd"] as? String {
            return AzureUsageRecord.normalizedProjectPath(cwd)
        }

        return AzureUsageRecord.normalizedProjectPath(extractStringValue(named: "cwd", from: line))
    }

    private static func displayName(forSessionProvider provider: String?) -> String {
        switch provider {
        case "azure": return "Azure"
        case "openai": return "OpenAI"
        case let provider? where !provider.isEmpty: return provider
        default: return "unknown provider"
        }
    }

    private static func jsonObject(from line: String) -> [String: Any]? {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return nil
        }
        return object
    }

    private static func filteredRelevantLineData(fileURL: URL) -> [Data]? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/grep")
        process.arguments = [
            "-aE",
            "\"type\":\"session_meta\"|\"type\":\"turn_context\"|\"payload\":\\{\"type\":\"token_count\"",
            fileURL.path
        ]

        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()

        do {
            try process.run()
        } catch {
            return nil
        }

        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0 || process.terminationStatus == 1 else {
            return nil
        }
        guard !data.isEmpty else {
            return []
        }

        return data.split(separator: 0x0A, omittingEmptySubsequences: false).map { slice in
            var line = Data(slice)
            if line.last == 0x0D {
                line.removeLast()
            }
            return line
        }
    }

    private static func extractStringValue(named name: String, from line: String) -> String? {
        let pattern = "\"\(name)\":\""
        guard let startRange = line.range(of: pattern) else { return nil }
        var value = ""
        var isEscaped = false

        for character in line[startRange.upperBound...] {
            if isEscaped {
                value.append(character)
                isEscaped = false
                continue
            }
            if character == "\\" {
                isEscaped = true
                continue
            }
            if character == "\"" {
                return value
            }
            value.append(character)
        }

        return nil
    }

    private static func extractTokenUsage(named name: String, from line: String, allowingMissingFields: Bool = false) -> AzureTokenUsage? {
        guard let objectBody = extractObjectBody(named: name, from: line) else {
            return nil
        }

        let inputTokens = extractIntValue(named: "input_tokens", from: objectBody)
        let cachedInputTokens = extractIntValue(named: "cached_input_tokens", from: objectBody)
            ?? extractIntValue(named: "cache_read_input_tokens", from: objectBody)
        let outputTokens = extractIntValue(named: "output_tokens", from: objectBody)
        let reasoningOutputTokens = extractIntValue(named: "reasoning_output_tokens", from: objectBody)
        let totalTokens = extractIntValue(named: "total_tokens", from: objectBody)

        if !allowingMissingFields {
            guard inputTokens != nil,
                  cachedInputTokens != nil,
                  outputTokens != nil,
                  reasoningOutputTokens != nil,
                  totalTokens != nil
            else {
                return nil
            }
        }

        let input = inputTokens ?? 0
        let cached = min(cachedInputTokens ?? 0, input)
        let output = outputTokens ?? 0
        let reasoning = reasoningOutputTokens ?? 0
        let total = max(totalTokens ?? 0, input + output)

        guard input >= 0, cached >= 0, output >= 0, reasoning >= 0, total >= 0 else {
            return nil
        }

        return AzureTokenUsage(
            inputTokens: input,
            cachedInputTokens: cached,
            outputTokens: output,
            reasoningOutputTokens: reasoning,
            totalTokens: total
        )
    }

    private static func extractObjectBody(named name: String, from line: String) -> Substring? {
        let pattern = "\"\(name)\":{"
        guard let startRange = line.range(of: pattern) else { return nil }
        var depth = 1
        let bodyStart = startRange.upperBound

        for index in line[bodyStart...].indices {
            let character = line[index]
            if character == "{" {
                depth += 1
            } else if character == "}" {
                depth -= 1
                if depth == 0 {
                    return line[bodyStart..<index]
                }
            }
        }

        return nil
    }

    private static func extractIntValue(named name: String, from body: Substring) -> Int? {
        let pattern = "\"\(name)\":"
        guard let startRange = body.range(of: pattern) else { return nil }
        var digits = ""

        for character in body[startRange.upperBound...] {
            if character.isNumber || (character == "-" && digits.isEmpty) {
                digits.append(character)
            } else {
                break
            }
        }

        return Int(digits)
    }

    private static func tokenUsage(from object: [String: Any]) -> AzureTokenUsage? {
        guard let inputTokens = intValue(object["input_tokens"]),
              let cachedInputTokens = intValue(object["cached_input_tokens"]),
              let outputTokens = intValue(object["output_tokens"]),
              let reasoningOutputTokens = intValue(object["reasoning_output_tokens"]),
              let totalTokens = intValue(object["total_tokens"]),
              inputTokens >= 0,
              cachedInputTokens >= 0,
              outputTokens >= 0,
              reasoningOutputTokens >= 0,
              totalTokens >= 0
        else {
            return nil
        }

        return AzureTokenUsage(
            inputTokens: inputTokens,
            cachedInputTokens: cachedInputTokens,
            outputTokens: outputTokens,
            reasoningOutputTokens: reasoningOutputTokens,
            totalTokens: totalTokens
        )
    }

    private static func intValue(_ value: Any?) -> Int? {
        if let int = value as? Int { return int }
        if let int64 = value as? Int64 { return Int(int64) }
        if let double = value as? Double, double.rounded() == double { return Int(double) }
        if let string = value as? String { return Int(string) }
        return nil
    }

    private static func stringValue(_ value: Any?) -> String? {
        value as? String
    }

    private static func date(from value: Any?) -> Date? {
        guard let string = value as? String else { return nil }
        return isoFormatterWithFractionalSeconds.date(from: string) ?? isoFormatter.date(from: string)
    }

    private static func minDate(_ lhs: Date?, _ rhs: Date) -> Date {
        guard let lhs else { return rhs }
        return min(lhs, rhs)
    }

    private static func maxDate(_ lhs: Date?, _ rhs: Date) -> Date {
        guard let lhs else { return rhs }
        return max(lhs, rhs)
    }

    private static let isoFormatterWithFractionalSeconds: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private static let dateOnlyFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    static let unknownEndpoint = "unknown endpoint"
    static let unknownResource = "unknown resource"
    static let unknownDeployment = "unknown deployment"
    static let unknownModel = "unknown"
    private static let sessionMetaBytes = Array("\"session_meta\"".utf8)
    private static let turnContextBytes = Array("\"turn_context\"".utf8)
    private static let tokenCountBytes = Array("\"token_count\"".utf8)
    private static let assistantTypeBytes = Array("\"type\":\"assistant\"".utf8)
}


private struct AzureUsageProjectSessionAccumulator {
    var sessionID: String
    var filePath: String
    var models = Set<String>()
    var totals = AzureUsageTokenTotals()
    var earliestActivity: Date?
    var latestActivity: Date?

    mutating func add(_ record: AzureUsageRecord, pricing: AzureModelPricing) {
        models.insert(record.model)
        totals.add(record.usage, pricing: pricing)
        earliestActivity = earliestActivity.map { min($0, record.timestamp) } ?? record.timestamp
        latestActivity = latestActivity.map { max($0, record.timestamp) } ?? record.timestamp
    }

    var group: AzureUsageProjectSessionGroup {
        AzureUsageProjectSessionGroup(
            sessionID: sessionID,
            filePath: filePath,
            models: models.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending },
            totals: totals,
            earliestActivity: earliestActivity,
            latestActivity: latestActivity
        )
    }
}

private struct AzureUsageScanState {
    var openAIDedupeKeys = Set<String>()
    var claudeCodeMessageKeys = Set<String>()
}

private struct AzureUsageParsedSession {
    var filePath: String
    var fileURL: URL
    var sessionID: String
    var metaTimestamp: Date?
    var forkedFromID: String?
    var projectPath: String
    var events: [AzureUsageParsedTokenEvent]
}

private struct AzureUsageParsedTokenEvent {
    var recordID: String
    var timestamp: Date
    var model: String
    var lastUsage: AzureTokenUsage
    var totalUsage: AzureTokenUsage?
}

private struct AzureUsageDetectedMetadata {
    var endpoint: String?
    var resource: String?
    var deployment: String?
    var warnings: [String] = []
}

private final class AzureUsageMetadataDetector {
    private let fileManager: FileManager
    private let urls: [URL]

    init(fileManager: FileManager, urls: [URL]) {
        self.fileManager = fileManager
        self.urls = urls
    }

    func detect() -> AzureUsageDetectedMetadata {
        var metadata = AzureUsageDetectedMetadata()

        for url in urls where fileManager.fileExists(atPath: url.path) {
            guard let contents = try? String(contentsOf: url, encoding: .utf8) else { continue }
            for rawLine in contents.components(separatedBy: .newlines) {
                let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !line.isEmpty, !isSecretBearing(line) else { continue }

                if metadata.endpoint == nil,
                   let endpoint = firstValue(in: line, names: ["AZURE_OPENAI_BASE_URL", "base_url"]) {
                    metadata.endpoint = endpoint
                    if metadata.resource == nil {
                        metadata.resource = resourceName(fromEndpoint: endpoint)
                    }
                }

                if metadata.resource == nil,
                   let resource = firstValue(in: line, names: ["AZURE_OPENAI_RESOURCE"]) {
                    metadata.resource = resource
                }

                if metadata.deployment == nil,
                   let deployment = firstValue(in: line, names: ["AZURE_OPENAI_DEPLOYMENT"]) {
                    metadata.deployment = deployment
                }
            }
        }

        if metadata.endpoint == nil || metadata.resource == nil {
            metadata.warnings.append("Azure endpoint/resource detection is limited to non-secret local config or wrapper metadata.")
        }

        return metadata
    }

    private func isSecretBearing(_ line: String) -> Bool {
        let lowered = line.lowercased()
        return ["api_key", "apikey", "secret", "token", "password", "credential", "bearer", "key="].contains { lowered.contains($0) }
    }

    private func firstValue(in line: String, names: [String]) -> String? {
        for name in names {
            if let shellDefault = shellDefaultValue(in: line, name: name) {
                return shellDefault
            }
            if let assignment = quotedAssignmentValue(in: line, name: name) {
                return assignment
            }
        }
        return nil
    }

    private func shellDefaultValue(in line: String, name: String) -> String? {
        guard lineReferencesName(line, name: name),
              let range = line.range(of: ":-")
        else {
            return nil
        }

        let tail = String(line[range.upperBound...])
        let value = tail
            .trimmingCharacters(in: CharacterSet(charactersIn: "}\"' "))
            .components(separatedBy: CharacterSet(charactersIn: "}\"' "))
            .first
        return clean(value)
    }

    private func quotedAssignmentValue(in line: String, name: String) -> String? {
        guard lineReferencesName(line, name: name),
              let equals = line.firstIndex(of: "=")
        else {
            return nil
        }

        var value = String(line[line.index(after: equals)...])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        value = value.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        return clean(value)
    }

    private func lineReferencesName(_ line: String, name: String) -> Bool {
        if line.hasPrefix("\(name)=") || line.contains("${\(name):-") {
            return true
        }
        if name == "base_url" {
            return line.localizedCaseInsensitiveContains("base_url")
        }
        return false
    }

    private func resourceName(fromEndpoint endpoint: String) -> String? {
        guard let host = URL(string: endpoint)?.host else { return nil }
        if let range = host.range(of: ".openai.azure.com") {
            return String(host[..<range.lowerBound])
        }
        return nil
    }

    private func clean(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("$") else { return nil }
        return trimmed
    }
}

private final class LineReader {
    private let fileHandle: FileHandle
    private var buffer = Data()
    private var offset: UInt64 = 0
    private var didReachEOF = false
    private let chunkSize = 64 * 1024

    init?(url: URL) {
        guard let fileHandle = try? FileHandle(forReadingFrom: url) else {
            return nil
        }
        self.fileHandle = fileHandle
    }

    func nextLineData() -> Data? {
        while true {
            if let newlineRange = buffer.firstRange(of: Data([0x0A])) {
                var line = buffer[..<newlineRange.lowerBound]
                let consumed = buffer.distance(from: buffer.startIndex, to: newlineRange.upperBound)
                buffer.removeSubrange(..<newlineRange.upperBound)
                offset += UInt64(consumed)
                if line.last == 0x0D {
                    line = line.dropLast()
                }
                return Data(line)
            }

            if didReachEOF {
                guard !buffer.isEmpty else { return nil }
                let line = buffer
                offset += UInt64(buffer.count)
                buffer.removeAll(keepingCapacity: true)
                if line.last == 0x0D {
                    return line.dropLast()
                }
                return line
            }

            let chunk = fileHandle.readData(ofLength: chunkSize)
            if chunk.isEmpty {
                didReachEOF = true
            } else {
                buffer.append(chunk)
            }
        }
    }

    deinit {
        try? fileHandle.close()
    }
}


private extension Data {
    func containsASCII(_ pattern: [UInt8]) -> Bool {
        guard !pattern.isEmpty, count >= pattern.count else { return false }
        return range(of: Data(pattern)) != nil
    }
}
