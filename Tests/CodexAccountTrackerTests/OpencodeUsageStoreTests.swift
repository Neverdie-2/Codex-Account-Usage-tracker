import XCTest
@testable import CodexAccountTracker

final class OpencodeUsageStoreTests: XCTestCase {
    /// Shape of one row's `data` JSON from opencode's message table (an
    /// assistant turn served by the local LM Studio server).
    private func assistantData(
        provider: String = "lmstudio",
        model: String = "qwen/qwen3-30b-a3b-2507",
        input: Int = 8129,
        output: Int = 120,
        reasoning: Int = 21,
        cacheRead: Int = 0,
        cacheWrite: Int = 0,
        created: Any? = 1780963531869,
        cwd: String? = "/Users/me/Desktop/UAI",
        role: String = "assistant"
    ) -> String {
        var tokens: [String: Any] = [
            "input": input, "output": output, "reasoning": reasoning,
            "cache": ["read": cacheRead, "write": cacheWrite],
        ]
        if input == 0 && output == 0 && reasoning == 0 { tokens = ["input": 0, "output": 0] }
        var obj: [String: Any] = [
            "role": role,
            "modelID": model,
            "providerID": provider,
            "tokens": tokens,
            "cost": 0,
        ]
        if let created { obj["time"] = ["created": created, "completed": created] }
        if let cwd { obj["path"] = ["cwd": cwd, "root": "/"] }
        let data = try! JSONSerialization.data(withJSONObject: obj)
        return String(decoding: data, as: UTF8.self)
    }

    func testMapsTokensModelAndProject() {
        let record = OpencodeUsageStore.record(
            messageID: "msg_abc",
            sessionID: "ses_1",
            data: assistantData(),
            filePath: "/tmp/opencode.db"
        )
        let r = try! XCTUnwrap(record)
        XCTAssertEqual(r.id, "opencode-msg_abc")
        XCTAssertEqual(r.sessionID, "ses_1")
        XCTAssertEqual(r.model, "qwen/qwen3-30b-a3b-2507")
        XCTAssertEqual(r.endpoint, "LM Studio")
        XCTAssertEqual(r.resource, "opencode")
        XCTAssertEqual(r.projectName, "UAI")
        XCTAssertEqual(r.usage.inputTokens, 8129)
        // reasoning folds into output so it is billed like output tokens
        XCTAssertEqual(r.usage.outputTokens, 141)
        XCTAssertEqual(r.usage.reasoningOutputTokens, 21)
        XCTAssertEqual(r.usage.totalTokens, 8270)
        XCTAssertEqual(r.timestamp.timeIntervalSince1970, 1780963531.869, accuracy: 0.001)
    }

    func testCacheTokensCountedAsInput() {
        let record = OpencodeUsageStore.record(
            messageID: "m", sessionID: "s",
            data: assistantData(input: 100, output: 10, reasoning: 0, cacheRead: 40, cacheWrite: 5),
            filePath: "/tmp/opencode.db"
        )
        let r = try! XCTUnwrap(record)
        XCTAssertEqual(r.usage.inputTokens, 145, "input includes cache read+write")
        XCTAssertEqual(r.usage.cachedInputTokens, 40)
        XCTAssertEqual(r.usage.cacheCreationInputTokens, 5)
        XCTAssertEqual(r.usage.uncachedInputTokens, 100)
    }

    func testSkipsNonLMStudioProvider() {
        XCTAssertNil(OpencodeUsageStore.record(
            messageID: "m", sessionID: "s",
            data: assistantData(provider: "anthropic"),
            filePath: "/tmp/opencode.db"
        ))
    }

    func testSkipsUserMessages() {
        XCTAssertNil(OpencodeUsageStore.record(
            messageID: "m", sessionID: "s",
            data: assistantData(role: "user"),
            filePath: "/tmp/opencode.db"
        ))
    }

    func testSkipsZeroTokenAndErroredMessages() {
        XCTAssertNil(OpencodeUsageStore.record(
            messageID: "m", sessionID: "s",
            data: assistantData(input: 0, output: 0, reasoning: 0),
            filePath: "/tmp/opencode.db"
        ))
    }

    func testSkipsMessagesWithoutTimestamp() {
        XCTAssertNil(OpencodeUsageStore.record(
            messageID: "m", sessionID: "s",
            data: assistantData(created: nil),
            filePath: "/tmp/opencode.db"
        ))
    }

    func testMissingCwdFallsBackToOpencodeProject() {
        let record = OpencodeUsageStore.record(
            messageID: "m", sessionID: "s",
            data: assistantData(cwd: nil),
            filePath: "/tmp/opencode.db"
        )
        XCTAssertEqual(try XCTUnwrap(record).projectName, "opencode")
    }

    func testFloatTokenCountsSurviveBridging() {
        // If opencode ever serializes a token count as a float, intValue must still read it.
        let json = """
        {"role":"assistant","providerID":"lmstudio","modelID":"qwen",
         "tokens":{"input":100.0,"output":5.0,"reasoning":0,"cache":{"read":0,"write":0}},
         "time":{"created":1780963531869}}
        """
        let r = try! XCTUnwrap(OpencodeUsageStore.record(
            messageID: "m", sessionID: "s", data: json, filePath: "/tmp/opencode.db"
        ))
        XCTAssertEqual(r.usage.inputTokens, 100)
        XCTAssertEqual(r.usage.outputTokens, 5)
    }
}
