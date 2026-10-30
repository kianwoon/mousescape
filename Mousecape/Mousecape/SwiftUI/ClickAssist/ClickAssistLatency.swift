// baseline-guard:allow new standalone latency instrumentation file, no prior baseline possible
//
//  ClickAssistLatency.swift
//  Mousecape
//
//  Passive latency instrumentation for the Click Assist event tap.
//
//  The tap callback owns the hot path: `record` and `noteTapDisable` may only
//  take an os_unfair_lock, write one preallocated slot and bump a counter.
//  They never allocate, never log and never touch the filesystem. All sorting,
//  percentile math and logging happens in `snapshotAndReset`, which is called
//  from the engine's off-callback stats timer.
//

import Foundation
import os.lock

/// Fixed-capacity ring of per-event callback durations (microseconds).
///
/// One buffer is allocated at init and never resized. `record` overwrites the
/// oldest sample when full (ring semantics), so a burst larger than capacity is
/// measured by the most recent `capacity` events; `dropped` exists only for a
/// caller that cannot store a sample, and stays 0 here by design.
final class LatencyRing: @unchecked Sendable {
    struct Stats {
        var count: Int
        var maxUs: Double
        var p50Us: Double
        var p99Us: Double
        var p99_9Us: Double
        var dropped: UInt64
        var tapDisableTimeout: UInt64
        var tapDisableUserInput: UInt64
    }

    /// Samples retained before the ring starts overwriting the oldest.
    let capacity: Int

    private var buffer: [UInt32]
    private var writeIndex = 0
    private var filled = 0
    private var droppedCount: UInt64 = 0
    private var tapDisableTimeoutCount: UInt64 = 0
    private var tapDisableUserInputCount: UInt64 = 0
    private var lock = os_unfair_lock_s()

    init(capacity: Int = 65536) {
        let cap = Swift.max(1, capacity)
        self.capacity = cap
        self.buffer = [UInt32](repeating: 0, count: cap)
    }

    /// Hot path: lock, clamp, store one slot, advance. No allocation, no I/O.
    func record(_ microseconds: Double) {
        let value: UInt32
        if microseconds <= 0 {
            value = 0
        } else if microseconds >= Double(UInt32.max) {
            value = UInt32.max
        } else {
            value = UInt32(microseconds.rounded())
        }
        os_unfair_lock_lock(&lock)
        buffer[writeIndex] = value
        writeIndex += 1
        if writeIndex == capacity { writeIndex = 0 }
        if filled < capacity { filled += 1 }
        os_unfair_lock_unlock(&lock)
    }

    /// Cold path: copy the used portion under the lock, sort and compute percentiles off it.
    func snapshotAndReset() -> Stats {
        os_unfair_lock_lock(&lock)
        let n = filled
        var values = Array(buffer[0..<n])
        let dropped = droppedCount
        let timeouts = tapDisableTimeoutCount
        let userInput = tapDisableUserInputCount
        filled = 0
        writeIndex = 0
        os_unfair_lock_unlock(&lock)

        values.sort()
        return Stats(count: n,
                     maxUs: values.last.map(Double.init) ?? 0,
                     p50Us: Self.nearestRank(values, 50),
                     p99Us: Self.nearestRank(values, 99),
                     p99_9Us: Self.nearestRank(values, 99.9),
                     dropped: dropped,
                     tapDisableTimeout: timeouts,
                     tapDisableUserInput: userInput)
    }

    /// Tap-disable counters are cumulative diagnostics; they survive timing resets.
    func noteTapDisable(timeout: Bool) {
        os_unfair_lock_lock(&lock)
        if timeout { tapDisableTimeoutCount += 1 } else { tapDisableUserInputCount += 1 }
        os_unfair_lock_unlock(&lock)
    }

    /// Nearest-rank percentile over an ASCENDING sorted buffer (rank is 1-based).
    private static func nearestRank(_ sorted: [UInt32], _ p: Double) -> Double {
        guard !sorted.isEmpty else { return 0 }
        // Epsilon absorbs binary floating error (99.9/100*1000 == 999.0000000000001).
        let raw = p / 100.0 * Double(sorted.count) - 1e-9
        let rank = Int(raw.rounded(.up))
        let index = Swift.min(Swift.max(rank, 1), sorted.count) - 1
        return Double(sorted[index])
    }
}
