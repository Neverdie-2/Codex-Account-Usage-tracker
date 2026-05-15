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
        .textSelection(.enabled)
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

            if viewModel.isPrivateServerRunning {
                Button {
                    viewModel.stopOwnServer()
                } label: {
                    Label("Stop Server", systemImage: "stop.circle")
                }
                .headerButtonSizing()
            } else {
                Button {
                    viewModel.startOwnServerAndRefresh()
                } label: {
                    Label("Start Own Server", systemImage: "play.circle")
                }
                .headerButtonSizing()
            }

            Button {
                viewModel.refreshNow()
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .headerButtonSizing()
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

private extension View {
    func headerButtonSizing() -> some View {
        self
            .font(.system(size: 13))
            .labelStyle(.titleAndIcon)
            .lineLimit(1)
            .controlSize(.regular)
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
                        .font(.system(size: 14.5, weight: .semibold))
                        .textSelection(.enabled)
                    Text("Last seen \(account.lastSeenAt)")
                        .font(.system(size: 12.5))
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
                        .font(.system(size: 15.5))
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
        .textSelection(.enabled)
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

            FixedColorProgressBar(value: Double(usedPercent ?? 0), total: 100, color: quotaColor)

            LabeledContent("Used", value: percentText(usedPercent))
                .font(.system(size: 14.5))
            LabeledContent("Reset", value: resetText)
                .font(.system(size: 14.5))
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
        if remainingPercent <= 25 { return Color(red: 0.95, green: 0.72, blue: 0.16) }
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

private struct FixedColorProgressBar: View {
    let value: Double
    let total: Double
    let color: Color

    private var fraction: Double {
        guard total > 0 else { return 0 }
        return min(max(value / total, 0), 1)
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color(nsColor: .separatorColor).opacity(0.45))
                Capsule()
                    .fill(color)
                    .frame(width: max(0, proxy.size.width * fraction))
            }
        }
        .frame(height: 5)
        .accessibilityLabel("Used quota")
        .accessibilityValue("\(Int((fraction * 100).rounded()))%")
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

    var body: some View {
        CodexLogUsageSectionView(
            title: "OpenAI Codex Usage",
            subtitle: "Manual scan of local Codex JSONL token usage for OpenAI sessions",
            dashboard: viewModel.openAIUsage,
            isRefreshing: viewModel.isOpenAIRefreshing,
            lastScannedAt: viewModel.openAILastScannedAt,
            scanMode: $viewModel.openAIUsageScanMode,
            customStartDate: $viewModel.openAICustomStartDate,
            sessionCounterLabel: CodexLogUsageProvider.openai.sessionCounterLabel,
            endpointTableTitle: "By provider / model deployment",
            emptyText: "No OpenAI Codex token events counted yet. Choose a window and click Refresh.",
            endpointLabel: { group in
                "\(group.endpoint) • \(group.deployment)"
            },
            refresh: viewModel.refreshOpenAIUsage
        )
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
        customStartDate: Binding<Date>,
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
        self.customStartDate = customStartDate
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
                    .controlSize(.large)
                    .frame(width: 167)
                }

                if let scanMode {
                    Picker("Window", selection: scanMode) {
                        ForEach(CodexUsageScanMode.allCases) { mode in
                            Text(mode.label).tag(mode)
                        }
                    }
                    .labelsHidden()
                    .controlSize(.large)
                    .frame(width: 167)
                }

                if (window?.wrappedValue == .sinceDate || scanMode?.wrappedValue == .sinceDate), let customStartDate {
                    DatePicker(
                        "Since",
                        selection: customStartDate,
                        displayedComponents: .date
                    )
                    .datePickerStyle(.compact)
                    .labelsHidden()
                    .controlSize(.large)
                    .frame(width: 133)
                }

                Button {
                    refresh()
                } label: {
                    Label(isRefreshing ? "Refreshing" : "Refresh", systemImage: "arrow.clockwise")
                }
                .controlSize(.large)
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

            AzureUsageProjectTableView(
                projects: dashboard.byProject,
                emptyText: emptyText
            )

            Divider()
                .padding(.horizontal, 8)

            AzureUsageScanStatsView(
                dashboard: dashboard,
                lastScannedAt: lastScannedAt,
                sessionCounterLabel: sessionCounterLabel
            )

            if !dashboard.summary.warnings.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(dashboard.summary.warnings, id: \.self) { warning in
                        Label(warning, systemImage: "exclamationmark.triangle")
                            .font(AzureUsageLowerFont.hiddenCaption)
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
                .textSelection(.enabled)
            Text(AzureUsageFormat.integer(value))
                .font(.system(size: 22, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .textSelection(.enabled)
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
                .textSelection(.enabled)
            Text(AzureUsageFormat.usd(value))
                .font(.system(size: 22, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .textSelection(.enabled)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

private enum AzureUsageLowerFont {
    static let empty = Font.system(size: 14)
    static let tableTitle = Font.system(size: 15, weight: .semibold)
    static let caption = Font.system(size: 14)
    static let captionSemibold = Font.system(size: 14, weight: .semibold)
    static let captionMonospaced = Font.system(size: 14)
    static let captionMonospacedSemibold = Font.system(size: 14, weight: .semibold)
    static let caption2 = Font.system(size: 13)
    static let hiddenCaption = Font.system(size: 14)
    static let hiddenCaptionSemibold = Font.system(size: 14, weight: .semibold)
    static let hiddenCaptionMonospaced = Font.system(size: 14)
    static let hiddenCaption2 = Font.system(size: 13)
}

private enum AzureUsageColumnWidth {
    static let events: CGFloat = 64
    static let tokens: CGFloat = 82
    static let cached: CGFloat = 82
    static let uncached: CGFloat = 88
    static let output: CGFloat = 82
    static let total: CGFloat = 94
    static let cost: CGFloat = 88
    static let sessions: CGFloat = 66
    static let projectEvents: CGFloat = 58
    static let projectTotal: CGFloat = 104
    static let projectCost: CGFloat = 86
    static let latest: CGFloat = 188
}

private enum AzureUsageFormat {
    static func integer(_ value: Int) -> String {
        value.formatted(.number.locale(Locale(identifier: "en_US")))
    }

    static func usd(_ value: Double) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencySymbol = "$"
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 2
        return formatter.string(from: NSNumber(value: value)) ?? "$\(String(format: "%.2f", value))"
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
                .font(AzureUsageLowerFont.tableTitle)

            if groups.isEmpty {
                Text(emptyText)
                    .font(AzureUsageLowerFont.empty)
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
                .frame(width: AzureUsageColumnWidth.events, alignment: .trailing)
            Text("Input")
                .frame(width: AzureUsageColumnWidth.tokens, alignment: .trailing)
            Text("Cached")
                .frame(width: AzureUsageColumnWidth.cached, alignment: .trailing)
            Text("Uncached")
                .frame(width: AzureUsageColumnWidth.uncached, alignment: .trailing)
            Text("Output")
                .frame(width: AzureUsageColumnWidth.output, alignment: .trailing)
            Text("Total")
                .frame(width: AzureUsageColumnWidth.total, alignment: .trailing)
            Text("Est. $")
                .frame(width: AzureUsageColumnWidth.cost, alignment: .trailing)
        }
        .font(AzureUsageLowerFont.captionSemibold)
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
                .font(AzureUsageLowerFont.caption)
                .lineLimit(2)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(AzureUsageFormat.integer(totals.eventCount))
                .monospacedDigit()
                .lineLimit(1)
                .textSelection(.enabled)
                .frame(width: AzureUsageColumnWidth.events, alignment: .trailing)
            Text(AzureUsageFormat.integer(totals.inputTokens))
                .monospacedDigit()
                .lineLimit(1)
                .textSelection(.enabled)
                .frame(width: AzureUsageColumnWidth.tokens, alignment: .trailing)
            Text(AzureUsageFormat.integer(totals.cachedInputTokens))
                .monospacedDigit()
                .lineLimit(1)
                .textSelection(.enabled)
                .frame(width: AzureUsageColumnWidth.cached, alignment: .trailing)
            Text(AzureUsageFormat.integer(totals.uncachedInputTokens))
                .monospacedDigit()
                .lineLimit(1)
                .textSelection(.enabled)
                .frame(width: AzureUsageColumnWidth.uncached, alignment: .trailing)
            Text(AzureUsageFormat.integer(totals.outputTokens))
                .monospacedDigit()
                .lineLimit(1)
                .textSelection(.enabled)
                .frame(width: AzureUsageColumnWidth.output, alignment: .trailing)
            Text(AzureUsageFormat.integer(totals.totalTokens))
                .monospacedDigit()
                .lineLimit(1)
                .textSelection(.enabled)
                .frame(width: AzureUsageColumnWidth.total, alignment: .trailing)
            Text(AzureUsageFormat.usd(totals.estimatedCostUSD))
                .monospacedDigit()
                .lineLimit(1)
                .textSelection(.enabled)
                .frame(width: AzureUsageColumnWidth.cost, alignment: .trailing)
        }
        .font(AzureUsageLowerFont.captionMonospaced)
        .padding(.vertical, 6)
    }
}

private struct AzureUsageProjectTableView: View {
    let projects: [AzureUsageProjectGroup]
    let emptyText: String

    private var folderProjects: [AzureUsageProjectGroup] {
        projects.filter { !$0.isChatGroup }
    }

    private var chatGroups: [AzureUsageProjectGroup] {
        projects.filter(\.isChatGroup)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            let hasChats = !chatGroups.isEmpty

            VStack(alignment: .leading, spacing: 0) {
                AzureUsageProjectGroupSectionView(
                    title: "By project",
                    firstColumnTitle: "Project",
                    projects: folderProjects,
                    emptyText: emptyText,
                    showsFooterDivider: hasChats
                )

                if hasChats {
                    AzureUsageProjectRowsView(
                        projects: chatGroups,
                        emptyText: emptyText,
                        showsTrailingDivider: false
                    )
                }
            }
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }
}

private struct AzureUsageProjectGroupSectionView: View {
    let title: String
    let firstColumnTitle: String
    let projects: [AzureUsageProjectGroup]
    let emptyText: String
    var showsFooterDivider = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(AzureUsageLowerFont.tableTitle)

            if projects.isEmpty {
                Text(emptyText)
                    .font(AzureUsageLowerFont.empty)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 72, alignment: .center)
            } else {
                VStack(spacing: 0) {
                    AzureUsageProjectHeaderRow(firstColumnTitle: firstColumnTitle)
                    ForEach(projects.prefix(12)) { project in
                        if project.id == projects.prefix(12).first?.id {
                            Divider()
                        }
                        AzureUsageProjectDisclosureRow(project: project)
                        Divider()
                    }
                }
            }
        }
        .padding(.top, 12)
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

private struct AzureUsageProjectRowsView: View {
    let projects: [AzureUsageProjectGroup]
    let emptyText: String
    var showsTrailingDivider = true

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if projects.isEmpty {
                Text(emptyText)
                    .font(AzureUsageLowerFont.empty)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 72, alignment: .center)
            } else {
                VStack(spacing: 0) {
                    ForEach(projects.prefix(12)) { project in
                        AzureUsageProjectDisclosureRow(project: project)
                        if showsTrailingDivider || project.id != projects.prefix(12).last?.id {
                            Divider()
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

private struct AzureUsageProjectHeaderRow: View {
    let firstColumnTitle: String

    var body: some View {
        HStack(spacing: 8) {
            Spacer(minLength: 0)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("Sessions")
                .frame(width: AzureUsageColumnWidth.sessions, alignment: .trailing)
            Text("Events")
                .frame(width: AzureUsageColumnWidth.projectEvents, alignment: .trailing)
            Text("Total")
                .frame(width: AzureUsageColumnWidth.projectTotal, alignment: .trailing)
            Text("Est. $")
                .frame(width: AzureUsageColumnWidth.projectCost, alignment: .trailing)
            Text("Latest")
                .frame(width: AzureUsageColumnWidth.latest, alignment: .trailing)
        }
        .font(AzureUsageLowerFont.captionSemibold)
        .foregroundStyle(.secondary)
        .padding(.vertical, 5)
    }
}

private struct AzureUsageProjectDisclosureRow: View {
    let project: AzureUsageProjectGroup
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            projectRow

            if isExpanded {
                expandedContent
                    .padding(.leading, 18)
                    .padding(.bottom, 8)
            }
        }
    }

    private var expandedContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()
            AzureUsageProjectBreakdownView(title: "Models", rows: project.byModel.prefix(8).map { row in
                AzureUsageProjectBreakdownRow(
                    name: "\(row.model) • \(row.pricing.rateSummary)",
                    totals: row.totals,
                    detail: nil
                )
            })

            Divider()
            AzureUsageProjectSessionTableView(sessions: Array(project.sessions.prefix(12)))
        }
    }

    private var projectRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .rotationEffect(.degrees(isExpanded ? 90 : 0))
                .frame(width: 12, alignment: .center)
                .foregroundStyle(.primary)
                .onTapGesture {
                    isExpanded.toggle()
                }

            Button {
                isExpanded.toggle()
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(project.isChatGroup ? "Chats" : project.projectName)
                        .font(AzureUsageLowerFont.captionSemibold)
                        .lineLimit(1)
                    if project.isChatGroup {
                        EmptyView()
                    } else {
                        Text(project.projectPath)
                            .font(AzureUsageLowerFont.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .contextMenu {
                Button("Copy name") {
                    copyToPasteboard(project.isChatGroup ? "Chats" : project.projectName)
                }
                if !project.isChatGroup {
                    Button("Copy path") {
                        copyToPasteboard(project.projectPath)
                    }
                }
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(AzureUsageFormat.integer(project.sessionCount))
                .monospacedDigit()
                .lineLimit(1)
                .textSelection(.enabled)
                .frame(width: AzureUsageColumnWidth.sessions, alignment: .trailing)
            Text(AzureUsageFormat.integer(project.totals.eventCount))
                .monospacedDigit()
                .lineLimit(1)
                .textSelection(.enabled)
                .frame(width: AzureUsageColumnWidth.projectEvents, alignment: .trailing)
            Text(AzureUsageFormat.integer(project.totals.totalTokens))
                .monospacedDigit()
                .lineLimit(1)
                .textSelection(.enabled)
                .frame(width: AzureUsageColumnWidth.projectTotal, alignment: .trailing)
            Text(AzureUsageFormat.usd(project.totals.estimatedCostUSD))
                .monospacedDigit()
                .lineLimit(1)
                .textSelection(.enabled)
                .frame(width: AzureUsageColumnWidth.projectCost, alignment: .trailing)
            Text(DateFormats.display(date: project.latestActivity))
                .lineLimit(1)
                .textSelection(.enabled)
                .frame(width: AzureUsageColumnWidth.latest, alignment: .trailing)
        }
        .font(AzureUsageLowerFont.captionMonospaced)
        .padding(.vertical, 6)
    }

    private func copyToPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

private struct AzureUsageProjectBreakdownView: View {
    let title: String
    let rows: [AzureUsageProjectBreakdownRow]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(AzureUsageLowerFont.hiddenCaptionSemibold)
                .foregroundStyle(.secondary)
            ForEach(rows) { row in
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(row.name)
                            .lineLimit(1)
                            .textSelection(.enabled)
                        if let detail = row.detail {
                            Text(detail)
                                .font(AzureUsageLowerFont.hiddenCaption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .textSelection(.enabled)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Text(AzureUsageFormat.integer(row.totals.eventCount))
                        .monospacedDigit()
                        .lineLimit(1)
                        .frame(width: AzureUsageColumnWidth.projectEvents, alignment: .trailing)
                    Text(AzureUsageFormat.integer(row.totals.totalTokens))
                        .monospacedDigit()
                        .lineLimit(1)
                        .frame(width: AzureUsageColumnWidth.projectTotal, alignment: .trailing)
                    Text(AzureUsageFormat.usd(row.totals.estimatedCostUSD))
                        .monospacedDigit()
                        .lineLimit(1)
                        .frame(width: AzureUsageColumnWidth.projectCost, alignment: .trailing)
                }
                .font(AzureUsageLowerFont.hiddenCaptionMonospaced)
                .padding(.vertical, 3)
            }
        }
    }
}

private struct AzureUsageProjectBreakdownRow: Identifiable {
    let id = UUID()
    let name: String
    let totals: AzureUsageTokenTotals
    let detail: String?
}

private struct AzureUsageProjectSessionTableView: View {
    let sessions: [AzureUsageProjectSessionGroup]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Sessions")
                .font(AzureUsageLowerFont.hiddenCaptionSemibold)
                .foregroundStyle(.secondary)

            ForEach(sessions) { session in
                HStack(spacing: 8) {
                    Text(session.shortSessionID)
                        .frame(width: 72, alignment: .leading)
                        .textSelection(.enabled)
                    Text(session.modelSummary)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text(AzureUsageFormat.integer(session.totals.eventCount))
                        .monospacedDigit()
                        .lineLimit(1)
                        .frame(width: AzureUsageColumnWidth.projectEvents, alignment: .trailing)
                    Text(AzureUsageFormat.integer(session.totals.totalTokens))
                        .monospacedDigit()
                        .lineLimit(1)
                        .frame(width: AzureUsageColumnWidth.projectTotal, alignment: .trailing)
                    Text(AzureUsageFormat.usd(session.totals.estimatedCostUSD))
                        .monospacedDigit()
                        .lineLimit(1)
                        .frame(width: AzureUsageColumnWidth.projectCost, alignment: .trailing)
                    Text(DateFormats.display(date: session.latestActivity))
                        .lineLimit(1)
                        .frame(width: AzureUsageColumnWidth.latest, alignment: .trailing)
                    Text(session.sourceFileName)
                        .lineLimit(1)
                        .frame(width: 140, alignment: .trailing)
                        .textSelection(.enabled)
                }
                .font(AzureUsageLowerFont.hiddenCaptionMonospaced)
                .padding(.vertical, 3)
            }
        }
    }
}

private struct AzureUsageScanStatsView: View {
    let dashboard: AzureUsageDashboard
    let lastScannedAt: Date?
    let sessionCounterLabel: String

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 230), spacing: 18)], alignment: .leading, spacing: 10) {
            AzureUsageStat(label: "Earliest event", value: DateFormats.display(date: dashboard.summary.earliestEvent))
            AzureUsageStat(label: "Latest event", value: DateFormats.display(date: dashboard.summary.latestEvent))
            AzureUsageStat(label: "Files scanned", value: AzureUsageFormat.integer(dashboard.summary.filesScanned))
            AzureUsageStat(label: "Sessions scanned", value: AzureUsageFormat.integer(dashboard.summary.sessionsScanned))
            AzureUsageStat(label: sessionCounterLabel, value: AzureUsageFormat.integer(dashboard.summary.azureSessions))
            AzureUsageStat(label: "Events counted", value: AzureUsageFormat.integer(dashboard.summary.eventsCounted))
            AzureUsageStat(label: "Duplicates skipped", value: AzureUsageFormat.integer(dashboard.summary.duplicateEventsSkipped))
            AzureUsageStat(label: "Startup replay skipped", value: AzureUsageFormat.integer(dashboard.summary.startupReplayEventsSkipped))
            AzureUsageStat(label: "Malformed skipped", value: AzureUsageFormat.integer(dashboard.summary.malformedEventsSkipped))
            AzureUsageStat(label: "Last scanned", value: DateFormats.display(date: lastScannedAt))
        }
    }
}

private struct AzureUsageStat: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .font(AzureUsageLowerFont.captionSemibold)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: true, vertical: false)
            Text(value)
                .font(AzureUsageLowerFont.caption)
                .foregroundStyle(.primary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
            .font(AzureUsageLowerFont.caption)
            .textSelection(.enabled)
    }
}

private struct StatusPill: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 12.5, weight: .semibold))
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
            .font(.system(size: 12.5, weight: .semibold))
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
