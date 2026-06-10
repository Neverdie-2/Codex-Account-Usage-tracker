# LM Studio Usage Tracking Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Show local LM Studio model usage (Qwen et al.) as a fourth dashboard section alongside Azure, OpenAI Codex, and Claude Code, with an "Est. saved" column priced at Claude Sonnet 4.6 reference rates.

**Architecture:** A new `LMStudioConversationStore` parses `~/.lmstudio/conversations/*.conversation.json` into the existing `AzureUsageRecord`/`AzureUsageScanResult` shapes (full rescan each refresh — files are small). A new `.lmStudio` provider case plugs into the existing pricing, caching, dashboard-building, and section-view machinery. No changes to the scanning internals of `AzureUsageScanner`; only its exhaustive provider switches gain no-op cases.

**Tech Stack:** Swift 5.9 / SwiftPM, SwiftUI, XCTest (new test target), JSONSerialization for the loosely-schema'd conversation files.

**Spec:** `docs/superpowers/specs/2026-06-10-lmstudio-usage-tracking-design.md`

## Verified facts about the LM Studio data (from the real machine)

- Conversations live at `~/.lmstudio/conversations/<epoch-ms>.conversation.json`.
- Shape: top-level `createdAt` (epoch ms), `name`, `lastUsedModel.identifier`, `messages[]`.
- Each message: `{"versions": [...], "currentlySelected": n}`. Each version: `{"type", "role", "senderInfo", "steps"}`. Count **every** version with stats (regenerations each really ran).
- Assistant versions contain `steps[]`; generation steps have `genInfo: {"indexedModelIdentifier", "identifier", "loadModelConfig", "predictionConfig", "stats"}`.
- `genInfo.stats`: `{"stopReason", "tokensPerSecond", "promptTokensCount", "predictedTokensCount", "totalTokensCount", ...draft counts}`. Draft counts are already folded into `predictedTokensCount` — ignore them.
- `step.stepIdentifier` = `"<epoch-ms>-<random double>"` → stable unique ID + timestamp.
- `genInfo.identifier` = model id (e.g. `qwen3.6-27b-uncensored-hauhaucs-balanced`).

## File structure

| File | Action | Responsibility |
|---|---|---|
| `Package.swift` | Modify | Add `CodexAccountTrackerTests` test target |
| `Sources/CodexAccountTracker/AzureUsageModels.swift` | Modify | `.lmStudio` enum case, `costLabel`, LM Studio pricing branch |
| `Sources/CodexAccountTracker/AzureUsageScanner.swift` | Modify | `.lmStudio` cases in the 3 exhaustive provider switches (no-op) |
| `Sources/CodexAccountTracker/LMStudioConversationStore.swift` | Create | Discover + parse conversation files → `AzureUsageScanResult` |
| `Sources/CodexAccountTracker/AccountTrackerViewModel.swift` | Modify | Published dashboard, refresh/rebuild, cache load, report text |
| `Sources/CodexAccountTracker/ContentView.swift` | Modify | `LMStudioUsageSectionView`, `costLabel` plumbing, section placement |
| `Tests/CodexAccountTrackerTests/LMStudioConversationStoreTests.swift` | Create | Fixture parsing tests, directory-scan tests |
| `Tests/CodexAccountTrackerTests/LMStudioPricingTests.swift` | Create | Provider/pricing/costLabel tests |

---

### Task 1: Provider case, pricing branch, costLabel, test target

**Files:**
- Modify: `Package.swift`
- Modify: `Sources/CodexAccountTracker/AzureUsageModels.swift:88-119` (enum), `:328` (pricing)
- Modify: `Sources/CodexAccountTracker/AzureUsageScanner.swift:29-53` (switches)
- Create: `Tests/CodexAccountTrackerTests/LMStudioPricingTests.swift`

- [ ] **Step 1: Add the test target to Package.swift**

Replace the `targets:` array so the file reads:

```swift
// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "CodexAccountTracker",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "CodexAccountTracker", targets: ["CodexAccountTracker"])
    ],
    targets: [
        .executableTarget(
            name: "CodexAccountTracker",
            path: "Sources/CodexAccountTracker"
        ),
        .testTarget(
            name: "CodexAccountTrackerTests",
            dependencies: ["CodexAccountTracker"],
            path: "Tests/CodexAccountTrackerTests"
        )
    ]
)
```

- [ ] **Step 2: Write the failing tests**

Create `Tests/CodexAccountTrackerTests/LMStudioPricingTests.swift`:

```swift
import XCTest
@testable import CodexAccountTracker

final class LMStudioPricingTests: XCTestCase {
    func testLMStudioProviderLabels() {
        XCTAssertEqual(CodexLogUsageProvider.lmStudio.rawValue, "lm-studio")
        XCTAssertEqual(CodexLogUsageProvider.lmStudio.displayName, "LM Studio")
        XCTAssertEqual(CodexLogUsageProvider.lmStudio.sessionCounterLabel, "LM Studio chats")
        XCTAssertEqual(CodexLogUsageProvider.lmStudio.costLabel, "Est. saved")
        XCTAssertEqual(CodexLogUsageProvider.claudeCode.costLabel, "Est. cost")
    }

    func testLMStudioPricingUsesSonnetReferenceRates() {
        let pricing = AzureModelPricing.defaultPricing(
            for: "qwen3.6-27b-uncensored-hauhaucs-balanced",
            provider: .lmStudio
        )
        XCTAssertTrue(pricing.isKnown)
        XCTAssertEqual(pricing.inputPerMillionUSD, 3.00)
        XCTAssertEqual(pricing.outputPerMillionUSD, 15.00)
    }

    func testLMStudioSavingsEstimate() {
        let pricing = AzureModelPricing.defaultPricing(for: "any-local-model", provider: .lmStudio)
        let usage = AzureTokenUsage(
            inputTokens: 1_000_000,
            cachedInputTokens: 0,
            outputTokens: 1_000_000,
            reasoningOutputTokens: 0,
            totalTokens: 2_000_000
        )
        XCTAssertEqual(pricing.estimatedCost(for: usage), 18.00, accuracy: 0.001)
    }
}
```

- [ ] **Step 3: Run tests to verify they fail**

Run: `swift test 2>&1 | tail -5`
Expected: compile FAILURE — `type 'CodexLogUsageProvider' has no member 'lmStudio'` (and no `costLabel`).

- [ ] **Step 4: Implement the enum case + costLabel**

In `Sources/CodexAccountTracker/AzureUsageModels.swift`, replace the `CodexLogUsageProvider` enum body (lines 88–119) with:

```swift
enum CodexLogUsageProvider: String, Equatable, Codable {
    case azure
    case openai
    case claudeCode = "claude-code"
    case lmStudio = "lm-studio"

    var displayName: String {
        switch self {
        case .azure: return "Azure"
        case .openai: return "Codex"
        case .claudeCode: return "Claude Code"
        case .lmStudio: return "LM Studio"
        }
    }

    var sessionCounterLabel: String {
        switch self {
        case .azure: return "Azure sessions"
        case .openai: return "Codex sessions"
        case .claudeCode: return "Claude Code sessions"
        case .lmStudio: return "LM Studio chats"
        }
    }

    /// Title for the money column. Local models cost nothing to run, so the
    /// LM Studio dashboard shows what the same tokens would have cost on a
    /// cloud model instead of an actual spend.
    var costLabel: String {
        switch self {
        case .azure, .openai, .claudeCode: return "Est. cost"
        case .lmStudio: return "Est. saved"
        }
    }

    var unknownEndpointWarning: String {
        switch self {
        case .azure:
            return "Azure endpoint/resource could not be reliably discovered from local logs or safe config metadata; grouped as unknown endpoint."
        case .openai:
            return "OpenAI Codex usage excludes Azure sessions; Azure usage remains in the separate Azure dashboard."
        case .claudeCode, .lmStudio:
            return ""
        }
    }
}
```

- [ ] **Step 5: Implement the pricing branch**

In `AzureUsageModels.swift`, `defaultPricing(for:provider:)` (line ~328), insert **before** the `if provider == .claudeCode || normalized.contains("claude-")` line:

```swift
        if provider == .lmStudio {
            return AzureModelPricing(
                modelPattern: "lm-studio-local",
                displayName: "Local model (Sonnet 4.6 reference rates)",
                inputPerMillionUSD: 3.00,
                cachedInputPerMillionUSD: 0.30,
                cacheWritePerMillionUSD: 3.75,
                outputPerMillionUSD: 15.00,
                isKnown: true
            )
        }
```

(Cache rates are included for completeness; LM Studio records always carry 0 cache tokens.)

- [ ] **Step 6: Satisfy the scanner's exhaustive switches**

In `Sources/CodexAccountTracker/AzureUsageScanner.swift` `scan(since:)` (lines 27–53), add `.lmStudio` cases to the three switches. The scanner is never constructed with `.lmStudio` (records come from `LMStudioConversationStore`), so these are inert:

```swift
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
```

```swift
        let fileURLs = switch provider {
        case .openai, .azure:
            jsonlFileURLs()
        case .claudeCode:
            jsonlFileURLs(since: startDate)
        case .lmStudio:
            [URL]()
        }
```

```swift
        switch provider {
        case .openai, .azure:
            scanCodexLocalSessions(fileURLs: fileURLs, metadata: metadata, eventCutoff: startDate, result: &result, state: &state)
        case .claudeCode:
            scanClaudeCodeSessions(fileURLs: fileURLs, eventCutoff: startDate, result: &result, state: &state)
        case .lmStudio:
            break
        }
```

- [ ] **Step 7: Run tests to verify they pass**

Run: `swift test 2>&1 | tail -5`
Expected: `Test Suite 'All tests' passed` with 3 tests. If the toolchain complains about testing an executable target, stop and report — do not restructure the package without discussion.

- [ ] **Step 8: Commit**

```bash
git add Package.swift Sources/CodexAccountTracker/AzureUsageModels.swift Sources/CodexAccountTracker/AzureUsageScanner.swift Tests/CodexAccountTrackerTests/LMStudioPricingTests.swift
git commit -m "feat: add lm-studio provider with Sonnet-reference savings pricing"
```

---

### Task 2: Conversation parsing — `LMStudioConversationStore.records(fromConversation:)`

**Files:**
- Create: `Sources/CodexAccountTracker/LMStudioConversationStore.swift`
- Create: `Tests/CodexAccountTrackerTests/LMStudioConversationStoreTests.swift`

- [ ] **Step 1: Write the failing tests**

Create `Tests/CodexAccountTrackerTests/LMStudioConversationStoreTests.swift`:

```swift
import XCTest
@testable import CodexAccountTracker

final class LMStudioConversationStoreTests: XCTestCase {
    /// Mirrors the real on-disk shape: one user message, one assistant message
    /// with two versions (a regeneration), each with a generation step.
    static let fixtureJSON = """
    {
      "name": "Qwen chat",
      "createdAt": 1780959551824,
      "lastUsedModel": { "identifier": "huihui-qwen3.6-35b-a3b-abliterated-mtp" },
      "messages": [
        {
          "currentlySelected": 0,
          "versions": [
            { "type": "singleStep", "role": "user", "senderInfo": {"senderName": "user"},
              "steps": [ { "type": "contentBlock", "stepIdentifier": "1780959828218-0.1", "content": [] } ] }
          ]
        },
        {
          "currentlySelected": 1,
          "versions": [
            { "type": "multiStep", "role": "assistant",
              "senderInfo": {"senderName": "qwen3.6-27b-uncensored-hauhaucs-balanced"},
              "steps": [
                { "type": "contentBlock", "stepIdentifier": "1780959836856-0.2",
                  "genInfo": {
                    "identifier": "qwen3.6-27b-uncensored-hauhaucs-balanced",
                    "stats": { "stopReason": "eosFound", "promptTokensCount": 11, "predictedTokensCount": 192, "totalTokensCount": 203 }
                  },
                  "content": [] }
              ] },
            { "type": "multiStep", "role": "assistant",
              "senderInfo": {"senderName": "qwen3.6-27b-uncensored-hauhaucs-balanced"},
              "steps": [
                { "type": "debugInfoBlock", "stepIdentifier": "1780959837000-0.5", "debugInfo": "x" },
                { "type": "contentBlock", "stepIdentifier": "1780959837238-0.3",
                  "genInfo": {
                    "identifier": "qwen3.6-27b-uncensored-hauhaucs-balanced",
                    "stats": { "stopReason": "eosFound", "promptTokensCount": 34, "predictedTokensCount": 233, "totalTokensCount": 267,
                               "totalDraftTokensCount": 100, "acceptedDraftTokensCount": 80 }
                  },
                  "content": [] }
              ] }
          ]
        }
      ]
    }
    """

    private func fixtureConversation() throws -> [String: Any] {
        let object = try JSONSerialization.jsonObject(with: Data(Self.fixtureJSON.utf8))
        return try XCTUnwrap(object as? [String: Any])
    }

    func testParsesEveryAssistantGeneration() throws {
        let records = LMStudioConversationStore.records(
            fromConversation: try fixtureConversation(),
            filePath: "/tmp/1780959551823.conversation.json"
        )
        XCTAssertEqual(records.count, 2, "both versions of the regenerated reply ran for real")

        XCTAssertEqual(records[0].usage.inputTokens, 11)
        XCTAssertEqual(records[0].usage.outputTokens, 192)
        XCTAssertEqual(records[0].usage.totalTokens, 203)
        XCTAssertEqual(records[0].usage.cachedInputTokens, 0)
        XCTAssertEqual(records[0].usage.cacheCreationInputTokens, 0)
        XCTAssertEqual(records[0].model, "qwen3.6-27b-uncensored-hauhaucs-balanced")
        XCTAssertEqual(records[0].endpoint, "LM Studio")
        XCTAssertEqual(records[0].sessionID, "1780959551823")

        XCTAssertEqual(records[1].usage.inputTokens, 34)
        XCTAssertEqual(records[1].usage.outputTokens, 233)
    }

    func testRecordIDsAreStableAndUnique() throws {
        let conversation = try fixtureConversation()
        let a = LMStudioConversationStore.records(fromConversation: conversation, filePath: "/tmp/1780959551823.conversation.json")
        let b = LMStudioConversationStore.records(fromConversation: conversation, filePath: "/tmp/1780959551823.conversation.json")
        XCTAssertEqual(a.map(\.id), b.map(\.id), "rescans must produce identical IDs")
        XCTAssertEqual(Set(a.map(\.id)).count, a.count, "IDs must be unique")
        XCTAssertEqual(a[0].id, "lm-studio-1780959551823-1780959836856-0.2")
    }

    func testTimestampComesFromStepIdentifier() throws {
        let records = LMStudioConversationStore.records(
            fromConversation: try fixtureConversation(),
            filePath: "/tmp/1780959551823.conversation.json"
        )
        XCTAssertEqual(records[0].timestamp.timeIntervalSince1970, 1780959836.856, accuracy: 0.001)
    }

    func testFallsBackToLastUsedModelWhenGenInfoLacksIdentifier() throws {
        var conversation = try fixtureConversation()
        var messages = try XCTUnwrap(conversation["messages"] as? [[String: Any]])
        var versions = try XCTUnwrap(messages[1]["versions"] as? [[String: Any]])
        var steps = try XCTUnwrap(versions[0]["steps"] as? [[String: Any]])
        var genInfo = try XCTUnwrap(steps[0]["genInfo"] as? [String: Any])
        genInfo.removeValue(forKey: "identifier")
        steps[0]["genInfo"] = genInfo
        versions[0]["steps"] = steps
        messages[1]["versions"] = versions
        conversation["messages"] = messages

        let records = LMStudioConversationStore.records(fromConversation: conversation, filePath: "/tmp/x.conversation.json")
        XCTAssertEqual(records[0].model, "huihui-qwen3.6-35b-a3b-abliterated-mtp")
    }

    func testSkipsZeroTokenAndStatlessSteps() throws {
        let conversation: [String: Any] = [
            "createdAt": 1780959551824 as Any,
            "messages": [
                ["versions": [["role": "assistant", "steps": [["type": "contentBlock", "stepIdentifier": "1-0.1"]]]]],
                ["versions": [["role": "assistant", "steps": [[
                    "type": "contentBlock", "stepIdentifier": "2-0.2",
                    "genInfo": ["stats": ["promptTokensCount": 0, "predictedTokensCount": 0]]
                ]]]]]
            ]
        ]
        let records = LMStudioConversationStore.records(fromConversation: conversation, filePath: "/tmp/y.conversation.json")
        XCTAssertTrue(records.isEmpty)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test 2>&1 | tail -5`
Expected: compile FAILURE — `cannot find 'LMStudioConversationStore' in scope`.

- [ ] **Step 3: Implement the store (parsing half)**

Create `Sources/CodexAccountTracker/LMStudioConversationStore.swift`:

```swift
import Foundation

/// Parses LM Studio chat history (~/.lmstudio/conversations/*.conversation.json)
/// into usage records for the LM Studio dashboard. Local generations are free;
/// the dashboard prices them at cloud reference rates as estimated savings.
final class LMStudioConversationStore {
    private let conversationsDirectoryURL: URL
    private let fileManager: FileManager

    init(
        conversationsDirectoryURL: URL = LMStudioConversationStore.defaultConversationsDirectoryURL(),
        fileManager: FileManager = .default
    ) {
        self.conversationsDirectoryURL = conversationsDirectoryURL
        self.fileManager = fileManager
    }

    static let unknownModel = "unknown local model"
    static let chatProject = "LM Studio chats"

    func scan() -> AzureUsageScanResult {
        var result = AzureUsageScanResult(provider: .lmStudio)
        guard let entries = try? fileManager.contentsOfDirectory(
            at: conversationsDirectoryURL,
            includingPropertiesForKeys: nil
        ) else {
            return result // LM Studio not installed or no chats yet — empty, no warnings.
        }

        let conversationFiles = entries
            .filter { $0.lastPathComponent.hasSuffix(".conversation.json") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        result.summary.filesScanned = conversationFiles.count

        for fileURL in conversationFiles {
            guard let data = try? Data(contentsOf: fileURL),
                  let object = try? JSONSerialization.jsonObject(with: data),
                  let conversation = object as? [String: Any]
            else {
                result.summary.malformedEventsSkipped += 1
                result.summary.warnings.append(
                    "Skipped unreadable LM Studio conversation file: \(fileURL.lastPathComponent)"
                )
                continue
            }

            let records = Self.records(fromConversation: conversation, filePath: fileURL.path)
            guard !records.isEmpty else { continue }
            result.summary.sessionsScanned += 1
            result.summary.providerSessions += 1
            for record in records {
                result.records.append(record)
                result.summary.eventsCounted += 1
                result.summary.earliestEvent = Self.minDate(result.summary.earliestEvent, record.timestamp)
                result.summary.latestEvent = Self.maxDate(result.summary.latestEvent, record.timestamp)
            }
        }

        result.records.sort { $0.timestamp < $1.timestamp }
        return result
    }

    /// One record per assistant generation. Every version of a message is
    /// counted — a regeneration is a second real inference pass.
    static func records(fromConversation conversation: [String: Any], filePath: String) -> [AzureUsageRecord] {
        let conversationID = URL(fileURLWithPath: filePath)
            .lastPathComponent
            .replacingOccurrences(of: ".conversation.json", with: "")
        let fallbackModel = ((conversation["lastUsedModel"] as? [String: Any])?["identifier"] as? String)
            ?? unknownModel
        let conversationCreatedAt = (conversation["createdAt"] as? Double).map { Date(timeIntervalSince1970: $0 / 1000) }
        guard let messages = conversation["messages"] as? [[String: Any]] else { return [] }

        var records: [AzureUsageRecord] = []
        for message in messages {
            guard let versions = message["versions"] as? [[String: Any]] else { continue }
            for version in versions {
                guard (version["role"] as? String) == "assistant",
                      let steps = version["steps"] as? [[String: Any]] else { continue }
                for step in steps {
                    guard let genInfo = step["genInfo"] as? [String: Any],
                          let stats = genInfo["stats"] as? [String: Any] else { continue }

                    let promptTokens = (stats["promptTokensCount"] as? Int) ?? 0
                    let predictedTokens = (stats["predictedTokensCount"] as? Int) ?? 0
                    guard promptTokens > 0 || predictedTokens > 0 else { continue }
                    let totalTokens = (stats["totalTokensCount"] as? Int) ?? (promptTokens + predictedTokens)

                    let model = (genInfo["identifier"] as? String) ?? fallbackModel
                    let stepIdentifier = (step["stepIdentifier"] as? String)
                        ?? "index-\(records.count)"
                    let timestamp = Self.timestamp(fromStepIdentifier: stepIdentifier)
                        ?? conversationCreatedAt
                        ?? Date(timeIntervalSince1970: 0)

                    let usage = AzureTokenUsage(
                        inputTokens: promptTokens,
                        cachedInputTokens: 0,
                        cacheCreationInputTokens: 0,
                        outputTokens: predictedTokens,
                        reasoningOutputTokens: 0,
                        totalTokens: totalTokens
                    )
                    records.append(AzureUsageRecord(
                        id: "lm-studio-\(conversationID)-\(stepIdentifier)",
                        sessionID: conversationID,
                        filePath: filePath,
                        timestamp: timestamp,
                        endpoint: "LM Studio",
                        resource: "Local chat",
                        deployment: model,
                        model: model,
                        projectPath: chatProject,
                        projectName: chatProject,
                        usage: usage
                    ))
                }
            }
        }
        return records
    }

    /// stepIdentifier looks like "1780959836856-0.2227165534417883" — epoch ms,
    /// a dash, then a random fraction.
    private static func timestamp(fromStepIdentifier stepIdentifier: String) -> Date? {
        guard let prefix = stepIdentifier.split(separator: "-").first,
              let epochMs = Double(prefix), epochMs > 0
        else { return nil }
        return Date(timeIntervalSince1970: epochMs / 1000)
    }

    private static func minDate(_ a: Date?, _ b: Date) -> Date {
        guard let a else { return b }
        return min(a, b)
    }

    private static func maxDate(_ a: Date?, _ b: Date) -> Date {
        guard let a else { return b }
        return max(a, b)
    }

    static func defaultConversationsDirectoryURL() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".lmstudio/conversations", isDirectory: true)
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test 2>&1 | tail -5`
Expected: PASS (8 tests total across both files).

- [ ] **Step 5: Commit**

```bash
git add Sources/CodexAccountTracker/LMStudioConversationStore.swift Tests/CodexAccountTrackerTests/LMStudioConversationStoreTests.swift
git commit -m "feat: parse LM Studio conversation files into usage records"
```

---

### Task 3: Directory scanning — `LMStudioConversationStore.scan()`

**Files:**
- Modify: `Tests/CodexAccountTrackerTests/LMStudioConversationStoreTests.swift` (append tests)
- (Implementation already landed in Task 2 — these tests lock its behavior.)

- [ ] **Step 1: Write the tests**

Append to `LMStudioConversationStoreTests.swift` inside the class:

```swift
    func testScanMissingDirectoryReturnsEmptyWithoutWarnings() {
        let store = LMStudioConversationStore(
            conversationsDirectoryURL: URL(fileURLWithPath: "/nonexistent/\(UUID().uuidString)")
        )
        let result = store.scan()
        XCTAssertEqual(result.provider, .lmStudio)
        XCTAssertTrue(result.records.isEmpty)
        XCTAssertTrue(result.summary.warnings.isEmpty)
    }

    func testScanSkipsMalformedFileWithWarningAndKeepsGoodFile() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("lmstudio-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        try Data(Self.fixtureJSON.utf8)
            .write(to: dir.appendingPathComponent("1780959551823.conversation.json"))
        try Data("{not json".utf8)
            .write(to: dir.appendingPathComponent("999.conversation.json"))
        try Data("{}".utf8)
            .write(to: dir.appendingPathComponent("ignored.txt"))

        let result = LMStudioConversationStore(conversationsDirectoryURL: dir).scan()

        XCTAssertEqual(result.summary.filesScanned, 2, "only *.conversation.json files count")
        XCTAssertEqual(result.records.count, 2)
        XCTAssertEqual(result.summary.sessionsScanned, 1)
        XCTAssertEqual(result.summary.eventsCounted, 2)
        XCTAssertEqual(result.summary.malformedEventsSkipped, 1)
        XCTAssertEqual(result.summary.warnings.count, 1)
        XCTAssertTrue(result.summary.warnings[0].contains("999.conversation.json"))
        XCTAssertEqual(result.summary.earliestEvent?.timeIntervalSince1970 ?? 0, 1780959836.856, accuracy: 0.001)
        XCTAssertEqual(result.summary.latestEvent?.timeIntervalSince1970 ?? 0, 1780959837.238, accuracy: 0.001)
    }
```

- [ ] **Step 2: Run tests — expect pass (implementation exists); fix `scan()` if any assertion fails**

Run: `swift test 2>&1 | tail -5`
Expected: PASS (10 tests). If a count is off, fix `scan()` in `LMStudioConversationStore.swift` — the tests are the contract.

- [ ] **Step 3: Commit**

```bash
git add Tests/CodexAccountTrackerTests/LMStudioConversationStoreTests.swift
git commit -m "test: lock LM Studio directory scan behavior"
```

---

### Task 4: View model wiring

**Files:**
- Modify: `Sources/CodexAccountTracker/AccountTrackerViewModel.swift`

No new unit tests — this is `@MainActor` SwiftUI plumbing mirroring the three existing providers line-for-line; verification is the build plus Task 5's end-to-end check.

- [ ] **Step 1: Add published state** (after `claudeCodeUsage` / sibling declarations, lines ~16-25)

```swift
    @Published private(set) var lmStudioUsage = AzureUsageDashboard.empty
```
```swift
    @Published private(set) var isLMStudioRefreshing = false
```
```swift
    @Published private(set) var lmStudioLastScannedAt: Date?
```

- [ ] **Step 2: Add scan-mode controls** (after `claudeCodeCustomStartDate`, line ~67)

```swift
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
```

- [ ] **Step 3: Add store + result state** (near `desktopChatStore`, lines ~107-108)

```swift
    private let lmStudioConversationStore = LMStudioConversationStore()
    private var lmStudioScanResult = AzureUsageScanResult(provider: .lmStudio)
```

- [ ] **Step 4: Add refresh + rebuild functions** (after `refreshClaudeCodeUsage()`, line ~341, and after `rebuildClaudeCodeUsageDashboard()`, line ~655)

```swift
    func refreshLMStudioUsage() {
        guard !isLMStudioRefreshing else { return }
        isLMStudioRefreshing = true

        Task { [weak self, lmStudioConversationStore, usageCacheStore] in
            // Conversation files are few and small; a full rescan each time keeps
            // dedupe trivial (the result wholesale-replaces the previous one).
            let result = await Task.detached(priority: .utility) {
                lmStudioConversationStore.scan()
            }.value

            guard let self else { return }
            defer { isLMStudioRefreshing = false }
            let scannedAt = Date()
            lmStudioScanResult = result
            lmStudioLastScannedAt = scannedAt
            usageCacheStore.save(lmStudioScanResult, scannedAt: scannedAt)
            rebuildLMStudioUsageDashboard()
        }
    }
```

```swift
    private func rebuildLMStudioUsageDashboard() {
        lmStudioUsage = AzureUsageScanner.dashboard(
            from: lmStudioScanResult,
            window: lmStudioUsageScanMode.usageWindow,
            customStartDate: lmStudioCustomStartDate,
            now: displayNow
        )
    }
```

- [ ] **Step 5: Load cache at startup** (in `loadUsageCaches()`, after the claude cache block ~line 447)

```swift
        if let lmStudioCache = usageCacheStore.load(provider: .lmStudio) {
            lmStudioScanResult = lmStudioCache.result
            lmStudioLastScannedAt = lmStudioCache.scannedAt
            rebuildLMStudioUsageDashboard()
        }
```

- [ ] **Step 6: Refresh on launch** (in `start()`, after the `if shouldRebuildClaudeCodeUsageCache { ... }` block, line ~224)

```swift
        // LM Studio rescans are cheap (a handful of JSON files) — always refresh on launch.
        refreshLMStudioUsage()
```

- [ ] **Step 7: Add to the selectable report** (in `selectableReportText`, after the Claude Code `appendUsageDashboard` call, line ~178; note the helper's hardcoded "Est. cost" line — parameterize it)

In `appendUsageDashboard(...)` change the signature to add `costLabel: String = "Est. cost"`:

```swift
    private func appendUsageDashboard(
        _ dashboard: AzureUsageDashboard,
        title: String,
        windowLabel: String,
        lastScannedAt: Date?,
        sessionCounterLabel: String,
        costLabel: String = "Est. cost",
        to lines: inout [String]
    ) {
```

and change the cost line inside it to:

```swift
        lines.append("\(costLabel) \(formatUSD(dashboard.totals.estimatedCostUSD))")
```

then insert after the Claude Code block in `selectableReportText`:

```swift
        lines.append("")
        appendUsageDashboard(
            lmStudioUsage,
            title: "LM Studio Usage",
            windowLabel: lmStudioUsageScanMode.label,
            lastScannedAt: lmStudioLastScannedAt,
            sessionCounterLabel: CodexLogUsageProvider.lmStudio.sessionCounterLabel,
            costLabel: CodexLogUsageProvider.lmStudio.costLabel,
            to: &lines
        )
```

- [ ] **Step 8: Build**

Run: `swift build 2>&1 | tail -3`
Expected: `Build complete!`

- [ ] **Step 9: Commit**

```bash
git add Sources/CodexAccountTracker/AccountTrackerViewModel.swift
git commit -m "feat: wire LM Studio usage into the tracker view model"
```

---

### Task 5: Dashboard section UI + end-to-end verification

**Files:**
- Modify: `Sources/CodexAccountTracker/ContentView.swift`

- [ ] **Step 1: Add `costLabel` to `CodexLogUsageSectionView`** (struct at line ~624)

Add the stored property after `sessionCounterLabel`:

```swift
    let costLabel: String
```

Add `costLabel: String = "Est. cost",` to **both** initializers (after the `sessionCounterLabel` parameter) and assign `self.costLabel = costLabel` in both bodies.

Change the cost panel (line ~762) from:

```swift
                AzureUsageCostPanel(title: "Est. cost", value: dashboard.totals.estimatedCostUSD)
```

to:

```swift
                AzureUsageCostPanel(title: costLabel, value: dashboard.totals.estimatedCostUSD)
```

- [ ] **Step 2: Add the section view** (after `ClaudeCodeUsageSectionView`, line ~622)

```swift
private struct LMStudioUsageSectionView: View {
    @EnvironmentObject private var viewModel: AccountTrackerViewModel

    var body: some View {
        CodexLogUsageSectionView(
            title: "LM Studio Usage",
            subtitle: "Local chats from ~/.lmstudio/conversations — free to run; savings vs Sonnet 4.6 cloud rates",
            dashboard: viewModel.lmStudioUsage,
            isRefreshing: viewModel.isLMStudioRefreshing,
            lastScannedAt: viewModel.lmStudioLastScannedAt,
            scanMode: $viewModel.lmStudioUsageScanMode,
            customStartDate: $viewModel.lmStudioCustomStartDate,
            sessionCounterLabel: CodexLogUsageProvider.lmStudio.sessionCounterLabel,
            costLabel: CodexLogUsageProvider.lmStudio.costLabel,
            endpointTableTitle: "By model",
            emptyText: "No LM Studio generations counted yet. Chat with a local model and click Refresh.",
            endpointLabel: { group in
                "\(group.endpoint) • \(group.deployment)"
            },
            refresh: viewModel.refreshLMStudioUsage
        )
    }
}
```

- [ ] **Step 3: Place the section** — at **both** layout call sites (lines ~18 and ~42), after `ClaudeCodeUsageSectionView()`:

```swift
                        LMStudioUsageSectionView()
```

- [ ] **Step 4: Build and run all tests**

Run: `swift build 2>&1 | tail -3 && swift test 2>&1 | tail -3`
Expected: `Build complete!` and all tests passing.

- [ ] **Step 5: End-to-end verification**

```bash
pkill -f "Codex Account Tracker.app" || true
./scripts/package_app.sh
open ".build/Codex Account Tracker.app"
```

Then verify in the running app:
- An "LM Studio Usage" section appears after Claude Code.
- With window "All time" it shows ~109 input / ~770 output tokens (the live conversation file), rows labeled `LM Studio • <qwen model id>`, money column titled "Est. saved".
- `~/Library/Application Support/CodexAccountTracker/lm-studio-usage-cache.json` exists after refresh.

- [ ] **Step 6: Commit**

```bash
git add Sources/CodexAccountTracker/ContentView.swift
git commit -m "feat: add LM Studio dashboard section with Est. saved column"
```

---

## Self-review notes

- Spec coverage: data source/parsing → Tasks 2-3; provider+pricing+costLabel → Task 1; VM/cache → Task 4; UI section → Task 5; error handling → Task 2 step 3 + Task 3 tests; testing → test target in Task 1, fixtures in Tasks 2-3, manual E2E in Task 5. Dedupe-across-rescans is handled by wholesale replacement (full rescan) + stable IDs; no merge path exists for `.lmStudio`.
- Cache filename is `lm-studio-usage-cache.json` (derived from `rawValue`), not `lmstudio-usage-cache.json` as the spec loosely wrote — same mechanism, accepted deviation.
- Type consistency: `costLabel` (enum property, section-view property, report-helper param) used consistently; `LMStudioConversationStore.records(fromConversation:filePath:)` referenced identically in tests and implementation.
