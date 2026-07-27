import Combine
import Foundation

@MainActor
final class AccountTrackerViewModel: ObservableObject {
    @Published private(set) var accounts: [AccountRecord] = []
    @Published private(set) var activeEmail: String?
    @Published private(set) var statusText = "Starting..."
    @Published private(set) var lastError: String?
    @Published private(set) var isRefreshing = false
    @Published private(set) var isLiveMonitoring = false
    @Published private(set) var runningServerEndpoint: String?
    @Published private(set) var displayNow = Date()
    @Published private(set) var azureUsage = AzureUsageDashboard.empty
    @Published private(set) var openAIUsage = AzureUsageDashboard.empty
    @Published private(set) var claudeCodeUsage = AzureUsageDashboard.empty
    @Published private(set) var lmStudioUsage = AzureUsageDashboard.empty
    @Published private(set) var claudeAzureUsage = AzureUsageDashboard.empty
    @Published private(set) var openAIAPIBilling = OpenAIAPIBillingDashboard.empty
    @Published private(set) var isAzureRefreshing = false
    @Published private(set) var isOpenAIRefreshing = false
    @Published private(set) var isClaudeCodeRefreshing = false
    @Published private(set) var isLMStudioRefreshing = false
    @Published private(set) var isClaudeAzureRefreshing = false
    @Published private(set) var isOpenAIAPIBillingRefreshing = false
    @Published private(set) var azureLastScannedAt: Date?
    @Published private(set) var openAILastScannedAt: Date?
    @Published private(set) var claudeCodeLastScannedAt: Date?
    @Published private(set) var lmStudioLastScannedAt: Date?
    @Published private(set) var claudeAzureLastScannedAt: Date?
    @Published private(set) var openAIAPIBillingLastScannedAt: Date?
    @Published var openAIAdminKey: String {
        didSet {
            KeychainSecretStore.save(openAIAdminKey, account: Self.openAIAdminKeyAccount)
        }
    }
    @Published var openAIAPIUsageWindow: OpenAIAPIUsageWindow = AppPreferences.openAIAPIUsageWindow {
        didSet {
            AppPreferences.openAIAPIUsageWindow = openAIAPIUsageWindow
            rebuildOpenAIAPIBillingDashboard()
        }
    }
    @Published var openAIAPICustomStartDate: Date = Calendar.current.date(byAdding: .day, value: -30, to: Date()) ?? Date() {
        didSet {
            if openAIAPIUsageWindow == .sinceDate {
                rebuildOpenAIAPIBillingDashboard()
            }
        }
    }
    @Published var openAIUsageScanMode: CodexUsageScanMode = .recent24Hours {
        didSet {
            rebuildOpenAIUsageDashboard()
        }
    }
    @Published var openAICustomStartDate: Date = Calendar.current.date(byAdding: .day, value: -7, to: Date()) ?? Date() {
        didSet {
            if openAIUsageScanMode == .sinceDate {
                rebuildOpenAIUsageDashboard()
            }
        }
    }
    @Published var claudeCodeUsageScanMode: CodexUsageScanMode = .recent24Hours {
        didSet {
            rebuildClaudeCodeUsageDashboard()
        }
    }
    @Published var claudeCodeCustomStartDate: Date = Calendar.current.date(byAdding: .day, value: -7, to: Date()) ?? Date() {
        didSet {
            if claudeCodeUsageScanMode == .sinceDate {
                rebuildClaudeCodeUsageDashboard()
            }
        }
    }
    @Published var lmStudioUsageScanMode: CodexUsageScanMode = .recent24Hours {
        didSet {
            rebuildLMStudioUsageDashboard()
        }
    }
    @Published var lmStudioCustomStartDate: Date = Calendar.current.date(byAdding: .day, value: -7, to: Date()) ?? Date() {
        didSet {
            if lmStudioUsageScanMode == .sinceDate {
                rebuildLMStudioUsageDashboard()
            }
        }
    }
    @Published var claudeAzureUsageScanMode: CodexUsageScanMode = .recent24Hours {
        didSet { rebuildClaudeAzureUsageDashboard() }
    }
    @Published var claudeAzureCustomStartDate: Date = Calendar.current.date(byAdding: .day, value: -7, to: Date()) ?? Date() {
        didSet { if claudeAzureUsageScanMode == .sinceDate { rebuildClaudeAzureUsageDashboard() } }
    }
    @Published var azureUsageWindow: AzureUsageTimeWindow = .last7Days {
        didSet {
            rebuildAzureUsageDashboard()
        }
    }
    @Published var azureCustomStartDate: Date = Calendar.current.date(byAdding: .day, value: -7, to: Date()) ?? Date() {
        didSet {
            if azureUsageWindow == .sinceDate {
                rebuildAzureUsageDashboard()
            }
        }
    }
    @Published var endpointText: String {
        didSet {
            AppPreferences.endpoint = endpointText.trimmingCharacters(in: .whitespacesAndNewlines)
            if oldValue != endpointText {
                stopLiveMonitoring()
                stopOwnServer()
                resumeManagedServer()
            }
        }
    }

    let refreshIntervalSeconds: TimeInterval = 30

    private let store = AccountStore()
    private let usageCacheStore = AzureUsageCacheStore()
    private let openAIAPIBillingCacheStore = OpenAIAPIBillingCacheStore()
    private let openAIAPIBillingClient = OpenAIAPIBillingClient()
    private let azureScanner = AzureUsageScanner()
    private let openAIUsageScanner = AzureUsageScanner(provider: .openai, logRoots: AzureUsageScanner.defaultLogRoots())
    private let claudeCodeUsageScanner = AzureUsageScanner(
        provider: .claudeCode,
        logRoots: AzureUsageScanner.defaultClaudeCodeLogRoots()
    )
    private let server = CodexServerManager()
    private var client: CodexRPCClient?
    private var azureScanResult = AzureUsageScanResult.empty
    private var openAIScanResult = AzureUsageScanResult(provider: .openai)
    private var claudeCodeScanResult = AzureUsageScanResult(provider: .claudeCode)
    private let desktopChatStore = ClaudeDesktopChatStore()
    private var desktopChatRecords: [AzureUsageRecord] = []
    private let lmStudioConversationStore = LMStudioConversationStore()
    private let opencodeUsageStore = OpencodeUsageStore()
    private let claudeAzureUsageStore = ClaudeAzureUsageStore()
    private var lmStudioScanResult = AzureUsageScanResult(provider: .lmStudio)
    private var claudeAzureScanResult = AzureUsageScanResult(provider: .claudeAzure)
    private var openAIAPIBillingResult = OpenAIAPIBillingResult.empty
    private var refreshTask: Task<Void, Never>?
    private var displayClockTask: Task<Void, Never>?
    private var authMonitorTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var shouldLiveMonitor = false
    private var pendingRefresh = false
    private var isManagingServerLifecycle = false
    private var isStartingLiveMonitoring = false
    private var isRecoveringAuthChange = false
    private var restartPolicy = ManagedServerRestartPolicy()
    /// Set once the managed server has crash-looped past the policy's limit;
    /// suppresses all auto-restart until a user action re-engages it.
    private var managedServerGaveUp = false
    private var shouldRebuildAzureUsageCache = false
    private var shouldRebuildOpenAIUsageCache = false
    private var shouldRebuildClaudeCodeUsageCache = false
    private var lastAuthFileSignature: AuthFileSignature?
    private var lastAuthChangeRecoveryAt: Date?
    private static let openAIAdminKeyAccount = "openai-admin-api-key"

    init() {
        endpointText = AppPreferences.endpoint
        openAIAdminKey = KeychainSecretStore.load(account: Self.openAIAdminKeyAccount)
    }

    var storagePath: String {
        store.path
    }

    var endpointURL: URL? {
        URL(string: endpointText.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    var selectableReportText: String {
        var lines: [String] = [
            "Codex Account Tracker",
            endpointText,
            statusText
        ]

        if let lastError {
            lines.append(lastError)
        }

        lines.append("")

        if accounts.isEmpty {
            lines.append("No accounts saved yet")
            lines.append("")
        } else {
            for account in accounts {
                append(account: account, to: &lines)
                lines.append("")
            }
        }

        appendUsageDashboard(
            openAIUsage,
            title: "OpenAI Codex Usage",
            windowLabel: openAIUsageScanMode.label,
            lastScannedAt: openAILastScannedAt,
            sessionCounterLabel: CodexLogUsageProvider.openai.sessionCounterLabel,
            to: &lines
        )
        lines.append("")
        appendUsageDashboard(
            claudeCodeUsage,
            title: "Claude Code Usage",
            windowLabel: claudeCodeUsageScanMode.label,
            lastScannedAt: claudeCodeLastScannedAt,
            sessionCounterLabel: CodexLogUsageProvider.claudeCode.sessionCounterLabel,
            to: &lines
        )
        lines.append("")
        appendUsageDashboard(
            lmStudioUsage,
            title: "LM Studio Usage",
            windowLabel: lmStudioUsageScanMode.label,
            lastScannedAt: lmStudioLastScannedAt,
            sessionCounterLabel: CodexLogUsageProvider.lmStudio.sessionCounterLabel,
            costLabel: CodexLogUsageProvider.lmStudio.costLabel,
            costShortLabel: CodexLogUsageProvider.lmStudio.costShortLabel,
            to: &lines
        )
        lines.append("")
        appendUsageDashboard(
            claudeAzureUsage,
            title: "Claude Azure Usage",
            windowLabel: claudeAzureUsageScanMode.label,
            lastScannedAt: claudeAzureLastScannedAt,
            sessionCounterLabel: CodexLogUsageProvider.claudeAzure.sessionCounterLabel,
            costLabel: CodexLogUsageProvider.claudeAzure.costLabel,
            costShortLabel: CodexLogUsageProvider.claudeAzure.costShortLabel,
            to: &lines
        )
        lines.append("")
        appendUsageDashboard(
            azureUsage,
            title: "Azure Usage",
            windowLabel: azureUsageWindow.label,
            lastScannedAt: azureLastScannedAt,
            sessionCounterLabel: CodexLogUsageProvider.azure.sessionCounterLabel,
            to: &lines
        )
        lines.append("")
        appendOpenAIAPIBillingDashboard(to: &lines)

        return lines.joined(separator: "\n")
    }

    func start() async {
        accounts = store.load()
        persistExpiredLocalResets(now: displayNow)
        startDisplayClock()
        startAuthFileMonitor()
        server.onOutput = { [weak self] output in
            guard !output.isEmpty else { return }
            guard !Self.isRoutineServerOutput(output) else { return }
            self?.lastError = output
        }
        server.onTermination = { [weak self] endpoint, uptime in
            guard let self else { return }
            guard self.runningServerEndpoint == endpoint?.absoluteString else { return }
            self.runningServerEndpoint = nil
            guard self.isManagingServerLifecycle != true else { return }
            guard self.shouldLiveMonitor, self.shouldAutoManageServer else { return }

            switch self.restartPolicy.serverDied(uptime: uptime) {
            case .retry(let delay):
                self.statusText = "Codex server stopped"
                self.lastError = "The tracker app-server stopped. Restarting it automatically."
                self.scheduleLiveReconnect(after: delay)
            case .giveUp:
                self.enterManagedServerGaveUpState()
            }
        }
        statusText = accounts.isEmpty ? "Idle" : "Saved"
        loadUsageCaches()
        if shouldRebuildAzureUsageCache {
            refreshAzureUsage()
        }
        if shouldRebuildOpenAIUsageCache {
            refreshOpenAIUsage()
        }
        if shouldRebuildClaudeCodeUsageCache {
            refreshClaudeCodeUsage()
        }
        // LM Studio rescans are cheap (a handful of JSON files) — always refresh on launch.
        refreshLMStudioUsage()
        refreshClaudeAzureUsage()
        await startLiveMonitoring()
    }

    func refreshNow() {
        Task {
            // If auto-restart gave up on a crash-looping server, Refresh is the
            // user's "try again" — re-engage live monitoring instead of a
            // one-shot fetch that would just fail against the dead server.
            if managedServerGaveUp, shouldAutoManageServer {
                resumeManagedServer()
                await startLiveMonitoring()
            } else {
                await refreshOnce(startOwnServer: false)
            }
        }
    }

    func refreshAzureUsage() {
        guard !isAzureRefreshing else { return }
        isAzureRefreshing = true
        let previousResult = azureScanResult
        let needsFullRebuild = shouldRebuildAzureUsageCache
        let startDate = needsFullRebuild
            ? nil
            : Self.incrementalUsageRefreshStartDate(from: previousResult)

        Task { [weak self, azureScanner, usageCacheStore] in
            let result = await Task.detached(priority: .utility) {
                azureScanner.scan(since: startDate)
            }.value

            guard let self else { return }
            defer { isAzureRefreshing = false }
            let scannedAt = Date()
            azureScanResult = needsFullRebuild
                ? result
                : Self.mergedUsageResult(previousResult, with: result)
            azureLastScannedAt = scannedAt
            usageCacheStore.save(azureScanResult, scannedAt: scannedAt)
            shouldRebuildAzureUsageCache = false
            AppPreferences.azureCodexForkReplayBackfillDone = true
            rebuildAzureUsageDashboard()
            // Claude dashboard folds Claude-named records from azureScanResult into its own
            // view (see rebuildClaudeCodeUsageDashboard), so it must rebuild when Azure data
            // changes — otherwise the Claude panel keeps showing stale Azure-Claude figures.
            rebuildClaudeCodeUsageDashboard()
        }
    }

    func refreshOpenAIUsage() {
        guard !isOpenAIRefreshing else { return }
        isOpenAIRefreshing = true
        let previousResult = openAIScanResult
        let needsFullRebuild = shouldRebuildOpenAIUsageCache
        let startDate = needsFullRebuild
            ? nil
            : Self.openAIUsageRefreshStartDate(
                previousResult: previousResult,
                scanMode: openAIUsageScanMode,
                now: displayNow,
                customStartDate: openAICustomStartDate
            )

        Task { [weak self, openAIUsageScanner, usageCacheStore] in
            let result = await Task.detached(priority: .utility) {
                openAIUsageScanner.scan(since: startDate)
            }.value

            guard let self else { return }
            defer { isOpenAIRefreshing = false }
            let scannedAt = Date()
            openAIScanResult = needsFullRebuild
                ? result
                : Self.mergedUsageResult(previousResult, with: result)
            openAILastScannedAt = scannedAt
            usageCacheStore.save(openAIScanResult, scannedAt: scannedAt)
            shouldRebuildOpenAIUsageCache = false
            AppPreferences.openAICodexForkReplayBackfillDone = true
            rebuildOpenAIUsageDashboard()
        }
    }

    func refreshClaudeCodeUsage() {
        guard !isClaudeCodeRefreshing else { return }
        isClaudeCodeRefreshing = true
        desktopChatRecords = desktopChatStore.recordsFromEntries(desktopChatStore.refreshAndLoad())
        let previousResult = claudeCodeScanResult
        // Trigger a one-time full backfill scan when we've never reached the foundry roots
        // (either a brand new install or upgrading from a build that didn't scan them).
        // The persistent flag prevents repaying full-scan cost forever on machines that
        // have no foundry data; the scan-state check is a defensive fallback if the
        // preference is ever cleared.
        let needsFoundryBackfill = !AppPreferences.claudeCodeFoundryBackfillDone
            && !Self.scanResultIncludesFoundry(previousResult)
        let needsFullRebuild = shouldRebuildClaudeCodeUsageCache || needsFoundryBackfill
        let startDate: Date? = needsFullRebuild
            ? nil
            : Self.openAIUsageRefreshStartDate(
                previousResult: previousResult,
                scanMode: claudeCodeUsageScanMode,
                now: displayNow,
                customStartDate: claudeCodeCustomStartDate
            )

        Task { [weak self, claudeCodeUsageScanner, usageCacheStore] in
            let result = await Task.detached(priority: .utility) {
                claudeCodeUsageScanner.scan(since: startDate)
            }.value

            guard let self else { return }
            defer { isClaudeCodeRefreshing = false }
            let scannedAt = Date()
            claudeCodeScanResult = needsFullRebuild
                ? result
                : Self.mergedUsageResult(previousResult, with: result)
            claudeCodeLastScannedAt = scannedAt
            usageCacheStore.save(claudeCodeScanResult, scannedAt: scannedAt)
            shouldRebuildClaudeCodeUsageCache = false
            AppPreferences.claudeCodeProjectRootBackfillDone = true
            if needsFoundryBackfill {
                AppPreferences.claudeCodeFoundryBackfillDone = true
            }
            rebuildClaudeCodeUsageDashboard()
            // Fresh transcripts change which gateway requests can be attributed to a
            // project, so refresh the Claude Azure "By project" breakdown too.
            rebuildClaudeAzureUsageDashboard()
        }
    }

    func refreshLMStudioUsage() {
        guard !isLMStudioRefreshing else { return }
        isLMStudioRefreshing = true

        Task { [weak self, lmStudioConversationStore, opencodeUsageStore, usageCacheStore] in
            // "LM Studio usage" = all usage of LM-Studio-served models, across
            // clients: the chat app (conversation files) and opencode (its SQLite
            // db, providerID == lmstudio). Both sources are cheap to rescan, so a
            // full rescan each time keeps dedupe trivial (record IDs are disjoint:
            // lm-studio-* vs opencode-*, so the merge just concatenates).
            let scans = await Task.detached(priority: .utility) {
                (conversations: lmStudioConversationStore.scan(), opencode: opencodeUsageStore.scan())
            }.value

            guard let self else { return }
            defer { isLMStudioRefreshing = false }
            let scannedAt = Date()
            lmStudioScanResult = Self.mergedUsageResult(scans.conversations, with: scans.opencode)
            lmStudioLastScannedAt = scannedAt
            usageCacheStore.save(lmStudioScanResult, scannedAt: scannedAt)
            rebuildLMStudioUsageDashboard()
        }
    }

    func refreshClaudeAzureUsage() {
        guard !isClaudeAzureRefreshing else { return }
        isClaudeAzureRefreshing = true
        Task { [weak self, claudeAzureUsageStore, usageCacheStore] in
            let scan = await Task.detached(priority: .utility) { claudeAzureUsageStore.scan() }.value
            guard let self else { return }
            defer { isClaudeAzureRefreshing = false }
            let scannedAt = Date()
            claudeAzureScanResult = scan
            claudeAzureLastScannedAt = scannedAt
            usageCacheStore.save(claudeAzureScanResult, scannedAt: scannedAt)
            rebuildClaudeAzureUsageDashboard()
            // Newly-logged gateway requests may newly identify a transcript session as
            // claude-azure, so rebuild Claude Code to keep those sessions excluded.
            rebuildClaudeCodeUsageDashboard()
        }
    }

    func refreshOpenAIAPIBilling() {
        guard !isOpenAIAPIBillingRefreshing else { return }
        isOpenAIAPIBillingRefreshing = true
        let adminKey = openAIAdminKey
        let startDate = openAIAPIUsageWindow.startDate(now: displayNow, customStartDate: openAIAPICustomStartDate)

        Task { [weak self, openAIAPIBillingClient, openAIAPIBillingCacheStore] in
            do {
                let result = try await openAIAPIBillingClient.fetch(adminKey: adminKey, startDate: startDate)

                guard let self else { return }
                defer { isOpenAIAPIBillingRefreshing = false }
                let scannedAt = Date()
                openAIAPIBillingResult = result
                openAIAPIBillingLastScannedAt = scannedAt
                openAIAPIBillingCacheStore.save(result, scannedAt: scannedAt)
                rebuildOpenAIAPIBillingDashboard()
                lastError = nil
            } catch {
                guard let self else { return }
                isOpenAIAPIBillingRefreshing = false
                lastError = error.localizedDescription
            }
        }
    }

    func startOwnServerAndRefresh() {
        Task {
            resumeManagedServer()
            await startServerAndRefresh(endpointText: AppPreferences.privateEndpoint)
        }
    }

    func toggleLiveMonitoring() {
        Task {
            if isLiveMonitoring {
                stopLiveMonitoring()
            } else {
                resumeManagedServer()
                await startLiveMonitoring()
            }
        }
    }

    func shutdown() {
        stopLiveMonitoring()
        stopOwnServer()
        displayClockTask?.cancel()
        displayClockTask = nil
        authMonitorTask?.cancel()
        authMonitorTask = nil
    }

    func updateSubscriptionExpiration(email: String, value: String) {
        guard let index = accounts.firstIndex(where: { $0.email.caseInsensitiveCompare(email) == .orderedSame }) else {
            return
        }

        accounts[index].subscriptionExpiresAt = value
        store.save(accounts)
    }

    func deleteAccount(email: String) {
        accounts.removeAll { $0.email.caseInsensitiveCompare(email) == .orderedSame }

        if activeEmail?.caseInsensitiveCompare(email) == .orderedSame {
            activeEmail = nil
        }

        store.save(accounts)
        statusText = accounts.isEmpty ? "Idle" : statusText
    }

    private func startRefreshLoop() {
        refreshTask?.cancel()
        let refreshIntervalSeconds = refreshIntervalSeconds
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(refreshIntervalSeconds * 1_000_000_000))
                await self?.refreshLiveClient()
            }
        }
    }

    private func loadUsageCaches() {
        if let azureCache = usageCacheStore.load(provider: .azure) {
            azureScanResult = azureCache.result
            azureLastScannedAt = azureCache.scannedAt
            shouldRebuildAzureUsageCache = !AppPreferences.azureCodexForkReplayBackfillDone
                && !azureCache.result.records.isEmpty
            rebuildAzureUsageDashboard()
        }

        if let openAICache = usageCacheStore.load(provider: .openai) {
            openAIScanResult = openAICache.result
            openAILastScannedAt = openAICache.scannedAt
            shouldRebuildOpenAIUsageCache = !AppPreferences.openAICodexForkReplayBackfillDone
                && !openAICache.result.records.isEmpty
            rebuildOpenAIUsageDashboard()
        }

        if let claudeCache = usageCacheStore.load(provider: .claudeCode) {
            claudeCodeScanResult = claudeCache.result
            claudeCodeLastScannedAt = claudeCache.scannedAt
            shouldRebuildClaudeCodeUsageCache = Self.needsClaudeCodeFullRebuild(claudeCache.result)
                || !AppPreferences.claudeCodeProjectRootBackfillDone
        }
        desktopChatRecords = desktopChatStore.loadCachedRecords()

        // Load the Claude Azure (gateway) cache BEFORE building either Claude dashboard:
        // both dashboards depend on both scan results (Claude Code excludes gateway
        // sessions; Claude Azure attributes requests to Claude Code projects), so the
        // correlator must see gateway data on the very first render — otherwise nothing
        // is excluded until the next background refresh completes.
        if let claudeAzureCache = usageCacheStore.load(provider: .claudeAzure) {
            claudeAzureScanResult = claudeAzureCache.result
            claudeAzureLastScannedAt = claudeAzureCache.scannedAt
        }
        rebuildClaudeCodeUsageDashboard()
        rebuildClaudeAzureUsageDashboard()

        if let lmStudioCache = usageCacheStore.load(provider: .lmStudio) {
            lmStudioScanResult = lmStudioCache.result
            lmStudioLastScannedAt = lmStudioCache.scannedAt
            rebuildLMStudioUsageDashboard()
        }

        if let apiBillingCache = openAIAPIBillingCacheStore.load() {
            openAIAPIBillingResult = apiBillingCache.result
            openAIAPIBillingLastScannedAt = apiBillingCache.scannedAt
            rebuildOpenAIAPIBillingDashboard()
        }
    }

    private func append(account: AccountRecord, to lines: inout [String]) {
        let isActive = account.email.caseInsensitiveCompare(activeEmail ?? "") == .orderedSame
        lines.append(account.email)
        lines.append("Last seen \(account.lastSeenAt)")
        lines.append("Plan \(account.planType)\(isActive ? " active" : "")")

        let primary = account.primaryDisplayWindow(now: displayNow)
        let secondary = account.secondaryDisplayWindow(now: displayNow)
        appendQuotaWindow(primary, title: "5-hour", to: &lines)
        appendQuotaWindow(secondary, title: "Weekly", to: &lines)

        if !account.subscriptionExpiresAt.isEmpty {
            lines.append("Subscription expiration \(account.subscriptionExpiresAt)")
        }
    }

    private func appendQuotaWindow(_ window: DisplayQuotaWindow, title: String, to lines: inout [String]) {
        lines.append("\(title)")
        lines.append("  Remaining \(formatPercent(window.remainingPercent))")
        lines.append("  Used \(formatPercent(window.usedPercent))")
        lines.append("  Reset \(DateFormats.display(epochSeconds: window.resetsAt))")
        if let windowDurationMins = window.windowDurationMins {
            lines.append("  Duration \(formatInteger(windowDurationMins)) min")
        }
    }

    private func appendUsageDashboard(
        _ dashboard: AzureUsageDashboard,
        title: String,
        windowLabel: String,
        lastScannedAt: Date?,
        sessionCounterLabel: String,
        costLabel: String = "Est. cost",
        costShortLabel: String = "Est.",
        to lines: inout [String]
    ) {
        lines.append(title)
        lines.append("Window \(windowLabel)")
        lines.append("Input \(formatInteger(dashboard.totals.inputTokens))")
        lines.append("Cached \(formatInteger(dashboard.totals.cachedInputTokens))")
        lines.append("Uncached \(formatInteger(dashboard.totals.uncachedInputTokens))")
        lines.append("Output \(formatInteger(dashboard.totals.outputTokens))")
        lines.append("Total \(formatInteger(dashboard.totals.totalTokens))")
        lines.append("\(costLabel) \(formatUSD(dashboard.totals.estimatedCostUSD))")

        lines.append("")
        lines.append("By provider / model deployment")
        for group in dashboard.byEndpointDeployment.prefix(8) {
            lines.append("  \(group.endpoint) | \(group.resource) | \(group.deployment)")
            appendTokenTotals(group.totals, costShortLabel: costShortLabel, to: &lines)
        }

        lines.append("")
        lines.append("By model")
        for group in dashboard.byModel.prefix(8) {
            lines.append("  \(group.model) - \(group.pricing.rateSummary)")
            appendTokenTotals(group.totals, costShortLabel: costShortLabel, to: &lines)
        }

        lines.append("")
        lines.append("By project")
        for project in dashboard.byProject.prefix(12) {
            lines.append("  \(project.projectName)")
            if !project.isChatGroup {
                lines.append("  \(project.projectPath)")
            }
            lines.append("  Sessions \(formatInteger(project.sessionCount)) | Events \(formatInteger(project.totals.eventCount)) | Total \(formatInteger(project.totals.totalTokens)) | \(costShortLabel) \(formatUSD(project.totals.estimatedCostUSD)) | Latest \(DateFormats.display(date: project.latestActivity))")
            if !project.byModel.isEmpty {
                lines.append("  Models")
                for model in project.byModel.prefix(8) {
                    lines.append("    \(model.model) - \(model.pricing.rateSummary)")
                    appendTokenTotals(model.totals, indent: "    ", costShortLabel: costShortLabel, to: &lines)
                }
            }
            if !project.sessions.isEmpty {
                lines.append("  Sessions")
                for session in project.sessions.prefix(12) {
                    lines.append("    \(session.shortSessionID) \(session.modelSummary) | Events \(formatInteger(session.totals.eventCount)) | Total \(formatInteger(session.totals.totalTokens)) | \(costShortLabel) \(formatUSD(session.totals.estimatedCostUSD)) | Latest \(DateFormats.display(date: session.latestActivity)) | \(session.sourceFileName)")
                }
            }
        }

        lines.append("")
        lines.append("Earliest event \(DateFormats.display(date: dashboard.summary.earliestEvent))")
        lines.append("Latest event \(DateFormats.display(date: dashboard.summary.latestEvent))")
        lines.append("Files scanned \(formatInteger(dashboard.summary.filesScanned))")
        lines.append("Sessions scanned \(formatInteger(dashboard.summary.sessionsScanned))")
        lines.append("\(sessionCounterLabel) \(formatInteger(dashboard.summary.azureSessions))")
        lines.append("Events counted \(formatInteger(dashboard.summary.eventsCounted))")
        lines.append("Duplicates skipped \(formatInteger(dashboard.summary.duplicateEventsSkipped))")
        lines.append("Startup replay skipped \(formatInteger(dashboard.summary.startupReplayEventsSkipped))")
        lines.append("Malformed skipped \(formatInteger(dashboard.summary.malformedEventsSkipped))")
        lines.append("Last scanned \(DateFormats.display(date: lastScannedAt))")

        if !dashboard.summary.warnings.isEmpty {
            lines.append("Warnings")
            lines.append(contentsOf: dashboard.summary.warnings.map { "  \($0)" })
        }
    }

    private func appendTokenTotals(_ totals: AzureUsageTokenTotals, indent: String = "    ", costShortLabel: String = "Est.", to lines: inout [String]) {
        lines.append("\(indent)Events \(formatInteger(totals.eventCount)) | Input \(formatInteger(totals.inputTokens)) | Output \(formatInteger(totals.outputTokens)) | Total \(formatInteger(totals.totalTokens)) | \(costShortLabel) \(formatUSD(totals.estimatedCostUSD))")
    }

    private func appendOpenAIAPIBillingDashboard(to lines: inout [String]) {
        lines.append("OpenAI API Billing")
        lines.append("Window \(openAIAPIUsageWindow.label)")
        lines.append("Billed cost \(formatUSD(openAIAPIBilling.totalCostUSD))")
        lines.append("Requests \(formatInteger(openAIAPIBilling.requestCount))")
        lines.append("Input \(formatInteger(openAIAPIBilling.inputTokens))")
        lines.append("Cached \(formatInteger(openAIAPIBilling.cachedInputTokens))")
        lines.append("Output \(formatInteger(openAIAPIBilling.outputTokens))")
        lines.append("Total \(formatInteger(openAIAPIBilling.totalTokens))")

        lines.append("")
        lines.append("API spend by project")
        for group in openAIAPIBilling.byProject.prefix(8) {
            lines.append("  \(group.label) \(formatUSD(group.amountUSD))")
        }

        lines.append("")
        lines.append("API spend by key")
        for group in openAIAPIBilling.byAPIKey.prefix(8) {
            lines.append("  \(group.label) \(formatUSD(group.amountUSD))")
        }

        lines.append("")
        lines.append("API usage by model")
        for group in openAIAPIBilling.byModel.prefix(8) {
            lines.append("  \(group.key) | Requests \(formatInteger(group.requestCount)) | Input \(formatInteger(group.inputTokens)) | Output \(formatInteger(group.outputTokens)) | Total \(formatInteger(group.totalTokens))")
        }

        lines.append("")
        lines.append("Billing buckets \(formatInteger(openAIAPIBilling.summary.bucketsFetched))")
        lines.append("Usage rows \(formatInteger(openAIAPIBilling.summary.usageRows))")
        lines.append("Cost rows \(formatInteger(openAIAPIBilling.summary.costRows))")
        lines.append("Last refreshed \(DateFormats.display(date: openAIAPIBillingLastScannedAt))")
    }

    private func formatPercent(_ value: Int?) -> String {
        guard let value else { return "Unknown" }
        return "\(value)%"
    }

    private func formatInteger(_ value: Int) -> String {
        value.formatted(.number.locale(Locale(identifier: "en_US")))
    }

    private func formatUSD(_ value: Double) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencySymbol = "$"
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 2
        return formatter.string(from: NSNumber(value: value)) ?? "$\(String(format: "%.2f", value))"
    }

    private func rebuildAzureUsageDashboard() {
        azureUsage = AzureUsageScanner.dashboard(
            from: azureScanResult,
            window: azureUsageWindow,
            customStartDate: azureCustomStartDate,
            now: displayNow
        )
    }

    private func rebuildOpenAIUsageDashboard() {
        openAIUsage = AzureUsageScanner.dashboard(
            from: openAIScanResult,
            window: openAIUsageScanMode.usageWindow,
            customStartDate: openAICustomStartDate,
            now: displayNow
        )
    }

    private func rebuildClaudeCodeUsageDashboard() {
        var combined = claudeCodeScanResult
        // A claude-azure (gateway) session is still Claude Code and writes a normal
        // transcript here, so its usage is ALSO logged to the gateway and shown in the
        // Claude Azure dashboard. Drop those sessions so they are not counted twice.
        let correlator = ClaudeAzureTranscriptCorrelator(
            claudeCodeRecords: claudeCodeScanResult.records,
            gatewayRecords: claudeAzureScanResult.records
        )
        if !correlator.azureSessionIDs.isEmpty {
            combined.records = combined.records.filter { !correlator.isAzureSession($0.sessionID) }
        }
        let azureClaudeRecords = azureScanResult.records
            .filter { $0.model.lowercased().contains("claude") }
            .map { record -> AzureUsageRecord in
                var relabeled = record
                relabeled.id = "azure-" + record.id
                relabeled.endpoint = "Azure"
                relabeled.resource = "Codex via Azure"
                return relabeled
            }
        if !azureClaudeRecords.isEmpty {
            combined.records.append(contentsOf: azureClaudeRecords)
        }
        if !desktopChatRecords.isEmpty {
            combined.records.append(contentsOf: desktopChatRecords)
        }
        combined.records.sort { $0.timestamp < $1.timestamp }
        claudeCodeUsage = AzureUsageScanner.dashboard(
            from: combined,
            window: claudeCodeUsageScanMode.usageWindow,
            customStartDate: claudeCodeCustomStartDate,
            now: displayNow
        )
    }

    private func rebuildLMStudioUsageDashboard() {
        lmStudioUsage = AzureUsageScanner.dashboard(
            from: lmStudioScanResult,
            window: lmStudioUsageScanMode.usageWindow,
            customStartDate: lmStudioCustomStartDate,
            now: displayNow
        )
    }

    private func rebuildClaudeAzureUsageDashboard() {
        // The gateway log has no project field, so attribute each request to the Claude
        // Code session/project that made it (fingerprint + time correlation). Requests
        // with no confident match land in an explicit "Unattributed" bucket.
        let correlator = ClaudeAzureTranscriptCorrelator(
            claudeCodeRecords: claudeCodeScanResult.records,
            gatewayRecords: claudeAzureScanResult.records
        )
        var attributed = claudeAzureScanResult
        attributed.records = attributed.records.map { record in
            var record = record
            if let project = correlator.attributedProject(for: record) {
                record.projectPath = project.path
                record.projectName = project.name
            } else {
                record.projectPath = ClaudeAzureTranscriptCorrelator.unattributedProjectPath
                record.projectName = ClaudeAzureTranscriptCorrelator.unattributedProjectName
            }
            return record
        }
        claudeAzureUsage = AzureUsageScanner.dashboard(
            from: attributed,
            window: claudeAzureUsageScanMode.usageWindow,
            customStartDate: claudeAzureCustomStartDate,
            now: displayNow
        )
    }

    private func rebuildOpenAIAPIBillingDashboard() {
        let startDate = openAIAPIUsageWindow.startDate(now: displayNow, customStartDate: openAIAPICustomStartDate)
        var filtered = OpenAIAPIBillingResult()
        filtered.usageRecords = openAIAPIBillingResult.usageRecords.filter { $0.endTime > startDate }
        filtered.costRecords = openAIAPIBillingResult.costRecords.filter { $0.endTime > startDate }
        filtered.summary = openAIAPIBillingResult.summary
        openAIAPIBilling = OpenAIAPIBillingDashboard.make(from: filtered)
    }

    private static func scanResultIncludesFoundry(_ result: AzureUsageScanResult) -> Bool {
        // claudeCodeFoundryRootPaths() returns standardized paths, but record.filePath comes
        // straight from URL.path in the scanner — non-standardized. On macOS those usually
        // match, but symlinks (/private/Users vs /Users, etc.) can diverge. Standardize the
        // record side here so the prefix check never misses a legitimately-foundry record.
        let foundryRoots = AzureUsageScanner.claudeCodeFoundryRootPaths()
        return result.records.contains { record in
            let standardizedPath = URL(fileURLWithPath: record.filePath).standardizedFileURL.path
            return foundryRoots.contains { standardizedPath.hasPrefix($0) }
        }
    }

    private static func needsClaudeCodeFullRebuild(_ result: AzureUsageScanResult) -> Bool {
        guard result.provider == .claudeCode, !result.records.isEmpty else { return false }
        return result.records.contains { record in
            guard record.id.hasPrefix("claude-code-") else { return true }
            let stableID = String(record.id.dropFirst("claude-code-".count))
            return record.id.hasPrefix("claude-code-request-")
                || record.id.hasPrefix("claude-code-message-")
                || !stableID.hasPrefix("msg_")
        }
    }

    private static func mergedUsageResult(_ existing: AzureUsageScanResult, with incremental: AzureUsageScanResult) -> AzureUsageScanResult {
        guard !existing.records.isEmpty else { return incremental }

        var recordsByID = Dictionary(uniqueKeysWithValues: existing.records.map { ($0.id, $0) })
        for record in incremental.records {
            if let priorRecord = recordsByID[record.id], existing.provider == .azure {
                // Azure endpoint/resource are inferred from current local config and can drift
                // when the user changes their codex-azure wrapper or config.toml. Once an Azure
                // record's labels are captured, keep them sticky so historical sessions don't
                // get relabeled to whatever endpoint is currently configured.
                var preserved = record
                preserved.endpoint = priorRecord.endpoint
                preserved.resource = priorRecord.resource
                preserved.deployment = priorRecord.deployment
                recordsByID[record.id] = preserved
            } else {
                recordsByID[record.id] = record
            }
        }

        var result = AzureUsageScanResult(provider: existing.provider)
        result.records = recordsByID.values.sorted { lhs, rhs in
            if lhs.timestamp != rhs.timestamp { return lhs.timestamp < rhs.timestamp }
            return lhs.id.localizedCaseInsensitiveCompare(rhs.id) == .orderedAscending
        }

        result.summary = mergedUsageSummary(existing.summary, incremental.summary, records: result.records)
        return result
    }

    private static func incrementalUsageRefreshStartDate(from result: AzureUsageScanResult) -> Date? {
        guard let latestKnownEvent = result.summary.latestEvent ?? result.records.map(\.timestamp).max() else {
            return nil
        }

        return latestKnownEvent
    }

    private static func openAIUsageRefreshStartDate(
        previousResult: AzureUsageScanResult,
        scanMode: CodexUsageScanMode,
        now: Date,
        customStartDate: Date
    ) -> Date? {
        windowAwareRefreshStartDate(
            previousResult: previousResult,
            windowStartDate: scanMode.startDate(now: now, customStartDate: customStartDate)
        )
    }

    private static func windowAwareRefreshStartDate(
        previousResult: AzureUsageScanResult,
        windowStartDate: Date?
    ) -> Date? {
        guard let incrementalStartDate = incrementalUsageRefreshStartDate(from: previousResult) else {
            return windowStartDate
        }

        guard let windowStartDate else {
            return incrementalStartDate
        }

        guard let earliestKnownEvent = previousResult.summary.earliestEvent ?? previousResult.records.map(\.timestamp).min() else {
            return windowStartDate
        }

        if windowStartDate < earliestKnownEvent {
            return windowStartDate
        }

        return incrementalStartDate
    }

    private static func mergedUsageSummary(
        _ existing: AzureUsageScanSummary,
        _ incremental: AzureUsageScanSummary,
        records: [AzureUsageRecord]
    ) -> AzureUsageScanSummary {
        var summary = AzureUsageScanSummary()
        summary.filesScanned = Set(records.map(\.filePath)).count
        summary.sessionsScanned = Set(records.map(\.sessionID)).count
        summary.providerSessions = summary.sessionsScanned
        summary.eventsCounted = records.count
        summary.duplicateEventsSkipped = existing.duplicateEventsSkipped + incremental.duplicateEventsSkipped
        summary.startupReplayEventsSkipped = existing.startupReplayEventsSkipped + incremental.startupReplayEventsSkipped
        summary.malformedEventsSkipped = existing.malformedEventsSkipped + incremental.malformedEventsSkipped
        summary.earliestEvent = records.map(\.timestamp).min()
        summary.latestEvent = records.map(\.timestamp).max()
        summary.warnings = Array(Set(existing.warnings + incremental.warnings)).sorted()
        return summary
    }

    private func startDisplayClock() {
        displayClockTask?.cancel()
        displayClockTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 60_000_000_000)
                await MainActor.run {
                    guard let self else { return }
                    let now = Date()
                    self.displayNow = now
                    self.persistExpiredLocalResets(now: now)
                }
            }
        }
    }

    private func startAuthFileMonitor() {
        authMonitorTask?.cancel()
        lastAuthFileSignature = authFileSignature()
        authMonitorTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                await MainActor.run {
                    self?.checkForAuthFileChange()
                }
            }
        }
    }

    private func startLiveMonitoring() async {
        guard !isStartingLiveMonitoring else { return }
        isStartingLiveMonitoring = true
        defer { isStartingLiveMonitoring = false }

        shouldLiveMonitor = true
        reconnectTask?.cancel()
        reconnectTask = nil
        await startServerIfAutoManaged()

        do {
            client = try await connectClient(enableNotifications: true)
            markManagedServerHealthy()
            isLiveMonitoring = true
            statusText = "Live"
            await refreshLiveClient()
            startRefreshLoop()
        } catch {
            if shouldAutoManageServer, await recoverLiveMonitorAfterConnectFailure(error) {
                return
            }

            client = nil
            isLiveMonitoring = false
            statusText = "Unavailable"
            lastError = "Could not connect to \(endpointText): \(error.localizedDescription)"
            scheduleLiveReconnect()
        }
    }

    private func stopLiveMonitoring() {
        shouldLiveMonitor = false
        reconnectTask?.cancel()
        reconnectTask = nil
        refreshTask?.cancel()
        refreshTask = nil
        client?.disconnect()
        client = nil
        isLiveMonitoring = false
        statusText = accounts.isEmpty ? "Idle" : "Saved"
    }

    private func refreshOnce(startOwnServer: Bool) async {
        guard beginRefresh() else { return }
        defer { endRefresh() }

        if startOwnServer {
            await startConfiguredServer()
        }

        do {
            let temporaryClient = try await connectClient(enableNotifications: false)
            defer { temporaryClient.disconnect() }
            try await fetchAndPersist(using: temporaryClient)
            statusText = "Saved"
            lastError = nil
        } catch {
            if isTokenInvalidatedError(error), await recoverFromInvalidatedTokenAndRetry() {
                return
            }

            statusText = "Unavailable"
            lastError = refreshErrorMessage(prefix: "Could not refresh from \(endpointText)", error: error)
        }
    }

    private func startServerAndRefresh(endpointText: String) async {
        self.endpointText = endpointText
        await refreshOnce(startOwnServer: true)
    }

    private func startConfiguredServer() async {
        guard let endpointURL else {
            statusText = "Invalid endpoint"
            lastError = "The Codex app-server URL is invalid."
            return
        }
        server.startIfNeeded(endpoint: endpointURL)
        runningServerEndpoint = server.endpoint?.absoluteString
    }

    private var shouldAutoManageServer: Bool {
        endpointText.trimmingCharacters(in: .whitespacesAndNewlines) == AppPreferences.privateEndpoint
    }

    private func startServerIfAutoManaged() async {
        guard shouldAutoManageServer else { return }
        guard !managedServerGaveUp else { return }
        guard !server.isRunning else {
            runningServerEndpoint = server.endpoint?.absoluteString
            return
        }

        await restartManagedServer()
        try? await Task.sleep(nanoseconds: 350_000_000)
    }

    private func connectClient(enableNotifications: Bool) async throws -> CodexRPCClient {
        statusText = "Connecting to Codex app-server..."
        lastError = nil
        guard let endpointURL else {
            throw RPCError.serverError("The Codex app-server URL is invalid.")
        }

        for attempt in 1...8 {
            let client = makeClient(endpoint: endpointURL, enableNotifications: enableNotifications)

            do {
                try await client.connect()
                return client
            } catch {
                client.disconnect()
                if attempt < 8 {
                    try? await Task.sleep(nanoseconds: 500_000_000)
                } else {
                    throw error
                }
            }
        }

        throw RPCError.disconnected
    }

    private func makeClient(endpoint: URL, enableNotifications: Bool) -> CodexRPCClient {
        let client = CodexRPCClient(endpoint: endpoint)

        if enableNotifications {
            client.onNotification = { [weak self] notification in
                Task { @MainActor in
                    await self?.handle(notification: notification)
                }
            }
            client.onDisconnect = { [weak self] error in
                Task { @MainActor in
                    self?.handleLiveDisconnect(error)
                }
            }
        }

        return client
    }

    private func handleLiveDisconnect(_ error: Error) {
        client = nil
        isLiveMonitoring = false
        statusText = "Disconnected"
        lastError = error.localizedDescription
        scheduleLiveReconnect()
    }

    /// Stop auto-restarting a server that keeps crashing on launch. The loop is
    /// paused (no reconnect, no refresh timer) with an actionable message until a
    /// user action calls `resumeManagedServer()`.
    private func enterManagedServerGaveUpState() {
        managedServerGaveUp = true
        reconnectTask?.cancel()
        reconnectTask = nil
        refreshTask?.cancel()
        refreshTask = nil
        client?.disconnect()
        client = nil
        isLiveMonitoring = false
        statusText = "Codex server unavailable"
        lastError = "The Codex app-server kept exiting right after launch, so the tracker paused auto-restart. Your `codex` CLI may be broken — run `codex --version` in a terminal; if it errors, reinstall Codex. Then press Refresh."
    }

    /// The managed server came up and we connected — clear crash-loop state.
    private func markManagedServerHealthy() {
        guard shouldAutoManageServer else { return }
        restartPolicy.serverBecameHealthy()
        managedServerGaveUp = false
    }

    /// Re-enable auto-restart after a give-up (called from user actions).
    private func resumeManagedServer() {
        restartPolicy.reset()
        managedServerGaveUp = false
    }

    private func scheduleLiveReconnect(after delay: TimeInterval = 2) {
        guard shouldLiveMonitor else { return }
        guard !managedServerGaveUp else { return }
        guard reconnectTask == nil else { return }

        reconnectTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            await MainActor.run {
                self?.reconnectTask = nil
            }
            await self?.startLiveMonitoring()
        }
    }

    private func refreshLiveClient() async {
        guard let client else {
            if shouldLiveMonitor {
                scheduleLiveReconnect(after: 1)
            }
            return
        }
        guard beginRefresh() else { return }
        defer { endRefresh() }

        do {
            try await fetchAndPersist(using: client)
            statusText = "Live"
            lastError = nil
            store.save(accounts)
        } catch {
            if isTokenInvalidatedError(error), await recoverLiveClientFromInvalidatedTokenAndRetry() {
                return
            }

            statusText = "Refresh failed"
            lastError = refreshErrorMessage(prefix: "Could not refresh from \(endpointText)", error: error)
        }
    }

    private func beginRefresh() -> Bool {
        if isRefreshing {
            pendingRefresh = true
            return false
        }

        isRefreshing = true
        return true
    }

    private func endRefresh() {
        isRefreshing = false

        guard pendingRefresh else { return }
        pendingRefresh = false

        Task { [weak self] in
            await self?.refreshLiveClient()
        }
    }

    func stopOwnServer() {
        server.stop()
        runningServerEndpoint = nil
    }

    var isPrivateServerRunning: Bool {
        runningServerEndpoint == AppPreferences.privateEndpoint
    }

    private func fetchAndPersist(using client: CodexRPCClient) async throws {
        let account = try await client.readAccount(refreshToken: false)
        guard let account else {
            activeEmail = nil
            statusText = "No ChatGPT account active"
            return
        }

        activeEmail = account.email
        upsert(email: account.email) { record in
            record.apply(planType: account.planType)
        }

        if let snapshot = try await client.readRateLimits() {
            upsert(email: account.email) { record in
                record.apply(snapshot: snapshot)
            }
        }

        store.save(accounts)
    }

    private func handle(notification: RPCNotification) async {
        switch notification {
        case .accountUpdated:
            await recoverLiveClientAfterAuthChange(reason: "Codex account changed. Restarting this tracker's app-server and fetching the active account.")
        case .rateLimitsUpdated(let snapshot):
            guard let snapshot, snapshot.hasQuotaData else {
                await refreshLiveClient()
                return
            }

            await applyRateLimitSnapshotToConfirmedAccount(snapshot)
        }
    }

    private func applyRateLimitSnapshotToConfirmedAccount(_ snapshot: RateLimitSnapshot) async {
        guard let client else { return }

        do {
            guard let account = try await client.readAccount(refreshToken: false) else {
                activeEmail = nil
                statusText = "No ChatGPT account active"
                return
            }

            activeEmail = account.email
            upsert(email: account.email) { record in
                record.apply(planType: account.planType)
                record.apply(snapshot: snapshot)
            }
            store.save(accounts)
            statusText = "Live"
            lastError = nil
        } catch {
            await refreshLiveClient()
        }
    }

    private func upsert(email: String, mutate: (inout AccountRecord) -> Void) {
        if let index = accounts.firstIndex(where: { $0.email.caseInsensitiveCompare(email) == .orderedSame }) {
            mutate(&accounts[index])
        } else {
            var record = AccountRecord.blank(email: email)
            mutate(&record)
            accounts.append(record)
        }

        accounts.sort { $0.email.localizedCaseInsensitiveCompare($1.email) == .orderedAscending }
    }

    private func persistExpiredLocalResets(now: Date) {
        var changed = false

        for index in accounts.indices {
            if accounts[index].applyExpiredLocalResets(now: now) {
                changed = true
            }
        }

        if changed {
            store.save(accounts)
        }
    }

    private func recoverFromInvalidatedTokenAndRetry() async -> Bool {
        guard let endpointURL else { return false }

        statusText = "Restarting Codex server..."
        lastError = "Codex reported an invalidated login token. Restarting this tracker's local app-server and retrying once."
        await restartManagedServer(endpoint: endpointURL)

        do {
            let retryClient = try await connectClient(enableNotifications: false)
            defer { retryClient.disconnect() }
            try await fetchAndPersist(using: retryClient)
            statusText = "Saved"
            lastError = nil
            return true
        } catch {
            statusText = "Codex login required"
            lastError = refreshErrorMessage(prefix: "Codex still rejected the local app-server token after restart", error: error)
            return true
        }
    }

    private func recoverLiveClientFromInvalidatedTokenAndRetry() async -> Bool {
        guard let endpointURL else { return false }

        client?.disconnect()
        client = nil
        statusText = "Restarting Codex server..."
        lastError = "Codex reported an invalidated login token. Restarting this tracker's local app-server and retrying once."
        await restartManagedServer(endpoint: endpointURL)

        do {
            let liveClient = try await connectClient(enableNotifications: true)
            client = liveClient
            isLiveMonitoring = true
            try await fetchAndPersist(using: liveClient)
            statusText = "Live"
            lastError = nil
            return true
        } catch {
            client = nil
            isLiveMonitoring = false
            statusText = "Codex login required"
            lastError = refreshErrorMessage(prefix: "Codex still rejected the local app-server token after restart", error: error)
            scheduleLiveReconnect(after: 5)
            return true
        }
    }

    private func recoverLiveMonitorAfterConnectFailure(_ originalError: Error) async -> Bool {
        guard let endpointURL else { return false }

        // The managed server already crash-looped past the limit — don't spawn a
        // competing server; the give-up state already surfaced the fix.
        guard !managedServerGaveUp else { return true }

        // If the server already died, its termination handler owns the restart
        // decision (backoff or give-up). Don't start a second doomed server here.
        if !server.isRunning, reconnectTask != nil {
            return true
        }

        statusText = "Restarting Codex server..."
        lastError = "Could not reconnect to the tracker app-server. Restarting it automatically."
        await restartManagedServer(endpoint: endpointURL)

        do {
            let liveClient = try await connectClient(enableNotifications: true)
            markManagedServerHealthy()
            client = liveClient
            isLiveMonitoring = true
            try await fetchAndPersist(using: liveClient)
            statusText = "Live"
            lastError = nil
            startRefreshLoop()
            return true
        } catch {
            if isTokenInvalidatedError(error), await recoverLiveClientFromInvalidatedTokenAndRetry() {
                return true
            }

            client = nil
            isLiveMonitoring = false
            statusText = "Unavailable"
            lastError = "Could not reconnect after restarting the tracker app-server: \(error.localizedDescription). Original error: \(originalError.localizedDescription)"
            scheduleLiveReconnect(after: 5)
            return true
        }
    }

    private func refreshErrorMessage(prefix: String, error: Error) -> String {
        if isTokenInvalidatedError(error) {
            return "\(prefix): Codex says the local login token is invalidated. Open Codex and sign in again, then refresh."
        }

        return "\(prefix): \(error.localizedDescription)"
    }

    private func isTokenInvalidatedError(_ error: Error) -> Bool {
        let message = error.localizedDescription.lowercased()
        return message.contains("token_invalidated")
            || message.contains("token has been invalidated")
            || (message.contains("401") && message.contains("unauthorized"))
    }

    private static func isRoutineServerOutput(_ output: String) -> Bool {
        let lines = output
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }

        guard !lines.isEmpty else { return true }
        return lines.allSatisfy { line in
            line.contains("codex app-server")
                || line.contains("listening on:")
                || line.contains("readyz:")
                || line.contains("healthz:")
                || line.contains("binds localhost only")
        }
    }

    private func restartManagedServer(endpoint: URL? = nil) async {
        guard let endpoint = endpoint ?? endpointURL else { return }

        isManagingServerLifecycle = true
        await server.restart(endpoint: endpoint)
        runningServerEndpoint = server.endpoint?.absoluteString
        isManagingServerLifecycle = false
    }

    private func checkForAuthFileChange() {
        guard let signature = authFileSignature() else { return }

        guard let lastSignature = lastAuthFileSignature else {
            lastAuthFileSignature = signature
            return
        }

        guard signature != lastSignature else { return }
        lastAuthFileSignature = signature

        guard shouldLiveMonitor, shouldAutoManageServer else { return }
        guard shouldRecoverForAuthChange() else { return }

        Task { [weak self] in
            await self?.recoverLiveClientAfterAuthChange(reason: "Codex auth changed. Restarting this tracker's app-server and fetching the active account.")
        }
    }

    private func shouldRecoverForAuthChange() -> Bool {
        let now = Date()
        if let lastAuthChangeRecoveryAt, now.timeIntervalSince(lastAuthChangeRecoveryAt) < 3 {
            return false
        }

        lastAuthChangeRecoveryAt = now
        return true
    }

    private func recoverLiveClientAfterAuthChange(reason: String) async {
        guard shouldAutoManageServer else {
            await refreshLiveClient()
            return
        }
        guard !isRecoveringAuthChange else { return }

        isRecoveringAuthChange = true
        defer { isRecoveringAuthChange = false }

        client?.disconnect()
        client = nil
        isRefreshing = false
        pendingRefresh = false
        statusText = "Switching account..."
        lastError = reason

        try? await Task.sleep(nanoseconds: 750_000_000)
        await restartManagedServer()

        do {
            let liveClient = try await connectClient(enableNotifications: true)
            client = liveClient
            isLiveMonitoring = true
            try await fetchAndPersist(using: liveClient)
            statusText = "Live"
            lastError = nil
            startRefreshLoop()
        } catch {
            client = nil
            isLiveMonitoring = false
            statusText = "Unavailable"
            lastError = refreshErrorMessage(prefix: "Could not refresh after Codex account switch", error: error)
            scheduleLiveReconnect(after: 5)
        }
    }

    private func authFileSignature() -> AuthFileSignature? {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex")
            .appendingPathComponent("auth.json")

        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else {
            return nil
        }

        return AuthFileSignature(
            modifiedAt: (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0,
            size: (attributes[.size] as? NSNumber)?.uint64Value ?? 0
        )
    }
}

private struct AuthFileSignature: Equatable {
    let modifiedAt: TimeInterval
    let size: UInt64
}
