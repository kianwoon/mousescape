// baseline-guard:allow new standalone prototype file, no prior baseline possible
import ApplicationServices
import CoreGraphics
import Foundation

/// One accessible, actionable element as observed by the resolver.
struct CachedTarget: Sendable {
    let key: String
    let role: String
    let label: String
    /// Global display coordinates, top-left origin (same space as CGEvent.location / AXPosition).
    let rect: CGRect
    /// Corrected point is clamped to rect.insetBy(inset, inset).
    let inset: CGFloat
    /// Admission tier, fixed by the resolver at collected time. First-class =
    /// genuine control role; second-class = container admitted by the tile/row
    /// size envelope only.
    let tier: DecisionCore.Tier
}

/// Immutable snapshot published by the background resolver and read by the tap.
/// `valid == false` means "no routing decisions from this snapshot" (fail-open).
struct CacheSnapshot: Sendable {
    let generation: UInt64
    let targets: [CachedTarget]
    let valid: Bool
    let reason: String
    let stamp: CFTimeInterval
    let resolverMs: Double
    let pointer: CGPoint
    let appName: String
    let pid: pid_t

    static let empty = CacheSnapshot(generation: 0, targets: [], valid: false,
                                     reason: "unavailable:not-started", stamp: 0,
                                     resolverMs: 0, pointer: .zero, appName: "-", pid: 0)
}

/// The only object shared between the resolver thread and the tap callback.
/// The callback does a short lock + struct copy; it never calls Accessibility.
final class CacheStore: @unchecked Sendable {
    private let lock = NSLock()
    private var snapshot = CacheSnapshot.empty
    /// Post-publish observers (the P2a overlay). Called AFTER the lock is released,
    /// with the same immutable struct the tap router reads: a slow or dead observer
    /// can never block the tap callback, which only ever calls `current()`.
    private var observers: [(CacheSnapshot) -> Void] = []
    /// Delivery-side table: the live AX element reference for each admitted
    /// candidate key, keyed by owning pid. Populated by the resolver each publish
    /// cycle, replaced wholesale, and cleared on invalidation. Deliberately NOT
    /// part of the Sendable snapshot: AXUIElement is only valid in this process
    /// and is not a value type, so it lives behind this lock as a side table.
    private var axElements: [pid_t: [String: AXUIElement]] = [:]

    func publish(_ s: CacheSnapshot) {
        lock.lock()
        snapshot = s
        let obs = observers
        lock.unlock()
        for o in obs { o(s) }
    }

    func addObserver(_ o: @escaping (CacheSnapshot) -> Void) {
        lock.lock()
        observers.append(o)
        lock.unlock()
    }

    func current() -> CacheSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return snapshot
    }

    /// Replace the element side table for `pid` (one publish cycle's worth).
    func setElements(_ map: [String: AXUIElement], pid: pid_t) {
        lock.lock()
        axElements = [pid: map]
        lock.unlock()
    }

    func clearElements() {
        lock.lock()
        axElements.removeAll()
        lock.unlock()
    }

    /// The element reference for a candidate key, or nil when the resolver did not
    /// (or can no longer) supply one. Read by the tap at delivery time only.
    func element(for key: String, pid: pid_t) -> AXUIElement? {
        lock.lock()
        defer { lock.unlock() }
        return axElements[pid]?[key]
    }
}
