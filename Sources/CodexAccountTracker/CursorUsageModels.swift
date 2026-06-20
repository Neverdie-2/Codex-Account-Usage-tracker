import Foundation

/// Workspace/project a Cursor conversation belongs to, derived from
/// `allComposers[i].workspaceIdentifier`. A null/absent workspace renders as
/// "Unscoped" (the Cursor equivalent of the Azure dashboard's "unknown project").
struct CursorWorkspaceProject: Codable, Equatable {
    /// Full `workspaceIdentifier.uri.path`. Nil when the conversation has no workspace.
    var path: String?
    /// `workspaceIdentifier.id`.
    var id: String?
    /// Display label: basename of `path`, or `Unscoped`.
    var name: String

    static let unscoped = "Unscoped"

    init(path: String?, id: String?) {
        let trimmedPath = path?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.path = (trimmedPath?.isEmpty == false) ? trimmedPath : nil
        let trimmedID = id?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.id = (trimmedID?.isEmpty == false) ? trimmedID : nil
        self.name = Self.displayName(forPath: self.path)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        path = try container.decodeIfPresent(String.self, forKey: .path)
        id = try container.decodeIfPresent(String.self, forKey: .id)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? Self.displayName(forPath: path)
    }

    static func displayName(forPath path: String?) -> String {
        guard let path, !path.isEmpty else { return unscoped }
        let trimmed = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !trimmed.isEmpty else { return unscoped }
        return URL(fileURLWithPath: path).lastPathComponent
    }

    static let unscopedProject = CursorWorkspaceProject(path: nil, id: nil)
}

/// One row of TABLE 1 — one Cursor conversation (composer). Persisted in
/// `cursor-usage-cache.json`; never holds raw message text (counts/metadata only).
struct CursorUsageRecord: Codable, Equatable, Identifiable {
    /// Stable id: `"cursor-composer-<composerId>"`.
    var id: String
    var conversationId: String
    var workspace: CursorWorkspaceProject
    var title: String
    /// `chat` / `agent` / `debug` / `unknown`.
    var mode: String
    /// DISTINCT non-null `modelInfo.modelName` from type==1 (user) bubbles.
    var modelsUsed: [String]
    var userCount: Int
    var assistantCount: Int
    var messageCount: Int
    var linesAdded: Int
    var linesRemoved: Int
    var filesChanged: Int
    var contextUsagePct: Double?
    var firstActivity: Date?
    var lastActivity: Date?

    init(
        id: String,
        conversationId: String,
        workspace: CursorWorkspaceProject,
        title: String,
        mode: String,
        modelsUsed: [String],
        userCount: Int,
        assistantCount: Int,
        messageCount: Int,
        linesAdded: Int,
        linesRemoved: Int,
        filesChanged: Int,
        contextUsagePct: Double?,
        firstActivity: Date?,
        lastActivity: Date?
    ) {
        self.id = id
        self.conversationId = conversationId
        self.workspace = workspace
        self.title = title
        self.mode = mode
        self.modelsUsed = modelsUsed
        self.userCount = userCount
        self.assistantCount = assistantCount
        self.messageCount = messageCount
        self.linesAdded = linesAdded
        self.linesRemoved = linesRemoved
        self.filesChanged = filesChanged
        self.contextUsagePct = contextUsagePct
        self.firstActivity = firstActivity
        self.lastActivity = lastActivity
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        conversationId = try container.decodeIfPresent(String.self, forKey: .conversationId) ?? ""
        workspace = try container.decodeIfPresent(CursorWorkspaceProject.self, forKey: .workspace) ?? .unscopedProject
        title = try container.decodeIfPresent(String.self, forKey: .title) ?? ""
        mode = try container.decodeIfPresent(String.self, forKey: .mode) ?? "unknown"
        modelsUsed = try container.decodeIfPresent([String].self, forKey: .modelsUsed) ?? []
        userCount = try container.decodeIfPresent(Int.self, forKey: .userCount) ?? 0
        assistantCount = try container.decodeIfPresent(Int.self, forKey: .assistantCount) ?? 0
        messageCount = try container.decodeIfPresent(Int.self, forKey: .messageCount) ?? 0
        linesAdded = try container.decodeIfPresent(Int.self, forKey: .linesAdded) ?? 0
        linesRemoved = try container.decodeIfPresent(Int.self, forKey: .linesRemoved) ?? 0
        filesChanged = try container.decodeIfPresent(Int.self, forKey: .filesChanged) ?? 0
        contextUsagePct = try container.decodeIfPresent(Double.self, forKey: .contextUsagePct)
        firstActivity = try container.decodeIfPresent(Date.self, forKey: .firstActivity)
        lastActivity = try container.decodeIfPresent(Date.self, forKey: .lastActivity)
    }

    /// Compact summary of `modelsUsed` for tight table cells.
    var modelSummary: String {
        if modelsUsed.isEmpty { return "—" }
        if modelsUsed.count == 1 { return modelsUsed[0] }
        return "\(modelsUsed[0]) +\(modelsUsed.count - 1)"
    }
}

/// Scan-level stats for TABLE 1. `modelsUsedToday` backs the "models used today"
/// chip row; it is recomputed against `now` on every scan.
struct CursorUsageSummary: Codable, Equatable {
    var composersScanned = 0
    var bubblesScanned = 0
    var modelsUsedToday: [String] = []
    var databaseFound = true
    var warnings: [String] = []

    static let empty = CursorUsageSummary()

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        composersScanned = try container.decodeIfPresent(Int.self, forKey: .composersScanned) ?? 0
        bubblesScanned = try container.decodeIfPresent(Int.self, forKey: .bubblesScanned) ?? 0
        modelsUsedToday = try container.decodeIfPresent([String].self, forKey: .modelsUsedToday) ?? []
        databaseFound = try container.decodeIfPresent(Bool.self, forKey: .databaseFound) ?? true
        warnings = try container.decodeIfPresent([String].self, forKey: .warnings) ?? []
    }
}

/// Whole-scan result persisted to `cursor-usage-cache.json`.
struct CursorUsageScanResult: Codable, Equatable {
    var records: [CursorUsageRecord] = []
    var summary = CursorUsageSummary()

    static let empty = CursorUsageScanResult()

    init() {}

    init(records: [CursorUsageRecord], summary: CursorUsageSummary) {
        self.records = records
        self.summary = summary
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        records = try container.decodeIfPresent([CursorUsageRecord].self, forKey: .records) ?? []
        summary = try container.decodeIfPresent(CursorUsageSummary.self, forKey: .summary) ?? .empty
    }
}

/// View-model facing dashboard: records already filtered to the selected window,
/// plus the today rollup. Built by `CursorUsageScanner.dashboard(from:window:now:)`.
struct CursorUsageDashboard: Codable, Equatable {
    var records: [CursorUsageRecord] = []
    var modelsUsedToday: [String] = []
    var summary = CursorUsageSummary()

    static let empty = CursorUsageDashboard()
}

/// Today / 24h / 7d / All filter for TABLE 1. Same shape as `AzureUsageTimeWindow`
/// so the section `Picker` reuses the existing pattern. The predicate compares a
/// record's `lastActivity` (UTC) against a local-day-aware cutoff.
enum CursorUsageTimeWindow: String, CaseIterable, Identifiable, Codable {
    case today
    case last24h
    case last7d
    case all

    var id: String { rawValue }

    var label: String {
        switch self {
        case .today: return "Today"
        case .last24h: return "Last 24h"
        case .last7d: return "Last 7d"
        case .all: return "All"
        }
    }

    /// Inclusive lower bound for `lastActivity`. `nil` means no filter (All).
    /// `today` resolves to the start of the local day so a record updated any
    /// time today is included.
    func startDate(now: Date, calendar: Calendar = .current) -> Date? {
        switch self {
        case .today:
            return calendar.startOfDay(for: now)
        case .last24h:
            return now.addingTimeInterval(-24 * 60 * 60)
        case .last7d:
            return now.addingTimeInterval(-7 * 24 * 60 * 60)
        case .all:
            return nil
        }
    }
}
