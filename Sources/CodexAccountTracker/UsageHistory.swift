import Foundation

enum UsageHistoryMetric: String, CaseIterable, Identifiable, Hashable {
    case totalTokens
    case inputTokens
    case cachedInput
    case cacheWrite
    case uncachedInput
    case outputTokens
    case events
    case estimatedCost

    var id: String { rawValue }

    var label: String {
        switch self {
        case .totalTokens: return "Total tokens"
        case .inputTokens: return "Input tokens"
        case .cachedInput: return "Cached input"
        case .cacheWrite: return "Cache write"
        case .uncachedInput: return "Uncached input"
        case .outputTokens: return "Output tokens"
        case .events: return "Events"
        case .estimatedCost: return "Estimated cost"
        }
    }

    func label(costLabel: String) -> String {
        self == .estimatedCost ? costLabel : label
    }

    func value(from totals: AzureUsageTokenTotals) -> Double {
        switch self {
        case .totalTokens: return Double(totals.totalTokens)
        case .inputTokens: return Double(totals.inputTokens)
        case .cachedInput: return Double(totals.cachedInputTokens)
        case .cacheWrite: return Double(totals.cacheCreationInputTokens)
        case .uncachedInput: return Double(totals.uncachedInputTokens)
        case .outputTokens: return Double(totals.outputTokens)
        case .events: return Double(totals.eventCount)
        case .estimatedCost: return totals.estimatedCostUSD
        }
    }
}

enum UsageHistoryGrouping: String, CaseIterable, Identifiable, Hashable {
    case model
    case project
    case endpoint
    case source
    case account

    var id: String { rawValue }

    var label: String {
        switch self {
        case .model: return "Model"
        case .project: return "Project"
        case .endpoint: return "Endpoint"
        case .source: return "Source"
        case .account: return "Account"
        }
    }
}

enum UsageHistoryBucketSize: String, CaseIterable, Identifiable, Hashable {
    case fiveMinutes
    case fifteenMinutes
    case hourly
    case threeHours
    case sixHours
    case twelveHours
    case daily
    case weekly
    case monthly

    var id: String { rawValue }

    var label: String {
        switch self {
        case .fiveMinutes: return "5 min"
        case .fifteenMinutes: return "15 min"
        case .hourly: return "Hour"
        case .threeHours: return "3 h"
        case .sixHours: return "6 h"
        case .twelveHours: return "12 h"
        case .daily: return "Day"
        case .weekly: return "Week"
        case .monthly: return "Month"
        }
    }

    static func forDisplayedInterval(_ interval: TimeInterval) -> UsageHistoryBucketSize {
        let hours = interval / 3_600
        if hours <= 48 { return .hourly }
        if interval <= 45 * 86_400 { return .daily }
        if interval <= 400 * 86_400 { return .weekly }
        return .monthly
    }

    /// Bucket width for the fixed-length buckets (minutes or hours); nil for calendar buckets.
    private var minuteWidth: Int? {
        switch self {
        case .fiveMinutes: return 5
        case .fifteenMinutes: return 15
        default: return nil
        }
    }

    private var hourWidth: Int? {
        switch self {
        case .threeHours: return 3
        case .sixHours: return 6
        case .twelveHours: return 12
        default: return nil
        }
    }

    fileprivate func start(of date: Date, calendar: Calendar) -> Date? {
        switch self {
        case .fiveMinutes, .fifteenMinutes:
            guard let minuteStart = calendar.dateInterval(of: .minute, for: date)?.start else {
                return nil
            }
            var components = calendar.dateComponents(
                [.year, .month, .day, .hour, .minute],
                from: minuteStart
            )
            let width = minuteWidth ?? 5
            components.minute = (components.minute ?? 0) / width * width
            components.second = 0
            return calendar.date(from: components)
        case .threeHours, .sixHours, .twelveHours:
            // Fixed-width buckets aligned to the start of the local day (00, 03, 06 … for 3 h).
            var components = calendar.dateComponents([.year, .month, .day, .hour], from: date)
            let width = hourWidth ?? 1
            components.hour = (components.hour ?? 0) / width * width
            return calendar.date(from: components)
        case .hourly:
            return calendar.dateInterval(of: .hour, for: date)?.start
        case .daily:
            return calendar.dateInterval(of: .day, for: date)?.start
        case .weekly:
            return calendar.dateInterval(of: .weekOfYear, for: date)?.start
        case .monthly:
            return calendar.dateInterval(of: .month, for: date)?.start
        }
    }

    fileprivate func next(after date: Date, calendar: Calendar) -> Date? {
        switch self {
        case .fiveMinutes, .fifteenMinutes:
            return calendar.date(byAdding: .minute, value: minuteWidth ?? 5, to: date)
        case .hourly:
            return calendar.date(byAdding: .hour, value: 1, to: date)
        case .threeHours, .sixHours, .twelveHours:
            return calendar.date(byAdding: .hour, value: hourWidth ?? 1, to: date)
        case .daily:
            return calendar.date(byAdding: .day, value: 1, to: date)
        case .weekly:
            return calendar.date(byAdding: .weekOfYear, value: 1, to: date)
        case .monthly:
            return calendar.date(byAdding: .month, value: 1, to: date)
        }
    }
}

enum UsageHistoryBucketSelection: String, CaseIterable, Identifiable, Hashable {
    case automatic
    case fiveMinutes
    case fifteenMinutes
    case hourly
    case threeHours
    case sixHours
    case twelveHours
    case daily
    case weekly
    case monthly

    var id: String { rawValue }

    var label: String {
        switch self {
        case .automatic: return "Auto"
        case .fiveMinutes: return UsageHistoryBucketSize.fiveMinutes.label
        case .fifteenMinutes: return UsageHistoryBucketSize.fifteenMinutes.label
        case .hourly: return UsageHistoryBucketSize.hourly.label
        case .threeHours: return UsageHistoryBucketSize.threeHours.label
        case .sixHours: return UsageHistoryBucketSize.sixHours.label
        case .twelveHours: return UsageHistoryBucketSize.twelveHours.label
        case .daily: return UsageHistoryBucketSize.daily.label
        case .weekly: return UsageHistoryBucketSize.weekly.label
        case .monthly: return UsageHistoryBucketSize.monthly.label
        }
    }

    var bucketSize: UsageHistoryBucketSize? {
        switch self {
        case .automatic: return nil
        case .fiveMinutes: return .fiveMinutes
        case .fifteenMinutes: return .fifteenMinutes
        case .hourly: return .hourly
        case .threeHours: return .threeHours
        case .sixHours: return .sixHours
        case .twelveHours: return .twelveHours
        case .daily: return .daily
        case .weekly: return .weekly
        case .monthly: return .monthly
        }
    }
}

enum UsageHistoryChartStyle: String, CaseIterable, Identifiable, Hashable {
    case area
    case bars

    var id: String { rawValue }

    var label: String {
        switch self {
        case .area: return "Area"
        case .bars: return "Bars"
        }
    }
}

struct UsageHistoryFilterState: Equatable, Hashable {
    var models: Set<String> = []
    var projects: Set<String> = []
    /// The configured panel-specific dimension: endpoint, source, or account.
    /// An empty set means "All".
    var secondary: Set<String> = []
}

struct UsageHistoryFilterOptions: Equatable {
    var models: [String] = []
    var projects: [String] = []
    var secondary: [String] = []
}

struct UsageHistoryPanelConfiguration: Equatable {
    let provider: CodexLogUsageProvider
    let collapseID: String
    let costLabel: String
    let groupings: [UsageHistoryGrouping]
    let filterGrouping: UsageHistoryGrouping?

    static let azure = UsageHistoryPanelConfiguration(
        provider: .azure,
        collapseID: AccountTrackerViewModel.CollapsibleSection.azureUsageHistory,
        costLabel: "Estimated cost",
        groupings: [.model, .project, .endpoint],
        filterGrouping: .endpoint
    )

    static let openAI = UsageHistoryPanelConfiguration(
        provider: .openai,
        collapseID: AccountTrackerViewModel.CollapsibleSection.openAIUsageHistory,
        costLabel: "Estimated cost",
        groupings: [.model, .project],
        filterGrouping: nil
    )

    static let claudeCode = UsageHistoryPanelConfiguration(
        provider: .claudeCode,
        collapseID: AccountTrackerViewModel.CollapsibleSection.claudeCodeUsageHistory,
        costLabel: "Estimated cost",
        groupings: [.model, .project, .source],
        filterGrouping: .source
    )

    static let claudeAzure = UsageHistoryPanelConfiguration(
        provider: .claudeAzure,
        collapseID: AccountTrackerViewModel.CollapsibleSection.claudeAzureUsageHistory,
        costLabel: "Estimated cost",
        groupings: [.model, .project, .account],
        filterGrouping: .account
    )

    static let lmStudio = UsageHistoryPanelConfiguration(
        provider: .lmStudio,
        collapseID: AccountTrackerViewModel.CollapsibleSection.lmStudioUsageHistory,
        costLabel: "Estimated savings",
        groupings: [.model, .project, .source],
        filterGrouping: .source
    )

    static let openWebUI = UsageHistoryPanelConfiguration(
        provider: .openWebUI,
        collapseID: AccountTrackerViewModel.CollapsibleSection.openWebUIUsageHistory,
        costLabel: "Estimated savings",
        groupings: [.model, .project, .source],
        filterGrouping: .source
    )
}

struct UsageHistoryPoint: Equatable, Identifiable {
    let date: Date
    let totals: AzureUsageTokenTotals
    let value: Double

    var id: Date { date }
}

struct UsageHistorySeries: Equatable, Identifiable {
    let id: String
    let name: String
    let totals: AzureUsageTokenTotals
    let points: [UsageHistoryPoint]
}

struct UsageHistoryResult: Equatable {
    let bucketSize: UsageHistoryBucketSize
    let effectiveStartDate: Date?
    let effectiveEndDate: Date
    let series: [UsageHistorySeries]

    static func empty(endDate: Date, bucketSize: UsageHistoryBucketSize = .hourly) -> UsageHistoryResult {
        UsageHistoryResult(
            bucketSize: bucketSize,
            effectiveStartDate: nil,
            effectiveEndDate: endDate,
            series: []
        )
    }
}

struct UsageHistoryBuilder {
    let calendar: Calendar

    init(calendar: Calendar = .current) {
        self.calendar = calendar
    }

    func build(
        records: [AzureUsageRecord],
        startDate: Date?,
        endDate: Date,
        configuration: UsageHistoryPanelConfiguration,
        metric: UsageHistoryMetric = .totalTokens,
        grouping: UsageHistoryGrouping = .model,
        filters: UsageHistoryFilterState = UsageHistoryFilterState(),
        bucketSize requestedBucketSize: UsageHistoryBucketSize? = nil
    ) -> UsageHistoryResult {
        let rangeStart: Date?
        if let startDate {
            rangeStart = startDate
        } else {
            rangeStart = records
                .filter { $0.timestamp <= endDate }
                .map(\.timestamp)
                .min()
        }

        guard let rangeStart, rangeStart <= endDate else {
            return .empty(endDate: endDate)
        }

        let bucketSize = requestedBucketSize ?? UsageHistoryBucketSize.forDisplayedInterval(
            endDate.timeIntervalSince(rangeStart)
        )
        guard let bucketStarts = makeBucketStarts(
            from: rangeStart,
            through: endDate,
            bucketSize: bucketSize
        ) else {
            return .empty(endDate: endDate, bucketSize: bucketSize)
        }

        var aggregates: [String: Aggregate] = [:]
        for record in records {
            guard record.timestamp >= rangeStart, record.timestamp <= endDate else { continue }
            guard matchesFilters(record, filters: filters, configuration: configuration) else { continue }
            guard let bucket = bucketSize.start(of: record.timestamp, calendar: calendar) else { continue }

            let label = Self.displayValue(for: record, grouping: grouping)
            var aggregate = aggregates[label] ?? Aggregate(label: label)
            aggregate.add(
                record.usage,
                pricing: AzureModelPricing.defaultPricing(for: record.model, provider: configuration.provider),
                bucket: bucket
            )
            aggregates[label] = aggregate
        }

        guard !aggregates.isEmpty else {
            return UsageHistoryResult(
                bucketSize: bucketSize,
                effectiveStartDate: rangeStart,
                effectiveEndDate: endDate,
                series: []
            )
        }

        let sortedAggregates = aggregates.values.sorted { lhs, rhs in
            let leftValue = metric.value(from: lhs.totals)
            let rightValue = metric.value(from: rhs.totals)
            if leftValue != rightValue { return leftValue > rightValue }
            return lhs.label.localizedCaseInsensitiveCompare(rhs.label) == .orderedAscending
        }
        let top = Array(sortedAggregates.prefix(8))
        let remainder = Array(sortedAggregates.dropFirst(8))

        var series = top.map {
            makeSeries(
                label: $0.label,
                totals: $0.totals,
                bucketTotals: $0.bucketTotals,
                buckets: bucketStarts,
                metric: metric
            )
        }

        if !remainder.isEmpty {
            var otherTotals = AzureUsageTokenTotals()
            var otherBucketTotals: [Date: AzureUsageTokenTotals] = [:]
            for aggregate in remainder {
                add(aggregate.totals, to: &otherTotals)
                for (bucket, totals) in aggregate.bucketTotals {
                    var bucketTotal = otherBucketTotals[bucket] ?? AzureUsageTokenTotals()
                    add(totals, to: &bucketTotal)
                    otherBucketTotals[bucket] = bucketTotal
                }
            }
            series.append(
                makeSeries(
                    label: "Other",
                    totals: otherTotals,
                    bucketTotals: otherBucketTotals,
                    buckets: bucketStarts,
                    metric: metric,
                    id: "other"
                )
            )
        }

        return UsageHistoryResult(
            bucketSize: bucketSize,
            effectiveStartDate: rangeStart,
            effectiveEndDate: endDate,
            series: series
        )
    }

    func filterOptions(
        records: [AzureUsageRecord],
        startDate: Date?,
        endDate: Date,
        configuration: UsageHistoryPanelConfiguration
    ) -> UsageHistoryFilterOptions {
        let rangeStart = startDate ?? records
            .filter { $0.timestamp <= endDate }
            .map(\.timestamp)
            .min()

        let inRange = records.filter { record in
            guard let rangeStart else { return false }
            return record.timestamp >= rangeStart && record.timestamp <= endDate
        }
        return UsageHistoryFilterOptions(
            models: values(in: inRange, grouping: .model),
            projects: values(in: inRange, grouping: .project),
            secondary: configuration.filterGrouping.map { values(in: inRange, grouping: $0) } ?? []
        )
    }

    static func displayValue(for record: AzureUsageRecord, grouping: UsageHistoryGrouping) -> String {
        switch grouping {
        case .model:
            return record.model.isEmpty ? AzureUsageScanner.unknownModel : record.model
        case .project:
            return AzureUsageScanner.historyProjectLabel(for: record)
        case .endpoint, .source:
            let endpoint = record.endpoint.isEmpty ? AzureUsageScanner.unknownEndpoint : record.endpoint
            let resource = record.resource.isEmpty ? AzureUsageScanner.unknownResource : record.resource
            return "\(endpoint) • \(resource)"
        case .account:
            return record.resource.isEmpty ? AzureUsageScanner.unknownResource : record.resource
        }
    }

    private func matchesFilters(
        _ record: AzureUsageRecord,
        filters: UsageHistoryFilterState,
        configuration: UsageHistoryPanelConfiguration
    ) -> Bool {
        if !filters.models.isEmpty, !filters.models.contains(Self.displayValue(for: record, grouping: .model)) {
            return false
        }
        if !filters.projects.isEmpty, !filters.projects.contains(Self.displayValue(for: record, grouping: .project)) {
            return false
        }
        if let filterGrouping = configuration.filterGrouping,
           !filters.secondary.isEmpty,
           !filters.secondary.contains(Self.displayValue(for: record, grouping: filterGrouping)) {
            return false
        }
        return true
    }

    private func values(in records: [AzureUsageRecord], grouping: UsageHistoryGrouping) -> [String] {
        Set(records.map { Self.displayValue(for: $0, grouping: grouping) })
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    private func makeBucketStarts(
        from startDate: Date,
        through endDate: Date,
        bucketSize: UsageHistoryBucketSize
    ) -> [Date]? {
        guard let first = bucketSize.start(of: startDate, calendar: calendar),
              let last = bucketSize.start(of: endDate, calendar: calendar),
              first <= last
        else { return nil }

        var buckets: [Date] = []
        var current = first
        while current <= last {
            buckets.append(current)
            guard let next = bucketSize.next(after: current, calendar: calendar), next > current else {
                break
            }
            current = next
        }
        return buckets
    }

    private func makeSeries(
        label: String,
        totals: AzureUsageTokenTotals,
        bucketTotals: [Date: AzureUsageTokenTotals],
        buckets: [Date],
        metric: UsageHistoryMetric,
        id: String? = nil
    ) -> UsageHistorySeries {
        UsageHistorySeries(
            id: id ?? "series:\(label)",
            name: label,
            totals: totals,
            points: buckets.map { bucket in
                let bucketTotal = bucketTotals[bucket] ?? AzureUsageTokenTotals()
                return UsageHistoryPoint(
                    date: bucket,
                    totals: bucketTotal,
                    value: metric.value(from: bucketTotal)
                )
            }
        )
    }

    private func add(_ source: AzureUsageTokenTotals, to destination: inout AzureUsageTokenTotals) {
        destination.inputTokens += source.inputTokens
        destination.cachedInputTokens += source.cachedInputTokens
        destination.cacheCreationInputTokens += source.cacheCreationInputTokens
        destination.uncachedInputTokens += source.uncachedInputTokens
        destination.outputTokens += source.outputTokens
        destination.reasoningOutputTokens += source.reasoningOutputTokens
        destination.totalTokens += source.totalTokens
        destination.eventCount += source.eventCount
        destination.estimatedCostUSD += source.estimatedCostUSD
    }

    private struct Aggregate {
        let label: String
        var totals = AzureUsageTokenTotals()
        var bucketTotals: [Date: AzureUsageTokenTotals] = [:]

        mutating func add(_ usage: AzureTokenUsage, pricing: AzureModelPricing, bucket: Date) {
            totals.add(usage, pricing: pricing)
            var bucketTotal = bucketTotals[bucket] ?? AzureUsageTokenTotals()
            bucketTotal.add(usage, pricing: pricing)
            bucketTotals[bucket] = bucketTotal
        }
    }
}

/// Axis maths for the history chart, kept free of SwiftUI so it can be tested.
enum UsageHistoryAxis {
    /// Highest *stacked* total across the buckets.
    ///
    /// The chart stacks its series, so the tallest thing drawn at any bucket is
    /// the sum of the visible series there, not the tallest single series. Every
    /// series carries the same bucket array in the same order (see
    /// `UsageHistoryBuilder.makeSeries`), so comparing by index is safe.
    static func stackedMaximum(of series: [UsageHistorySeries]) -> Double {
        let bucketCount = series.map(\.points.count).max() ?? 0
        guard bucketCount > 0 else { return 0 }

        var highest = 0.0
        for index in 0..<bucketCount {
            var stacked = 0.0
            for one in series where index < one.points.count {
                stacked += max(0, one.points[index].value)
            }
            highest = max(highest, stacked)
        }
        return highest
    }

    /// Top of the y scale: the stacked maximum plus a little headroom, so the
    /// tallest stack never sits flush against the top of the plot.
    static func upperBound(for maximum: Double) -> Double {
        guard maximum.isFinite, maximum > 0 else { return 1 }
        return maximum * 1.05
    }

    /// Axis-sized number: `18.4M` rather than `1,84E7`.
    static func compactValue(
        _ value: Double,
        locale: Locale = .autoupdatingCurrent
    ) -> String {
        guard value.isFinite else { return "" }
        let magnitude = abs(value)
        switch magnitude {
        case 1_000_000_000...:
            return trimmed(value / 1_000_000_000, locale: locale) + "B"
        case 1_000_000...:
            return trimmed(value / 1_000_000, locale: locale) + "M"
        case 1_000...:
            return trimmed(value / 1_000, locale: locale) + "K"
        default:
            return trimmed(value, locale: locale)
        }
    }

    /// Axis-sized money, using the same compaction as tokens.
    static func compactCost(
        _ value: Double,
        locale: Locale = .autoupdatingCurrent
    ) -> String {
        "$" + compactValue(value, locale: locale)
    }

    private static func trimmed(_ value: Double, locale: Locale) -> String {
        let rounded = (value * 10).rounded() / 10
        let fractionDigits = rounded == rounded.rounded() ? 0 : 1
        return rounded.formatted(
            .number.precision(.fractionLength(fractionDigits)).locale(locale)
        )
    }
}

/// Which categorical colour slot each series gets.
///
/// Slots are handed out by the series' position in the full result, so two
/// series can never land on the same colour and hiding one never repaints the
/// others. The roll-up row keeps a reserved neutral slot of its own.
enum UsageHistorySeriesPalette {
    static let otherSeriesID = "other"
    /// Sentinel for the reserved neutral used by the roll-up row.
    static let otherSlot = -1
    /// `UsageHistoryBuilder` caps a result at this many named series plus "Other".
    static let slotCount = 8

    static func slotAssignments(for series: [UsageHistorySeries]) -> [String: Int] {
        var assignments: [String: Int] = [:]
        var nextSlot = 0
        for one in series {
            if one.id == otherSeriesID {
                assignments[one.id] = otherSlot
            } else {
                assignments[one.id] = min(nextSlot, slotCount - 1)
                nextSlot += 1
            }
        }
        return assignments
    }
}
