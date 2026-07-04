import XCTest
@testable import CodexAccountTracker

final class ManagedServerRestartPolicyTests: XCTestCase {
    // A server that ran for a healthy amount of time before dying is a normal
    // termination: retry promptly at the base delay, no crash-loop suspicion.
    func testHealthyUptimeRetriesAtBaseDelay() {
        var policy = ManagedServerRestartPolicy(
            immediateDeathThreshold: 5,
            maxConsecutiveImmediateDeaths: 5,
            baseDelay: 1,
            maxDelay: 60
        )

        XCTAssertEqual(policy.serverDied(uptime: 30), .retry(after: 1))
    }

    // A server that dies before the threshold is a crash: retry, but start
    // backing off so we stop hammering every second.
    func testImmediateDeathBacksOffExponentially() {
        var policy = ManagedServerRestartPolicy(
            immediateDeathThreshold: 5,
            maxConsecutiveImmediateDeaths: 10,
            baseDelay: 1,
            maxDelay: 60
        )

        XCTAssertEqual(policy.serverDied(uptime: 1), .retry(after: 1))
        XCTAssertEqual(policy.serverDied(uptime: 1), .retry(after: 2))
        XCTAssertEqual(policy.serverDied(uptime: 1), .retry(after: 4))
        XCTAssertEqual(policy.serverDied(uptime: 1), .retry(after: 8))
    }

    // Backoff never exceeds maxDelay no matter how long the crash loop runs.
    func testBackoffIsCappedAtMaxDelay() {
        var policy = ManagedServerRestartPolicy(
            immediateDeathThreshold: 5,
            maxConsecutiveImmediateDeaths: 100,
            baseDelay: 1,
            maxDelay: 10
        )

        var last: ManagedServerRestartPolicy.Decision = .retry(after: 0)
        for _ in 0..<20 {
            last = policy.serverDied(uptime: 0)
        }
        XCTAssertEqual(last, .retry(after: 10))
    }

    // After too many consecutive immediate deaths, stop auto-restarting entirely
    // instead of flickering forever.
    func testGivesUpAfterMaxConsecutiveImmediateDeaths() {
        var policy = ManagedServerRestartPolicy(
            immediateDeathThreshold: 5,
            maxConsecutiveImmediateDeaths: 3,
            baseDelay: 1,
            maxDelay: 60
        )

        XCTAssertEqual(policy.serverDied(uptime: 0), .retry(after: 1))
        XCTAssertEqual(policy.serverDied(uptime: 0), .retry(after: 2))
        XCTAssertEqual(policy.serverDied(uptime: 0), .giveUp)
    }

    // A server that comes up healthy resets the crash counter, so a later
    // hiccup starts backoff from scratch rather than tripping the give-up cap.
    func testHealthyServerResetsCrashCounter() {
        var policy = ManagedServerRestartPolicy(
            immediateDeathThreshold: 5,
            maxConsecutiveImmediateDeaths: 3,
            baseDelay: 1,
            maxDelay: 60
        )

        _ = policy.serverDied(uptime: 0)
        _ = policy.serverDied(uptime: 0)
        policy.serverBecameHealthy()

        XCTAssertEqual(policy.serverDied(uptime: 0), .retry(after: 1))
    }

    // A long-lived server that finally dies also resets the counter.
    func testHealthyUptimeResetsCrashCounter() {
        var policy = ManagedServerRestartPolicy(
            immediateDeathThreshold: 5,
            maxConsecutiveImmediateDeaths: 3,
            baseDelay: 1,
            maxDelay: 60
        )

        _ = policy.serverDied(uptime: 0)
        _ = policy.serverDied(uptime: 0)
        XCTAssertEqual(policy.serverDied(uptime: 30), .retry(after: 1))
        // Counter was reset by the healthy run, so backoff restarts.
        XCTAssertEqual(policy.serverDied(uptime: 0), .retry(after: 1))
    }

    // Manual reset (e.g. user hits "Restart server") clears a given-up state.
    func testResetClearsCrashCounter() {
        var policy = ManagedServerRestartPolicy(
            immediateDeathThreshold: 5,
            maxConsecutiveImmediateDeaths: 2,
            baseDelay: 1,
            maxDelay: 60
        )

        _ = policy.serverDied(uptime: 0)
        XCTAssertEqual(policy.serverDied(uptime: 0), .giveUp)

        policy.reset()
        XCTAssertEqual(policy.serverDied(uptime: 0), .retry(after: 1))
    }
}
