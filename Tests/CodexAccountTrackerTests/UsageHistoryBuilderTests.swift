import Foundation
import XCTest
@testable import CodexAccountTracker

final class UsageHistoryBuilderTests: XCTestCase {
    private var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private func date(_ value: String) -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.date(from: value)!
    }

    private func record(
        _ id: String,
        at timestamp: Date,
        model: String = "gpt-5.6-luna",
        project: String = "Project A",
        endpoint: String = "Azure",
        resource: String = "resource-a",
        usage: AzureTokenUsage = AzureTokenUsage(
            inputTokens: 100,
            cachedInputTokens: 20,
            cacheCreationInputTokens: 10,
            outputTokens: 50,
            reasoningOutputTokens: 0,
            totalTokens: 150
        )
    ) -> AzureUsageRecord {
        AzureUsageRecord(
            id: id,
            sessionID: id,
            filePath: "/tmp/\(id).jsonl",
            timestamp: timestamp,
            endpoint: endpoint,
            resource: resource,
            deployment: model,
            model: model,
            projectPath: "/projects/\(project)",
            projectName: project,
            usage: usage
        )
    }

    private func build(
        _ records: [AzureUsageRecord],
        start: Date,
        end: Date,
        configuration: UsageHistoryPanelConfiguration = .azure,
        metric: UsageHistoryMetric = .totalTokens,
        grouping: UsageHistoryGrouping = .model,
        filters: UsageHistoryFilterState = UsageHistoryFilterState(),
        bucketSize: UsageHistoryBucketSize? = nil,
        calendar: Calendar? = nil
    ) -> UsageHistoryResult {
        UsageHistoryBuilder(calendar: calendar ?? utcCalendar).build(
            records: records,
            startDate: start,
            endDate: end,
            configuration: configuration,
            metric: metric,
            grouping: grouping,
            filters: filters,
            bucketSize: bucketSize
        )
    }

    func testManualFiveMinuteBucketsOverrideAutomaticSelection() {
        let start = date("2026-01-01T00:00:00Z")
        let result = build(
            [
                record("first", at: start.addingTimeInterval(2 * 60)),
                record("second", at: start.addingTimeInterval(7 * 60))
            ],
            start: start,
            end: start.addingTimeInterval(10 * 60),
            bucketSize: .fiveMinutes
        )

        XCTAssertEqual(result.bucketSize, .fiveMinutes)
        XCTAssertEqual(result.series[0].points.map(\.date), [
            start,
            start.addingTimeInterval(5 * 60),
            start.addingTimeInterval(10 * 60)
        ])
        XCTAssertEqual(result.series[0].points.map(\.value), [150, 150, 0])
    }

    func testSelectsHourlyDailyWeeklyAndMonthlyBuckets() {
        let start = date("2026-01-01T00:00:00Z")
        XCTAssertEqual(build([record("h", at: start)], start: start, end: start.addingTimeInterval(48 * 3_600)).bucketSize, .hourly)
        XCTAssertEqual(build([record("d", at: start)], start: start, end: start.addingTimeInterval(48 * 3_600 + 1)).bucketSize, .daily)
        XCTAssertEqual(build([record("w", at: start)], start: start, end: start.addingTimeInterval(45 * 86_400 + 1)).bucketSize, .weekly)
        XCTAssertEqual(build([record("m", at: start)], start: start, end: start.addingTimeInterval(400 * 86_400 + 1)).bucketSize, .monthly)
    }

    func testStartBoundaryIsInclusiveAndEarlierRecordsAreExcluded() {
        let start = date("2026-01-01T01:00:00Z")
        let result = build(
            [
                record("before", at: start.addingTimeInterval(-1)),
                record("at-start", at: start),
                record("after", at: start.addingTimeInterval(3_600))
            ],
            start: start,
            end: start.addingTimeInterval(3_600)
        )

        XCTAssertEqual(result.series.count, 1)
        XCTAssertEqual(result.series[0].totals.eventCount, 2)
        XCTAssertEqual(result.series[0].totals.totalTokens, 300)
    }

    func testEveryMetricIsCalculatedFromAggregatedTotals() {
        let start = date("2026-01-01T00:00:00Z")
        let usage = AzureTokenUsage(
            inputTokens: 100,
            cachedInputTokens: 20,
            cacheCreationInputTokens: 10,
            outputTokens: 50,
            reasoningOutputTokens: 0,
            totalTokens: 150
        )
        let input = record("metrics", at: start, usage: usage)
        let pricing = AzureModelPricing.defaultPricing(for: input.model, provider: .azure)
        let expected: [(UsageHistoryMetric, Double)] = [
            (.totalTokens, 150),
            (.inputTokens, 100),
            (.cachedInput, 20),
            (.cacheWrite, 10),
            (.uncachedInput, 70),
            (.outputTokens, 50),
            (.events, 1),
            (.estimatedCost, pricing.estimatedCost(for: usage))
        ]

        for (metric, value) in expected {
            let result = build([input], start: start, end: start, metric: metric)
            XCTAssertEqual(result.series[0].points[0].value, value, accuracy: 0.000001, "\(metric)")
        }
    }

    func testModelProjectAndSecondaryFilters() {
        let start = date("2026-01-01T00:00:00Z")
        let records = [
            record("a", at: start, model: "model-a", project: "Project A", endpoint: "Anthropic", resource: "native"),
            record("b", at: start, model: "model-b", project: "Project B", endpoint: "Azure", resource: "account-b")
        ]

        let modelResult = build(
            records,
            start: start,
            end: start,
            filters: UsageHistoryFilterState(models: ["model-a"], projects: [], secondary: [])
        )
        XCTAssertEqual(modelResult.series[0].name, "model-a")
        XCTAssertEqual(modelResult.series[0].totals.eventCount, 1)

        let projectResult = build(
            records,
            start: start,
            end: start,
            filters: UsageHistoryFilterState(models: [], projects: ["Project B"], secondary: [])
        )
        XCTAssertEqual(projectResult.series[0].totals.eventCount, 1)
        XCTAssertEqual(projectResult.series[0].totals.totalTokens, 150)

        let sourceFilter = UsageHistoryFilterState(
            models: [],
            projects: [],
            secondary: ["Azure • account-b"]
        )
        let sourceResult = build(
            records,
            start: start,
            end: start,
            configuration: .claudeCode,
            grouping: .source,
            filters: sourceFilter
        )
        XCTAssertEqual(sourceResult.series.map(\.name), ["Azure • account-b"])
    }

    func testTopEightPlusOtherConservesAllValues() {
        let start = date("2026-01-01T00:00:00Z")
        let records = (0..<10).map { index in
            record(
                "model-\(index)",
                at: start,
                model: "model-\(index)",
                usage: AzureTokenUsage(
                    inputTokens: index + 1,
                    cachedInputTokens: 0,
                    outputTokens: 0,
                    reasoningOutputTokens: 0,
                    totalTokens: index + 1
                )
            )
        }

        let result = build(records, start: start, end: start)
        XCTAssertEqual(result.series.count, 9)
        XCTAssertEqual(result.series.last?.name, "Other")
        XCTAssertEqual(result.series.last?.totals.totalTokens, 3)
        XCTAssertEqual(result.series.reduce(0) { $0 + $1.totals.totalTokens }, 55)
        XCTAssertEqual(result.series.flatMap(\.points).filter { $0.date == start }.reduce(0) { $0 + Int($1.value) }, 55)
    }

    func testMissingBucketsAreZeroFilledAndChronological() {
        let start = date("2026-01-01T00:00:00Z")
        let result = build(
            [
                record("late", at: start.addingTimeInterval(2 * 3_600)),
                record("early", at: start)
            ],
            start: start,
            end: start.addingTimeInterval(2 * 3_600)
        )

        XCTAssertEqual(result.series[0].points.map(\.date), [
            start,
            start.addingTimeInterval(3_600),
            start.addingTimeInterval(2 * 3_600)
        ])
        XCTAssertEqual(result.series[0].points.map(\.value), [150, 0, 150])
    }

    func testUnknownDimensionValuesRemainRepresented() {
        let start = date("2026-01-01T00:00:00Z")
        let unknown = AzureUsageRecord(
            id: "unknown",
            sessionID: "unknown",
            filePath: "/tmp/unknown.jsonl",
            timestamp: start,
            endpoint: "",
            resource: "",
            deployment: "",
            model: "",
            projectPath: AzureUsageRecord.unknownProject,
            usage: AzureTokenUsage(
                inputTokens: 1,
                cachedInputTokens: 0,
                outputTokens: 1,
                reasoningOutputTokens: 0,
                totalTokens: 2
            )
        )

        XCTAssertEqual(build([unknown], start: start, end: start).series[0].name, AzureUsageScanner.unknownModel)
        XCTAssertEqual(
            build([unknown], start: start, end: start, grouping: .project).series[0].name,
            AzureUsageRecord.unknownProject
        )
        XCTAssertEqual(
            build([unknown], start: start, end: start, grouping: .endpoint).series[0].name,
            "\(AzureUsageScanner.unknownEndpoint) • \(AzureUsageScanner.unknownResource)"
        )
    }

    func testEmptyAndSinglePointHistories() {
        let start = date("2026-01-01T00:00:00Z")
        XCTAssertTrue(build([], start: start, end: start).series.isEmpty)

        let result = build([record("one", at: start)], start: start, end: start)
        XCTAssertEqual(result.series.count, 1)
        XCTAssertEqual(result.series[0].points.count, 1)
    }

    func testAreaAndBarsChartStylesKeepAreaAsDefault() {
        XCTAssertEqual(UsageHistoryChartStyle.allCases, [.area, .bars])
        XCTAssertEqual(UsageHistoryChartStyle.area.label, "Area")
        XCTAssertEqual(UsageHistoryChartStyle.bars.label, "Bars")
    }

    func testEuropeSofiaDaylightSavingTransitionUsesLocalBuckets() {
        var sofia = Calendar(identifier: .gregorian)
        sofia.timeZone = TimeZone(identifier: "Europe/Sofia")!
        let start = sofia.date(from: DateComponents(year: 2026, month: 3, day: 29, hour: 0))!
        let end = sofia.date(from: DateComponents(year: 2026, month: 3, day: 29, hour: 6))!
        let result = build(
            [
                record("dst-a", at: sofia.date(byAdding: .hour, value: 1, to: start)!),
                record("dst-b", at: sofia.date(byAdding: .hour, value: 4, to: start)!)
            ],
            start: start,
            end: end,
            calendar: sofia
        )

        XCTAssertEqual(result.bucketSize, .hourly)
        XCTAssertEqual(result.series[0].points.count, 6)
        XCTAssertEqual(Set(result.series[0].points.map(\.date)).count, 6)
    }

    func testChartTotalsMatchAzureDashboardForSameRange() {
        let start = date("2026-01-01T00:00:00Z")
        let end = date("2026-01-03T00:00:00Z")
        let records = [
            record("one", at: start),
            record("two", at: start.addingTimeInterval(86_400), model: "gpt-5.5")
        ]
        let scanResult = AzureUsageScanResult(provider: .azure, records: records)
        let dashboard = AzureUsageScanner.dashboard(
            from: scanResult,
            window: .sinceDate,
            customStartDate: start,
            now: end
        )
        let history = build(records, start: start, end: end)
        let chartTotals = history.series.reduce(into: AzureUsageTokenTotals()) { total, series in
            total.inputTokens += series.totals.inputTokens
            total.cachedInputTokens += series.totals.cachedInputTokens
            total.cacheCreationInputTokens += series.totals.cacheCreationInputTokens
            total.uncachedInputTokens += series.totals.uncachedInputTokens
            total.outputTokens += series.totals.outputTokens
            total.totalTokens += series.totals.totalTokens
            total.eventCount += series.totals.eventCount
            total.estimatedCostUSD += series.totals.estimatedCostUSD
        }

        XCTAssertEqual(chartTotals.inputTokens, dashboard.totals.inputTokens)
        XCTAssertEqual(chartTotals.cachedInputTokens, dashboard.totals.cachedInputTokens)
        XCTAssertEqual(chartTotals.cacheCreationInputTokens, dashboard.totals.cacheCreationInputTokens)
        XCTAssertEqual(chartTotals.outputTokens, dashboard.totals.outputTokens)
        XCTAssertEqual(chartTotals.totalTokens, dashboard.totals.totalTokens)
        XCTAssertEqual(chartTotals.eventCount, dashboard.totals.eventCount)
        XCTAssertEqual(chartTotals.estimatedCostUSD, dashboard.totals.estimatedCostUSD, accuracy: 0.000001)
    }

    func testClaudeCodeTransformedRecordsRetainDistinctSources() {
        let start = date("2026-01-01T00:00:00Z")
        let records = [
            record("anthropic", at: start, endpoint: "Anthropic", resource: "Claude Code transcripts"),
            record("azure", at: start, endpoint: "Azure", resource: "Codex via Azure"),
            record("desktop", at: start, endpoint: "Anthropic", resource: "Claude Desktop app")
        ]
        let result = build(records, start: start, end: start, configuration: .claudeCode, grouping: .source)
        XCTAssertEqual(Set(result.series.map(\.name)), Set([
            "Anthropic • Claude Code transcripts",
            "Azure • Codex via Azure",
            "Anthropic • Claude Desktop app"
        ]))
    }

    func testClaudeAzureAccountUsesResourceAndLMStudioUsesSavingsWording() {
        let start = date("2026-01-01T00:00:00Z")
        let account = record("account", at: start, endpoint: "Claude Azure", resource: "best02")
        let accountResult = build(
            [account],
            start: start,
            end: start,
            configuration: .claudeAzure,
            grouping: .account
        )
        XCTAssertEqual(accountResult.series[0].name, "best02")
        let accountFiltered = build(
            [
                account,
                record("other-account", at: start, endpoint: "Claude Azure", resource: "ffola")
            ],
            start: start,
            end: start,
            configuration: .claudeAzure,
            filters: UsageHistoryFilterState(models: [], projects: [], secondary: ["best02"])
        )
        XCTAssertEqual(accountFiltered.series[0].totals.eventCount, 1)

        let lmStudioSources = build(
            [
                record("chat", at: start, endpoint: "LM Studio", resource: "Local chat"),
                record("opencode", at: start, endpoint: "LM Studio", resource: "opencode")
            ],
            start: start,
            end: start,
            configuration: .lmStudio,
            grouping: .source
        )
        XCTAssertEqual(Set(lmStudioSources.series.map(\.name)), Set([
            "LM Studio • Local chat",
            "LM Studio • opencode"
        ]))
        XCTAssertEqual(UsageHistoryMetric.estimatedCost.label(costLabel: UsageHistoryPanelConfiguration.lmStudio.costLabel), "Estimated savings")
        XCTAssertEqual(UsageHistoryPanelConfiguration.lmStudio.filterGrouping, .source)
    }

    @MainActor
    func testNestedHistoryCollapseIDsPersistWithoutChangingTopLevelCollapseAllSet() {
        let topLevel = Set(AccountTrackerViewModel.CollapsibleSection.all)
        let history = Set(AccountTrackerViewModel.CollapsibleSection.history)
        XCTAssertTrue(topLevel.isDisjoint(with: history))

        var persisted = topLevel
        persisted.formUnion(history)
        XCTAssertTrue(AccountTrackerViewModel.CollapsibleSection.all.allSatisfy { persisted.contains($0) })
        XCTAssertFalse(AccountTrackerViewModel.CollapsibleSection.all.contains(AccountTrackerViewModel.CollapsibleSection.azureUsageHistory))

        let collapsedWithHistoryOpen = AccountTrackerViewModel.toggledTopLevelCollapseAll([
            AccountTrackerViewModel.CollapsibleSection.azureUsageHistory
        ])
        XCTAssertTrue(collapsedWithHistoryOpen.contains(AccountTrackerViewModel.CollapsibleSection.azureUsageHistory))
        let expandedWithHistoryOpen = AccountTrackerViewModel.toggledTopLevelCollapseAll(collapsedWithHistoryOpen)
        XCTAssertTrue(expandedWithHistoryOpen.contains(AccountTrackerViewModel.CollapsibleSection.azureUsageHistory))
        XCTAssertFalse(AccountTrackerViewModel.areAllTopLevelSectionsCollapsed(expandedWithHistoryOpen))

        let original = AppPreferences.collapsedSections
        defer { AppPreferences.collapsedSections = original }
        AppPreferences.collapsedSections = [AccountTrackerViewModel.CollapsibleSection.azureUsageHistory]
        XCTAssertEqual(AppPreferences.collapsedSections, [AccountTrackerViewModel.CollapsibleSection.azureUsageHistory])
    }
}
