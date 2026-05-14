import Foundation

struct AccountRecord: Codable, Equatable, Identifiable {
    var id: String { email.lowercased() }

    var email: String
    var planType: String
    var subscriptionExpiresAt: String

    var primaryUsedPercent: Int?
    var primaryRemainingPercent: Int?
    var primaryWindowDurationMins: Int?
    var primaryResetsAt: Int64?

    var secondaryUsedPercent: Int?
    var secondaryRemainingPercent: Int?
    var secondaryWindowDurationMins: Int?
    var secondaryResetsAt: Int64?

    var lastSeenAt: String

    static func blank(email: String) -> AccountRecord {
        AccountRecord(
            email: email,
            planType: "unknown",
            subscriptionExpiresAt: "",
            primaryUsedPercent: nil,
            primaryRemainingPercent: nil,
            primaryWindowDurationMins: nil,
            primaryResetsAt: nil,
            secondaryUsedPercent: nil,
            secondaryRemainingPercent: nil,
            secondaryWindowDurationMins: nil,
            secondaryResetsAt: nil,
            lastSeenAt: DateFormats.currentLocalTimestamp()
        )
    }

    mutating func apply(planType: String?) {
        if let planType, !planType.isEmpty {
            self.planType = planType
        }
        lastSeenAt = DateFormats.currentLocalTimestamp()
    }

    mutating func apply(snapshot: RateLimitSnapshot) {
        if let planType = snapshot.planType, !planType.isEmpty {
            self.planType = planType
        }

        if let primary = snapshot.primary {
            primaryUsedPercent = primary.usedPercent
            primaryRemainingPercent = RateLimitWindow.remaining(from: primary.usedPercent)
            primaryWindowDurationMins = primary.windowDurationMins
            primaryResetsAt = primary.resetsAt
        }

        if let secondary = snapshot.secondary {
            secondaryUsedPercent = secondary.usedPercent
            secondaryRemainingPercent = RateLimitWindow.remaining(from: secondary.usedPercent)
            secondaryWindowDurationMins = secondary.windowDurationMins
            secondaryResetsAt = secondary.resetsAt
        }

        lastSeenAt = DateFormats.currentLocalTimestamp()
    }

    mutating func applyExpiredLocalResets(now: Date = Date()) -> Bool {
        var changed = false

        if hasResetPassed(resetsAt: primaryResetsAt, now: now),
           primaryUsedPercent != nil || primaryRemainingPercent != nil {
            if primaryUsedPercent != 0 {
                primaryUsedPercent = 0
                changed = true
            }
            if primaryRemainingPercent != 100 {
                primaryRemainingPercent = 100
                changed = true
            }
            if let nextReset = projectedResetAt(
                resetsAt: primaryResetsAt,
                windowDurationMins: primaryWindowDurationMins,
                now: now
            ), nextReset != primaryResetsAt {
                primaryResetsAt = nextReset
                changed = true
            }
        }

        if hasResetPassed(resetsAt: secondaryResetsAt, now: now),
           secondaryUsedPercent != nil || secondaryRemainingPercent != nil {
            if secondaryUsedPercent != 0 {
                secondaryUsedPercent = 0
                changed = true
            }
            if secondaryRemainingPercent != 100 {
                secondaryRemainingPercent = 100
                changed = true
            }
            if let nextReset = projectedResetAt(
                resetsAt: secondaryResetsAt,
                windowDurationMins: secondaryWindowDurationMins,
                now: now
            ), nextReset != secondaryResetsAt {
                secondaryResetsAt = nextReset
                changed = true
            }
        }

        return changed
    }

    func primaryDisplayWindow(now: Date = Date()) -> DisplayQuotaWindow {
        DisplayQuotaWindow(
            usedPercent: projectedUsedPercent(usedPercent: primaryUsedPercent, resetsAt: primaryResetsAt, now: now),
            remainingPercent: projectedRemainingPercent(remainingPercent: primaryRemainingPercent, resetsAt: primaryResetsAt, now: now),
            windowDurationMins: primaryWindowDurationMins,
            resetsAt: projectedResetAt(resetsAt: primaryResetsAt, windowDurationMins: primaryWindowDurationMins, now: now)
        )
    }

    func secondaryDisplayWindow(now: Date = Date()) -> DisplayQuotaWindow {
        DisplayQuotaWindow(
            usedPercent: projectedUsedPercent(usedPercent: secondaryUsedPercent, resetsAt: secondaryResetsAt, now: now),
            remainingPercent: projectedRemainingPercent(remainingPercent: secondaryRemainingPercent, resetsAt: secondaryResetsAt, now: now),
            windowDurationMins: secondaryWindowDurationMins,
            resetsAt: projectedResetAt(resetsAt: secondaryResetsAt, windowDurationMins: secondaryWindowDurationMins, now: now)
        )
    }

    private func projectedUsedPercent(usedPercent: Int?, resetsAt: Int64?, now: Date) -> Int? {
        guard let usedPercent else { return nil }
        guard hasResetPassed(resetsAt: resetsAt, now: now) else { return usedPercent }
        return 0
    }

    private func projectedRemainingPercent(remainingPercent: Int?, resetsAt: Int64?, now: Date) -> Int? {
        guard remainingPercent != nil else { return nil }
        guard hasResetPassed(resetsAt: resetsAt, now: now) else { return remainingPercent }
        return 100
    }

    private func hasResetPassed(resetsAt: Int64?, now: Date) -> Bool {
        guard let resetsAt else { return false }
        return now.timeIntervalSince1970 >= TimeInterval(resetsAt)
    }

    private func projectedResetAt(resetsAt: Int64?, windowDurationMins: Int?, now: Date) -> Int64? {
        guard let resetsAt,
              let windowDurationMins,
              windowDurationMins > 0
        else {
            return resetsAt
        }

        let nowSeconds = Int64(now.timeIntervalSince1970)
        guard nowSeconds >= resetsAt else { return resetsAt }

        let windowSeconds = Int64(windowDurationMins * 60)
        let elapsed = nowSeconds - resetsAt
        let windowsPassed = (elapsed / windowSeconds) + 1
        return resetsAt + (windowsPassed * windowSeconds)
    }
}

struct DisplayQuotaWindow: Equatable {
    var usedPercent: Int?
    var remainingPercent: Int?
    var windowDurationMins: Int?
    var resetsAt: Int64?
}

struct RateLimitSnapshot: Equatable {
    var planType: String?
    var primary: RateLimitWindow?
    var secondary: RateLimitWindow?

    var hasQuotaData: Bool {
        primary != nil || secondary != nil
    }
}

struct RateLimitWindow: Equatable {
    var usedPercent: Int
    var windowDurationMins: Int?
    var resetsAt: Int64?

    static func remaining(from usedPercent: Int) -> Int {
        max(0, min(100, 100 - usedPercent))
    }
}

enum DateFormats {
    static func currentLocalTimestamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ssZZZZZ"
        return formatter.string(from: Date())
    }

    static func display(epochSeconds: Int64?) -> String {
        guard let epochSeconds else { return "Unknown" }
        let formatter = DateFormatter()
        formatter.locale = Locale.current
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: Date(timeIntervalSince1970: TimeInterval(epochSeconds)))
    }

    static func display(date: Date?) -> String {
        guard let date else { return "Unknown" }
        let formatter = DateFormatter()
        formatter.locale = Locale.current
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}
