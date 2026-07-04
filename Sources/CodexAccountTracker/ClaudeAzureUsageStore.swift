import Foundation

/// Reads the LiteLLM gateway usage log (~/.opus-gateway/usage.jsonl) — one JSON
/// line per request, tagged with the serving Azure account (best02 / ffola /
/// zelen) — into usage records for the Claude Azure dashboard.
///
/// One record per request, so each request is its own "session": the "By account"
/// table's Events column = per-account request count (windowed). NOTE: the section
/// HEADLINE "Claude Azure requests" renders summary.providerSessions, which the
/// shared dashboard() does not re-window (AzureUsageScanner.swift:92-96), so the
/// headline is a LIFETIME total — same behavior as every other provider. The
/// authoritative windowed per-account numbers are the table rows.
final class ClaudeAzureUsageStore {
    private let usageFileURL: URL
    private let fileManager: FileManager

    init(
        usageFileURL: URL = ClaudeAzureUsageStore.defaultUsageFileURL(),
        fileManager: FileManager = .default
    ) {
        self.usageFileURL = usageFileURL
        self.fileManager = fileManager
    }

    static let endpointName = "Claude Azure"
    static let modelName = "claude-opus-4-8"

    func scan() -> AzureUsageScanResult {
        var result = AzureUsageScanResult(provider: .claudeAzure)

        // Missing file (callback not deployed yet / no requests) → empty, no warnings.
        guard fileManager.fileExists(atPath: usageFileURL.path),
              let data = try? Data(contentsOf: usageFileURL),
              let text = String(data: data, encoding: .utf8)
        else {
            return result
        }
        result.summary.filesScanned = 1

        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        var index = 0
        for rawLine in lines {
            defer { index += 1 }
            let trimmed = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            guard let lineData = trimmed.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: lineData),
                  let entry = object as? [String: Any]
            else {
                result.summary.malformedEventsSkipped += 1
                continue
            }
            guard let record = Self.record(from: entry, lineIndex: index, filePath: usageFileURL.path) else {
                result.summary.malformedEventsSkipped += 1
                continue
            }
            result.records.append(record)
            result.summary.sessionsScanned += 1
            result.summary.providerSessions += 1   // lifetime request count (see headline note above)
            result.summary.eventsCounted += 1
            result.summary.earliestEvent = Self.minDate(result.summary.earliestEvent, record.timestamp)
            result.summary.latestEvent = Self.maxDate(result.summary.latestEvent, record.timestamp)
        }

        result.records.sort { $0.timestamp < $1.timestamp }
        return result
    }

    static func record(from entry: [String: Any], lineIndex: Int, filePath: String) -> AzureUsageRecord? {
        guard let ts = (entry["ts"] as? NSNumber)?.doubleValue, ts > 0 else { return nil }
        let timestamp = Date(timeIntervalSince1970: ts)

        let rawAccount = (entry["account"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let account = (rawAccount.isEmpty || rawAccount == "unknown") ? "unknown account" : rawAccount

        let model = Self.normalizedModel(entry["model"] as? String)

        let promptTokens = (entry["prompt_tokens"] as? NSNumber)?.intValue ?? 0
        let cacheRead = (entry["cache_read_tokens"] as? NSNumber)?.intValue ?? 0
        let cacheCreation = (entry["cache_creation_tokens"] as? NSNumber)?.intValue ?? 0
        let outputTokens = (entry["output_tokens"] as? NSNumber)?.intValue ?? 0
        let totalTokens = (entry["total_tokens"] as? NSNumber)?.intValue ?? 0
        let inputUncachedRaw = (entry["input_uncached"] as? NSNumber)?.intValue  // nil if null/absent

        let cacheSum = cacheRead + cacheCreation
        // Convention-independent: guarantee inputInclusive >= cacheSum so the app's
        // uncachedInputTokens = input - cached - cacheCreation never clamps to 0.
        let nonCacheInput: Int
        if let uncached = inputUncachedRaw, uncached > 0 {
            nonCacheInput = uncached                        // Anthropic native truth
        } else if promptTokens >= cacheSum {
            nonCacheInput = promptTokens - cacheSum          // litellm was cache-inclusive
        } else {
            nonCacheInput = promptTokens                     // litellm was cache-exclusive
        }
        let inputInclusive = nonCacheInput + cacheSum

        // A request with no tokens at all is not worth a row.
        guard inputInclusive > 0 || outputTokens > 0 else { return nil }

        let resolvedTotal = totalTokens > 0 ? totalTokens : inputInclusive + outputTokens
        let usage = AzureTokenUsage(
            inputTokens: inputInclusive,
            cachedInputTokens: cacheRead,
            cacheCreationInputTokens: cacheCreation,
            outputTokens: outputTokens,
            reasoningOutputTokens: 0,
            totalTokens: resolvedTotal
        )

        let callID = (entry["call_id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let stableID = (callID?.isEmpty == false ? callID! : "claude-azure-\(lineIndex)-\(ts)")

        return AzureUsageRecord(
            id: stableID,
            sessionID: stableID,                 // one request == one "session" (request counter)
            filePath: filePath,
            timestamp: timestamp,
            endpoint: endpointName,
            resource: account,                   // best02 | ffola | zelen | "unknown account"
            deployment: model,                   // stable literal -> one row per account
            model: model,
            projectPath: endpointName,           // per-project unavailable via gateway (see Limitations)
            projectName: endpointName,
            usage: usage
        )
    }

    static func normalizedModel(_ value: String?) -> String {
        var model = (value?.trimmingCharacters(in: .whitespacesAndNewlines)) ?? ""
        if model.isEmpty { return modelName }
        if model.hasPrefix("anthropic/") { model = String(model.dropFirst("anthropic/".count)) }
        return model.isEmpty ? modelName : model
    }

    private static func minDate(_ a: Date?, _ b: Date) -> Date { guard let a else { return b }; return min(a, b) }
    private static func maxDate(_ a: Date?, _ b: Date) -> Date { guard let a else { return b }; return max(a, b) }

    static func defaultUsageFileURL() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".opus-gateway/usage.jsonl", isDirectory: false)
    }
}
