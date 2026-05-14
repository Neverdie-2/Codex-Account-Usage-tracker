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
    @Published private(set) var isAzureRefreshing = false
    @Published private(set) var isOpenAIRefreshing = false
    @Published private(set) var azureLastScannedAt: Date?
    @Published private(set) var openAILastScannedAt: Date?
    @Published var openAIUsageScanMode: CodexUsageScanMode = .recent24Hours {
        didSet {
            rebuildOpenAIUsageDashboard()
        }
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
            }
        }
    }

    let refreshIntervalSeconds: TimeInterval = 30

    private let store = AccountStore()
    private let usageCacheStore = AzureUsageCacheStore()
    private let azureScanner = AzureUsageScanner()
    private let openAIUsageScanner = AzureUsageScanner(provider: .openai, logRoots: AzureUsageScanner.defaultLogRoots())
    private let server = CodexServerManager()
    private var client: CodexRPCClient?
    private var azureScanResult = AzureUsageScanResult.empty
    private var openAIScanResult = AzureUsageScanResult(provider: .openai)
    private var refreshTask: Task<Void, Never>?
    private var displayClockTask: Task<Void, Never>?
    private var authMonitorTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var shouldLiveMonitor = false
    private var pendingRefresh = false
    private var isManagingServerLifecycle = false
    private var isStartingLiveMonitoring = false
    private var isRecoveringAuthChange = false
    private var lastAuthFileSignature: AuthFileSignature?
    private var lastAuthChangeRecoveryAt: Date?

    init() {
        endpointText = AppPreferences.endpoint
    }

    var storagePath: String {
        store.path
    }

    var endpointURL: URL? {
        URL(string: endpointText.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    func start() async {
        accounts = store.load()
        persistExpiredLocalResets(now: displayNow)
        startDisplayClock()
        startAuthFileMonitor()
        server.onOutput = { [weak self] output in
            guard !output.isEmpty else { return }
            self?.lastError = output
        }
        server.onTermination = { [weak self] endpoint in
            guard self?.runningServerEndpoint == endpoint?.absoluteString else { return }
            self?.runningServerEndpoint = nil
            guard self?.isManagingServerLifecycle != true else { return }
            if self?.shouldLiveMonitor == true, self?.shouldAutoManageServer == true {
                self?.statusText = "Codex server stopped"
                self?.lastError = "The tracker app-server stopped. Restarting it automatically."
                self?.scheduleLiveReconnect(after: 1)
            }
        }
        statusText = accounts.isEmpty ? "Idle" : "Saved"
        loadUsageCaches()
        await startLiveMonitoring()
    }

    func refreshNow() {
        Task {
            await refreshOnce(startOwnServer: false)
        }
    }

    func refreshAzureUsage() {
        guard !isAzureRefreshing else { return }
        isAzureRefreshing = true

        Task { [weak self, azureScanner, usageCacheStore] in
            let result = await Task.detached(priority: .utility) {
                azureScanner.scan()
            }.value

            guard let self else { return }
            defer { isAzureRefreshing = false }
            let scannedAt = Date()
            azureScanResult = result
            azureLastScannedAt = scannedAt
            usageCacheStore.save(result, scannedAt: scannedAt)
            rebuildAzureUsageDashboard()
        }
    }

    func refreshOpenAIUsage() {
        guard !isOpenAIRefreshing else { return }
        isOpenAIRefreshing = true

        Task { [weak self, openAIUsageScanner, usageCacheStore] in
            let result = await Task.detached(priority: .utility) {
                openAIUsageScanner.scan()
            }.value

            guard let self else { return }
            defer { isOpenAIRefreshing = false }
            let scannedAt = Date()
            openAIScanResult = result
            openAILastScannedAt = scannedAt
            usageCacheStore.save(result, scannedAt: scannedAt)
            rebuildOpenAIUsageDashboard()
        }
    }

    func startOwnServerAndRefresh() {
        Task {
            await startServerAndRefresh(endpointText: AppPreferences.privateEndpoint)
        }
    }

    func startSharedServerAndRefresh() {
        Task {
            await startServerAndRefresh(endpointText: AppPreferences.defaultEndpoint)
        }
    }

    func toggleLiveMonitoring() {
        Task {
            if isLiveMonitoring {
                stopLiveMonitoring()
            } else {
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
            rebuildAzureUsageDashboard()
        }

        if let openAICache = usageCacheStore.load(provider: .openai) {
            openAIScanResult = openAICache.result
            openAILastScannedAt = openAICache.scannedAt
            rebuildOpenAIUsageDashboard()
        }
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
            customStartDate: Date(timeIntervalSince1970: 0),
            now: displayNow
        )
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

    private func scheduleLiveReconnect(after delay: TimeInterval = 2) {
        guard shouldLiveMonitor else { return }
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

    var isSharedServerRunning: Bool {
        runningServerEndpoint == AppPreferences.defaultEndpoint
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

        statusText = "Restarting Codex server..."
        lastError = "Could not reconnect to the tracker app-server. Restarting it automatically."
        await restartManagedServer(endpoint: endpointURL)

        do {
            let liveClient = try await connectClient(enableNotifications: true)
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
