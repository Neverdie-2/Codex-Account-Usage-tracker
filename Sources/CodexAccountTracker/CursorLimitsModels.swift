import Foundation

/// `GET /api/usage-summary` — the primary feed for TABLE 2. Every field is
/// optional so a forgiving decode survives Cursor adding/removing keys; integer
/// JSON values decode cleanly into the `Double?` percentage/amount fields.
struct UsageSummaryResponse: Codable, Equatable {
    var billingCycleStart: String?
    var billingCycleEnd: String?
    var membershipType: String?
    var limitType: String?
    var isUnlimited: Bool?
    var autoModelSelectedDisplayMessage: String?
    var namedModelSelectedDisplayMessage: String?
    var individualUsage: IndividualUsage?

    struct IndividualUsage: Codable, Equatable {
        var plan: Plan?
        var onDemand: OnDemand?
    }

    struct Plan: Codable, Equatable {
        var enabled: Bool?
        var used: Double?
        var limit: Double?
        var remaining: Double?
        var breakdown: Breakdown?
        var autoPercentUsed: Double?
        var apiPercentUsed: Double?
        var totalPercentUsed: Double?
    }

    struct Breakdown: Codable, Equatable {
        var included: Double?
        var bonus: Double?
        var total: Double?
    }

    struct OnDemand: Codable, Equatable {
        var enabled: Bool?
        var used: Double?
        // limit/remaining are null when on-demand is disabled — keep optional.
        var limit: Double?
        var remaining: Double?
    }
}

/// `GET /api/auth/me` — identity.
struct AuthMeResponse: Codable, Equatable {
    var email: String?
    var emailVerified: Bool?
    var name: String?
    var sub: String?
    var id: String?

    private enum CodingKeys: String, CodingKey {
        case email
        case emailVerified = "email_verified"
        case name
        case sub
        case id
    }
}

/// `GET /api/auth/stripe` — plan/subscription detail.
struct AuthStripeResponse: Codable, Equatable {
    var membershipType: String?
    var subscriptionStatus: String?
    var pendingCancellationDate: String?
    var verifiedStudent: Bool?
    var isOnStudentPlan: Bool?
    var isYearlyPlan: Bool?
    var individualMembershipType: String?
}

/// `GET /api/usage?user=<sub>` — deprecated legacy premium-request counters.
/// Free plan returns zeros/nulls; kept forgiving and de-emphasized in the UI.
struct LegacyUsageResponse: Codable, Equatable {
    var startOfMonth: String?
    var models: [String: LegacyModelUsage]?

    struct LegacyModelUsage: Codable, Equatable {
        var numRequests: Int?
        var numRequestsTotal: Int?
        var numTokens: Int?
        var maxTokenUsage: Int?
        var maxRequestUsage: Int?
    }

    private enum CodingKeys: String, CodingKey {
        case startOfMonth
        case models
    }

    init(from decoder: Decoder) throws {
        let container = try? decoder.container(keyedBy: CodingKeys.self)
        startOfMonth = try? container?.decodeIfPresent(String.self, forKey: .startOfMonth)
        models = try? container?.decodeIfPresent([String: LegacyModelUsage].self, forKey: .models)
    }

    init(startOfMonth: String? = nil, models: [String: LegacyModelUsage]? = nil) {
        self.startOfMonth = startOfMonth
        self.models = models
    }
}

enum CursorAPIError: Error, Equatable {
    case unauthorized
    case httpStatus(Int)
    case network
    case decoding
    case invalidURL
}
