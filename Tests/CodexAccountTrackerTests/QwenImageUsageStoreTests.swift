import SQLite3
import XCTest
@testable import CodexAccountTracker

final class QwenImageUsageStoreTests: XCTestCase {
    /// Shape of one Open WebUI `file.meta` JSON for a picture returned by the
    /// ComfyUI image engine. The prompt text lives in `data.prompt` and in the
    /// workflow's node 4; the store must never copy either into a record.
    private func meta(edit: Bool = true, width: Int = 1024, height: Int = 1024, steps: Int = 25,
                      unet: String = "qwen-image-2.1-Q8_0.gguf", workflowAsString: Bool = true) -> String {
        var graph: [String: Any] = [
            "1": ["class_type": "UnetLoaderGGUF", "inputs": ["unet_name": unet]],
            "4": ["class_type": "TextEncodeQwenImage21", "inputs": ["prompt": "SECRET PROMPT", "resolution": 1024]],
            "6": ["class_type": "KSampler", "inputs": ["seed": 7, "steps": steps, "cfg": 1.0]],
            "8": ["class_type": "SaveImage", "inputs": ["filename_prefix": "edits/qwen_2_1"]],
        ]
        if edit { graph["5"] = ["class_type": "LoadImage", "inputs": ["image": "src.png [output]"]] }
        let graphValue: Any = workflowAsString
            ? String(decoding: try! JSONSerialization.data(withJSONObject: graph), as: UTF8.self)
            : graph
        var data: [String: Any] = [
            "prompt": "SECRET PROMPT", "width": width, "height": height,
            "workflow": ["workflow": graphValue, "nodes": []],
        ]
        if edit { data["image"] = "/api/v1/files/abc/content" } else { data["n"] = 1; data["steps"] = steps }
        let object: [String: Any] = [
            "name": "generated-image.png", "content_type": "image/png", "size": 2_321_660,
            "file_hash": "3d47", "data": data,
        ]
        return String(decoding: try! JSONSerialization.data(withJSONObject: object), as: UTF8.self)
    }

    func testEditBecomesOneImageRecordWithoutPromptText() {
        let record = QwenImageUsageStore.record(
            fileID: "ac2bf260", fileName: "generated-image.png", createdAt: 1_790_082_269,
            meta: meta(), chatID: "chat-9", filePath: "/tmp/webui.db"
        )
        let r = try! XCTUnwrap(record)
        XCTAssertEqual(r.id, "qwen-image-ac2bf260")
        XCTAssertEqual(r.sessionID, "chat-9")
        XCTAssertEqual(r.endpoint, "Open WebUI")
        XCTAssertEqual(r.resource, "edit · 1024×1024 · 25 steps")
        XCTAssertEqual(r.model, "qwen-image-2.1-Q8_0.gguf")
        XCTAssertEqual(r.projectPath, QwenImageUsageStore.chatProject)
        XCTAssertEqual(r.usage.imageCount, 1)
        XCTAssertEqual(r.usage.totalTokens, 0)
        XCTAssertEqual(r.timestamp.timeIntervalSince1970, 1_790_082_269, accuracy: 0.001)
        let encoded = String(decoding: try! JSONEncoder().encode(r), as: UTF8.self)
        XCTAssertFalse(encoded.contains("SECRET"), "prompt text must never reach a record")
    }

    func testGenerationKindAndDictWorkflowAndUnlinkedChat() {
        let r = try! XCTUnwrap(QwenImageUsageStore.record(
            fileID: "f", fileName: "generated-image.png", createdAt: 1_790_000_000,
            meta: meta(edit: false, width: 512, height: 512, steps: 20, workflowAsString: false),
            chatID: nil, filePath: "/tmp/webui.db"
        ))
        XCTAssertEqual(r.resource, "generate · 512×512 · 20 steps")
        XCTAssertEqual(r.sessionID, QwenImageUsageStore.unlinkedSession)
    }

    func testUploadsUndatedAndMalformedRowsAreSkipped() {
        XCTAssertNil(QwenImageUsageStore.record(
            fileID: "u", fileName: "image.png", createdAt: 1_790_000_000, meta: meta(), chatID: nil, filePath: "/tmp/webui.db"
        ), "a user upload is not a generated picture")
        XCTAssertNil(QwenImageUsageStore.record(
            fileID: "g", fileName: "generated-image.png", createdAt: 0, meta: meta(), chatID: nil, filePath: "/tmp/webui.db"
        ))
        XCTAssertNil(QwenImageUsageStore.record(
            fileID: "g", fileName: "generated-image.png", createdAt: 1_790_000_000, meta: "not json", chatID: nil, filePath: "/tmp/webui.db"
        ))
    }

    func testMissingWorkflowStillCountsThePictureWithUnknownModel() {
        let r = try! XCTUnwrap(QwenImageUsageStore.record(
            fileID: "g", fileName: "generated-image.png", createdAt: 1_790_000_000,
            meta: #"{"name":"generated-image.png","data":{"width":1024,"height":1024}}"#,
            chatID: nil, filePath: "/tmp/webui.db"
        ))
        XCTAssertEqual(r.model, QwenImageUsageStore.unknownModel)
        XCTAssertEqual(r.resource, "generate · 1024×1024")
        XCTAssertEqual(r.usage.imageCount, 1)
    }

    func testChatIDsAreFoundThroughChatHistoryFiles() {
        let chat: [String: Any] = [
            "history": ["messages": [
                "a1": ["role": "assistant", "files": [["type": "image", "id": "file-1", "name": "generated-image.png"]]],
                "u1": ["role": "user"],
            ]],
        ]
        let json = String(decoding: try! JSONSerialization.data(withJSONObject: chat), as: UTF8.self)
        let map = QwenImageUsageStore.chatIDsByFileID(fromChatRows: [(id: "chat-1", chat: json), (id: "bad", chat: "{")])
        XCTAssertEqual(map, ["file-1": "chat-1"])
    }

    func testImagePricingAtFalReferenceRate() {
        let pricing = AzureModelPricing.defaultPricing(for: "qwen-image-2.1-Q8_0.gguf", provider: .qwenImage)
        XCTAssertTrue(pricing.isKnown)
        XCTAssertEqual(pricing.perImageUSD, 0.035)
        XCTAssertEqual(pricing.rateSummary, "$0.035/image")
        let one = AzureTokenUsage(inputTokens: 0, cachedInputTokens: 0, outputTokens: 0, reasoningOutputTokens: 0, totalTokens: 0, imageCount: 1)
        XCTAssertEqual(pricing.estimatedCost(for: one), 0.035, accuracy: 0.000001)
        XCTAssertFalse(AzureModelPricing.defaultPricing(for: "some-other.safetensors", provider: .qwenImage).isKnown)
        // Text presets are untouched by the image field.
        let astra = AzureModelPricing.defaultPricing(for: "gpt-6-astra", provider: .azure)
        XCTAssertNil(astra.perImageUSD)
    }

    func testTotalsAndChartMetricCountImages() {
        var totals = AzureUsageTokenTotals()
        let pricing = AzureModelPricing.defaultPricing(for: "qwen-image-2.1-Q8_0.gguf", provider: .qwenImage)
        for _ in 0..<3 {
            totals.add(AzureTokenUsage(inputTokens: 0, cachedInputTokens: 0, outputTokens: 0, reasoningOutputTokens: 0, totalTokens: 0, imageCount: 1), pricing: pricing)
        }
        XCTAssertEqual(totals.imageCount, 3)
        XCTAssertEqual(totals.eventCount, 3)
        XCTAssertEqual(totals.estimatedCostUSD, 0.105, accuracy: 0.000001)
        XCTAssertEqual(UsageHistoryMetric.images.value(from: totals), 3)
        XCTAssertEqual(UsageHistoryPanelConfiguration.qwenImage.defaultMetric, .images)
        XCTAssertEqual(UsageHistoryPanelConfiguration.lmStudio.defaultMetric, .totalTokens)
    }

    func testOldCachesDecodeWithoutImageFields() throws {
        let json = #"{"inputTokens":10,"cachedInputTokens":0,"outputTokens":5,"reasoningOutputTokens":0,"totalTokens":15}"#
        let usage = try JSONDecoder().decode(AzureTokenUsage.self, from: Data(json.utf8))
        XCTAssertEqual(usage.imageCount, 0)
        XCTAssertEqual(usage.signature, "10,0,0,5,0,15", "dedupe signature must not change")
    }

    func testProviderLabels() {
        XCTAssertEqual(CodexLogUsageProvider.qwenImage.rawValue, "qwen-image")
        XCTAssertEqual(CodexLogUsageProvider.qwenImage.displayName, "Qwen Image")
        XCTAssertEqual(CodexLogUsageProvider.qwenImage.sessionCounterLabel, "Qwen Image chats")
        XCTAssertEqual(CodexLogUsageProvider.qwenImage.costLabel, "Est. saved")
    }

    func testScanReadsFileAndChatTablesFromSQLite() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("qwen-image-store-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let dbURL = directory.appendingPathComponent("webui.db")

        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(dbURL.path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        XCTAssertEqual(sqlite3_exec(db, "CREATE TABLE file (id VARCHAR NOT NULL, user_id VARCHAR, filename TEXT, meta JSON, created_at BIGINT, hash TEXT, data JSON, updated_at BIGINT, path TEXT, PRIMARY KEY (id))", nil, nil, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(db, "CREATE TABLE chat (id VARCHAR NOT NULL, user_id VARCHAR, title TEXT, chat JSON, PRIMARY KEY (id))", nil, nil, nil), SQLITE_OK)
        let m = meta().replacingOccurrences(of: "'", with: "''")
        XCTAssertEqual(sqlite3_exec(db, "INSERT INTO file (id, filename, meta, created_at) VALUES ('file-1', 'generated-image.png', '\(m)', 1790082269)", nil, nil, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(db, "INSERT INTO file (id, filename, meta, created_at) VALUES ('file-2', 'image.png', '{\"data\":{}}', 1790082200)", nil, nil, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(db, "INSERT INTO file (id, filename, meta, created_at) VALUES ('file-3', 'generated-image.png', 'broken', 1790082300)", nil, nil, nil), SQLITE_OK)
        let chat = #"{"history":{"messages":{"a1":{"role":"assistant","files":[{"type":"image","id":"file-1"}]}}}}"#
        XCTAssertEqual(sqlite3_exec(db, "INSERT INTO chat VALUES ('chat-1', 'u', 't', '\(chat)')", nil, nil, nil), SQLITE_OK)

        let result = QwenImageUsageStore(databaseURL: dbURL).scan()
        XCTAssertEqual(result.provider, .qwenImage)
        XCTAssertEqual(result.records.count, 1)
        XCTAssertEqual(result.records[0].sessionID, "chat-1")
        XCTAssertEqual(result.records[0].usage.imageCount, 1)
        XCTAssertEqual(result.summary.malformedEventsSkipped, 1)
        XCTAssertEqual(result.summary.sessionsScanned, 1)
        XCTAssertTrue(result.summary.warnings.isEmpty)
    }

    func testMissingDatabaseIsEmptyWithoutWarnings() {
        let result = QwenImageUsageStore(databaseURL: URL(fileURLWithPath: "/nonexistent/webui.db")).scan()
        XCTAssertTrue(result.records.isEmpty)
        XCTAssertTrue(result.summary.warnings.isEmpty)
    }
}
