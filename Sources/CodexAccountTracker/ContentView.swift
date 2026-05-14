import AppKit
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var viewModel: AccountTrackerViewModel

    var body: some View {
        VStack(spacing: 0) {
            HeaderView()

            if viewModel.accounts.isEmpty {
                ScrollView {
                    VStack(spacing: 14) {
                        EmptyStateView()
                            .frame(minHeight: 300)
                        AzureUsageSectionView()
                        OpenAIUsageSectionView()
                    }
                    .padding(20)
                }
                .background(Color(nsColor: .windowBackgroundColor))
            } else {
                ScrollView {
                    LazyVStack(spacing: 14) {
                        ForEach(viewModel.accounts) { account in
                            AccountCardView(
                                account: account,
                                displayNow: viewModel.displayNow,
                                isActive: account.email.caseInsensitiveCompare(viewModel.activeEmail ?? "") == .orderedSame,
                                onExpirationChange: { value in
                                    viewModel.updateSubscriptionExpiration(email: account.email, value: value)
                                },
                                onDelete: {
                                    viewModel.deleteAccount(email: account.email)
                                }
                            )
                        }

                        AzureUsageSectionView()
                        OpenAIUsageSectionView()
                    }
                    .padding(20)
                }
                .background(Color(nsColor: .windowBackgroundColor))
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
            viewModel.shutdown()
        }
    }
}

private struct HeaderView: View {
    @EnvironmentObject private var viewModel: AccountTrackerViewModel

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Codex Account Tracker")
                    .font(.title2.weight(.semibold))
                Text(viewModel.endpointText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            Spacer()

            StatusPill(text: viewModel.statusText)

            Button {
                viewModel.toggleLiveMonitoring()
            } label: {
                Label(
                    viewModel.isLiveMonitoring ? "Stop Live" : "Live Monitor",
                    systemImage: viewModel.isLiveMonitoring ? "pause.circle" : "dot.radiowaves.left.and.right"
                )
            }

            if viewModel.isSharedServerRunning {
                Button {
                    viewModel.stopOwnServer()
                } label: {
                    Label("Stop Shared Server", systemImage: "stop.circle")
                }
            } else {
                Button {
                    viewModel.startSharedServerAndRefresh()
                } label: {
                    Label("Start Shared Server", systemImage: "play.circle")
                }
            }

            if viewModel.isPrivateServerRunning {
                Button {
                    viewModel.stopOwnServer()
                } label: {
                    Label("Stop Own Server", systemImage: "stop.circle")
                }
            } else {
                Button {
                    viewModel.startOwnServerAndRefresh()
                } label: {
                    Label("Start Own Server", systemImage: "play.circle")
                }
            }

            Button {
                viewModel.refreshNow()
            } label: {
                Label(viewModel.isRefreshing ? "Refreshing" : "Refresh", systemImage: "arrow.clockwise")
            }
            .disabled(viewModel.isRefreshing)
        }
        .padding(20)
        .background(.bar)
        .overlay(alignment: .bottom) {
            Divider()
        }

        if let lastError = viewModel.lastError {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(.yellow)
                Text(lastError)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            .background(Color(nsColor: .controlBackgroundColor))
            .overlay(alignment: .bottom) {
                Divider()
            }
        }
    }
}

private struct EmptyStateView: View {
    @EnvironmentObject private var viewModel: AccountTrackerViewModel

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "person.crop.circle.badge.clock")
                .font(.system(size: 46))
                .foregroundStyle(.secondary)
            Text("No accounts saved yet")
                .font(.title3.weight(.medium))
            Text("Open Codex with a ChatGPT account active, then refresh. The tracker connects to the configured Codex app-server and saves the account.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 460)
            Button {
                viewModel.refreshNow()
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }
}

private struct AccountCardView: View {
    let account: AccountRecord
    let displayNow: Date
    let isActive: Bool
    let onExpirationChange: (String) -> Void
    let onDelete: () -> Void

    @State private var isConfirmingDelete = false

    init(
        account: AccountRecord,
        displayNow: Date,
        isActive: Bool,
        onExpirationChange: @escaping (String) -> Void,
        onDelete: @escaping () -> Void
    ) {
        self.account = account
        self.displayNow = displayNow
        self.isActive = isActive
        self.onExpirationChange = onExpirationChange
        self.onDelete = onDelete
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(account.email)
                        .font(.headline)
                        .textSelection(.enabled)
                    Text("Last seen \(account.lastSeenAt)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }

                Spacer()

                PlanPill(text: account.planType)
                if isActive {
                    StatusPill(text: "Active")
                }
                Button(role: .destructive) {
                    isConfirmingDelete = true
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.red)
                .help("Delete saved account")
            }

            HStack(spacing: 12) {
                let primaryWindow = account.primaryDisplayWindow(now: displayNow)
                let secondaryWindow = account.secondaryDisplayWindow(now: displayNow)

                QuotaPanel(
                    title: "5-hour",
                    remainingPercent: primaryWindow.remainingPercent,
                    usedPercent: primaryWindow.usedPercent,
                    resetText: DateFormats.display(epochSeconds: primaryWindow.resetsAt),
                    durationMins: primaryWindow.windowDurationMins
                )

                QuotaPanel(
                    title: "Weekly",
                    remainingPercent: secondaryWindow.remainingPercent,
                    usedPercent: secondaryWindow.usedPercent,
                    resetText: DateFormats.display(epochSeconds: secondaryWindow.resetsAt),
                    durationMins: secondaryWindow.windowDurationMins
                )

                SubscriptionExpirationEditor(
                    value: account.subscriptionExpiresAt,
                    onChange: onExpirationChange
                )
                .frame(width: 230, alignment: .topLeading)
            }
        }
        .padding(16)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(isActive ? Color.accentColor.opacity(0.55) : Color(nsColor: .separatorColor), lineWidth: isActive ? 1.5 : 1)
        }
        .confirmationDialog(
            "Delete saved account?",
            isPresented: $isConfirmingDelete,
            titleVisibility: .visible
        ) {
            Button("Delete \(account.email)", role: .destructive) {
                onDelete()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            if isActive {
                Text("This removes the saved tracker record for this account. Because it is currently active, it may be saved again on the next refresh.")
            } else {
                Text("This removes the saved tracker record for this account. It does not affect your Codex login.")
            }
        }
    }
}

private struct SubscriptionExpirationEditor: View {
    let value: String
    let onChange: (String) -> Void

    @State private var hasDate: Bool
    @State private var selectedDate: Date
    @State private var isEditing = false

    init(value: String, onChange: @escaping (String) -> Void) {
        self.value = value
        self.onChange = onChange
        let parsedDate = Self.parse(value)
        _hasDate = State(initialValue: parsedDate != nil)
        _selectedDate = State(initialValue: parsedDate ?? Date())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Subscription expiration")
                .font(.system(size: 16, weight: .semibold))

            if hasDate {
                if isEditing {
                    HStack(spacing: 8) {
                        DatePicker(
                            "Subscription expiration",
                            selection: $selectedDate,
                            displayedComponents: .date
                        )
                        .labelsHidden()
                        .datePickerStyle(.compact)
                        .controlSize(.regular)
                        .font(.system(size: 15))
                        .onChange(of: selectedDate) { _, newValue in
                            save(newValue)
                        }

                        Button {
                            isEditing = false
                        } label: {
                            Label("Done", systemImage: "checkmark.circle")
                        }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                        .help("Done editing subscription date")
                    }
                    .background(
                        ClickOutsideMonitor {
                            isEditing = false
                        }
                    )
                } else {
                    HStack(spacing: 8) {
                        Button {
                            isEditing = true
                        } label: {
                            Text(Self.format(selectedDate))
                                .font(.system(size: 16))
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        .buttonStyle(.plain)
                        .help("Edit subscription expiration date")

                        Button {
                            hasDate = false
                            isEditing = false
                            onChange("")
                        } label: {
                            Label("Clear", systemImage: "xmark.circle")
                        }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                        .help("Clear subscription date")
                    }
                }
            } else {
                Button {
                    selectedDate = Date()
                    hasDate = true
                    isEditing = true
                    save(selectedDate)
                } label: {
                    Label("Set date", systemImage: "calendar.badge.plus")
                }
                .controlSize(.small)
            }
        }
        .onChange(of: value) { _, newValue in
            guard newValue != Self.format(selectedDate) else { return }
            if let parsedDate = Self.parse(newValue) {
                selectedDate = parsedDate
                hasDate = true
            } else if newValue.isEmpty {
                hasDate = false
                isEditing = false
            }
        }
    }

    private func save(_ date: Date) {
        let formattedDate = Self.format(date)
        if formattedDate != value {
            onChange(formattedDate)
        }
    }

    private static func parse(_ value: String) -> Date? {
        formatter.date(from: value.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private static func format(_ date: Date) -> String {
        formatter.string(from: date)
    }

    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}

private struct ClickOutsideMonitor: NSViewRepresentable {
    let onOutsideClick: () -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        context.coordinator.view = view
        context.coordinator.installMonitor()
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.view = nsView
        context.coordinator.onOutsideClick = onOutsideClick
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.removeMonitor()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onOutsideClick: onOutsideClick)
    }

    final class Coordinator {
        weak var view: NSView?
        var onOutsideClick: () -> Void

        private var monitor: Any?

        init(onOutsideClick: @escaping () -> Void) {
            self.onOutsideClick = onOutsideClick
        }

        func installMonitor() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
                guard let self, let view, let window = view.window, event.window === window else {
                    return event
                }

                let frameInWindow = view.convert(view.bounds, to: nil)
                if !frameInWindow.contains(event.locationInWindow) {
                    DispatchQueue.main.async {
                        self.onOutsideClick()
                    }
                }

                return event
            }
        }

        func removeMonitor() {
            if let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
        }

        deinit {
            removeMonitor()
        }
    }
}

private struct QuotaPanel: View {
    let title: String
    let remainingPercent: Int?
    let usedPercent: Int?
    let resetText: String
    let durationMins: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text(durationLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(percentText(remainingPercent))
                    .font(.system(size: 30, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(quotaColor)
                Text("remaining")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            ProgressView(value: Double(usedPercent ?? 0), total: 100)
                .tint(quotaColor)

            LabeledContent("Used", value: percentText(usedPercent))
            LabeledContent("Reset", value: resetText)
        }
        .font(.callout)
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 150, alignment: .topLeading)
        .background(Color(nsColor: .textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var quotaColor: Color {
        guard let remainingPercent else { return .secondary }
        if remainingPercent <= 10 { return .red }
        if remainingPercent <= 25 { return .orange }
        return .green
    }

    private var durationLabel: String {
        guard let durationMins else { return "Window unknown" }
        if durationMins == 300 { return "300 min" }
        if durationMins == 10_080 { return "10080 min" }
        return "\(durationMins) min"
    }

    private func percentText(_ value: Int?) -> String {
        guard let value else { return "--%" }
        return "\(value)%"
    }
}

private struct AzureUsageSectionView: View {
    @EnvironmentObject private var viewModel: AccountTrackerViewModel

    var body: some View {
        CodexLogUsageSectionView(
            title: "Azure Usage",
            subtitle: "Local Codex JSONL token usage for Azure sessions",
            dashboard: viewModel.azureUsage,
            isRefreshing: viewModel.isAzureRefreshing,
            lastScannedAt: viewModel.azureLastScannedAt,
            window: $viewModel.azureUsageWindow,
            customStartDate: $viewModel.azureCustomStartDate,
            sessionCounterLabel: CodexLogUsageProvider.azure.sessionCounterLabel,
            endpointTableTitle: "By endpoint / resource / deployment",
            endpointLabel: { group in
                let endpoint = group.endpoint
                let resource = group.resource == AzureUsageScanner.unknownResource ? "resource unknown" : group.resource
                return "\(endpoint) • \(resource) • \(group.deployment)"
            },
            refresh: viewModel.refreshAzureUsage
        )
    }
}

private struct OpenAIUsageSectionView: View {
    @EnvironmentObject private var viewModel: AccountTrackerViewModel
    @State private var isConfirmingAllTimeScan = false

    var body: some View {
        CodexLogUsageSectionView(
            title: "OpenAI Codex Usage",
            subtitle: "Manual scan of local Codex JSONL token usage for OpenAI sessions",
            dashboard: viewModel.openAIUsage,
            isRefreshing: viewModel.isOpenAIRefreshing,
            lastScannedAt: viewModel.openAILastScannedAt,
            scanMode: $viewModel.openAIUsageScanMode,
            sessionCounterLabel: CodexLogUsageProvider.openai.sessionCounterLabel,
            endpointTableTitle: "By provider / model deployment",
            emptyText: "No OpenAI Codex token events counted yet. Choose a window and click Scan.",
            endpointLabel: { group in
                "\(group.endpoint) • \(group.deployment)"
            },
            refresh: {
                if viewModel.openAIUsageScanMode.requiresConfirmation {
                    isConfirmingAllTimeScan = true
                } else {
                    viewModel.refreshOpenAIUsage()
                }
            }
        )
        .confirmationDialog(
            "Scan all OpenAI Codex history?",
            isPresented: $isConfirmingAllTimeScan,
            titleVisibility: .visible
        ) {
            Button("Scan all history") {
                viewModel.refreshOpenAIUsage()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("OpenAI Codex history can include very large JSONL files. Recent windows are recommended for normal use.")
        }
    }
}

private struct CodexLogUsageSectionView: View {
    let title: String
    let subtitle: String
    let dashboard: AzureUsageDashboard
    let isRefreshing: Bool
    let lastScannedAt: Date?
    var window: Binding<AzureUsageTimeWindow>?
    var customStartDate: Binding<Date>?
    var scanMode: Binding<CodexUsageScanMode>?
    let sessionCounterLabel: String
    let endpointTableTitle: String
    let emptyText: String
    let endpointLabel: (AzureUsageGroup) -> String
    let refresh: () -> Void

    init(
        title: String,
        subtitle: String,
        dashboard: AzureUsageDashboard,
        isRefreshing: Bool,
        lastScannedAt: Date?,
        window: Binding<AzureUsageTimeWindow>,
        customStartDate: Binding<Date>,
        sessionCounterLabel: String,
        endpointTableTitle: String,
        emptyText: String = "No token events counted for this window",
        endpointLabel: @escaping (AzureUsageGroup) -> String,
        refresh: @escaping () -> Void
    ) {
        self.title = title
        self.subtitle = subtitle
        self.dashboard = dashboard
        self.isRefreshing = isRefreshing
        self.lastScannedAt = lastScannedAt
        self.window = window
        self.customStartDate = customStartDate
        self.scanMode = nil
        self.sessionCounterLabel = sessionCounterLabel
        self.endpointTableTitle = endpointTableTitle
        self.emptyText = emptyText
        self.endpointLabel = endpointLabel
        self.refresh = refresh
    }

    init(
        title: String,
        subtitle: String,
        dashboard: AzureUsageDashboard,
        isRefreshing: Bool,
        lastScannedAt: Date?,
        scanMode: Binding<CodexUsageScanMode>,
        sessionCounterLabel: String,
        endpointTableTitle: String,
        emptyText: String,
        endpointLabel: @escaping (AzureUsageGroup) -> String,
        refresh: @escaping () -> Void
    ) {
        self.title = title
        self.subtitle = subtitle
        self.dashboard = dashboard
        self.isRefreshing = isRefreshing
        self.lastScannedAt = lastScannedAt
        self.window = nil
        self.customStartDate = nil
        self.scanMode = scanMode
        self.sessionCounterLabel = sessionCounterLabel
        self.endpointTableTitle = endpointTableTitle
        self.emptyText = emptyText
        self.endpointLabel = endpointLabel
        self.refresh = refresh
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(title)
                        .font(.headline)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if let window {
                    Picker("Window", selection: window) {
                        ForEach(AzureUsageTimeWindow.allCases) { window in
                            Text(window.label).tag(window)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 150)
                }

                if let scanMode {
                    Picker("Window", selection: scanMode) {
                        ForEach(CodexUsageScanMode.allCases) { mode in
                            Text(mode.label).tag(mode)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 150)
                }

                if window?.wrappedValue == .sinceDate, let customStartDate {
                    DatePicker(
                        "Since",
                        selection: customStartDate,
                        displayedComponents: .date
                    )
                    .datePickerStyle(.compact)
                    .labelsHidden()
                    .frame(width: 120)
                }

                Button {
                    refresh()
                } label: {
                    Label(isRefreshing ? "Scanning" : "Rescan", systemImage: "arrow.clockwise")
                }
                .disabled(isRefreshing)
            }

            HStack(spacing: 12) {
                AzureUsageTotalPanel(title: "Input", value: dashboard.totals.inputTokens)
                AzureUsageTotalPanel(title: "Cached", value: dashboard.totals.cachedInputTokens)
                AzureUsageTotalPanel(title: "Uncached", value: dashboard.totals.uncachedInputTokens)
                AzureUsageTotalPanel(title: "Output", value: dashboard.totals.outputTokens)
                AzureUsageTotalPanel(title: "Total", value: dashboard.totals.totalTokens)
                AzureUsageCostPanel(title: "Est. cost", value: dashboard.totals.estimatedCostUSD)
            }

            HStack(alignment: .top, spacing: 12) {
                AzureUsageTableView(
                    title: endpointTableTitle,
                    groups: dashboard.byEndpointDeployment,
                    emptyText: emptyText,
                    label: endpointLabel
                )

                AzureUsageTableView(
                    title: "By model",
                    groups: dashboard.byModel,
                    emptyText: emptyText,
                    label: { group in
                        "\(group.model) • \(group.pricing.rateSummary)"
                    }
                )
            }

            AzureUsageScanStatsView(
                dashboard: dashboard,
                lastScannedAt: lastScannedAt,
                sessionCounterLabel: sessionCounterLabel
            )

            if !dashboard.summary.warnings.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(dashboard.summary.warnings, id: \.self) { warning in
                        Label(warning, systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
            }
        }
        .padding(16)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
        }
    }
}

private struct AzureUsageTotalPanel: View {
    let title: String
    let value: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(value.formatted())
                .font(.system(size: 22, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

private struct AzureUsageCostPanel: View {
    let title: String
    let value: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(value.formatted(.currency(code: "USD").precision(.fractionLength(2))))
                .font(.system(size: 22, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

private struct AzureUsageTableView: View {
    let title: String
    let groups: [AzureUsageGroup]
    let emptyText: String
    let label: (AzureUsageGroup) -> String

    init(
        title: String,
        groups: [AzureUsageGroup],
        emptyText: String = "No token events counted for this window",
        label: @escaping (AzureUsageGroup) -> String
    ) {
        self.title = title
        self.groups = groups
        self.emptyText = emptyText
        self.label = label
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.subheadline.weight(.semibold))

            if groups.isEmpty {
                Text(emptyText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 72, alignment: .center)
            } else {
                VStack(spacing: 0) {
                    AzureUsageHeaderRow()
                    ForEach(groups.prefix(8)) { group in
                        AzureUsageRow(title: label(group), totals: group.totals)
                        if group.id != groups.prefix(8).last?.id {
                            Divider()
                        }
                    }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

private struct AzureUsageHeaderRow: View {
    var body: some View {
        HStack(spacing: 8) {
            Text("Name")
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("Events")
                .frame(width: 54, alignment: .trailing)
            Text("Input")
                .frame(width: 74, alignment: .trailing)
            Text("Output")
                .frame(width: 74, alignment: .trailing)
            Text("Total")
                .frame(width: 82, alignment: .trailing)
            Text("Est. $")
                .frame(width: 72, alignment: .trailing)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
        .padding(.vertical, 5)
    }
}

private struct AzureUsageRow: View {
    let title: String
    let totals: AzureUsageTokenTotals

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.caption)
                .lineLimit(2)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(totals.eventCount.formatted())
                .frame(width: 54, alignment: .trailing)
            Text(totals.inputTokens.formatted())
                .frame(width: 74, alignment: .trailing)
            Text(totals.outputTokens.formatted())
                .frame(width: 74, alignment: .trailing)
            Text(totals.totalTokens.formatted())
                .frame(width: 82, alignment: .trailing)
            Text(totals.estimatedCostUSD.formatted(.currency(code: "USD").precision(.fractionLength(2))))
                .frame(width: 72, alignment: .trailing)
        }
        .font(.caption.monospacedDigit())
        .padding(.vertical, 6)
    }
}

private struct AzureUsageScanStatsView: View {
    let dashboard: AzureUsageDashboard
    let lastScannedAt: Date?
    let sessionCounterLabel: String

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 10)], alignment: .leading, spacing: 8) {
            AzureUsageStat(label: "Earliest event", value: DateFormats.display(date: dashboard.summary.earliestEvent))
            AzureUsageStat(label: "Latest event", value: DateFormats.display(date: dashboard.summary.latestEvent))
            AzureUsageStat(label: "Files scanned", value: dashboard.summary.filesScanned.formatted())
            AzureUsageStat(label: "Sessions scanned", value: dashboard.summary.sessionsScanned.formatted())
            AzureUsageStat(label: sessionCounterLabel, value: dashboard.summary.azureSessions.formatted())
            AzureUsageStat(label: "Events counted", value: dashboard.summary.eventsCounted.formatted())
            AzureUsageStat(label: "Duplicates skipped", value: dashboard.summary.duplicateEventsSkipped.formatted())
            AzureUsageStat(label: "Startup replay skipped", value: dashboard.summary.startupReplayEventsSkipped.formatted())
            AzureUsageStat(label: "Malformed skipped", value: dashboard.summary.malformedEventsSkipped.formatted())
            AzureUsageStat(label: "Last scanned", value: DateFormats.display(date: lastScannedAt))
        }
    }
}

private struct AzureUsageStat: View {
    let label: String
    let value: String

    var body: some View {
        LabeledContent(label, value: value)
            .font(.caption)
            .textSelection(.enabled)
    }
}

private struct StatusPill: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(Color.accentColor.opacity(0.13))
            .foregroundStyle(Color.accentColor)
            .clipShape(Capsule())
    }
}

private struct PlanPill: View {
    let text: String

    var body: some View {
        Text(text.uppercased())
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(Capsule())
            .overlay {
                Capsule()
                    .stroke(Color(nsColor: .separatorColor))
            }
    }
}
