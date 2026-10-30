// baseline-guard:allow new standalone prototype file, no prior baseline possible
import CoreGraphics
import Foundation
import os

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
    /// Published evidence (resolver background queue, top-3 nearest only). The tap
    /// consumes these values; it never refreshes them with an AX call.
    var verdict: ClickAssistVerdict = .unknown
    var chromeEligible: Bool = false
    var evidenceGeneration: UInt64 = 0
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
    /// Service epoch that produced this snapshot. An empty value means the
    /// snapshot was produced locally (static harness / tests).
    var epoch: String = "-"

    static let empty = CacheSnapshot(generation: 0, targets: [], valid: false,
                                     reason: "unavailable:not-started", stamp: 0,
                                     resolverMs: 0, pointer: .zero, appName: "-", pid: 0)
}

/// The only object shared between the resolver thread and the tap callback.
/// The callback NEVER blocks: reads use `os_unfair_lock_trylock` and fall back to
/// the reader's own last-seen immutable snapshot. Publishing stays a full lock.
final class CacheStore: @unchecked Sendable {
    private var lock = os_unfair_lock_s()
    private var snapshot = CacheSnapshot.empty
    /// Miss counter, guarded by its own trylock so even the counter cannot block
    /// the callback.
    private var missLock = os_unfair_lock_s()
    private var _snapshotTrylockMiss = 0
    /// Post-publish observers (the P2a overlay). Called AFTER the lock is released,
    /// with the same immutable struct the tap router reads: a slow or dead observer
    /// can never block the tap callback, which only ever calls `current()`.
    private var observers: [(CacheSnapshot) -> Void] = []
    func publish(_ s: CacheSnapshot) {
        os_unfair_lock_lock(&lock)
        snapshot = s
        let obs = observers
        os_unfair_lock_unlock(&lock)
        for o in obs { o(s) }
    }

    func addObserver(_ o: @escaping (CacheSnapshot) -> Void) {
        os_unfair_lock_lock(&lock)
        observers.append(o)
        os_unfair_lock_unlock(&lock)
    }

    /// Event-tap read path: trylock only. `lastSeen` is the reader's own copy and
    /// is overwritten on a successful read; on contention it is returned as-is.
    /// Safe because snapshots are immutable and evidence carries its own
    /// generation/age, so a slightly older snapshot is rejected by the existing
    /// expiry rules rather than trusted.
    func current(else lastSeen: inout CacheSnapshot) -> CacheSnapshot {
        if os_unfair_lock_trylock(&lock) {
            lastSeen = snapshot
            os_unfair_lock_unlock(&lock)
            return lastSeen
        }
        recordTrylockMiss()
        return lastSeen
    }

    /// Publisher-side read (resolver only): blocking is acceptable off-callback.
    func current() -> CacheSnapshot {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        return snapshot
    }

    private func recordTrylockMiss() {
        guard os_unfair_lock_trylock(&missLock) else { return }
        _snapshotTrylockMiss += 1
        os_unfair_lock_unlock(&missLock)
    }

    /// Number of callback reads that could not take the lock (never blocks).
    var snapshotTrylockMiss: Int {
        guard os_unfair_lock_trylock(&missLock) else { return _snapshotTrylockMiss }
        defer { os_unfair_lock_unlock(&missLock) }
        return _snapshotTrylockMiss
    }

}
