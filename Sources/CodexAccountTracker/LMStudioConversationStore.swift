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
