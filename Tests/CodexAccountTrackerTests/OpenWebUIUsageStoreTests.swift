import SQLite3
import XCTest
@testable import CodexAccountTracker

final class OpenWebUIUsageStoreTests: XCTestCase {
    /// Shape of one Open WebUI `chat.chat` JSON: `history.messages` keyed by
    /// message id. The usage block is what Open WebUI 0.11 stores for a
    /// llama.cpp-served turn after `merge_usage` (summed canonical fields plus
    /// the last round's llama.cpp fields).
    private func chat(
        assistantUsage: [String: Any]?,
        timestamp: Any? = 1790059268,
        model: String = "qwen-image-editor",
        role: String = "assistant"
    ) -> [String: Any] {
        var assistant: [String: Any] = [
            "id": "a1", "parentId": "u1", "role": role, "content": "…", "done": true,
            "model": model,
        ]
        if let timestamp { assistant["timestamp"] = timestamp }
        if let assistantUsage { assistant["usage"] = assistantUsage }
        return [
            "id": "chat-1",
            "history": [
                "currentId": "a1",
                "messages": [
                    "u1": ["id": "u1", "role": "user", "content": "…", "timestamp": 1790059200, "childrenIds": ["a1"]],
                    "a1": assistant,
                ],
            ],
        ]
    }

    private let twoRoundUsage: [String: Any] = [
        "cache_n": 8071, "prompt_n": 158, "predicted_n": 56,
        "input_tokens": 16156, "output_tokens": 201, "total_tokens": 16357,
        "prompt_tokens": 8229, "completion_tokens": 56,
    ]

    func testTwoRoundTurnUsesSummedTotalsAndNoCache() {
        let records = OpenWebUIUsageStore.records(
            fromChat: chat(assistantUsage: twoRoundUsage),
            chatID: "chat-1",
            filePath: "/tmp/webui.db",
            modelLabel: "huihui-qwen3.6-35b-a3b-abliterated-ggml-model-q4_k"
        )
        XCTAssertEqual(records.count, 1)
        let r = records[0]
        XCTAssertEqual(r.id, "open-webui-chat-1-a1")
        XCTAssertEqual(r.sessionID, "chat-1")
        XCTAssertEqual(r.endpoint, "Open WebUI")
        XCTAssertEqual(r.resource, "qwen-image-editor")
        XCTAssertEqual(r.model, "huihui-qwen3.6-35b-a3b-abliterated-ggml-model-q4_k")
        XCTAssertEqual(r.projectPath, OpenWebUIUsageStore.chatProject)
        XCTAssertEqual(r.usage.inputTokens, 16156)
        XCTAssertEqual(r.usage.outputTokens, 201)
        XCTAssertEqual(r.usage.totalTokens, 16357)
        // prompt_tokens (8,229) != input_tokens (16,156): two rounds, so the last
        // round's cache_n cannot describe the whole turn.
        XCTAssertEqual(r.usage.cachedInputTokens, 0)
        XCTAssertEqual(r.timestamp.timeIntervalSince1970, 1790059268, accuracy: 0.001)
    }

    func testSingleRoundTurnKeepsCacheHits() {
        let usage: [String: Any] = [
            "cache_n": 8071, "prompt_n": 158, "input_tokens": 8229, "output_tokens": 56,
            "total_tokens": 8285, "prompt_tokens": 8229, "completion_tokens": 56,
        ]
        let r = OpenWebUIUsageStore.records(
            fromChat: chat(assistantUsage: usage), chatID: "c", filePath: "/tmp/webui.db", modelLabel: nil
        )[0]
        XCTAssertEqual(r.usage.cachedInputTokens, 8071)
        XCTAssertEqual(r.usage.inputTokens, 8229)
        // No state file → the Open WebUI profile id is the only model label available.
        XCTAssertEqual(r.model, "qwen-image-editor")
    }

    func testFallsBackToLlamaCppFieldsWhenCanonicalMissing() {
        let usage: [String: Any] = ["prompt_tokens": 100, "completion_tokens": 20, "cache_n": 40]
        let r = OpenWebUIUsageStore.records(
            fromChat: chat(assistantUsage: usage), chatID: "c", filePath: "/tmp/webui.db", modelLabel: nil
        )[0]
        XCTAssertEqual(r.usage.inputTokens, 100)
        XCTAssertEqual(r.usage.outputTokens, 20)
        XCTAssertEqual(r.usage.cachedInputTokens, 40)
        XCTAssertEqual(r.usage.totalTokens, 120)
    }

    func testAbortedTurnsUserTurnsAndUndatedTurnsAreSkipped() {
        XCTAssertTrue(OpenWebUIUsageStore.records(
            fromChat: chat(assistantUsage: nil), chatID: "c", filePath: "/tmp/webui.db", modelLabel: nil
        ).isEmpty, "assistant turn without usage = aborted turn")
        XCTAssertTrue(OpenWebUIUsageStore.records(
            fromChat: chat(assistantUsage: twoRoundUsage, role: "user"), chatID: "c", filePath: "/tmp/webui.db", modelLabel: nil
        ).isEmpty)
        XCTAssertTrue(OpenWebUIUsageStore.records(
            fromChat: chat(assistantUsage: twoRoundUsage, timestamp: nil), chatID: "c", filePath: "/tmp/webui.db", modelLabel: nil
        ).isEmpty)
        XCTAssertTrue(OpenWebUIUsageStore.records(
            fromChat: ["id": "x"], chatID: "c", filePath: "/tmp/webui.db", modelLabel: nil
        ).isEmpty, "chat without history")
    }

    func testModelLabelComesFromLlamaServerArgv() {
        let argv = [
            "/usr/bin/sandbox-exec", "-f", "/x/local-only.sb", "/opt/homebrew/bin/llama-server",
            "--model", "/Users/me/.lmstudio/models/huihui-ai/X/Huihui-Qwen3.6-35B-A3B-abliterated-ggml-model-Q4_K.gguf",
            "--alias", "qwen-local-assistant",
        ]
        XCTAssertEqual(
            OpenWebUIUsageStore.modelLabel(fromArgv: argv),
            "huihui-qwen3.6-35b-a3b-abliterated-ggml-model-q4_k"
        )
        XCTAssertNil(OpenWebUIUsageStore.modelLabel(fromArgv: ["llama-server", "--model"]))
        XCTAssertNil(OpenWebUIUsageStore.modelLabel(fromArgv: ["llama-server"]))
        XCTAssertNil(OpenWebUIUsageStore.modelLabel(fromStateFileAt: URL(fileURLWithPath: "/nonexistent/state.json")))
    }

    func testGGUFLabelPricesAtQwen35BReferenceRate() {
        let pricing = AzureModelPricing.defaultPricing(
            for: "huihui-qwen3.6-35b-a3b-abliterated-ggml-model-q4_k", provider: .openWebUI
        )
        XCTAssertTrue(pricing.isKnown)
        XCTAssertEqual(pricing.inputPerMillionUSD, 0.14, accuracy: 0.0001)
        XCTAssertEqual(pricing.outputPerMillionUSD, 1.00, accuracy: 0.0001)
        XCTAssertFalse(AzureModelPricing.defaultPricing(for: "qwen-image-editor", provider: .openWebUI).isKnown)
    }

    func testProviderLabels() {
        XCTAssertEqual(CodexLogUsageProvider.openWebUI.rawValue, "open-webui")
        XCTAssertEqual(CodexLogUsageProvider.openWebUI.displayName, "Open WebUI")
        XCTAssertEqual(CodexLogUsageProvider.openWebUI.sessionCounterLabel, "Open WebUI chats")
        XCTAssertEqual(CodexLogUsageProvider.openWebUI.costLabel, "Est. saved")
        XCTAssertEqual(CodexLogUsageProvider.openWebUI.costShortLabel, "Saved")
    }

    func testScanReadsChatTableFromSQLite() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("open-webui-store-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let dbURL = directory.appendingPathComponent("webui.db")
        let stateURL = directory.appendingPathComponent("chat-assistant-server.json")
        try Data("""
        {"pid": 1, "argv": ["llama-server", "--model", "/m/Huihui-Qwen3.6-35B-A3B-abliterated-ggml-model-Q4_K.gguf"]}
        """.utf8).write(to: stateURL)

        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(dbURL.path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        XCTAssertEqual(sqlite3_exec(db, "CREATE TABLE chat (id VARCHAR NOT NULL, user_id VARCHAR, title TEXT, chat JSON, PRIMARY KEY (id))", nil, nil, nil), SQLITE_OK)
        let good = try JSONSerialization.data(withJSONObject: chat(assistantUsage: twoRoundUsage))
        let goodJSON = String(decoding: good, as: UTF8.self).replacingOccurrences(of: "'", with: "''")
        XCTAssertEqual(sqlite3_exec(db, "INSERT INTO chat VALUES ('chat-1', 'u', 't', '\(goodJSON)')", nil, nil, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(db, "INSERT INTO chat VALUES ('chat-2', 'u', 't', 'not json')", nil, nil, nil), SQLITE_OK)

        let result = OpenWebUIUsageStore(databaseURL: dbURL, assistantStateURL: stateURL).scan()
        XCTAssertEqual(result.provider, .openWebUI)
        XCTAssertEqual(result.records.count, 1)
        XCTAssertEqual(result.records[0].model, "huihui-qwen3.6-35b-a3b-abliterated-ggml-model-q4_k")
        XCTAssertEqual(result.summary.malformedEventsSkipped, 1)
        XCTAssertEqual(result.summary.sessionsScanned, 1)
        XCTAssertEqual(result.summary.eventsCounted, 1)
        XCTAssertTrue(result.summary.warnings.isEmpty)
    }

    func testMissingDatabaseIsEmptyWithoutWarnings() {
        let result = OpenWebUIUsageStore(
            databaseURL: URL(fileURLWithPath: "/nonexistent/webui.db"),
            assistantStateURL: URL(fileURLWithPath: "/nonexistent/state.json")
        ).scan()
        XCTAssertTrue(result.records.isEmpty)
        XCTAssertTrue(result.summary.warnings.isEmpty)
    }
}
