import Foundation

/// One row of TABLE 2 — a signed-in Cursor account's monthly limits snapshot.
/// Persisted to `cursor-accounts.json`. Holds no secrets: email, plan,
/// percentages, the single monthly billing cycle, on-demand status, timestamps.
/// `id` is the lowercased email so multi-account is a later additive change.
struct CursorAccountRecord: Codable, Equatable, Identifiable {
    var id: String
    var email: String
    var userSubID: String?
    var membershipType: String
    var subscriptionStatus: String?
    var pendingCancellationDate: String?

    // Percentages of the included monthly total.
    var autoPercentUsed: Double?
    var apiPercentUsed: Double?
    var totalPercentUsed: Double?

    // included + bonus = total breakdown, plus the raw plan used/limit/remaining.
    var includedAmount: Double?
    var bonusAmount: Double?
    var totalAmount: Double?
    var planUsed: Double?
    var planLimit: Double?
    var planRemaining: Double?

    // One monthly cycle (ISO8601 UTC strings, displayed local).
    var billingCycleStart: String?
    var billingCycleEnd: String?

    var isUnlimited: Bool
    var limitType: String?
    var autoDisplayMessage: String?
    var apiDisplayMessage: String?

    // On-demand (pay-as-you-go beyond the included cap).
    var onDemandEnabled: Bool
    var onDemandUsed: Double?
    var onDemandLimit: Double?
    var onDemandRemaining: Double?

    /// True when the row was filled from cached `ItemTable cursorAuth/*` fields
    /// because the API was unreachable / the token was expired (401/403).
    var stale: Bool
    var lastSeenAt: String

    // MARK: Derived

    /// `100 - totalPercentUsed`, clamped to [0, 100]. No direct API field.
    var pctRemaining: Double? {
        guard let used = totalPercentUsed else { return nil }
        return max(0, min(100, 100 - used))
    }

    /// Parsed `billingCycleEnd` for the live reset countdown.
    var billingCycleEndDate: Date? {
        Self.parseISO8601(billingCycleEnd)
    }

    var billingCycleStartDate: Date? {
        Self.parseISO8601(billingCycleStart)
    }

    /// Seconds remaining until the monthly reset, never negative.
    func resetCountdown(now: Date) -> TimeInterval? {
        guard let end = billingCycleEndDate else { return nil }
        return max(0, end.timeIntervalSince(now))
    }

    // MARK: Construction

    static func blank(email: String) -> CursorAccountRecord {
        CursorAccountRecord(
            id: email.lowercased(),
            email: email,
            userSubID: nil,
            membershipType: "unknown",
            subscriptionStatus: nil,
            pendingCancellationDate: nil,
            autoPercentUsed: nil,
            apiPercentUsed: nil,
            totalPercentUsed: nil,
            includedAmount: nil,
            bonusAmount: nil,
            totalAmount: nil,
            planUsed: nil,
            planLimit: nil,
            planRemaining: nil,
            billingCycleStart: nil,
            billingCycleEnd: nil,
            isUnlimited: false,
            limitType: nil,
            autoDisplayMessage: nil,
            apiDisplayMessage: nil,
            onDemandEnabled: false,
            onDemandUsed: nil,
            onDemandLimit: nil,
            onDemandRemaining: nil,
            stale: false,
            lastSeenAt: DateFormats.currentLocalTimestamp()
        )
    }

    /// Map a live API fetch into a record. `me`/`stripe` are best-effort enrichers.
    static func make(
        email: String,
        summary: UsageSummaryResponse,
        me: AuthMeResponse?,
        stripe: AuthStripeResponse?,
        subFromJWT: String?,
        lastSeenAt: String
    ) -> CursorAccountRecord {
        var record = blank(email: email)
        record.lastSeenAt = lastSeenAt
        record.stale = false
        record.userSubID = me?.sub ?? subFromJWT

        record.membershipType = stripe?.membershipType
            ?? stripe?.individualMembershipType
            ?? summary.membershipType
            ?? "unknown"
        record.subscriptionStatus = stripe?.subscriptionStatus
        record.pendingCancellationDate = stripe?.pendingCancellationDate

        record.billingCycleStart = summary.billingCycleStart
        record.billingCycleEnd = summary.billingCycleEnd
        record.isUnlimited = summary.isUnlimited ?? false
        record.limitType = summary.limitType
        record.autoDisplayMessage = summary.autoModelSelectedDisplayMessage
        record.apiDisplayMessage = summary.namedModelSelectedDisplayMessage

        if let plan = summary.individualUsage?.plan {
            record.autoPercentUsed = plan.autoPercentUsed
            record.apiPercentUsed = plan.apiPercentUsed
            record.totalPercentUsed = plan.totalPercentUsed
            record.planUsed = plan.used
            record.planLimit = plan.limit
            record.planRemaining = plan.remaining
            record.includedAmount = plan.breakdown?.included
            record.bonusAmount = plan.breakdown?.bonus
            record.totalAmount = plan.breakdown?.total
        }

        if let onDemand = summary.individualUsage?.onDemand {
            record.onDemandEnabled = onDemand.enabled ?? false
            record.onDemandUsed = onDemand.used
            record.onDemandLimit = onDemand.limit
            record.onDemandRemaining = onDemand.remaining
        }

        return record
    }

    /// Build a stale row from cached `ItemTable cursorAuth/*` fields when the API
    /// could not be reached. Preserves any prior live snapshot passed as `previous`.
    static func staleFromCache(
        email: String,
        membershipType: String?,
        subscriptionStatus: String?,
        previous: CursorAccountRecord?,
        lastSeenAt: String
    ) -> CursorAccountRecord {
        var record = previous ?? blank(email: email)
        record.id = email.lowercased()
        record.email = email
        if let membershipType, !membershipType.isEmpty {
            record.membershipType = membershipType
        }
        if let subscriptionStatus, !subscriptionStatus.isEmpty {
            record.subscriptionStatus = subscriptionStatus
        }
        record.stale = true
        record.lastSeenAt = lastSeenAt
        return record
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        email = try c.decodeIfPresent(String.self, forKey: .email) ?? ""
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? email.lowercased()
        userSubID = try c.decodeIfPresent(String.self, forKey: .userSubID)
        membershipType = try c.decodeIfPresent(String.self, forKey: .membershipType) ?? "unknown"
        subscriptionStatus = try c.decodeIfPresent(String.self, forKey: .subscriptionStatus)
        pendingCancellationDate = try c.decodeIfPresent(String.self, forKey: .pendingCancellationDate)
        autoPercentUsed = try c.decodeIfPresent(Double.self, forKey: .autoPercentUsed)
        apiPercentUsed = try c.decodeIfPresent(Double.self, forKey: .apiPercentUsed)
        totalPercentUsed = try c.decodeIfPresent(Double.self, forKey: .totalPercentUsed)
        includedAmount = try c.decodeIfPresent(Double.self, forKey: .includedAmount)
        bonusAmount = try c.decodeIfPresent(Double.self, forKey: .bonusAmount)
        totalAmount = try c.decodeIfPresent(Double.self, forKey: .totalAmount)
        planUsed = try c.decodeIfPresent(Double.self, forKey: .planUsed)
        planLimit = try c.decodeIfPresent(Double.self, forKey: .planLimit)
        planRemaining = try c.decodeIfPresent(Double.self, forKey: .planRemaining)
        billingCycleStart = try c.decodeIfPresent(String.self, forKey: .billingCycleStart)
        billingCycleEnd = try c.decodeIfPresent(String.self, forKey: .billingCycleEnd)
        isUnlimited = try c.decodeIfPresent(Bool.self, forKey: .isUnlimited) ?? false
        limitType = try c.decodeIfPresent(String.self, forKey: .limitType)
        autoDisplayMessage = try c.decodeIfPresent(String.self, forKey: .autoDisplayMessage)
        apiDisplayMessage = try c.decodeIfPresent(String.self, forKey: .apiDisplayMessage)
        onDemandEnabled = try c.decodeIfPresent(Bool.self, forKey: .onDemandEnabled) ?? false
        onDemandUsed = try c.decodeIfPresent(Double.self, forKey: .onDemandUsed)
        onDemandLimit = try c.decodeIfPresent(Double.self, forKey: .onDemandLimit)
        onDemandRemaining = try c.decodeIfPresent(Double.self, forKey: .onDemandRemaining)
        stale = try c.decodeIfPresent(Bool.self, forKey: .stale) ?? false
        lastSeenAt = try c.decodeIfPresent(String.self, forKey: .lastSeenAt) ?? ""
    }

    init(
        id: String,
        email: String,
        userSubID: String?,
        membershipType: String,
        subscriptionStatus: String?,
        pendingCancellationDate: String?,
        autoPercentUsed: Double?,
        apiPercentUsed: Double?,
        totalPercentUsed: Double?,
        includedAmount: Double?,
        bonusAmount: Double?,
        totalAmount: Double?,
        planUsed: Double?,
        planLimit: Double?,
        planRemaining: Double?,
        billingCycleStart: String?,
        billingCycleEnd: String?,
        isUnlimited: Bool,
        limitType: String?,
        autoDisplayMessage: String?,
        apiDisplayMessage: String?,
        onDemandEnabled: Bool,
        onDemandUsed: Double?,
        onDemandLimit: Double?,
        onDemandRemaining: Double?,
        stale: Bool,
        lastSeenAt: String
    ) {
        self.id = id
        self.email = email
        self.userSubID = userSubID
        self.membershipType = membershipType
        self.subscriptionStatus = subscriptionStatus
        self.pendingCancellationDate = pendingCancellationDate
        self.autoPercentUsed = autoPercentUsed
        self.apiPercentUsed = apiPercentUsed
        self.totalPercentUsed = totalPercentUsed
        self.includedAmount = includedAmount
        self.bonusAmount = bonusAmount
        self.totalAmount = totalAmount
        self.planUsed = planUsed
        self.planLimit = planLimit
        self.planRemaining = planRemaining
        self.billingCycleStart = billingCycleStart
        self.billingCycleEnd = billingCycleEnd
        self.isUnlimited = isUnlimited
        self.limitType = limitType
        self.autoDisplayMessage = autoDisplayMessage
        self.apiDisplayMessage = apiDisplayMessage
        self.onDemandEnabled = onDemandEnabled
        self.onDemandUsed = onDemandUsed
        self.onDemandLimit = onDemandLimit
        self.onDemandRemaining = onDemandRemaining
        self.stale = stale
        self.lastSeenAt = lastSeenAt
    }

    /// Parse an ISO8601 timestamp that may or may not carry fractional seconds
    /// (`…11:57:07.800Z` vs `…11:57:07Z`).
    static func parseISO8601(_ value: String?) -> Date? {
        guard let value, !value.isEmpty else { return nil }
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFraction.date(from: value) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: value)
    }

    /// Format a remaining interval as `Dd HHh MMm` (the Cursor reset countdown).
    static func formatCountdown(_ seconds: TimeInterval) -> String {
        let total = Int(max(0, seconds))
        let days = total / 86_400
        let hours = (total % 86_400) / 3_600
        let minutes = (total % 3_600) / 60
        return String(format: "%dd %02dh %02dm", days, hours, minutes)
    }
}
