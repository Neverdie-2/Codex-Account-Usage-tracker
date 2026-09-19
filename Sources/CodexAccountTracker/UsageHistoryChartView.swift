import Charts
import SwiftUI

struct UsageHistoryChartView: View {
    let records: [AzureUsageRecord]
    let recordsRevision: Int
    let startDate: Date?
    let endDate: Date
    let configuration: UsageHistoryPanelConfiguration
    let isCollapsed: Bool
    let onToggleCollapse: () -> Void

    @State private var metric: UsageHistoryMetric = .totalTokens
    @State private var chartStyle: UsageHistoryChartStyle = .area
    @State private var bucketSelection: UsageHistoryBucketSelection = .automatic
    @State private var grouping: UsageHistoryGrouping
    @State private var filters = UsageHistoryFilterState()
    @State private var hiddenSeries = Set<String>()
    @State private var selectedBucket: Date?
    @State private var result: UsageHistoryResult
    @State private var filterOptions = UsageHistoryFilterOptions()

    init(
        records: [AzureUsageRecord],
        recordsRevision: Int,
        startDate: Date?,
        endDate: Date,
        configuration: UsageHistoryPanelConfiguration,
        isCollapsed: Bool,
        onToggleCollapse: @escaping () -> Void
    ) {
        self.records = records
        self.recordsRevision = recordsRevision
        self.startDate = startDate
        self.endDate = endDate
        self.configuration = configuration
        self.isCollapsed = isCollapsed
        self.onToggleCollapse = onToggleCollapse
        _grouping = State(initialValue: configuration.groupings.first ?? .model)
        _result = State(initialValue: .empty(endDate: endDate))
    }

    private var buildKey: UsageHistoryBuildKey {
        UsageHistoryBuildKey(
            recordsRevision: recordsRevision,
            startDate: startDate,
            endDate: endDate,
            metric: metric,
            grouping: grouping,
            filters: filters,
            bucketSelection: bucketSelection,
            isCollapsed: isCollapsed
        )
    }

    private var visibleSeries: [UsageHistorySeries] {
        result.series.filter { !hiddenSeries.contains($0.id) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button {
                withAnimation(.easeInOut(duration: 0.18)) {
                    onToggleCollapse()
                }
            } label: {
                HStack(spacing: 8) {
                    UsageHistoryChevron(isCollapsed: isCollapsed)
                    Text("Historical Usage")
                        .font(.headline)
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Historical Usage")
            .accessibilityValue(isCollapsed ? "Collapsed" : "Expanded")

            if !isCollapsed {
                controls

                if result.series.isEmpty {
                    Text("No historical usage in this period")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 260)
                        .accessibilityLabel("No historical usage in this period")
                } else if visibleSeries.isEmpty {
                    Text("All series are hidden. Select a legend item to show it.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 260)
                } else {
                    chart
                    legend
                    if let selectedBucketForDisplay {
                        tooltip(for: selectedBucketForDisplay)
                    }
                }
            }
        }
        .padding(12)
        .background(Color(nsColor: .textBackgroundColor).opacity(0.55))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .task(id: buildKey) {
            guard !isCollapsed else { return }
            let records = records
            let startDate = startDate
            let endDate = endDate
            let configuration = configuration
            let metric = metric
            let grouping = grouping
            let filters = filters
            let bucketSize = bucketSelection.bucketSize
            let builder = UsageHistoryBuilder(calendar: .current)
            let built = await Task.detached(priority: .userInitiated) {
                let chartResult = builder.build(
                    records: records,
                    startDate: startDate,
                    endDate: endDate,
                    configuration: configuration,
                    metric: metric,
                    grouping: grouping,
                    filters: filters,
                    bucketSize: bucketSize
                )
                let options = builder.filterOptions(
                    records: records,
                    startDate: startDate,
                    endDate: endDate,
                    configuration: configuration
                )
                return (chartResult, options)
            }.value

            guard !Task.isCancelled else { return }
            result = built.0
            filterOptions = built.1
            selectedBucket = nil
            hiddenSeries.formIntersection(result.series.map(\.id))
        }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Picker("Metric", selection: $metric) {
                    ForEach(UsageHistoryMetric.allCases) { metric in
                        Text(metric.label(costLabel: configuration.costLabel)).tag(metric)
                    }
                }
                .labelsHidden()
                .frame(width: 180)

                Picker("Group by", selection: $grouping) {
                    ForEach(configuration.groupings) { grouping in
                        Text(grouping.label).tag(grouping)
                    }
                }
                .labelsHidden()
                .frame(width: 140)

                Picker("Chart", selection: $chartStyle) {
                    ForEach(UsageHistoryChartStyle.allCases) { style in
                        Text(style.label).tag(style)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 140)

                Picker("Bucket", selection: $bucketSelection) {
                    ForEach(UsageHistoryBucketSelection.allCases) { selection in
                        Text(selection.label).tag(selection)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 105)

                Spacer()
            }

            HStack(spacing: 8) {
                UsageHistoryMultiSelect(
                    title: "Model",
                    values: filterOptions.models,
                    selection: $filters.models
                )
                UsageHistoryMultiSelect(
                    title: "Project",
                    values: filterOptions.projects,
                    selection: $filters.projects
                )
                if let filterGrouping = configuration.filterGrouping {
                    UsageHistoryMultiSelect(
                        title: filterGrouping.label,
                        values: filterOptions.secondary,
                        selection: $filters.secondary
                    )
                }
                Spacer()
            }
        }
    }

    private var chart: some View {
        let labels = visibleSeries.map(\.name)
        let colors = visibleSeries.map { seriesColor(for: $0) }
        // The marks stack, so the ceiling is the tallest stacked bucket — not the
        // tallest single point. Scaling to the single point let the stack draw
        // past the top of the plot and over whatever sat above it.
        let upperBound = UsageHistoryAxis.upperBound(
            for: UsageHistoryAxis.stackedMaximum(of: visibleSeries)
        )

        return Chart {
            if chartStyle == .area {
                ForEach(visibleSeries) { series in
                    ForEach(series.points) { point in
                        AreaMark(
                            x: .value("Time", point.date),
                            y: .value(metric.label(costLabel: configuration.costLabel), point.value)
                        )
                        .foregroundStyle(by: .value("Series", series.name))
                        .interpolationMethod(.monotone)
                    }
                }
            } else {
                ForEach(visibleSeries) { series in
                    ForEach(series.points) { point in
                        BarMark(
                            x: .value("Time", point.date),
                            y: .value(metric.label(costLabel: configuration.costLabel), point.value),
                            width: .ratio(0.85)
                        )
                        .foregroundStyle(by: .value("Series", series.name))
                    }
                }
            }

            if let selectedBucketForDisplay {
                RuleMark(x: .value("Selected time", selectedBucketForDisplay))
                    .foregroundStyle(.secondary)
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4]))
            }
        }
        .chartForegroundStyleScale(domain: labels, range: colors)
        .chartYScale(domain: 0...upperBound)
        .chartLegend(.hidden)
        .chartXSelection(value: $selectedBucket)
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: xAxisLabelCount)) { _ in
                AxisGridLine()
                AxisTick()
                AxisValueLabel(format: xAxisFormat)
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 5)) { value in
                AxisGridLine()
                AxisTick()
                AxisValueLabel {
                    if let raw = value.as(Double.self) {
                        Text(yAxisLabel(raw))
                    }
                }
            }
        }
        // Belt and braces: whatever the scale works out to be, a mark can never
        // paint outside the plot rect and onto the rows around it.
        .chartPlotStyle { plot in
            plot.clipped()
        }
        .frame(height: 260)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Historical usage chart")
        .accessibilityValue(accessibilitySummary)
    }

    private var xAxisLabelCount: Int {
        min(8, max(2, result.series.first?.points.count ?? 2))
    }

    private var xAxisFormat: Date.FormatStyle {
        switch result.bucketSize {
        case .fiveMinutes, .hourly:
            return .dateTime.hour().minute()
        case .daily, .weekly:
            return .dateTime.month(.abbreviated).day()
        case .monthly:
            return .dateTime.month(.abbreviated).year(.twoDigits)
        }
    }

    private func yAxisLabel(_ value: Double) -> String {
        metric == .estimatedCost
            ? UsageHistoryAxis.compactCost(value)
            : UsageHistoryAxis.compactValue(value)
    }

    /// Slots come from the full result, not the visible subset, so toggling a
    /// legend entry never repaints the series that stayed on screen.
    private var seriesSlots: [String: Int] {
        UsageHistorySeriesPalette.slotAssignments(for: result.series)
    }

    private func seriesColor(for series: UsageHistorySeries) -> Color {
        UsageHistoryPalette.color(slot: seriesSlots[series.id])
    }

    private var legend: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 150), alignment: .leading)],
            alignment: .leading,
            spacing: 6
        ) {
            ForEach(result.series) { series in
                Button {
                    if hiddenSeries.contains(series.id) {
                        hiddenSeries.remove(series.id)
                    } else {
                        hiddenSeries.insert(series.id)
                    }
                } label: {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(seriesColor(for: series))
                            .frame(width: 9, height: 9)
                            .opacity(hiddenSeries.contains(series.id) ? 0.3 : 1)
                        Image(systemName: hiddenSeries.contains(series.id) ? "eye.slash" : "eye")
                            .font(.caption2)
                        Text(series.name)
                            .lineLimit(1)
                    }
                    .foregroundStyle(hiddenSeries.contains(series.id) ? .secondary : .primary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(series.name) series")
                .accessibilityValue(hiddenSeries.contains(series.id) ? "Hidden" : "Shown")
            }
        }
    }

    private var selectedBucketForDisplay: Date? {
        guard let selectedBucket,
              let points = result.series.first?.points,
              let nearest = points.min(by: {
                  abs($0.date.timeIntervalSince(selectedBucket)) < abs($1.date.timeIntervalSince(selectedBucket))
              })
        else { return nil }
        return nearest.date
    }

    private func tooltip(for date: Date) -> some View {
        let bucketTotals = visibleSeries.reduce(into: AzureUsageTokenTotals()) { total, series in
            guard let point = series.points.first(where: { $0.date == date }) else { return }
            add(point.totals, to: &total)
        }

        return VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text(date.formatted(date: .abbreviated, time: .shortened))
                    .font(.system(size: 16, weight: .semibold))
                Text("\(result.bucketSize.label) bucket • By \(grouping.label)")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text("Visible series total")
                    .font(.system(size: 15, weight: .semibold))
                Text("Total tokens: \(formatInteger(bucketTotals.totalTokens))")
                Text("\(configuration.costLabel): \(formatCost(bucketTotals.estimatedCostUSD))")
            }
            .font(.system(size: 14))

            Divider()

            HStack(alignment: .top, spacing: 14) {
                tooltipSeriesColumn(0, date: date)
                tooltipSeriesColumn(1, date: date)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func tooltipSeriesColumn(_ column: Int, date: Date) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(visibleSeries.indices).filter { $0 % 2 == column }, id: \.self) { index in
                let series = visibleSeries[index]
                if let point = series.points.first(where: { $0.date == date }) {
                    tooltipSeriesCard(series: series, point: point)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func tooltipSeriesCard(series: UsageHistorySeries, point: UsageHistoryPoint) -> some View {
        let color = seriesColor(for: series)
        let hasUsage = point.totals.totalTokens != 0 || point.totals.eventCount != 0
            || point.totals.estimatedCostUSD != 0

        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 7) {
                Circle()
                    .fill(color)
                    .frame(width: 9, height: 9)
                Text(series.name)
                    .font(.system(size: 15, weight: .semibold))
                    .lineLimit(2)
            }

            if hasUsage {
                Text("Total tokens: \(formatInteger(point.totals.totalTokens))")
                Text("Input: \(formatInteger(point.totals.inputTokens))")
                Text("Cached input: \(formatInteger(point.totals.cachedInputTokens))")
                Text("Cache write: \(formatInteger(point.totals.cacheCreationInputTokens))")
                Text("Uncached input: \(formatInteger(point.totals.uncachedInputTokens))")
                Text("Output: \(formatInteger(point.totals.outputTokens))")
                Text("Events: \(formatInteger(point.totals.eventCount))")
                Text("\(configuration.costLabel): \(formatCost(point.totals.estimatedCostUSD))")
            } else {
                Text("No usage in this bucket")
                    .foregroundStyle(.secondary)
            }
        }
        .font(.system(size: 14))
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(color.opacity(0.10))
        .overlay {
            RoundedRectangle(cornerRadius: 6)
                .stroke(color.opacity(0.35), lineWidth: 1)
        }
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 2)
                .fill(color)
                .frame(width: 4)
                .padding(.vertical, 5)
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private var accessibilitySummary: String {
        guard !result.series.isEmpty else { return "No historical usage in this period" }
        let total = result.series.reduce(into: AzureUsageTokenTotals()) { partial, series in
            partial.inputTokens += series.totals.inputTokens
            partial.cachedInputTokens += series.totals.cachedInputTokens
            partial.cacheCreationInputTokens += series.totals.cacheCreationInputTokens
            partial.uncachedInputTokens += series.totals.uncachedInputTokens
            partial.outputTokens += series.totals.outputTokens
            partial.totalTokens += series.totals.totalTokens
            partial.eventCount += series.totals.eventCount
            partial.estimatedCostUSD += series.totals.estimatedCostUSD
        }
        return "Grouped by \(grouping.label). \(formatInteger(total.totalTokens)) total tokens across \(formatInteger(total.eventCount)) events."
    }

    private func formatInteger(_ value: Int) -> String {
        value.formatted(.number)
    }

    private func formatCost(_ value: Double) -> String {
        value.formatted(.currency(code: "USD"))
    }

    private func add(_ source: AzureUsageTokenTotals, to target: inout AzureUsageTokenTotals) {
        target.inputTokens += source.inputTokens
        target.cachedInputTokens += source.cachedInputTokens
        target.cacheCreationInputTokens += source.cacheCreationInputTokens
        target.uncachedInputTokens += source.uncachedInputTokens
        target.outputTokens += source.outputTokens
        target.totalTokens += source.totalTokens
        target.eventCount += source.eventCount
        target.estimatedCostUSD += source.estimatedCostUSD
    }
}

private struct UsageHistoryBuildKey: Hashable {
    let recordsRevision: Int
    let startDate: Date?
    let endDate: Date
    let metric: UsageHistoryMetric
    let grouping: UsageHistoryGrouping
    let filters: UsageHistoryFilterState
    let bucketSelection: UsageHistoryBucketSelection
    let isCollapsed: Bool
}

private struct UsageHistoryMultiSelect: View {
    let title: String
    let values: [String]
    let selection: Binding<Set<String>>

    var body: some View {
        Menu {
            Button("All") {
                selection.wrappedValue = []
            }
            Divider()
            ForEach(values, id: \.self) { value in
                Button {
                    var next = selection.wrappedValue
                    if next.contains(value) {
                        next.remove(value)
                    } else {
                        next.insert(value)
                    }
                    selection.wrappedValue = next
                } label: {
                    Label(
                        value,
                        systemImage: selection.wrappedValue.contains(value) ? "checkmark" : ""
                    )
                }
            }
        } label: {
            HStack(spacing: 5) {
                Text(title)
                Text(selection.wrappedValue.isEmpty ? "All" : "\(selection.wrappedValue.count) selected")
                    .foregroundStyle(.secondary)
                Image(systemName: "chevron.down")
                    .font(.caption2)
            }
        }
        .menuStyle(.borderedButton)
        .controlSize(.small)
    }
}

private struct UsageHistoryChevron: View {
    let isCollapsed: Bool

    var body: some View {
        Image(systemName: "chevron.right")
            .font(.caption.weight(.bold))
            .rotationEffect(.degrees(isCollapsed ? 0 : 90))
            .frame(width: 14)
            .foregroundStyle(.secondary)
    }
}

private enum UsageHistoryPalette {
    /// Fixed categorical order, validated for colour-vision deficiency against
    /// both the light and the dark chart surface (worst adjacent CVD ΔE 9.1
    /// light / 8.4 dark, normal-vision ΔE 19.6 / 19.3). Slots are handed out by
    /// position, never by a hash of the name: with twelve hashed colours and up
    /// to nine series, two series shared one colour almost every time.
    private static let steps: [(light: UInt32, dark: UInt32)] = [
        (0x2a78d6, 0x3987e5),   // blue
        (0xeb6834, 0xd95926),   // orange
        (0x1baf7a, 0x199e70),   // aqua
        (0xeda100, 0xc98500),   // yellow
        (0xe87ba4, 0xd55181),   // magenta
        (0x008300, 0x008300),   // green
        (0x4a3aa7, 0x9085e9),   // violet
        (0xe34948, 0xe66767)    // red
    ]

    /// Reserved neutral for the "Other" roll-up, kept out of the categorical set.
    private static let otherStep: (light: UInt32, dark: UInt32) = (0x6f6f6a, 0x9a9a92)

    static func color(slot: Int?) -> Color {
        guard let slot, slot >= 0, slot < steps.count else {
            return dynamic(otherStep)
        }
        return dynamic(steps[slot])
    }

    private static func dynamic(_ step: (light: UInt32, dark: UInt32)) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return NSColor(rgb: isDark ? step.dark : step.light)
        })
    }
}

private extension NSColor {
    convenience init(rgb: UInt32) {
        self.init(
            srgbRed: Double((rgb >> 16) & 0xff) / 255,
            green: Double((rgb >> 8) & 0xff) / 255,
            blue: Double(rgb & 0xff) / 255,
            alpha: 1
        )
    }
}
