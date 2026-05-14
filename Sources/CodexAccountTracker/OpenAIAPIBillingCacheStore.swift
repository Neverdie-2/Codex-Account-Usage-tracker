import Foundation

final class OpenAIAPIBillingCacheStore {
    private let directoryURL: URL

    init(directoryURL: URL = AzureUsageCacheStore.defaultDirectoryURL()) {
        self.directoryURL = directoryURL
    }

    func load() -> OpenAIAPIBillingCacheEntry? {
        let url = fileURL()
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }

        do {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(OpenAIAPIBillingCacheEntry.self, from: data)
        } catch {
            print("Failed to load OpenAI API billing cache: \(error)")
            return nil
        }
    }

    func save(_ result: OpenAIAPIBillingResult, scannedAt: Date) {
        do {
            try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            let data = try encoder.encode(OpenAIAPIBillingCacheEntry(scannedAt: scannedAt, result: result))
            try data.write(to: fileURL(), options: [.atomic])
        } catch {
            print("Failed to save OpenAI API billing cache: \(error)")
        }
    }

    private func fileURL() -> URL {
        directoryURL.appendingPathComponent("openai-api-billing-cache.json")
    }
}

struct OpenAIAPIBillingCacheEntry: Codable, Equatable {
    var scannedAt: Date
    var result: OpenAIAPIBillingResult
}
