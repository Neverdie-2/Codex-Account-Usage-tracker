import Foundation

/// Decides how the tracker should react when its managed Codex `app-server`
/// terminates. A server that dies almost immediately after launch (before the
/// tracker ever connects) is treated as a crash: the policy backs off
/// exponentially and, after enough consecutive crashes, gives up auto-restarting
/// so the app stops flickering and pegging the CPU. A broken `codex` install is
/// the usual cause — see `serverDied(uptime:)`.
struct ManagedServerRestartPolicy {
    /// A server that stayed alive at least this long is considered to have
    /// started successfully; its death is a normal termination, not a crash.
    let immediateDeathThreshold: TimeInterval
    /// After this many consecutive crashes the policy stops auto-restarting.
    let maxConsecutiveImmediateDeaths: Int
    let baseDelay: TimeInterval
    let maxDelay: TimeInterval

    private var consecutiveImmediateDeaths = 0

    init(
        immediateDeathThreshold: TimeInterval = 6,
        maxConsecutiveImmediateDeaths: Int = 5,
        baseDelay: TimeInterval = 1,
        maxDelay: TimeInterval = 60
    ) {
        self.immediateDeathThreshold = immediateDeathThreshold
        self.maxConsecutiveImmediateDeaths = maxConsecutiveImmediateDeaths
        self.baseDelay = baseDelay
        self.maxDelay = maxDelay
    }

    enum Decision: Equatable {
        case retry(after: TimeInterval)
        case giveUp
    }

    /// Report that the managed server terminated after living `uptime` seconds.
    mutating func serverDied(uptime: TimeInterval) -> Decision {
        guard uptime < immediateDeathThreshold else {
            consecutiveImmediateDeaths = 0
            return .retry(after: baseDelay)
        }

        consecutiveImmediateDeaths += 1
        if consecutiveImmediateDeaths >= maxConsecutiveImmediateDeaths {
            return .giveUp
        }

        let exponent = Double(consecutiveImmediateDeaths - 1)
        let delay = min(baseDelay * pow(2, exponent), maxDelay)
        return .retry(after: delay)
    }

    /// The managed server came up and the tracker connected — clear crash state.
    mutating func serverBecameHealthy() {
        consecutiveImmediateDeaths = 0
    }

    /// Fully reset (e.g. the user manually restarts the server), re-enabling
    /// auto-restart even after the policy had given up.
    mutating func reset() {
        consecutiveImmediateDeaths = 0
    }
}
