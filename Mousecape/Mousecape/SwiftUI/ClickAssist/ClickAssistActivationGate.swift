// baseline-guard:allow new pure activation gate, no prior baseline possible
//
//  ClickAssistActivationGate.swift
//  Service-side validation for one `activate` request. Pure and deterministic:
//  the service owns the persisted `State`; time is always passed in.
//

import Foundation

/// Versioned JSON request body for `activate`.
struct ActivationRequestWire: Codable, Equatable, Sendable {
    var requestID: String
    var targetKey: String
    var pid: Int32
    var generation: UInt64
    /// Monotonic seconds at issue time (shared system-wide clock).
    var issuedAt: Double
    var deadlineMs: Double

    var deadline: Double { issuedAt + deadlineMs / 1000 }
}

enum ActivationRejection: String, Sendable, Equatable {
    case malformed
    case staleGeneration = "stale-generation"
    case expired
    case unknownTarget = "unknown-target"
    case notChromeEligible = "not-chrome-eligible"
    case duplicateRequest = "duplicate-request"
    case duplicateTarget = "duplicate-target"
    case queueFull = "queue-full"
}

enum ActivationGate {
    static let maxQueued = 4
    static let dedupeWindowMs: Double = 250
    /// Request-id records older than this are pruned (they only exist to dedupe).
    static let requestMemorySeconds: Double = 60

    struct State: Sendable, Equatable {
        var pending = 0
        var lastRequest: [String: Double] = [:]
        var lastTarget: [String: Double] = [:]
    }

    /// Validate against the CURRENT service-side snapshot and element table.
    /// Returns nil when admitted (and reserves a queue slot + records dedupe).
    static func admit(_ request: ActivationRequestWire,
                      now: Double,
                      currentGeneration: UInt64,
                      targetExists: Bool,
                      chromeEligible: Bool,
                      state: inout State) -> ActivationRejection? {
        prune(now, &state)
        if request.generation != currentGeneration { return .staleGeneration }
        if now >= request.deadline { return .expired }
        if !targetExists { return .unknownTarget }
        if !chromeEligible { return .notChromeEligible }
        if state.lastRequest[request.requestID] != nil { return .duplicateRequest }
        if let last = state.lastTarget[request.targetKey],
           (now - last) * 1000 < dedupeWindowMs {
            return .duplicateTarget
        }
        if state.pending >= maxQueued { return .queueFull }
        state.lastRequest[request.requestID] = now
        state.lastTarget[request.targetKey] = now
        state.pending += 1
        return nil
    }

    /// Release the reserved queue slot once the worker finishes (success or not).
    static func finish(_ state: inout State) {
        if state.pending > 0 { state.pending -= 1 }
    }

    static func prune(_ now: Double, _ state: inout State) {
        state.lastRequest = state.lastRequest.filter { now - $0.value <= requestMemorySeconds }
        state.lastTarget = state.lastTarget.filter { (now - $0.value) * 1000 <= dedupeWindowMs * 4 }
    }
}
