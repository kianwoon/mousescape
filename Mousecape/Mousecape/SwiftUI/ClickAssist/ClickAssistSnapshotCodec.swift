// baseline-guard:allow new pure wire codec, no prior baseline possible
//
//  ClickAssistSnapshotCodec.swift
//  Shared by the resolver XPC service and the agent client, and compiled by the
//  headless suite. Pure value/JSON logic only: no AX, no AppKit, no timers.
//

import CoreGraphics
import Foundation

/// Wire form of the resolver's published evidence. Every payload is versioned
/// JSON with an `epoch` identifying the service process instance.
struct SnapshotWire: Codable, Equatable, Sendable {
    static let version = 1

    var version: Int
    var epoch: String
    var generation: UInt64
    /// Monotonic seconds (CACurrentMediaTime) at publish. Shared system-wide, so
    /// the client can compute age against its own monotonic clock.
    var publishedAt: Double
    /// Policy constant: maximum accepted evidence age in milliseconds.
    var ageMs: Double
    var pid: Int32
    var valid: Bool
    var reason: String
    /// Diagnostics + client-side reasoning: where the resolver's pointer sample
    /// was and which app the snapshot describes. Optional for wire compatibility.
    var pointerX: Double?
    var pointerY: Double?
    var appName: String?
    var targets: [SnapshotWireTarget]
    /// Trace attribution for first-appearance latency. Optional so an older
    /// service/client pair stays wire-compatible.
    var ptrGen: UInt64?
    var cycleStartAt: Double?
    var walkMs: Double?
    var evidenceMs: Double?
    var encodeMs: Double?
    var evidenceN: Int?
    var trunc: String?
    /// Absent in older payloads; decodes as focused (today's behaviour).
    var pointerWindowFocused: Bool?

    init(epoch: String, generation: UInt64, publishedAt: Double,
         ageMs: Double = ClickAssistSnapshotCodec.evidenceMaxAgeMs,
         pid: Int32 = 0,
         valid: Bool = true,
         reason: String = "fresh",
         targets: [SnapshotWireTarget]) {
        self.version = SnapshotWire.version
        self.epoch = epoch
        self.generation = generation
        self.publishedAt = publishedAt
        self.ageMs = ageMs
        self.pid = pid
        self.valid = valid
        self.reason = reason
        self.targets = targets
    }
}

struct SnapshotWireRect: Codable, Equatable, Sendable {
    var x: Double
    var y: Double
    var w: Double
    var h: Double

    init(_ r: CGRect) {
        x = Double(r.origin.x)
        y = Double(r.origin.y)
        w = Double(r.size.width)
        h = Double(r.size.height)
    }

    var cgRect: CGRect { CGRect(x: x, y: y, width: w, height: h) }
}

struct SnapshotWireTarget: Codable, Equatable, Sendable {
    var key: String
    var role: String
    var label: String
    var rect: SnapshotWireRect
    var inset: Double
    var tier: Int
    var chromeEligible: Bool
    var verdict: String
    var evidenceGeneration: UInt64
    /// Per-target COLLECTION time (CACurrentMediaTime seconds). Kept separate
    /// from the snapshot's `publishedAt` so encode/send latency cannot make
    /// evidence look younger than it is.
    var collectedAt: Double
    /// Owning window frame; optional so older payloads still decode.
    var windowRect: SnapshotWireRect?

    init(_ t: CachedTarget) {
        key = t.key
        role = t.role
        label = t.label
        rect = SnapshotWireRect(t.rect)
        inset = Double(t.inset)
        tier = t.tier == .firstClass ? 1 : 2
        chromeEligible = t.chromeEligible
        verdict = t.verdict.rawValue
        evidenceGeneration = t.evidenceGeneration
        collectedAt = t.collectedAt
        windowRect = t.windowRect.map(SnapshotWireRect.init)
    }

    var cachedTarget: CachedTarget {
        CachedTarget(key: key, role: role, label: label, rect: rect.cgRect,
                     inset: CGFloat(inset),
                     tier: tier == 1 ? .firstClass : .secondClass,
                     verdict: ClickAssistVerdict(rawValue: verdict) ?? .unknown,
                     chromeEligible: chromeEligible,
                     evidenceGeneration: evidenceGeneration,
                     collectedAt: collectedAt,
                     windowRect: windowRect?.cgRect)
    }
}

enum ClickAssistSnapshotCodec {
    /// Hard payload ceiling. Larger payloads are rejected (and logged by the
    /// service), never truncated.
    static let maxPayloadBytes = 256 * 1024
    static let evidenceMaxAgeMs: Double = 400

    enum Reject: String, Error, Sendable, Equatable {
        case oversize
        case malformed
        case versionMismatch = "version-mismatch"
        case staleEpoch = "stale-epoch"
        case oldGeneration = "old-generation"
        case expired
    }

    struct Decoded: Equatable, Sendable {
        let wire: SnapshotWire
        let ageMs: Double
    }

    static func encode(_ wire: SnapshotWire) -> Data? {
        guard let data = try? JSONEncoder().encode(wire) else { return nil }
        guard data.count <= maxPayloadBytes else { return nil }
        return data
    }

    /// Validate a published payload against the client's local state.
    /// - `expectedEpoch`: nil accepts and adopts the first epoch seen.
    /// - `currentGeneration`: nil means no prior snapshot in this epoch.
    /// - `now`: local monotonic seconds.
    static func decode(_ data: Data, expectedEpoch: String?,
                       currentGeneration: UInt64?, now: Double) -> Result<Decoded, Reject> {
        guard data.count <= maxPayloadBytes else { return .failure(.oversize) }
        guard let wire = try? JSONDecoder().decode(SnapshotWire.self, from: data) else {
            return .failure(.malformed)
        }
        guard wire.version == SnapshotWire.version else { return .failure(.versionMismatch) }
        if let expectedEpoch, wire.epoch != expectedEpoch {
            return .failure(.staleEpoch)
        }
        if let currentGeneration, wire.generation <= currentGeneration {
            return .failure(.oldGeneration)
        }
        let ageMs = max(0, (now - wire.publishedAt) * 1000)
        guard ageMs <= evidenceMaxAgeMs else { return .failure(.expired) }
        return .success(Decoded(wire: wire, ageMs: ageMs))
    }
}

extension SnapshotWire {
    init(snapshot: CacheSnapshot, epoch: String) {
        self.init(epoch: epoch,
                  generation: snapshot.generation,
                  publishedAt: snapshot.stamp,
                  pid: snapshot.pid,
                  valid: snapshot.valid,
                  reason: snapshot.reason,
                  targets: snapshot.targets.map(SnapshotWireTarget.init))
        self.pointerX = Double(snapshot.pointer.x)
        self.pointerY = Double(snapshot.pointer.y)
        self.appName = snapshot.appName
        self.ptrGen = snapshot.pointerGeneration
        self.cycleStartAt = snapshot.cycleStartAt
        self.walkMs = snapshot.walkMs
        self.evidenceMs = snapshot.evidenceMs
        self.evidenceN = snapshot.evidenceN
        self.trunc = snapshot.trunc
        self.pointerWindowFocused = snapshot.pointerWindowFocused
    }

    /// Materialize the local immutable snapshot the tap/overlay consume. `stamp`
    /// stays the service publish time so the tap's age math is end-to-end.
    func cacheSnapshot() -> CacheSnapshot {
        CacheSnapshot(generation: generation,
                      targets: targets.map(\.cachedTarget),
                      valid: valid,
                      reason: reason,
                      stamp: publishedAt,
                      resolverMs: 0,
                      pointer: .zero,
                      appName: "-",
                      pid: pid,
                      epoch: epoch,
                      pointerGeneration: ptrGen ?? 0,
                      cycleStartAt: cycleStartAt ?? 0,
                      walkMs: walkMs ?? 0,
                      evidenceMs: evidenceMs ?? 0,
                      evidenceN: evidenceN ?? 0,
                      trunc: trunc ?? "none",
                      pointerWindowFocused: pointerWindowFocused ?? true)
    }
}

// MARK: - First-appearance trace formatting (pure; unit-tested with no I/O)

/// One resolver cycle's latency attribution. All timestamps are monotonic
/// (CACurrentMediaTime) and all durations are milliseconds.
struct ClickAssistTraceSample: Equatable, Sendable {
    var cycle: UInt64
    var ptrGen: UInt64
    var walkMs: Double
    var evidenceMs: Double
    var encodeMs: Double
    var sendMs: Double
    var recvAgeMs: Double
    var totalMs: Double
    var targets: Int
    var evidenceN: Int
    /// `none` | `deadline` | `budget`.
    var trunc: String
}

enum ClickAssistTraceFormatter {
    /// Per-cycle pointer-window cycle line. `overshoot` is reported separately
    /// from the shared rotation deadline so a slow pointer walk is attributable.
    static func resolverCycle(gen: UInt64, walkMs: Double, deadlineMs: Double,
                              evidenceN: Int, evidenceMs: Double) -> String {
        let overshoot = walkMs > deadlineMs * 1.5 ? 1 : 0
        return String(format: "RESOLVER_CYCLE gen=%llu walk_ms=%.1f deadline_ms=%.0f overshoot=%d evidence_n=%d evidence_ms=%.1f",
                      gen, walkMs, deadlineMs, overshoot, evidenceN, evidenceMs)
    }

    /// Client-side consolidated line: publish -> client accepted, broken into
    /// walk / evidence / encode / send / receive segments.
    static func cbTrace(_ s: ClickAssistTraceSample) -> String {
        String(format: "CB_TRACE cycle=%llu ptrGen=%llu walk_ms=%.1f evidence_ms=%.1f encode_ms=%.1f send_ms=%.1f recv_age_ms=%.1f total_ms=%.1f targets=%d evidence_n=%d trunc=%@",
               s.cycle, s.ptrGen, s.walkMs, s.evidenceMs, s.encodeMs, s.sendMs,
               s.recvAgeMs, s.totalMs, s.targets, s.evidenceN, s.trunc as NSString)
    }
}
