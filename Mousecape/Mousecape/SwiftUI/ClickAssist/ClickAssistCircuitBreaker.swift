// baseline-guard:allow new pure circuit breaker, no prior baseline possible
//
//  ClickAssistCircuitBreaker.swift
//  Client-side recovery policy for the resolver XPC connection. Pure value type:
//  time is always passed in, so the schedule is deterministic in tests.
//

import Foundation

struct ClickAssistCircuitBreaker: Sendable {
    enum State: String, Sendable, Equatable {
        case closed
        case open
    }

    enum Action: Sendable, Equatable {
        /// Reconnect after this many seconds.
        case retry(after: Double)
        /// Circuit opened: stop reconnecting until an explicit re-enable.
        case open
    }

    /// Reconnect backoff schedule. After the last entry the last delay repeats
    /// until the failure cap opens the circuit.
    static let schedule: [Double] = [1, 2, 4]
    /// Failures are counted only inside this rolling window.
    static let failureWindow: Double = 60
    /// A circuit opens after this many failures inside the window.
    static let maxFailures = 3
    /// Continuous healthy time that clears failure history.
    static let healthyReset: Double = 60

    private(set) var state: State = .closed
    private(set) var failures: [Double] = []
    private var healthySince: Double?

    /// Local failure history only; call on connection interruption/invalidation
    /// or when the no-snapshot watchdog fires.
    mutating func recordFailure(now: Double) -> Action {
        healthySince = nil
        failures.removeAll { now - $0 > Self.failureWindow }
        failures.append(now)
        if failures.count >= Self.maxFailures {
            state = .open
            return .open
        }
        let index = min(failures.count - 1, Self.schedule.count - 1)
        return .retry(after: Self.schedule[max(0, index)])
    }

    /// Call on every successfully decoded snapshot. After `healthyReset` seconds
    /// of continuous success the failure history is cleared.
    mutating func recordSuccess(now: Double) {
        guard state == .closed else { return }
        if let healthySince {
            if now - healthySince >= Self.healthyReset {
                failures.removeAll()
                self.healthySince = now
            }
        } else {
            healthySince = now
        }
    }

    /// Explicit re-enable (config toggle cycle or agent restart).
    mutating func reset() {
        state = .closed
        failures.removeAll()
        healthySince = nil
    }
}
