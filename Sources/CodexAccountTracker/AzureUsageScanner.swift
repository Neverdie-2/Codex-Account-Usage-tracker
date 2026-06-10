import Foundation

final class AzureUsageScanner {
    private let fileManager: FileManager
    private let logRoots: [URL]
    private let metadataURLs: [URL]
    private let provider: CodexLogUsageProvider
    private let codexLocalUsageIndexStore: CodexLocalUsageIndexStore
    private let claudeCodeUsageIndexStore: ClaudeCodeUsageIndexStore

    init(
        provider: CodexLogUsageProvider = .azure,
        fileManager: FileManager = .default,
        logRoots: [URL] = AzureUsageScanner.defaultLogRoots(),
        metadataURLs: [URL] = AzureUsageScanner.defaultMetadataURLs(),
        codexLocalUsageIndexStore: CodexLocalUsageIndexStore = CodexLocalUsageIndexStore(),
        claudeCodeUsageIndexStore: ClaudeCodeUsageIndexStore = ClaudeCodeUsageIndexStore()
    ) {
        self.provider = provider
        self.fileManager = fileManager
        self.logRoots = logRoots
        self.metadataURLs = metadataURLs
        self.codexLocalUsageIndexStore = codexLocalUsageIndexStore
        self.claudeCodeUsageIndexStore = claudeCodeUsageIndexStore
    }

    func scan(since startDate: Date? = nil) -> AzureUsageScanResult {
        // LM Studio usage comes from LMStudioConversationStore; this scanner has no
        // LM Studio path. Fail loudly in debug if one is ever wired up by mistake —
        // otherwise it would silently return an empty, plausible-looking result.
        assert(provider != .lmStudio, "Use LMStudioConversationStore for LM Studio usage")
        let metadata: AzureUsageDetectedMetadata
        switch provider {
        case .azure:
            metadata = AzureUsageMetadataDetector(fileManager: fileManager, urls: metadataURLs).detect()
        case .openai:
            metadata = AzureUsageDetectedMetadata(endpoint: "OpenAI", resource: "Codex local logs", deployment: nil, warnings: [])
        case .claudeCode:
            metadata = AzureUsageDetectedMetadata(endpoint: "Anthropic", resource: "Claude Code transcripts", deployment: nil, warnings: [])
        case .lmStudio:
            // LM Studio usage is produced by LMStudioConversationStore, not this scanner.
            metadata = AzureUsageDetectedMetadata(endpoint: "LM Studio", resource: "Local chats", deployment: nil, warnings: [])
        }
        var result = AzureUsageScanResult(provider: provider)
        var state = AzureUsageScanState()
        var warnings = metadata.warnings
        let fileURLs = switch provider {
        case .openai, .azure:
            jsonlFileURLs()
        case .claudeCode:
            jsonlFileURLs(since: startDate)
        case .lmStudio:
            [URL]()
        }
        result.summary.filesScanned = fileURLs.count

        switch provider {
        case .openai, .azure:
            scanCodexLocalSessions(fileURLs: fileURLs, metadata: metadata, eventCutoff: startDate, result: &result, state: &state)
        case .claudeCode:
            scanClaudeCodeSessions(fileURLs: fileURLs, eventCutoff: startDate, result: &result, state: &state)
        case .lmStudio:
            break
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

    private func scanCodexLocalSessions(
        fileURLs: [URL],
        metadata: AzureUsageDetectedMetadata,
        eventCutoff: Date?,
        result: inout AzureUsageScanResult,
        state: inout AzureUsageScanState
    ) {
        var index = codexLocalUsageIndexStore.load()
        let currentPaths = Set(fileURLs.map(\.path))
        var didChangeIndex = false
        for cachedPath in Array(index.files.keys) where !currentPaths.contains(cachedPath) {
            index.files.removeValue(forKey: cachedPath)
            didChangeIndex = true
        }

        var sessions: [CodexLocalUsageIndexedSession] = []
        for fileURL in fileURLs {
            guard let fingerprint = CodexLocalUsageFileFingerprint.make(fileURL: fileURL, fileManager: fileManager) else {
                continue
            }

            if let cached = index.files[fileURL.path],
               cached.fingerprint == fingerprint {
                sessions.append(cached.session)
                continue
            }

            let rootURL = logRoots.first { fileURL.path.hasPrefix($0.path) }
            if let session = parseCodexLocalFile(fileURL: fileURL, rootURL: rootURL) {
                index.files[fileURL.path] = CodexLocalUsageIndexedFile(fingerprint: fingerprint, session: session)
                sessions.append(session)
            } else {
                index.files.removeValue(forKey: fileURL.path)
            }
            didChangeIndex = true
        }

        sessions.sort { lhs, rhs in
            let lhsDate = lhs.metaTimestamp ?? Date.distantPast
            let rhsDate = rhs.metaTimestamp ?? Date.distantPast
            if lhsDate != rhsDate { return lhsDate < rhsDate }
            return lhs.filePath.localizedCaseInsensitiveCompare(rhs.filePath) == .orderedAscending
        }

        result.summary.sessionsScanned = sessions.count
        result.summary.providerSessions = sessions.filter(isTargetCodexLocalSession).count
        for session in sessions {
            guard isTargetCodexLocalSession(session) else {
                seedCodexLocalReplayState(from: session, state: &state)
                continue
            }
            processCodexLocalSession(session, metadata: metadata, eventCutoff: eventCutoff, result: &result, state: &state)
        }

        if didChangeIndex {
            codexLocalUsageIndexStore.save(index)
        }
    }

    private func parseCodexLocalFile(fileURL: URL, rootURL: URL?) -> CodexLocalUsageIndexedSession? {
        let fileSessionID = Self.sessionID(for: fileURL, rootURL: rootURL)
        var sessionID = fileSessionID
        var metaTimestamp: Date?
        var forkedFromID: String?
        var projectPath = AzureUsageRecord.unknownProject
        var sessionProvider: String?
        var originator: String?
        var didReadCodexSessionMeta = false
        var didReadSessionMeta = false
        var currentModel: String?
        var parsedEvents: [CodexLocalUsageIndexedEvent] = []
        var eventIndex = 0

        func consume(_ lineData: Data) -> Bool {
            guard !lineData.isEmpty else { return true }

            if lineData.containsASCII(Self.sessionMetaBytes) {
                guard let line = String(data: lineData, encoding: .utf8) else { return false }
                guard !didReadCodexSessionMeta else { return true }
                didReadCodexSessionMeta = true
                sessionProvider = Self.extractStringValue(named: "model_provider", from: line)
                originator = Self.extractStringValue(named: "originator", from: line)
                guard sessionProvider == CodexLogUsageProvider.openai.rawValue
                    || sessionProvider == CodexLogUsageProvider.azure.rawValue
                    || sessionProvider == "azure_echo"
                else { return false }
                didReadSessionMeta = true
                if let id = Self.extractStringValue(named: "id", from: line), !id.isEmpty {
                    sessionID = id
                }
                metaTimestamp = Self.date(from: Self.extractStringValue(named: "timestamp", from: line))
                forkedFromID = Self.extractStringValue(named: "forked_from_id", from: line)
                projectPath = Self.extractProjectPath(from: line)
                return true
            }

            guard didReadSessionMeta else { return true }

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
            let replayKey = totalUsage.map { Self.replayDedupeKey(model: currentModel ?? Self.unknownModel, totalUsage: $0, lastUsage: lastUsage) }
            parsedEvents.append(CodexLocalUsageIndexedEvent(
                recordID: "\(sessionID)-\(eventIndex)",
                timestamp: timestamp,
                model: currentModel ?? Self.unknownModel,
                lastUsage: lastUsage,
                replayKey: replayKey,
                sessionDedupeKey: totalUsage.map { "\(sessionID)|\($0.signature)" }
            ))
            return true
        }

        guard let relevantLines = Self.codexLocalRelevantLineData(fileURL: fileURL) else {
            return nil
        }
        for lineData in relevantLines {
            guard consume(lineData) else { return nil }
        }

        guard didReadSessionMeta else { return nil }
        return CodexLocalUsageIndexedSession(
            filePath: fileURL.path,
            sessionID: sessionID,
            provider: sessionProvider ?? "",
            originator: originator,
            metaTimestamp: metaTimestamp,
            forkedFromID: forkedFromID,
            projectPath: projectPath,
            events: parsedEvents
        )
    }

    private func isTargetCodexLocalSession(_ session: CodexLocalUsageIndexedSession) -> Bool {
        session.provider == provider.rawValue
            && (provider != .openai || session.originator == "Codex Desktop")
    }

    private func seedCodexLocalReplayState(from session: CodexLocalUsageIndexedSession, state: inout AzureUsageScanState) {
        for event in session.events {
            guard let replayKey = replayDedupeKey(for: event) else { continue }
            state.codexLocalReplayKeys.insert(replayKey)
        }
    }

    private func processCodexLocalSession(
        _ session: CodexLocalUsageIndexedSession,
        metadata: AzureUsageDetectedMetadata,
        eventCutoff: Date?,
        result: inout AzureUsageScanResult,
        state: inout AzureUsageScanState
    ) {
        let replayPrefixCount = startupReplayPrefixCount(for: session, state: state)
        let isForkedSession = session.forkedFromID?.isEmpty == false
        for (eventOffset, event) in session.events.enumerated() {
            let sessionDedupeKey = event.sessionDedupeKey
            let replayKey = event.replayKey

            if let eventCutoff, event.timestamp <= eventCutoff {
                if let sessionDedupeKey {
                    state.codexLocalDedupeKeys.insert(sessionDedupeKey)
                }
                if let replayKey {
                    state.codexLocalReplayKeys.insert(replayKey)
                }
                continue
            }

            if eventOffset < replayPrefixCount {
                result.summary.startupReplayEventsSkipped += 1
                if let replayKey {
                    state.codexLocalReplayKeys.insert(replayKey)
                }
                continue
            }

            if isForkedSession,
               let replayKey,
               state.codexLocalReplayKeys.contains(replayKey) {
                result.summary.startupReplayEventsSkipped += 1
                continue
            }

            if let sessionDedupeKey {
                guard state.codexLocalDedupeKeys.insert(sessionDedupeKey).inserted else {
                    result.summary.duplicateEventsSkipped += 1
                    if let replayKey {
                        state.codexLocalReplayKeys.insert(replayKey)
                    }
                    continue
                }
            }

            if event.lastUsage.isZero {
                if let replayKey {
                    state.codexLocalReplayKeys.insert(replayKey)
                }
                continue
            }

            appendRecord(
                sessionID: session.sessionID,
                recordID: event.recordID,
                fileURL: URL(fileURLWithPath: session.filePath),
                timestamp: event.timestamp,
                metadata: metadata,
                model: event.model,
                usage: event.lastUsage,
                projectPath: session.projectPath,
                result: &result
            )

            if let replayKey {
                state.codexLocalReplayKeys.insert(replayKey)
            }
        }
    }

    private func startupReplayPrefixCount(for session: CodexLocalUsageIndexedSession, state: AzureUsageScanState) -> Int {
        guard session.forkedFromID?.isEmpty == false else {
            return 0
        }

        var matchingPrefixCount = 0
        for event in session.events {
            guard let replayKey = replayDedupeKey(for: event),
                  state.codexLocalReplayKeys.contains(replayKey)
            else {
                break
            }
            matchingPrefixCount += 1
        }
        if matchingPrefixCount > 0 {
            return matchingPrefixCount
        }

        guard let replayCutoff = startupReplayCutoff(for: session) else {
            return 0
        }
        return session.events.prefix { $0.timestamp <= replayCutoff }.count
    }

    private func startupReplayCutoff(for session: CodexLocalUsageIndexedSession) -> Date? {
        guard session.forkedFromID?.isEmpty == false, !session.events.isEmpty else {
            return nil
        }
        let start = session.events.map(\.timestamp).min()
        guard let start else { return nil }
        let burstEnd = start.addingTimeInterval(5)
        let burstEvents = session.events.filter { event in
            event.timestamp >= start && event.timestamp <= burstEnd
        }
        guard burstEvents.count >= 5 else { return nil }
        return burstEvents.map(\.timestamp).max()
    }

    private func replayDedupeKey(for event: CodexLocalUsageIndexedEvent) -> String? {
        event.replayKey
    }

    private static func replayDedupeKey(model: String, totalUsage: AzureTokenUsage, lastUsage: AzureTokenUsage) -> String {
        "\(model)|\(totalUsage.signature)|\(lastUsage.signature)"
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
        var keyedRows: [String: AzureUsageParsedClaudeCodeEvent] = [:]
        var unkeyedRows: [AzureUsageParsedClaudeCodeEvent] = []
        var index = claudeCodeUsageIndexStore.load()
        var didChangeIndex = false

        if eventCutoff == nil {
            let currentPaths = Set(fileURLs.map(\.path))
            for cachedPath in Array(index.files.keys) where !currentPaths.contains(cachedPath) {
                index.files.removeValue(forKey: cachedPath)
                didChangeIndex = true
            }
        }

        for fileURL in fileURLs {
            guard let fingerprint = CodexLocalUsageFileFingerprint.make(fileURL: fileURL, fileManager: fileManager) else {
                continue
            }

            let indexedFile: ClaudeCodeUsageIndexedFile
            if let cached = index.files[fileURL.path],
               cached.fingerprint == fingerprint {
                indexedFile = cached
            } else if let parsed = parseClaudeCodeFile(
                fileURL: fileURL,
                fingerprint: fingerprint,
                anthropicMetadata: anthropicMetadata,
                foundryMetadata: foundryMetadata,
                anthropicDesktopMetadata: anthropicDesktopMetadata,
                foundryRootPaths: foundryRootPaths
            ) {
                index.files[fileURL.path] = parsed
                indexedFile = parsed
                didChangeIndex = true
            } else {
                index.files.removeValue(forKey: fileURL.path)
                didChangeIndex = true
                continue
            }

            if indexedFile.sawAssistantLine {
                result.summary.sessionsScanned += 1
            }
            result.summary.malformedEventsSkipped += indexedFile.malformedEventsSkipped
            var fileKeyedRows: [String: AzureUsageParsedClaudeCodeEvent] = [:]
            var fileUnkeyedRows: [AzureUsageParsedClaudeCodeEvent] = []
            var didCountProviderSession = false

            for indexedRow in indexedFile.rows {
                if let eventCutoff, indexedRow.timestamp <= eventCutoff {
                    continue
                }

                if !didCountProviderSession {
                    result.summary.providerSessions += 1
                    didCountProviderSession = true
                }

                let row = parsedClaudeCodeEvent(from: indexedRow)

                if let billingKey = row.billingKey {
                    // Streaming chunks share the same provider message/request identity inside
                    // a transcript. Later chunks carry cumulative usage, so the last row wins
                    // before we compare duplicates copied into other transcript files.
                    fileKeyedRows[billingKey] = row
                } else {
                    fileUnkeyedRows.append(row)
                }
            }

            for row in fileKeyedRows.values {
                guard let billingKey = row.billingKey else {
                    unkeyedRows.append(row)
                    continue
                }
                if let existing = keyedRows[billingKey] {
                    result.summary.duplicateEventsSkipped += 1
                    if Self.claudeCodeRowWins(candidate: row, existing: existing) {
                        keyedRows[billingKey] = row
                    }
                } else {
                    keyedRows[billingKey] = row
                }
            }
            unkeyedRows.append(contentsOf: fileUnkeyedRows)
        }

        if didChangeIndex {
            claudeCodeUsageIndexStore.save(index)
        }

        let rows = keyedRows.values.sorted { lhs, rhs in
            if lhs.timestamp != rhs.timestamp { return lhs.timestamp < rhs.timestamp }
            return lhs.recordID.localizedCaseInsensitiveCompare(rhs.recordID) == .orderedAscending
        } + unkeyedRows

        for row in rows {
            appendRecord(
                sessionID: row.sessionID,
                recordID: row.recordID,
                fileURL: row.fileURL,
                timestamp: row.timestamp,
                metadata: row.metadata,
                model: row.model,
                usage: row.usage,
                projectPath: row.projectPath,
                result: &result
            )
        }
    }

    private func parseClaudeCodeFile(
        fileURL: URL,
        fingerprint: CodexLocalUsageFileFingerprint,
        anthropicMetadata: AzureUsageDetectedMetadata,
        foundryMetadata: AzureUsageDetectedMetadata,
        anthropicDesktopMetadata: AzureUsageDetectedMetadata,
        foundryRootPaths: [String]
    ) -> ClaudeCodeUsageIndexedFile? {
        let standardizedPath = fileURL.standardizedFileURL.path
        let isFoundry = foundryRootPaths.contains { standardizedPath.hasPrefix($0) }
        let defaultMetadata = isFoundry ? foundryMetadata : anthropicMetadata
        let sessionID = fileURL.deletingPathExtension().lastPathComponent
        var sawAssistantLine = false
        var malformedEventsSkipped = 0
        var rows: [ClaudeCodeUsageIndexedRow] = []

        guard let assistantLines = Self.claudeCodeAssistantLineData(fileURL: fileURL) else {
            return nil
        }

        for lineData in assistantLines {
            guard let object = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  (object["type"] as? String) == "assistant",
                  let message = object["message"] as? [String: Any],
                  let usageDict = message["usage"] as? [String: Any]
            else { continue }

            sawAssistantLine = true

            guard let messageID = message["id"] as? String, !messageID.isEmpty else {
                malformedEventsSkipped += 1
                continue
            }
            let requestID = object["requestId"] as? String
            let logSessionID = (object["sessionId"] as? String)
                ?? (object["session_id"] as? String)
                ?? ((object["metadata"] as? [String: Any])?["sessionId"] as? String)
                ?? ((message["metadata"] as? [String: Any])?["sessionId"] as? String)
                ?? sessionID

            guard let timestamp = Self.date(from: object["timestamp"]) else {
                malformedEventsSkipped += 1
                continue
            }

            let model = (object["model"] as? String)
                ?? (message["model"] as? String)
                ?? Self.unknownModel
            if model == "<synthetic>" { continue }

            let usage = Self.claudeCodeTokenUsage(from: usageDict)
            if usage.isZero { continue }

            let entrypoint = (object["entrypoint"] as? String) ?? ""
            let metadata = (isFoundry && entrypoint == "claude-desktop")
                ? anthropicDesktopMetadata
                : defaultMetadata

            rows.append(ClaudeCodeUsageIndexedRow(
                sessionID: logSessionID,
                filePath: fileURL.path,
                timestamp: timestamp,
                endpoint: metadata.endpoint,
                resource: metadata.resource,
                deployment: metadata.deployment,
                model: model,
                usage: usage,
                projectPath: Self.claudeCodeProjectPath(fileURL: fileURL, cwd: object["cwd"] as? String),
                messageID: messageID,
                requestID: requestID,
                isSidechain: Self.boolValue(object["isSidechain"]),
                isSubagent: fileURL.path.contains("/subagents/")
            ))
        }

        return ClaudeCodeUsageIndexedFile(
            fingerprint: fingerprint,
            sawAssistantLine: sawAssistantLine,
            malformedEventsSkipped: malformedEventsSkipped,
            rows: rows
        )
    }

    private func parsedClaudeCodeEvent(from row: ClaudeCodeUsageIndexedRow) -> AzureUsageParsedClaudeCodeEvent {
        AzureUsageParsedClaudeCodeEvent(
            sessionID: row.sessionID,
            fileURL: URL(fileURLWithPath: row.filePath),
            timestamp: row.timestamp,
            metadata: AzureUsageDetectedMetadata(
                endpoint: row.endpoint,
                resource: row.resource,
                deployment: row.deployment,
                warnings: []
            ),
            model: row.model,
            usage: row.usage,
            projectPath: row.projectPath,
            messageID: row.messageID,
            requestID: row.requestID,
            isSidechain: row.isSidechain,
            pathRole: row.isSubagent ? .subagent : .parent
        )
    }

    private static func claudeCodeProjectPath(fileURL: URL, cwd: String?) -> String {
        let fallback = AzureUsageRecord.normalizedProjectPath(cwd)
        guard let projectDirectoryName = claudeCodeProjectDirectoryName(for: fileURL) else {
            return fallback
        }

        if let cwd, !cwd.isEmpty {
            var candidate = URL(fileURLWithPath: cwd).standardizedFileURL
            while candidate.path != "/" {
                if claudeCodeEncodedProjectPath(candidate.path) == projectDirectoryName {
                    return AzureUsageRecord.normalizedProjectPath(candidate.path)
                }
                candidate.deleteLastPathComponent()
            }
        }

        return fallback
    }

    private static func claudeCodeProjectDirectoryName(for fileURL: URL) -> String? {
        let standardizedPath = fileURL.standardizedFileURL.path
        for root in defaultClaudeCodeLogRoots() {
            let rootPath = root.standardizedFileURL.path + "/"
            guard standardizedPath.hasPrefix(rootPath) else { continue }
            let relativePath = String(standardizedPath.dropFirst(rootPath.count))
            return relativePath.split(separator: "/").first.map(String.init)
        }
        return nil
    }

    private static func claudeCodeEncodedProjectPath(_ path: String) -> String {
        path.replacingOccurrences(of: "/", with: "-")
    }

    private static func claudeCodeRowWins(candidate: AzureUsageParsedClaudeCodeEvent, existing: AzureUsageParsedClaudeCodeEvent) -> Bool {
        let candidateCost = AzureModelPricing.defaultPricing(for: candidate.model, provider: .claudeCode).estimatedCost(for: candidate.usage)
        let existingCost = AzureModelPricing.defaultPricing(for: existing.model, provider: .claudeCode).estimatedCost(for: existing.usage)
        if candidateCost != existingCost {
            return candidateCost > existingCost
        }
        if candidate.usage.totalTokens != existing.usage.totalTokens {
            return candidate.usage.totalTokens > existing.usage.totalTokens
        }
        if candidate.usage.outputTokens != existing.usage.outputTokens {
            return candidate.usage.outputTokens > existing.usage.outputTokens
        }
        if candidate.isSidechain != existing.isSidechain {
            return !candidate.isSidechain
        }
        if candidate.pathRole != existing.pathRole {
            return candidate.pathRole == .parent
        }
        return candidate.fileURL.path.localizedCaseInsensitiveCompare(existing.fileURL.path) == .orderedAscending
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
        case .lmStudio:
            // Unreachable: the scanner never emits LM Studio records (see scan()).
            endpoint = metadata.endpoint ?? "LM Studio"
            resource = metadata.resource ?? "Local chats"
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

    private static func codexLocalRelevantLineData(fileURL: URL) -> [Data]? {
        guard let data = try? Data(contentsOf: fileURL, options: [.mappedIfSafe]) else {
            return nil
        }

        var lineRangesByStart: [Data.Index: Range<Data.Index>] = [:]
        for pattern in codexLocalRelevantLinePatterns {
            var searchRange = data.startIndex..<data.endIndex
            while let match = data.range(of: pattern, options: [], in: searchRange) {
                let lineStart: Data.Index
                if let previousNewline = data[..<match.lowerBound].lastIndex(of: 0x0A) {
                    lineStart = data.index(after: previousNewline)
                } else {
                    lineStart = data.startIndex
                }

                let lineEnd = data[match.upperBound..<data.endIndex].firstIndex(of: 0x0A) ?? data.endIndex
                lineRangesByStart[lineStart] = lineStart..<lineEnd
                searchRange = match.upperBound..<data.endIndex
            }
        }

        return lineRangesByStart
            .values
            .sorted { $0.lowerBound < $1.lowerBound }
            .map { range in
                var line = Data(data[range])
                if line.last == 0x0D {
                    line.removeLast()
                }
                return line
            }
    }

    private static func claudeCodeAssistantLineData(fileURL: URL) -> [Data]? {
        guard let data = try? Data(contentsOf: fileURL, options: [.mappedIfSafe]) else {
            return nil
        }

        var lines: [Data] = []
        var searchRange = data.startIndex..<data.endIndex
        let assistantPattern = Data(assistantTypeBytes)
        let usagePattern = Data("\"usage\"".utf8)
        while let match = data.range(of: assistantPattern, options: [], in: searchRange) {
            let lineStart: Data.Index
            if let previousNewline = data[..<match.lowerBound].lastIndex(of: 0x0A) {
                lineStart = data.index(after: previousNewline)
            } else {
                lineStart = data.startIndex
            }
            let lineEnd = data[match.upperBound..<data.endIndex].firstIndex(of: 0x0A) ?? data.endIndex
            searchRange = match.upperBound..<data.endIndex

            let lineRange = lineStart..<lineEnd
            guard data.range(of: usagePattern, options: [], in: lineRange) != nil else {
                continue
            }

            var line = Data(data[lineRange])
            if line.last == 0x0D {
                line.removeLast()
            }
            lines.append(line)
        }

        return lines
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

    private static func boolValue(_ value: Any?) -> Bool {
        if let bool = value as? Bool { return bool }
        if let number = value as? NSNumber { return number.boolValue }
        return false
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
    private static let codexLocalRelevantLinePatterns = [
        Data(sessionMetaBytes),
        Data(turnContextBytes),
        Data(tokenCountBytes)
    ]
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
    var codexLocalDedupeKeys = Set<String>()
    var codexLocalReplayKeys = Set<String>()
}

private enum AzureUsageClaudeCodePathRole {
    case parent
    case subagent
}

private struct AzureUsageParsedClaudeCodeEvent {
    var sessionID: String
    var fileURL: URL
    var timestamp: Date
    var metadata: AzureUsageDetectedMetadata
    var model: String
    var usage: AzureTokenUsage
    var projectPath: String
    var messageID: String
    var requestID: String?
    var isSidechain: Bool
    var pathRole: AzureUsageClaudeCodePathRole

    var billingKey: String? {
        if let requestID, !requestID.isEmpty {
            return "\(messageID):\(requestID)"
        }
        return messageID.isEmpty ? nil : messageID
    }

    var recordID: String {
        if let requestID, !requestID.isEmpty {
            return "claude-code-\(messageID)-\(requestID)"
        }
        return "claude-code-\(messageID)"
    }
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
