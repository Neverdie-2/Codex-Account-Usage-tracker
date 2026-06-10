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
