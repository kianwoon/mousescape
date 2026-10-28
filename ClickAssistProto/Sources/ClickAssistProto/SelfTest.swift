// baseline-guard:allow new standalone prototype file, no prior baseline possible
import AppKit
import ApplicationServices
import CoreGraphics
import Darwin

/// Line sink: every resolver/tap decision is mirrored to stdout and retained so the
/// self-test can assert on the routing log itself.
final class LogSink {
    // DEFECT 1 FIX: one lock guards ALL mutable state. Writers (tap thread, resolver
    // queue, overlay socket reader) only append under the lock; stdout I/O is drained
    // by a dedicated serial queue, so the tap callback never calls print/fflush and
    // never waits for a consumer.
    private let lock = NSLock()
    private var _lines: [String] = []
    private var pending: [String] = []
    private let maxLines = 4000
    private let maxPending = 4096
    private var flushScheduled = false
    private let flushQueue = DispatchQueue(label: "clickassist.log.flush", qos: .utility)

    var lines: [String] {
        lock.lock(); defer { lock.unlock() }
        return _lines
    }

    func write(_ line: String) {
        lock.lock()
        _lines.append(line)
        if _lines.count > maxLines { _lines.removeFirst(_lines.count - maxLines) }
        pending.append(line)
        if pending.count > maxPending { pending.removeFirst(pending.count - maxPending) }
        let schedule = !flushScheduled
        flushScheduled = true
        lock.unlock()
        if schedule {
            flushQueue.async { [weak self] in self?.drain() }   // non-blocking for tap thread
        }
    }

    private func drain() {
        while true {
            lock.lock()
            if pending.isEmpty {
                flushScheduled = false
                lock.unlock()
                return
            }
            let batch = pending
            pending.removeAll(keepingCapacity: true)
            lock.unlock()
            for line in batch { print(line) }
            fflush(stdout)
        }
    }

    func mark() -> Int {
        lock.lock(); defer { lock.unlock() }
        return _lines.count
    }

    func since(_ mark: Int) -> [String] {
        lock.lock(); defer { lock.unlock() }
        return Array(_lines[min(mark, _lines.count)...])
    }
}

/// Drives synthetic probes through the real HID event stream and asserts what the
/// controls actually received, plus what the cache-only router logged.
final class SelfTest {
    enum Mode { case trustedTap, failOpen }

    private let window: TestWindow
    private let tap: AssistTap?
    private let sink: LogSink
    private let cache: CacheStore?
    private let resolver: AccessibilityResolver?
    private let overlay: OverlayLink?
    private let allowDangerous: Bool
    private let mode: Mode

    private var steps: [(String, () -> Void)] = []
    private var passes = 0
    private var failures = 0
    private var mark = 0

    // Probe geometry, content-view coordinates.
    // button (240,140,120,60) -> maxX 360, midY 170
    private let inside = NSPoint(x: 300, y: 170)
    private let insideEdge = NSPoint(x: 358, y: 195)    // +2 pt inside button's right edge
    private let nearMiss = NSPoint(x: 369, y: 170)      // 9.0 pt outside right edge (>= 8)
    private let insideCorrected = NSPoint(x: 356, y: 170) // static target clamp(4)
    private let noCandidate = NSPoint(x: 400, y: 170)
    private let farAway = NSPoint(x: 100, y: 60)
    private let dragStart = NSPoint(x: 369, y: 170)
    private let dragEnd = NSPoint(x: 369, y: 150)
    private let dragStartCorrected = NSPoint(x: 356, y: 170)
    private let dragEndCorrected = NSPoint(x: 356, y: 150)
    private let ambiguous = NSPoint(x: 209, y: 80)      // 10.0 pt from ambigLeft and ambigRight
    // AX frames are inset from the NSView frames (button bezel), so P1 probes are derived
    // from the CACHED rects at run time rather than from view geometry.
    private var p1NearMiss: NSPoint?
    private var p1DirectHit: NSPoint?

    init(window: TestWindow, tap: AssistTap?, sink: LogSink,
         cache: CacheStore? = nil, resolver: AccessibilityResolver? = nil,
         overlay: OverlayLink? = nil, allowDangerous: Bool = false, mode: Mode) {
        self.window = window
        self.tap = tap
        self.sink = sink
        self.cache = cache
        self.resolver = resolver
        self.overlay = overlay
        self.allowDangerous = allowDangerous
        self.mode = mode
    }

    func start() {
        print("SELFTEST start mode=\(mode == .trustedTap ? "trusted-tap" : "fail-open") tolerance=\(tap?.tolerance ?? 12)")
        if mode == .trustedTap {
            // DEFECT 4 FIX: dangerous cases are opt-in only. Plain --selftest never
            // reaches spacesSteps/browserSteps/electronSteps/postKey.
            if allowDangerous {
                steps = p0Steps() + p1Steps() + p2bSteps() + p3Steps() + compatSteps()
                    + spacesSteps() + browserSteps() + electronSteps()
                    + restoreSteps() + p2Steps()
            } else {
                steps = p0Steps() + p1Steps() + p2bSteps() + p3Steps() + compatSteps() + p2Steps()
            }
        } else {
            steps = failOpenSteps()
        }
        pump()
    }

    // MARK: - P0 regression suite (static target, proves the P0 mechanism is intact)

    private func p0Steps() -> [(String, () -> Void)] {
        var s: [(String, () -> Void)] = []
        let log = window.eventLog
        s.append(("p0:mode", {
            self.tap?.targetSource = .staticTargets([self.window.buttonTarget()])
            print("P0-SUITE targetSource=static r1-target")
        }))

        s.append(("act:inside", { log.reset(); self.mark = self.sink.mark(); self.postClick(self.inside) }))
        s.append(("assert:inside", {
            self.check("1-baseline-inside", log.buttonDown.count == 1 && log.buttonUp.count == 1
                      && self.near(log.buttonDown.first, self.inside) && self.near(log.buttonUp.first, self.inside)
                      && log.backgroundDown.isEmpty,
                      "buttonDown=\(self.points(log.buttonDown)) buttonUp=\(self.points(log.buttonUp)) bg=\(log.backgroundDown.count)")
        }))

        s.append(("act:near-miss", { log.reset(); self.mark = self.sink.mark(); self.postClick(self.nearMiss) }))
        s.append(("assert:near-miss", {
            let mutations = self.sink.since(self.mark).filter { $0.contains("MUTATE") }
            let ok = log.buttonDown.count == 1 && log.buttonUp.count == 1
                && self.near(log.buttonDown.first, self.insideCorrected)
                && self.near(log.buttonUp.first, self.insideCorrected)
                && log.backgroundDown.isEmpty
            self.check("2-redirect-9pt-outside", ok,
                       "posted=\(self.pt(self.nearMiss)) deliveredDown=\(self.points(log.buttonDown)) deliveredUp=\(self.points(log.buttonUp)) bg=\(log.backgroundDown.count) mutations=\(mutations.count)")
            self.check("2b-down-up-same-corrected-point",
                       self.near(log.buttonDown.first, log.buttonUp.first ?? NSPoint(x: -1, y: -1))
                       && !log.buttonDown.isEmpty,
                       "down=\(self.points(log.buttonDown)) up=\(self.points(log.buttonUp))")
            self.check("2c-down-and-up-both-rewritten",
                       mutations.count == 2
                       && mutations.contains { $0.contains("type=leftMouseDown") && $0.contains("mode=return-modified-event") }
                       && mutations.contains { $0.contains("type=leftMouseUp") && $0.contains("mode=return-modified-event") },
                       "tapLog=\(mutations.joined(separator: " | "))")
        }))

        s.append(("act:no-candidate", { log.reset(); self.mark = self.sink.mark(); self.postClick(self.noCandidate) }))
        s.append(("assert:no-candidate", {
            let ok = log.backgroundDown.count == 1 && log.backgroundUp.count == 1
                && self.near(log.backgroundDown.first, self.noCandidate)
                && self.near(log.backgroundUp.first, self.noCandidate)
                && log.buttonDown.isEmpty
            self.check("3-passthrough-no-candidate", ok,
                       "posted=\(self.pt(self.noCandidate)) deliveredBgDown=\(self.points(log.backgroundDown)) deliveredBgUp=\(self.points(log.backgroundUp)) equality=orig==delivered")
            self.check("3b-no-mutation-logged", !self.sink.since(self.mark).contains { $0.contains("MUTATE") },
                       "tapLog=\(self.sink.since(self.mark).joined(separator: " | "))")
        }))

        s.append(("act:assist-disabled", {
            log.reset(); self.tap?.assistEnabled = false; self.mark = self.sink.mark(); self.postClick(self.nearMiss)
        }))
        s.append(("assert:assist-disabled", {
            let ok = log.backgroundDown.count == 1 && self.near(log.backgroundDown.first, self.nearMiss)
                && log.buttonDown.isEmpty
            self.check("4-passthrough-assist-disabled", ok,
                       "posted=\(self.pt(self.nearMiss)) deliveredBgDown=\(self.points(log.backgroundDown)) equality=orig==delivered")
            self.check("4b-disabled-logged", self.sink.since(self.mark).contains { $0.contains("reason=assist-disabled") },
                       "tapLog=\(self.sink.since(self.mark).joined(separator: " | "))")
            self.tap?.assistEnabled = true
        }))

        s.append(("act:far", { log.reset(); self.mark = self.sink.mark(); self.postClick(self.farAway) }))
        s.append(("assert:far", {
            self.check("5-passthrough-far", log.backgroundDown.count == 1
                       && self.near(log.backgroundDown.first, self.farAway) && log.buttonDown.isEmpty,
                       "posted=\(self.pt(self.farAway)) deliveredBgDown=\(self.points(log.backgroundDown))")
        }))

        s.append(("act:drag", {
            log.reset(); self.mark = self.sink.mark()
            self.postDrag(from: self.dragStart, to: self.dragEnd)
        }))
        s.append(("assert:drag", {
            let mutations = self.sink.since(self.mark).filter { $0.contains("MUTATE") }
            let ok = log.buttonDown.count == 1 && log.buttonDragged.count == 1 && log.buttonUp.count == 1
                && self.near(log.buttonDown.first, self.dragStartCorrected)
                && self.near(log.buttonDragged.first, self.dragEndCorrected)
                && self.near(log.buttonUp.first, self.dragEndCorrected)
                && log.backgroundDown.isEmpty
            self.check("6-drag-constant-delta", ok,
                       "down=\(self.points(log.buttonDown)) drag=\(self.points(log.buttonDragged)) up=\(self.points(log.buttonUp)) expectedDelta=(-13.0,0.0)")
            let deltas = Set(mutations.compactMap { line -> String? in
                guard let r = line.range(of: "delta=") else { return nil }
                return String(line[r.upperBound...].prefix(while: { $0 != " " }))
            })
            self.check("6b-one-translation-vector", deltas == ["(-13.0,0.0)"] && mutations.count == 3,
                       "deltas=\(deltas) mutations=\(mutations.count) latched=\(mutations.filter { $0.contains("gesture=latched-constant") }.count)")
        }))

        s.append(("act:after-drag", {
            log.reset()
            let stuck = CGEventSource.buttonState(.combinedSessionState, button: .left)
            self.check("7-no-stuck-button", stuck == false, "CGEventSource.buttonState(left)=\(stuck)")
            self.postClick(self.inside)
        }))
        s.append(("assert:after-drag", {
            self.check("7b-subsequent-normal-click", log.buttonDown.count == 1 && log.buttonUp.count == 1
                       && self.near(log.buttonDown.first, self.inside) && log.backgroundDown.isEmpty,
                       "deliveredDown=\(self.points(log.buttonDown)) deliveredUp=\(self.points(log.buttonUp))")
        }))

        s.append(("act:right", { log.reset(); self.mark = self.sink.mark(); self.postClick(self.nearMiss, button: .right) }))
        s.append(("assert:right", {
            self.check("8-right-click-near-miss", log.buttonRightDown.count == 1
                       && self.near(log.buttonRightDown.first, self.insideCorrected) && log.backgroundDown.isEmpty,
                       "rightDown=\(self.points(log.buttonRightDown)) expected=\(self.pt(self.insideCorrected))")
        }))

        s.append(("act:modifier", { log.reset(); self.postClick(self.nearMiss, flags: .maskCommand) }))
        s.append(("assert:modifier", {
            self.check("9-modifier-flagged-near-miss", log.buttonDown.count == 1
                       && self.near(log.buttonDown.first, self.insideCorrected) && log.backgroundDown.isEmpty,
                       "cmdClickDown=\(self.points(log.buttonDown)) expected=\(self.pt(self.insideCorrected))")
        }))
        return s
    }

    // MARK: - P1 suite (AX resolver + cache-only routing)

    private func p1Steps() -> [(String, () -> Void)] {
        var s: [(String, () -> Void)] = []
        let log = window.eventLog
        guard let cache, let resolver else { return s }

        s.append(("p1:mode", {
            self.tap?.targetSource = .cache(cache)
            NSApp.activate(ignoringOtherApps: true)
            self.window.makeKeyAndOrderFront(nil)
            resolver.suspendRefresh(false)
            resolver.setEnabled(true)
            print("P1-SUITE targetSource=cache (AX resolver -> CacheStore)")
        }))
        s.append(("wait:cache", {}))

        // GATE 2/3 setup: cache was published before any click.
        s.append(("assert:cache-warm", {
            let snap = cache.current()
            let btn = snap.targets.first { $0.key == "assistButton" }
            let viewRect = self.window.buttonTarget().rect
            // AX reports the button's content frame (inset from the NSView frame by the bezel).
            let rectOK = btn.map { viewRect.contains($0.rect)
                && abs($0.rect.midX - viewRect.midX) <= 2 && abs($0.rect.midY - viewRect.midY) <= 2 } ?? false
            self.check("P1A-ax-cache-warm", snap.valid && btn != nil && rectOK,
                       "gen=\(snap.generation) valid=\(snap.valid) targets=\(snap.targets.count) axRect=\(btn.map { "\($0.rect)" } ?? "nil") viewRect=\(viewRect) age_ms=\(String(format: "%.1f", (CACurrentMediaTime() - snap.stamp) * 1000))")
            self.check("P1B-cache-has-all-ax-controls",
                       Set(snap.targets.map(\.key)).isSuperset(of: ["assistButton", "decoyButton", "ambigLeft", "ambigRight"]),
                       "keys=\(snap.targets.map(\.key))")
            if let btn {
                self.p1NearMiss = self.window.contentPoint(forCGPoint: CGPoint(x: btn.rect.maxX + 9, y: btn.rect.midY))
                self.p1DirectHit = self.window.contentPoint(forCGPoint: CGPoint(x: btn.rect.midX, y: btn.rect.minY + 2))
            }
        }))

        // GATE 3: boundary-distance redirect to an AX-discovered element.
        s.append(("act:ax-redirect", {
            log.reset(); self.mark = self.sink.mark()
            self.postClick(self.p1NearMiss ?? self.nearMiss)
        }))
        s.append(("assert:ax-redirect", {
            let snap = cache.current()
            guard let btn = snap.targets.first(where: { $0.key == "assistButton" }) else {
                self.check("P1C-ax-redirect", false, "no cached assistButton"); return
            }
            let probe = self.p1NearMiss ?? self.nearMiss
            let expectedCG = self.clamp(self.window.cgPoint(forContentPoint: probe), btn)
            let expected = self.window.contentPoint(forCGPoint: expectedCG)
            let line = self.decisionLine()
            let latency = self.latencyUS(line)
            let ok = log.buttonDown.count == 1 && log.buttonUp.count == 1
                && self.near(log.buttonDown.first, expected) && self.near(log.buttonUp.first, expected)
                && log.backgroundDown.isEmpty && log.auxDown.isEmpty
            self.check("P1C-boundary-redirect-ax", ok,
                       "posted=\(self.pt(probe)) cachedRect=\(btn.rect) deliveredDown=\(self.points(log.buttonDown)) deliveredUp=\(self.points(log.buttonUp)) expected=\(self.pt(expected))")
            self.check("P1D-cache-sourced-before-click", (line?.contains("source=cache") ?? false)
                       && (self.ageMs(line) ?? -1) > 0
                       && self.generationPublishedBeforeDecision(line),
                       "decision=\(line ?? "nil") publishedBeforeClick=\(self.generationPublishedBeforeDecision(line))")
            self.check("P1E-callback-latency-us", (latency ?? 99999) < 500,
                       String(format: "latency_us=%.2f (callback did cache lookup only, threshold 500)", latency ?? -1))
            self.check("P1F-down-up-same-point", self.near(log.buttonDown.first, log.buttonUp.first), "down=\(self.points(log.buttonDown)) up=\(self.points(log.buttonUp))")
        }))

        // GATE 4: direct-hit priority inside a cached actionable rect.
        s.append(("act:direct-hit", {
            log.reset(); self.mark = self.sink.mark()
            self.postClick(self.p1DirectHit ?? self.insideEdge)
        }))
        s.append(("assert:direct-hit", {
            let line = self.decisionLine()
            let probe = self.p1DirectHit ?? self.insideEdge
            self.check("P1G-direct-hit-priority",
                       log.buttonDown.count == 1 && self.near(log.buttonDown.first, probe)
                       && log.backgroundDown.isEmpty && !self.sink.since(self.mark).contains(where: { $0.contains("MUTATE") })
                       && self.decisionContains("reason=direct-hit")
                       && self.decisionContains("other=decoyButton"),
                       "delivered=\(self.points(log.buttonDown)) equality=orig==delivered decision=\(line ?? "nil")")
        }))

        // GATE 5: two near-equal candidates inside tolerance -> ambiguous passthrough.
        s.append(("act:ambiguous", { log.reset(); self.mark = self.sink.mark(); self.postClick(self.ambiguous) }))
        s.append(("assert:ambiguous", {
            let line = self.decisionLine()
            self.check("P1H-ambiguity-guard",
                       log.backgroundDown.count == 1 && self.near(log.backgroundDown.first, self.ambiguous)
                       && log.buttonDown.isEmpty && log.auxDown.isEmpty
                       && !self.sink.since(self.mark).contains(where: { $0.contains("MUTATE") })
                       && self.decisionContains("reason=ambiguous")
                       && self.decisionContains("ambigLeft") && self.decisionContains("ambigRight"),
                       "posted=\(self.pt(self.ambiguous)) deliveredBg=\(self.points(log.backgroundDown)) equality=orig==delivered decision=\(line ?? "nil")")
        }))

        // GATE 6: window moved -> AX notification invalidates -> passthrough until refresh.
        s.append(("act:move", {
            log.reset()
            resolver.suspendRefresh(true)
            self.mark = self.sink.mark()
            var origin = self.window.frame.origin
            origin.x += 40
            self.window.setFrameOrigin(origin)
            print("WINDOW_MOVED to \(origin)")
        }))
        s.append(("assert:invalidated", {
            let lines = self.sink.since(self.mark)
            self.check("P1I-window-move-invalidates",
                       lines.contains { $0.contains("RESOLVER_INVALIDATE") && $0.contains("windowmoved") },
                       "resolverLog=\(lines.filter { $0.contains("RESOLVER") }.joined(separator: " | "))")
        }))
        s.append(("act:stale-probe", {
            log.reset(); self.mark = self.sink.mark()
            self.postClick(self.p1NearMiss ?? self.nearMiss)
        }))
        s.append(("assert:stale-probe", {
            let line = self.decisionLine()
            let probe = self.p1NearMiss ?? self.nearMiss
            self.check("P1J-stale-passthrough",
                       log.backgroundDown.count == 1 && self.near(log.backgroundDown.first, probe)
                       && log.buttonDown.isEmpty
                       && self.decisionContains("reason=stale:"),
                       "posted=\(self.pt(probe)) deliveredBg=\(self.points(log.backgroundDown)) equality=orig==delivered decision=\(line ?? "nil")")
        }))
        s.append(("act:resume", { resolver.suspendRefresh(false) }))
        s.append(("wait:resume", {}))
        s.append(("act:post-refresh", {
            log.reset(); self.mark = self.sink.mark()
            self.postClick(self.p1NearMiss ?? self.nearMiss)
        }))
        s.append(("assert:post-refresh", {
            let snap = cache.current()
            if let btn = snap.targets.first(where: { $0.key == "assistButton" }) {
                let p = self.p1NearMiss ?? self.nearMiss
                let expected = self.window.contentPoint(forCGPoint: self.clamp(self.window.cgPoint(forContentPoint: p), btn))
                self.check("P1K-recovered-after-refresh",
                           log.buttonDown.count == 1 && self.near(log.buttonDown.first, expected) && log.backgroundDown.isEmpty,
                           "gen=\(snap.generation) deliveredDown=\(self.points(log.buttonDown)) expected=\(self.pt(expected))")
            } else {
                self.check("P1K-recovered-after-refresh", false, "no cached assistButton after resume gen=\(snap.generation)")
            }
        }))

        // GATE 6b: resolver disabled -> unavailable, then recovery.
        s.append(("act:disable", {
            resolver.setEnabled(false)
            log.reset(); self.mark = self.sink.mark()
            self.postClick(self.p1NearMiss ?? self.nearMiss)
        }))
        s.append(("assert:disable", {
            let line = self.decisionLine()
            let probe = self.p1NearMiss ?? self.nearMiss
            self.check("P1L-unavailable-passthrough",
                       log.backgroundDown.count == 1 && self.near(log.backgroundDown.first, probe)
                       && log.buttonDown.isEmpty
                       && self.decisionContains("reason=unavailable:resolver-disabled"),
                       "posted=\(self.pt(probe)) deliveredBg=\(self.points(log.backgroundDown)) equality=orig==delivered decision=\(line ?? "nil")")
        }))
        s.append(("act:enable", { resolver.setEnabled(true) }))
        s.append(("wait:enable", {}))
        s.append(("act:final", {
            log.reset()
            self.postClick(self.p1NearMiss ?? self.nearMiss)
        }))
        s.append(("assert:final", {
            self.check("P1M-assisted-again-after-enable",
                       log.buttonDown.count == 1 && log.backgroundDown.isEmpty,
                       "deliveredDown=\(self.points(log.buttonDown)) gen=\(cache.current().generation)")
        }))
        return s
    }


    // MARK: - P2b suite (runtime-configurable tolerance: radius sweep + cache invalidation)

    private var p2bProbes: [String: NSPoint] = [:]

    /// Runtime radius change: clamp, apply to tap + overlay, then invalidate the
    /// decision cache with reason=tolerance-change so no decision computed under the
    /// old radius survives (generation bump forces a fresh eligibility calculation).
    @discardableResult
    private func applyTolerance(_ requested: CGFloat) -> CGFloat {
        let clamped = AssistTap.clampTolerance(requested)
        let old = tap?.tolerance ?? 12
        if clamped != requested {
            sink.write("TOLERANCE_CLAMP requested=\(requested) clamped=\(clamped) rule=range-8-16")
        }
        tap?.setTolerance(clamped)
        overlay?.setTolerance(clamped)
        if clamped != old, let resolver {
            let genBefore = cache?.current().generation ?? 0
            resolver.invalidate(reason: "tolerance-change", prefixStale: false)
            let genAfter = cache?.current().generation ?? 0
            sink.write("TOLERANCE_APPLY from=\(old) to=\(clamped) gen_before=\(genBefore) gen_after=\(genAfter) next=decision-under-new-radius")
        }
        return clamped
    }

    private func p2bSteps() -> [(String, () -> Void)] {
        var s: [(String, () -> Void)] = []
        let log = window.eventLog

        func redirectCase(_ key: String, _ expectedDist: Double, _ name: String,
                          overlayTol: String? = nil, latency: Bool = false) {
            s.append(("act:p2b-\(name)", {
                log.reset(); self.mark = self.sink.mark()
                self.postClick(self.p2bProbes[key]!)
            }))
            s.append(("assert:p2b-\(name)", {
                guard let line = self.decisionLine(), line.hasPrefix("MUTATE"),
                      let gen = self.value(line, key: "gen="),
                      let dist = self.value(line, key: "dist=").flatMap({ Double($0) }),
                      abs(dist - expectedDist) <= 0.05 else {
                    self.check("P2B-\(name)", false, "expected redirect dist=\(expectedDist): \(self.decisionLine() ?? "nil")")
                    return
                }
                guard let btn = self.cache?.current().targets.first(where: { $0.key == "assistButton" }) else {
                    self.check("P2B-\(name)", false, "no cached assistButton"); return
                }
                let posted = self.p2bProbes[key]!
                let expected = self.window.contentPoint(
                    forCGPoint: DecisionCore.clampPoint(self.window.cgPoint(forContentPoint: posted), into: btn.rect, inset: btn.inset))
                var overlayOK = true
                var overlayDetail = "not-checked"
                if let overlayTol {
                    // The publish holding the decision's gen may predate cursor arrival;
                    // the overlay re-renders the SAME decision on the next publish, so
                    // accept gen >= decisionGen with identical target/tol/frame/pointer.
                    let ol = self.sink.lines.first { ol in
                        guard ol.hasPrefix("OVERLAY_STATE"), ol.contains("action=show"),
                              ol.contains("target=assistButton"), ol.contains("tol=\(overlayTol)") else { return false }
                        guard let r = ol.range(of: "gen="),
                              let oGen = Int(ol[r.upperBound...].prefix { $0 != " " }),
                              let dGen = Int(gen), oGen >= dGen else { return false }
                        return true
                    }
                    var frameOK = false
                    var pointerOK = false
                    if let ol {
                        frameOK = self.nearRect(self.parseRect(ol, key: "frame=") ?? .zero, btn.rect)
                        let decidedAt = self.parsePoint(line, key: "orig=") ?? .zero
                        let shown = self.parsePoint(ol, key: "pointer=") ?? .zero
                        pointerOK = abs(shown.x - decidedAt.x) <= 3 && abs(shown.y - decidedAt.y) <= 3
                    }
                    overlayOK = ol != nil && frameOK && pointerOK
                    overlayDetail = ol ?? "nil"
                }
                self.check("P2B-\(name)",
                           log.buttonDown.count == 1 && self.near(log.buttonDown.first, expected)
                           && log.backgroundDown.isEmpty && overlayOK,
                           "posted=\(self.pt(posted)) delivered=\(self.points(log.buttonDown)) expected=\(self.pt(expected)) dist=\(dist) tol=\(self.tap?.tolerance ?? -1) overlay=\(overlayDetail)")
                if latency {
                    let us = self.latencyUS(line) ?? 99999
                    self.check("P2B-\(name)-latency-us", us < 500,
                               String(format: "latency_us=%.2f threshold=500 radius=8", us))
                }
            }))
        }

        func passCase(_ key: String, _ reason: String, _ name: String, direct: Bool = false) {
            s.append(("act:p2b-\(name)", {
                log.reset(); self.mark = self.sink.mark()
                self.postClick(self.p2bProbes[key]!)
            }))
            s.append(("assert:p2b-\(name)", {
                let posted = self.p2bProbes[key]!
                let delivered = direct ? log.buttonDown : log.backgroundDown
                let untouched = direct ? log.backgroundDown.isEmpty : log.buttonDown.isEmpty
                self.check("P2B-\(name)",
                           delivered.count == 1 && self.near(delivered.first, posted) && untouched
                           && self.decisionContains("reason=\(reason)"),
                           "posted=\(self.pt(posted)) delivered=\(self.points(delivered)) equality=orig==delivered router=\(self.decisionLine() ?? "nil")")
            }))
        }

        s.append(("p2b:mode", {
            print("P2B-SUITE runtime-tolerance default=12 range=8-16 clamped semantics=boundary-distance<=tolerance")
        }))

        // Probes derived from the LIVE cached rect (exact boundary distances by construction).
        s.append(("assert:p2b-probes", {
            guard let btn = self.cache?.current().targets.first(where: { $0.key == "assistButton" }) else {
                self.check("P2B0-probes-from-cache", false, "no cached assistButton"); return
            }
            self.p2bProbes["direct"] = self.window.contentPoint(forCGPoint: CGPoint(x: btn.rect.midX, y: btn.rect.midY))
            for k in [8.0, 12.0, 16.0, 17.5] {
                self.p2bProbes["k\(k)"] = self.window.contentPoint(forCGPoint: CGPoint(x: btn.rect.maxX + k, y: btn.rect.midY))
            }
            self.check("P2B0-probes-from-cache", true,
                       "axRect=\(btn.rect) direct=\(self.pt(self.p2bProbes["direct"]!)) k8=\(self.pt(self.p2bProbes["k8.0"]!)) k12=\(self.pt(self.p2bProbes["k12.0"]!)) k16=\(self.pt(self.p2bProbes["k16.0"]!)) k17.5=\(self.pt(self.p2bProbes["k17.5"]!))")
        }))

        // GATE 4 sweep at default radius 12.
        passCase("direct", "direct-hit", "r0-direct-hit-at-tol12", direct: true)
        redirectCase("k8.0", 8.0, "r8-redirect-at-tol12")
        redirectCase("k12.0", 12.0, "r12-redirect-at-default-tol12")
        passCase("k17.5", "no-candidate-in-radius", "r17.5-beyond-tol12")

        // GATE 3: tolerance change mid-run -> generation bump, fresh eligibility.
        s.append(("act:p2b-tol16", { self.mark = self.sink.mark(); self.applyTolerance(16) }))
        s.append(("assert:p2b-tol16", {
            let lines = self.sink.since(self.mark)
            let apply = lines.first { $0.hasPrefix("TOLERANCE_APPLY") && $0.contains("to=16.0") }
            let invalidate = lines.first { $0.contains("RESOLVER_INVALIDATE") && $0.contains("reason=tolerance-change") }
            var genOK = false
            if let apply, let rBefore = apply.range(of: "gen_before="),
               let rAfter = apply.range(of: "gen_after=") {
                let b = Int(apply[rBefore.upperBound...].prefix { $0 != " " }) ?? -1
                let a = Int(apply[rAfter.upperBound...].prefix { $0 != " " }) ?? -1
                genOK = a > b
            }
            self.check("P2B5-tolerance-change-bumps-generation",
                       apply != nil && invalidate != nil && genOK,
                       "apply=\(apply ?? "nil") invalidate=\(invalidate ?? "nil") genBumped=\(genOK)")
        }))
        s.append(("wait:p2b-tol16", {}))

        redirectCase("k16.0", 16.0, "r16-redirect-at-tol16")
        passCase("k17.5", "no-candidate-in-radius", "r17.5-beyond-tol16")

        s.append(("act:p2b-tol8", { self.mark = self.sink.mark(); self.applyTolerance(8) }))
        s.append(("assert:p2b-tol8", {
            let lines = self.sink.since(self.mark)
            let apply = lines.first { $0.hasPrefix("TOLERANCE_APPLY") && $0.contains("to=8.0") }
            let invalidate = lines.first { $0.contains("RESOLVER_INVALIDATE") && $0.contains("reason=tolerance-change") }
            self.check("P2B8-tolerance-shrink-bumps-generation",
                       apply != nil && invalidate != nil,
                       "apply=\(apply ?? "nil") invalidate=\(invalidate ?? "nil")")
        }))
        s.append(("wait:p2b-tol8", {}))

        // GATE 5: redirect at minimum radius + latency + overlay same-decision at tol=8.
        redirectCase("k8.0", 8.0, "r8-redirect-at-tol8", overlayTol: "8.0", latency: true)
        passCase("k12.0", "no-candidate-in-radius", "r12-beyond-shrunk-tol8")

        // GATE 2: out-of-range values are CLAMPED (evidence line), then restore default.
        s.append(("act:p2b-clamp", { self.mark = self.sink.mark(); self.applyTolerance(20); self.applyTolerance(5) }))
        s.append(("assert:p2b-clamp", {
            let lines = self.sink.since(self.mark)
            let hi = lines.contains { $0.hasPrefix("TOLERANCE_CLAMP") && $0.contains("requested=20.0") && $0.contains("clamped=16.0") }
            let lo = lines.contains { $0.hasPrefix("TOLERANCE_CLAMP") && $0.contains("requested=5.0") && $0.contains("clamped=8.0") }
            self.check("P2B11-out-of-range-clamped", hi && lo,
                       "high=\(hi) low=\(lo) rule=range-8-16 action=clamp")
        }))
        s.append(("act:p2b-restore", { self.applyTolerance(12) }))
        return s
    }


    // MARK: - P3 suite (gesture classes: double-click, drag threshold, analog controls, interruptions)

    private var p3Probes: [String: NSPoint] = [:]
    private var p3BtnTarget: CachedTarget?

    /// General bounded delivery wait for gesture-up assertions: poll `check` on the
    /// main runloop (letting queued events process between polls) until it passes or
    /// the deadline expires. Bounded — on expiry the body runs with `false` so the
    /// caller FAILS with evidence instead of papering over a real delivery miss.
    private func awaitDelivery(deadline: TimeInterval = 2.0, interval: TimeInterval = 0.05,
                               check: @escaping () -> Bool,
                               then body: @escaping (_ deliveredInTime: Bool) -> Void) {
        let start = CACurrentMediaTime()
        func poll() {
            if check() { body(true); return }
            if CACurrentMediaTime() - start >= deadline { body(false); return }
            DispatchQueue.main.asyncAfter(deadline: .now() + interval) { poll() }
        }
        poll()
    }

    /// Native-control gestures must not start inside a stale window (AX events from the
    /// previous gesture invalidate briefly); run body on the first fresh snapshot.
    private func whenFresh(_ body: @escaping () -> Void) {
        func attempt(_ n: Int) {
            guard n > 0 else { body(); return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                guard self.cache?.current().valid == true else { attempt(n - 1); return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    if self.cache?.current().valid == true { body() } else { attempt(n - 1) }
                }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { attempt(12) }
    }

    /// Re-activate the harness if something stole frontmost (log the recovery).
    private func ensureFrontmost(_ tag: String) {
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier != getpid() else { return }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        sink.write("P3-FOCUSRESTORED at=\(tag) frontmost=\(NSWorkspace.shared.frontmostApplication?.localizedName ?? "-")")
    }

    private func buttonStateLeft() -> Bool {
        CGEventSource.buttonState(.combinedSessionState, button: .left)
    }

    /// Click posted as two down/up pairs inside the system double-click interval.
    private func postDoubleClick(_ p: NSPoint, flags: CGEventFlags = []) {
        postClick(p, flags: flags, clickState: 1)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
            self.postClick(p, flags: flags, clickState: 2)
        }
    }

    /// Gesture sequences against NATIVE controls (slider/scroller/text view). Their
    /// tracking loops block the main run loop, so events are posted from a background
    /// queue; the tap source is registered in commonModes and keeps mutating.
    private func postGestureBG(_ events: [(CGEventType, CGPoint, CGEventFlags)], gap: Double = 0.06,
                               leadIn: Double = 0.35) {
        let src = CGEventSource(stateID: .hidSystemState)
        // leadIn: the overlay ring resizes to the new cursor position when the moved
        // event lands, which invalidates once; the down follows after it settles.
        func step(_ i: Int, delay: Double) {
            DispatchQueue.global().asyncAfter(deadline: .now() + delay) {
                let (t, p, f) = events[i]
                if let e = CGEvent(mouseEventSource: src, mouseType: t, mouseCursorPosition: p, mouseButton: .left) {
                    e.flags = f
                    e.post(tap: .cghidEventTap)
                }
                if i + 1 < events.count {
                    step(i + 1, delay: i == 0 ? leadIn : gap)
                }
            }
        }
        step(0, delay: 0)
    }

    /// Expected delivered point for a posted CG point redirected into `t` (shared clamp).
    private func redirectedExpected(_ postedCG: CGPoint, _ t: CachedTarget) -> NSPoint {
        self.window.contentPoint(forCGPoint: DecisionCore.clampPoint(postedCG, into: t.rect, inset: t.inset))
    }

    private func p3Steps() -> [(String, () -> Void)] {
        var s: [(String, () -> Void)] = []
        let log = self.window.eventLog
        let slog = self.window.sliderLog
        let clog = self.window.scrollLog
        let tlog = self.window.textLog

        // System dialogs (universalAccessAuthWarn) can steal frontmost; recover ours.
        s.append(("act:p3-recover", {
            let warn = NSWorkspace.shared.runningApplications.first {
                $0.localizedName?.contains("universalAccessAuthWarn") == true
            }
            if let warn { warn.terminate(); print("P3-PRE dismissed universalAccessAuthWarn pid=\(warn.processIdentifier)") }
            NSApp.activate(ignoringOtherApps: true)
            self.window.makeKeyAndOrderFront(nil)
            print("P3-PRE frontmost=\(NSWorkspace.shared.frontmostApplication?.localizedName ?? "-") pid=\(getpid())")
        }))
        s.append(("wait:p3-recover", {}))

        // Probe geometry from the live cache (exact boundary distances by construction).
        s.append(("p3:probes", {
            guard let btn = self.cache?.current().targets.first(where: { $0.key == "assistButton" }),
                  let sld = self.cache?.current().targets.first(where: { $0.key == "assistSlider" }),
                  let scr = self.cache?.current().targets.first(where: { $0.key == "assistScrollbar" }),
                  let txt = self.cache?.current().targets.first(where: { $0.key == "assistTextField" }) else {
                self.check("P3A0-probes-from-cache", false,
                           "targets=\(self.cache?.current().targets.map(\.key) ?? [])"); return
            }
            self.p3BtnTarget = btn
            func cp(_ cg: CGPoint) -> NSPoint { self.window.contentPoint(forCGPoint: cg) }
            self.p3Probes["btnK9"] = cp(CGPoint(x: btn.rect.maxX + 9, y: btn.rect.midY))
            self.p3Probes["btnK2"] = cp(CGPoint(x: btn.rect.maxX + 2, y: btn.rect.midY))
            self.p3Probes["btnInA"] = cp(CGPoint(x: btn.rect.minX + 20, y: btn.rect.midY))
            self.p3Probes["btnInB"] = cp(CGPoint(x: btn.rect.minX + 20, y: btn.rect.midY - 20))
            self.p3Probes["btnCenter"] = cp(CGPoint(x: btn.rect.midX, y: btn.rect.midY))
            // slider: press 8 pt BELOW the track at the value-30 knob x -> x is preserved by the clamp
            let knobW: CGFloat = 23, v0: CGFloat = 30
            let usable = sld.rect.width - knobW
            let knobX = sld.rect.minX + knobW / 2 + (v0 / 100) * usable
            self.p3Probes["sldBelow"] = cp(CGPoint(x: knobX, y: sld.rect.minY - 8))
            // scrollbar analog (vertical slider): press 8 pt RIGHT of the track at knob y
            self.p3Probes["scrRight"] = cp(CGPoint(x: scr.rect.maxX + 8, y: scr.rect.midY))
            // text view: direct-hit inside; redirected 8 pt LEFT of the left edge
            self.p3Probes["txtIn1"] = cp(CGPoint(x: txt.rect.minX + 40, y: txt.rect.midY))
            self.p3Probes["txtIn2"] = cp(CGPoint(x: txt.rect.minX + 100, y: txt.rect.midY))
            self.p3Probes["txtLeft"] = cp(CGPoint(x: txt.rect.minX - 8, y: txt.rect.midY))
            self.p3Probes["bgFar"] = cp(self.window.cgPoint(forContentPoint: NSPoint(x: 100, y: 320)))
            self.check("P3A0-probes-from-cache", true,
                       "btn=\(btn.rect) slider=\(sld.rect) scroll=\(scr.rect) text=\(txt.rect) dblClickInterval=\(String(format: "%.2f", NSEvent.doubleClickInterval))s")
        }))

        // GATE 2: double-click — two redirected clicks inside the interval -> clickState=2.
        s.append(("act:p3-dbl-redirected", { log.reset(); self.mark = self.sink.mark(); self.postDoubleClick(self.p3Probes["btnK9"]!) }))
        s.append(("assert:p3-dbl-redirected", {
            guard let btn = self.p3BtnTarget else {
                self.check("P3A1-doubleclick-redirected", false, "no probe-time assistButton rect"); return
            }
            let mutations = self.sink.since(self.mark).filter { $0.contains("MUTATE") }
            let expected = self.redirectedExpected(self.window.cgPoint(forContentPoint: self.p3Probes["btnK9"]!), btn)
            self.check("P3A1-doubleclick-redirected",
                       log.buttonDown.count == 2 && log.buttonUp.count == 2
                       && log.buttonClickCounts == [1, 2]
                       && self.near(log.buttonDown.last, expected) && log.backgroundDown.isEmpty
                       && mutations.count == 4,
                       "deliveredDown=\(self.points(log.buttonDown)) expected=\(self.pt(expected)) clickStates=\(log.buttonClickCounts) mutations=\(mutations.count) clickState2AtTarget=\(self.near(log.buttonDown.last, expected))")
        }))

        // GATE 2: redirected click + (later, outside interval) direct-hit click -> clickState=1.
        s.append(("act:p3-pair-first", { log.reset(); self.mark = self.sink.mark(); self.postClick(self.p3Probes["btnK9"]!) }))
        s.append(("wait:p3-pair-interval1", {}))
        s.append(("wait:p3-pair-interval2", {}))
        s.append(("act:p3-pair-second", { log.reset(); self.mark = self.sink.mark(); self.postClick(self.p3Probes["btnCenter"]!) }))
        s.append(("assert:p3-pair-second", {
            self.check("P3A2-pair-outside-interval-clickstate1",
                       log.buttonDown.count == 1 && log.buttonClickCounts == [1]
                       && self.near(log.buttonDown.first, self.p3Probes["btnCenter"])
                       && !self.sink.since(self.mark).contains(where: { $0.contains("MUTATE") }),
                       "deliveredDown=\(self.points(log.buttonDown)) clickStates=\(log.buttonClickCounts) equality=orig==delivered (direct hit)")
        }))

        // GATE 2: direct-hit double-click -> native pass-through, clickState=2.
        s.append(("act:p3-dbl-direct", { log.reset(); self.mark = self.sink.mark(); self.postDoubleClick(self.p3Probes["btnCenter"]!) }))
        s.append(("assert:p3-dbl-direct", {
            self.check("P3A3-doubleclick-direct-native",
                       log.buttonDown.count == 2 && log.buttonClickCounts == [1, 2]
                       && self.near(log.buttonDown.first, self.p3Probes["btnCenter"])
                       && self.near(log.buttonDown.last, self.p3Probes["btnCenter"])
                       && !self.sink.since(self.mark).contains(where: { $0.contains("MUTATE") })
                       && log.backgroundDown.isEmpty,
                       "deliveredDown=\(self.points(log.buttonDown)) clickStates=\(log.buttonClickCounts) mutations=0 equality=orig==delivered")
        }))

        // GATE 3: movement below drag slop still completes as a click (redirected down).
        s.append(("act:p3-slop", {
            log.reset(); self.mark = self.sink.mark()
            self.postDrag(from: self.p3Probes["btnK2"]!, to: NSPoint(x: self.p3Probes["btnK2"]!.x + 2, y: self.p3Probes["btnK2"]!.y))
        }))
        s.append(("assert:p3-slop", {
            guard let btn = self.cache?.current().targets.first(where: { $0.key == "assistButton" }) else {
                self.check("P3B1-below-drag-slop", false, "no cached assistButton"); return
            }
            let expected = self.redirectedExpected(self.window.cgPoint(forContentPoint: self.p3Probes["btnK2"]!), btn)
            let expectedUp = NSPoint(x: expected.x + 2, y: expected.y)   // latched delta applies to the up
            self.check("P3B1-below-drag-slop",
                       log.buttonDown.count == 1 && log.buttonUp.count == 1
                       && self.near(log.buttonDown.first, expected) && self.near(log.buttonUp.first, expectedUp)
                       && log.buttonClickCounts == [1] && !self.buttonStateLeft(),
                       "deliveredDown=\(self.points(log.buttonDown)) expectedDown=\(self.pt(expected)) deliveredUp=\(self.points(log.buttonUp)) expectedUp=\(self.pt(expectedUp)) clickStates=\(log.buttonClickCounts) buttonStateLeft=\(self.buttonStateLeft())")
        }))

        // GATE 3: redirected drag — one latched rigid translation on dragged + up.
        s.append(("act:p3-redirected-drag", {
            log.reset(); self.mark = self.sink.mark()
            self.postDrag(from: self.p3Probes["btnK9"]!, to: NSPoint(x: self.p3Probes["btnK9"]!.x, y: self.p3Probes["btnK9"]!.y - 20))
        }))
        s.append(("assert:p3-redirected-drag", {
            guard let btn = self.p3BtnTarget else {
                self.check("P3B2-redirected-drag-rigid", false, "no probe-time assistButton rect"); return
            }
            let eDown = self.redirectedExpected(self.window.cgPoint(forContentPoint: self.p3Probes["btnK9"]!), btn)
            let eUp = self.redirectedExpected(self.window.cgPoint(forContentPoint: NSPoint(x: self.p3Probes["btnK9"]!.x, y: self.p3Probes["btnK9"]!.y - 20)), btn)
            let ok = log.buttonDown.count == 1 && log.buttonDragged.count == 1 && log.buttonUp.count == 1
                && self.near(log.buttonDown.first, eDown) && self.near(log.buttonDragged.first, eUp)
                && self.near(log.buttonUp.first, eUp) && !self.buttonStateLeft()
            self.check("P3B2-redirected-drag-rigid", ok,
                       "down=\(self.points(log.buttonDown)) drag=\(self.points(log.buttonDragged)) up=\(self.points(log.buttonUp)) eDown=\(self.pt(eDown)) eUp=\(self.pt(eUp)) rigid=latched-constant buttonStateLeft=\(self.buttonStateLeft())")
        }))

        // GATE 3: direct-hit drag — zero mutation.
        s.append(("act:p3-direct-drag", {
            log.reset(); self.mark = self.sink.mark()
            self.postDrag(from: self.p3Probes["btnInA"]!, to: self.p3Probes["btnInB"]!)
        }))
        s.append(("assert:p3-direct-drag", {
            self.check("P3B3-direct-drag-zero-mutation",
                       log.buttonDown.count == 1 && self.near(log.buttonDown.first, self.p3Probes["btnInA"])
                       && self.near(log.buttonUp.first, self.p3Probes["btnInB"])
                       && !self.sink.since(self.mark).contains(where: { $0.contains("MUTATE") })
                       && !self.buttonStateLeft(),
                       "down=\(self.points(log.buttonDown)) up=\(self.points(log.buttonUp)) mutations=0 equality=orig==delivered buttonStateLeft=\(self.buttonStateLeft())")
        }))

        // GATE 4a: slider — redirected press below the track, drag right +40 px.
        s.append(("act:p3-slider", {
            log.reset(); slog.reset()
            self.ensureFrontmost("p3-slider")
            self.window.p3Slider?.doubleValue = 30
            self.mark = self.sink.mark()
            self.whenFresh {
                let p0 = self.window.cgPoint(forContentPoint: self.p3Probes["sldBelow"]!)
                var events: [(CGEventType, CGPoint, CGEventFlags)] = [(.mouseMoved, p0, []),
                                                                      (.leftMouseDown, p0, [])]
                for i in 1...4 { events.append((.leftMouseDragged, CGPoint(x: p0.x + CGFloat(i) * 10, y: p0.y), [])) }
                events.append((.leftMouseUp, CGPoint(x: p0.x + 40, y: p0.y), []))
                self.postGestureBG(events)
            }
        }))
        s.append(("wait:p3-slider", {}))
        s.append(("wait:p3-slider2", {}))
        s.append(("wait:p3-slider3", {}))
        s.append(("assert:p3-slider", {
            guard let sld = self.cache?.current().targets.first(where: { $0.key == "assistSlider" }) else {
                self.check("P3C1-slider-redirected-press-drag", false, "no cached assistSlider"); return
            }
            let eDown = self.redirectedExpected(self.window.cgPoint(forContentPoint: self.p3Probes["sldBelow"]!), sld)
            let value = self.window.p3Slider?.doubleValue ?? -1
            let stable = self.window.p3Slider?.doubleValue ?? -2
            let ok = slog.buttonDown.count == 1
                && self.near(slog.buttonDown.first, eDown)
                && value > 38 && value < 62 && abs(value - stable) < 0.001 && !self.buttonStateLeft()
            self.check("P3C1-slider-redirected-press-drag", ok,
                       "deliveredDown=\(self.points(slog.buttonDown)) expected=\(self.pt(eDown)) value0=30 value=\(String(format: "%.1f", value)) delta=\(String(format: "%.1f", value - 30)) for40px stable=\(value == stable) buttonStateLeft=\(self.buttonStateLeft())")
        }))

        // GATE 4b: scrollbar analog (vertical slider) — redirected press right of the
        // track at knob height, drag up 40 px; value must track the translated drag.
        s.append(("act:p3-scroller", {
            log.reset(); clog.reset()
            self.ensureFrontmost("p3-scroller")
            self.window.p3Scrollbar?.doubleValue = 0.5
            self.mark = self.sink.mark()
            self.whenFresh {
                let p0 = self.window.cgPoint(forContentPoint: self.p3Probes["scrRight"]!)
                var events: [(CGEventType, CGPoint, CGEventFlags)] = [(.mouseMoved, p0, []),
                                                                      (.leftMouseDown, p0, [])]
                for i in 1...4 { events.append((.leftMouseDragged, CGPoint(x: p0.x, y: p0.y - CGFloat(i) * 10), [])) }
                events.append((.leftMouseUp, CGPoint(x: p0.x, y: p0.y - 40), []))
                self.postGestureBG(events)
            }
        }))
        s.append(("wait:p3-scroller", {}))
        s.append(("wait:p3-scroller2", {}))
        s.append(("wait:p3-scroller3", {}))
        s.append(("assert:p3-scroller", {
            guard let scr = self.cache?.current().targets.first(where: { $0.key == "assistScrollbar" }) else {
                self.check("P3C2-scrollbar-redirected-press-drag", false, "no cached assistScrollbar"); return
            }
            let eDown = self.redirectedExpected(self.window.cgPoint(forContentPoint: self.p3Probes["scrRight"]!), scr)
            let value = self.window.p3Scrollbar?.doubleValue ?? -1
            let stable = self.window.p3Scrollbar?.doubleValue ?? -2
            let ok = clog.buttonDown.count == 1 && self.near(clog.buttonDown.first, eDown)
                && value > 0.55 && value < 0.98
                && abs(value - stable) < 0.001 && !self.buttonStateLeft()
            self.check("P3C2-scrollbar-redirected-press-drag", ok,
                       "control=vertical-slider-scrollbar-analog deliveredDown=\(self.points(clog.buttonDown)) expected=\(self.pt(eDown)) drags=\(clog.buttonDragged.count) value0=0.5 value=\(String(format: "%.3f", value)) delta=\(String(format: "%.3f", value - 0.5)) for40pxUp stable=\(value == stable) buttonStateLeft=\(self.buttonStateLeft())")
        }))

        // GATE 5a: text selection via DIRECT hit — zero mutation, selection extends.
        s.append(("act:p3-text-direct", {
            log.reset(); tlog.reset()
            self.ensureFrontmost("p3-text-direct")
            self.window.p3Text?.selectedRange = NSRange(location: 0, length: 0)
            self.mark = self.sink.mark()
            self.whenFresh {
                let p0 = self.window.cgPoint(forContentPoint: self.p3Probes["txtIn1"]!)
                var events: [(CGEventType, CGPoint, CGEventFlags)] = [(.mouseMoved, p0, []),
                                                                      (.leftMouseDown, p0, []),
                                                                      (.leftMouseDragged, self.window.cgPoint(forContentPoint: self.p3Probes["txtIn2"]!), [])]
                events.append((.leftMouseUp, self.window.cgPoint(forContentPoint: self.p3Probes["txtIn2"]!), []))
                self.postGestureBG(events)
            }
        }))
        s.append(("wait:p3-text-direct", {}))
        s.append(("wait:p3-text-direct2", {}))
        s.append(("assert:p3-text-direct", {
            let sel = self.window.p3Text?.selectedRange.length ?? -1
            self.check("P3D1-textfield-direct-select-no-mutation",
                       tlog.buttonDown.count == 1 && self.near(tlog.buttonDown.first, self.p3Probes["txtIn1"])
                       && !self.sink.since(self.mark).contains(where: { $0.contains("MUTATE") })
                       && sel > 0 && !self.buttonStateLeft(),
                       "down=\(self.points(tlog.buttonDown)) equality=orig==delivered selectedLength=\(sel) mutations=0 buttonStateLeft=\(self.buttonStateLeft()) (NSTextView tracking consumes dragged/up)")
        }))

        // GATE 5b: REDIRECTED down into the text view, drag extends selection at translated coords.
        s.append(("act:p3-text-redirected", {
            log.reset(); tlog.reset()
            self.window.p3Text?.selectedRange = NSRange(location: 0, length: 0)
            self.mark = self.sink.mark()
            let p0 = self.window.cgPoint(forContentPoint: self.p3Probes["txtLeft"]!)
            let pUp = self.window.cgPoint(forContentPoint: self.p3Probes["bgFar"]!)
            var events: [(CGEventType, CGPoint, CGEventFlags)] = [(.mouseMoved, p0, []),
                                                                  (.leftMouseDown, p0, [])]
            for i in 1...4 { events.append((.leftMouseDragged, CGPoint(x: p0.x + CGFloat(i) * 20, y: p0.y), [])) }
            events.append((.leftMouseUp, pUp, []))
            self.postGestureBG(events)
        }))
        s.append(("wait:p3-text-redirected", {}))
        s.append(("wait:p3-text-redirected2", {}))
        s.append(("assert:p3-text-redirected", {
            guard let txt = self.cache?.current().targets.first(where: { $0.key == "assistTextField" }) else {
                self.check("P3D2-textfield-redirected-selection", false, "no cached assistTextField"); return
            }
            let eDown = self.redirectedExpected(self.window.cgPoint(forContentPoint: self.p3Probes["txtLeft"]!), txt)
            let sel = self.window.p3Text?.selectedRange.length ?? -1
            let mutations = self.sink.since(self.mark).filter { $0.contains("MUTATE") && $0.contains("type=leftMouseDown") }
            self.check("P3D2-textfield-redirected-selection",
                       tlog.buttonDown.count == 1 && self.near(tlog.buttonDown.first, eDown)
                       && sel > 0 && mutations.count == 1
                       && !self.buttonStateLeft(),
                       "deliveredDown=\(self.points(tlog.buttonDown)) expected=\(self.pt(eDown)) selectedLength=\(sel) mutatedDown=\(mutations.count) buttonStateLeft=\(self.buttonStateLeft())")
        }))
        s.append(("act:p3-text-defocus", {
            log.reset(); self.mark = self.sink.mark()
            self.postClick(self.p3Probes["btnCenter"]!)   // mouse-up elsewhere
        }))
        s.append(("assert:p3-text-defocus", {
            let sel = self.window.p3Text?.selectedRange.length ?? -1
            self.check("P3D3-textfield-no-stuck-selection-state",
                       log.buttonDown.count == 1 && !self.buttonStateLeft() && sel == 27,
                       "mouseUpElsewhere=\(log.buttonDown.count) selectionFrozenAt=\(sel) (27, not extending) buttonStateLeft=\(self.buttonStateLeft())")
        }))
        s.append(("act:p3-text-fresh", {
            log.reset(); tlog.reset()
            self.mark = self.sink.mark()
            self.postClick(self.p3Probes["txtIn1"]!)
        }))
        s.append(("assert:p3-text-fresh", {
            let sel = self.window.p3Text?.selectedRange.length ?? -1
            self.check("P3D3b-no-stuck-selection-fresh-click",
                       tlog.buttonDown.count == 1 && sel == 0 && !self.buttonStateLeft(),
                       "freshClick=\(tlog.buttonDown.count) selectionLength=\(sel) (0 = stale selection gone) buttonStateLeft=\(self.buttonStateLeft())")
        }))

        // GATE 6: modifier-flagged redirected click + drag — flags preserved on delivery.
        s.append(("act:p3-modifiers", {
            log.reset(); self.mark = self.sink.mark()
            self.whenFresh {
                self.postClick(self.p3Probes["btnK9"]!, flags: .maskShift)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    self.postClick(self.p3Probes["btnK9"]!, flags: .maskCommand)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        self.postDrag(from: self.p3Probes["btnK9"]!, to: NSPoint(x: self.p3Probes["btnK9"]!.x, y: self.p3Probes["btnK9"]!.y - 20), flags: .maskAlternate)
                    }
                }
            }
        }))
        s.append(("wait:p3-modifiers1", {}))
        s.append(("wait:p3-modifiers2", {}))
        s.append(("wait:p3-modifiers3", {}))
        s.append(("wait:p3-modifiers4", {}))
        s.append(("assert:p3-modifiers", {
            let shift = log.buttonDownFlags.first.map { $0 & CGEventFlags.maskShift.rawValue != 0 } ?? false
            let cmd = log.buttonDownFlags.dropFirst().first.map { $0 & CGEventFlags.maskCommand.rawValue != 0 } ?? false
            let alt = log.buttonDragFlags.last.map { $0 & CGEventFlags.maskAlternate.rawValue != 0 } ?? false
            let srcFlags = CGEventSource.flagsState(.combinedSessionState)
            self.check("P3E0-modifier-flags-preserved",
                       log.buttonDown.count == 3 && shift && cmd && alt
                       && !self.buttonStateLeft(),
                       "downs=\(log.buttonDown.count) downFlags=\(log.buttonDownFlags.map { "0x" + String($0, radix: 16) }) shift=\(shift) cmd=\(cmd) altDrag=\(alt) buttonStateLeft=\(self.buttonStateLeft())")
        }))

        // GATE 7a: snapshot invalidated MID-GESTURE — latched gesture completes, next click fresh.
        s.append(("act:p7-invalid-midgesture", {
            self.resolver?.suspendRefresh(true)
            log.reset(); self.mark = self.sink.mark()
            self.postDrag(from: self.p3Probes["btnK9"]!, to: NSPoint(x: self.p3Probes["btnK9"]!.x, y: self.p3Probes["btnK9"]!.y - 20))
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.045) {
                self.resolver?.invalidate(reason: "midgesture-test")
            }
        }))
        s.append(("wait:p7a", {}))
        s.append(("assert:p7-invalid-midgesture", {
            guard let btn = self.p3BtnTarget else {
                self.check("P3E1-invalidated-midgesture-latch-completes", false, "no probe-time assistButton rect"); return
            }
            let eUp = self.redirectedExpected(self.window.cgPoint(forContentPoint: NSPoint(x: self.p3Probes["btnK9"]!.x, y: self.p3Probes["btnK9"]!.y - 20)), btn)
            let invalid = self.sink.since(self.mark).contains { $0.contains("RESOLVER_INVALIDATE") && $0.contains("reason=stale:midgesture-test") }
            self.awaitDelivery(deadline: 2.0, check: { log.buttonUp.count == 1 }) { delivered in
                self.check("P3E1-invalidated-midgesture-latch-completes",
                           delivered && self.near(log.buttonUp.first, eUp) && invalid
                           && !self.buttonStateLeft(),
                           "upDeliveredInWindow=\(delivered) up=\(self.points(log.buttonUp)) eUp=\(self.pt(eUp)) rigid=latched-constant (latch survives snapshot invalidation) invalidate=\(invalid) buttonStateLeft=\(self.buttonStateLeft())")
            }
        }))
        s.append(("act:p7-invalid-nextclick", { log.reset(); self.mark = self.sink.mark(); self.postClick(self.p3Probes["btnK9"]!) }))
        s.append(("assert:p7-invalid-nextclick", {
            self.check("P3E1b-next-click-fresh-passthrough",
                       log.backgroundDown.count == 1 && self.near(log.backgroundDown.first, self.p3Probes["btnK9"])
                       && log.buttonDown.isEmpty && self.decisionContains("reason=stale:"),
                       "deliveredBg=\(self.points(log.backgroundDown)) equality=orig==delivered router=\(self.decisionLine() ?? "nil")")
            self.resolver?.suspendRefresh(false)
        }))

        // GATE 7b: tap disabled MID-GESTURE — up delivers unmuted, no stuck button, re-enable works.
        s.append(("act:p7b-tapoff-midgesture", {
            log.reset(); self.mark = self.sink.mark()
            let p = self.window.cgPoint(forContentPoint: self.p3Probes["btnK9"]!)
            self.post(.mouseMoved, at: p, button: .left, flags: [])
            self.post(.leftMouseDown, at: p, button: .left, flags: [])
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                self.tap?.setTapEnabled(false)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    self.post(.leftMouseUp, at: p, button: .left, flags: [])
                }
            }
        }))
        s.append(("wait:p7b", {}))
        s.append(("assert:p7b-tapoff-midgesture", {
            let upUnmuted = self.near(log.buttonUp.first, self.p3Probes["btnK9"])
            self.check("P3E2-tap-disabled-midgesture",
                       log.buttonDown.count == 1 && log.buttonUp.count == 1 && upUnmuted
                       && !self.buttonStateLeft()
                       && self.sink.since(self.mark).contains { $0.contains("TAP_DISABLED") },
                       "down=\(self.points(log.buttonDown)) upAtPosted=\(self.points(log.buttonUp)) unmuted=\(upUnmuted) buttonStateLeft=\(self.buttonStateLeft())")
            self.tap?.setTapEnabled(true)
        }))
        s.append(("act:p7b-after-reenable", { log.reset(); self.mark = self.sink.mark(); self.postClick(self.p3Probes["btnK9"]!) }))
        s.append(("assert:p7b-after-reenable", {
            guard let btn = self.cache?.current().targets.first(where: { $0.key == "assistButton" }) else {
                self.check("P3E2b-after-reenable-redirect-works", false, "no cached assistButton"); return
            }
            let expected = self.redirectedExpected(self.window.cgPoint(forContentPoint: self.p3Probes["btnK9"]!), btn)
            self.check("P3E2b-after-reenable-redirect-works",
                       log.buttonDown.count == 1 && self.near(log.buttonDown.first, expected)
                       && log.buttonClickCounts == [1] && !self.buttonStateLeft(),
                       "deliveredDown=\(self.points(log.buttonDown)) expected=\(self.pt(expected)) clickStates=\(log.buttonClickCounts) buttonStateLeft=\(self.buttonStateLeft())")
        }))

        // GATE 7c: frontmost-app switch MID-DRAG — gesture delivered consistently, no orphaned state.
        // DEFECT 4 FIX: this is the only baseline case that activates an external app
        // (Finder), so it is gated with the dangerous cases and never runs in plain --selftest.
        if self.allowDangerous {
        s.append(("act:p7c-appswitch", {
            log.reset(); self.mark = self.sink.mark()
            let p0 = self.window.cgPoint(forContentPoint: self.p3Probes["btnK9"]!)
            let p1 = CGPoint(x: p0.x, y: p0.y - 20)
            var events: [(CGEventType, CGPoint, CGEventFlags)] = [(.mouseMoved, p0, []),
                                                                  (.leftMouseDown, p0, []),
                                                                  (.leftMouseDragged, p1, []),
                                                                  (.leftMouseUp, p1, [])]
            self.postGestureBG(events, gap: 0.15)
            let before = NSWorkspace.shared.frontmostApplication?.localizedName ?? "-"
            print("P3-7C frontmost_before=\(before)")
            // down lands at +0.35 (leadIn); switch frontmost mid-drag at +0.45
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
                let finder = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first
                finder?.activate(options: [.activateIgnoringOtherApps])
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    print("P3-7C frontmost_midgesture=\(NSWorkspace.shared.frontmostApplication?.localizedName ?? "-")")
                }
            }
            _ = events.count
        }))
        s.append(("wait:p7c", {}))
        s.append(("wait:p7c2", {}))
        s.append(("assert:p7c-appswitch", {
            guard let btn = self.p3BtnTarget else {
                self.check("P3E3-appswitch-midgesture-delivered", false, "no probe-time assistButton rect"); return
            }
            let eDown = self.redirectedExpected(self.window.cgPoint(forContentPoint: self.p3Probes["btnK9"]!), btn)
            let p1cg = CGPoint(x: self.window.cgPoint(forContentPoint: self.p3Probes["btnK9"]!).x,
                               y: self.window.cgPoint(forContentPoint: self.p3Probes["btnK9"]!).y - 20)
            let eUp = self.redirectedExpected(p1cg, btn)
            let switched = self.sink.since(self.mark).contains {
                $0.contains("RESOLVER_INVALIDATE") && ($0.contains("app-switch") || $0.contains("app-resign-active"))
            }
            NSApp.activate(ignoringOtherApps: true)
            self.window.makeKeyAndOrderFront(nil)
            self.check("P3E3-appswitch-midgesture-delivered",
                       log.buttonDown.count == 1 && log.buttonDragged.count == 1 && log.buttonUp.count == 1
                       && self.near(log.buttonDown.first, eDown) && self.near(log.buttonUp.first, eUp)
                       && !self.buttonStateLeft() && switched,
                       "down=\(self.points(log.buttonDown)) eDown=\(self.pt(eDown)) up=\(self.points(log.buttonUp)) eUp=\(self.pt(eUp)) rigid=latched-constant appSwitchInvalidation=\(switched) buttonStateLeft=\(self.buttonStateLeft())")
        }))
        s.append(("act:p7c-after", { log.reset(); self.mark = self.sink.mark(); self.postClick(self.p3Probes["btnK9"]!) }))
        s.append(("assert:p7c-after", {
            guard let btn = self.p3BtnTarget else {
                self.check("P3E3b-no-orphaned-state", false, "no probe-time assistButton rect"); return
            }
            let expected = self.redirectedExpected(self.window.cgPoint(forContentPoint: self.p3Probes["btnK9"]!), btn)
            self.check("P3E3b-no-orphaned-state",
                       log.buttonDown.count == 1 && self.near(log.buttonDown.first, expected)
                       && log.backgroundDown.isEmpty && !self.buttonStateLeft(),
                       "deliveredDown=\(self.points(log.buttonDown)) expected=\(self.pt(expected)) nextClickWorks=true buttonStateLeft=\(self.buttonStateLeft())")
        }))
        } else {
            s.append(("skip:p7c-external-appswitch", {
                print("SKIP P3E3/P3E3b external-app switch: requires --dangerous or CLICKASSIST_ALLOW_DANGEROUS=1 (plain --selftest never touches external apps)")
            }))
        }
        return s
    }

    // MARK: - Gate 2/3/9: pure-function compatibility proofs

    private func compatSteps() -> [(String, () -> Void)] {
        var s: [(String, () -> Void)] = []
        s.append(("compat:pure", {
            // GATE 2 (SIMULATED): a second display ABOVE the main display has
            // negative CG y. The same single-offset flip must translate it.
            let mainH: CGFloat = 2160
            let aboveCocoa = NSRect(x: 100, y: mainH + 500, width: 800, height: 600)
            let aboveCG = ScreenSpace.cgRect(fromCocoaScreen: aboveCocoa, mainHeight: mainH)
            self.check("G2-simulated-secondary-above-negative-y",
                       self.nearRect(aboveCG, CGRect(x: 100, y: -1100, width: 800, height: 600), 0.0001),
                       "simulated display=above-main cocoa=\(aboveCocoa) -> cg=\(aboveCG) expected=(100,-1100,800,600)")

            let leftCocoa = NSRect(x: -1600, y: 200, width: 400, height: 300)
            let leftCG = ScreenSpace.cgRect(fromCocoaScreen: leftCocoa, mainHeight: mainH)
            self.check("G2-simulated-secondary-left-offset-origin",
                       self.nearRect(leftCG, CGRect(x: -1600, y: 1660, width: 400, height: 300), 0.0001),
                       "simulated display=left-of-main cocoa=\(leftCocoa) -> cg=\(leftCG) expected=(-1600,1660,400,300)")

            let repo = CGRect(x: -1600, y: -900, width: 400, height: 200)
            let cand = [DecisionCore.Candidate(key: "sim-secondary-button", rect: repo, inset: 2)]
            let probe = CGPoint(x: -1191, y: -800)   // 9 pt right of the synthetic rect
            if case .redirect(let c, let corrected, let dist) =
                DecisionCore.route(point: probe, candidates: cand, tolerance: 12) {
                self.check("G2-simulated-secondary-redirect-math",
                           c.key == "sim-secondary-button" && self.nearPoint(corrected, CGPoint(x: -1202, y: -800))
                           && abs(dist - 9) <= 0.001,
                           "simulated posted=\(probe) rect=\(repo) -> corrected=\(corrected) expected=(-1202,-800) dist=\(dist)")
            } else {
                self.check("G2-simulated-secondary-redirect-math", false,
                           "simulated expected redirect, got \(DecisionCore.route(point: probe, candidates: cand, tolerance: 12))")
            }
            if case .noCandidate = DecisionCore.route(point: CGPoint(x: -1183, y: -800),
                                                      candidates: cand, tolerance: 12) {
                self.check("G2-simulated-secondary-beyond-tolerance", true,
                           "simulated 17 pt outside -> no-candidate (single-display math would also be correct)")
            } else {
                self.check("G2-simulated-secondary-beyond-tolerance", false,
                           "simulated 17 pt outside unexpectedly routed")
            }

            // GATE 3: host backing scale + exact AX/CG <-> backing-pixel round trip.
            let scale = NSScreen.screens[0].backingScaleFactor
            self.check("G3-host-backing-scale",
                       scale >= 1 && scale == (NSScreen.main?.backingScaleFactor ?? -1),
                       "host scale=\(scale) screens=\(NSScreen.screens.map { "\($0.frame.size.width)x\($0.frame.size.height)@\($0.backingScaleFactor)" })")
            let known = CGRect(x: -1600, y: -1100, width: 640, height: 360)
            let pixels = ScreenSpace.pixelRect(fromGlobalRect: known, scale: scale)
            let roundTrip = ScreenSpace.globalRect(fromPixelRect: pixels, scale: scale)
            self.check("G3-backing-scale-roundtrip-exact",
                       roundTrip == known,
                       "known=\(known) scale=\(scale) backingPixels=\(pixels) roundTrip=\(roundTrip) exact=\(roundTrip == known)")

            print("G9-GENERALIZATION invariant: routing is display-agnostic — one global-space vertical flip plus rect-agnostic boundary/clamp math; no per-display or per-app branch.")
            print("G9-GENERALIZATION tested-instance: simulated secondary display at CG y=-900 redirected a 9 pt near miss to (-1202,-800); the same clamp ran on the browser AXButton and the VS Code AXMenuBarItem below.")
            print("G9-GENERALIZATION unseen-input: a third display placed above-left with both negative x and negative y (e.g. Cocoa origin (-1600, 2660)) needs no new code — cgRect flips only y and the candidate rect is already in that global space; DecisionCore.clampPoint then corrects any near miss regardless of origin sign.")
        }))
        return s
    }

    // MARK: - Gate 4: Space switch invalidation + recovery (single execution)

    private var spaceSwitched = false

    private func spacesSteps() -> [(String, () -> Void)] {
        var s: [(String, () -> Void)] = []
        s.append(("spaces:pre", {
            self.ensureFrontmost("spaces-pre")
            self.tap?.targetSource = self.cache.map { .cache($0) } ?? .staticTargets([])
            let ok = self.waitUntil(2.0) {
                self.cache?.current().valid == true
                    && self.cache?.current().targets.contains { $0.key == "assistButton" } == true
            }
            self.check("G4-space-precondition", ok,
                       "frontmost=\(NSWorkspace.shared.frontmostApplication?.localizedName ?? "-") cacheValid=\(self.cache?.current().valid ?? false)")
            if let btn = self.cache?.current().targets.first(where: { $0.key == "assistButton" }) {
                let hover = CGPoint(x: btn.rect.maxX + 9, y: btn.rect.midY)
                self.post(.mouseMoved, at: hover, button: .left, flags: [])
                print("G4-SPACE hover=\(hover) candidate=assistButton")
            }
        }))
        s.append(("spaces:switch", {
            self.mark = self.sink.mark()
            self.postKey(124, flags: .maskControl)   // ctrl-right: one Space switch
            self.spaceSwitched = self.waitUntil(3.0) {
                self.sink.since(self.mark).contains {
                    $0.contains("RESOLVER_INVALIDATE") && $0.contains("space-change")
                }
            }
        }))
        s.append(("spaces:assert-switch", {
            let line = self.sink.since(self.mark).first { $0.contains("RESOLVER_INVALIDATE") && $0.contains("space-change") }
            self.check("G4-space-switch-invalidates", self.spaceSwitched && line != nil,
                       "synthetic=ctrl-right executed=once invalidate=\(line ?? "nil")")
        }))
        s.append(("spaces:restore", {
            if self.spaceSwitched { self.postKey(123, flags: .maskControl) }   // ctrl-left: restore
            let recovered = self.waitUntil(3.0) {
                self.cache?.current().valid == true
                    && self.cache?.current().targets.contains { $0.key == "assistButton" } == true
            }
            self.check("G4-space-return-recovery", recovered,
                       "restored=\(self.spaceSwitched) cacheValid=\(self.cache?.current().valid ?? false) assistButton=\(self.cache?.current().targets.contains { $0.key == "assistButton" } ?? false) gen=\(self.cache?.current().generation ?? 0)")
            self.ensureFrontmost("spaces-restore")
        }))
        return s
    }

    // MARK: - Gate 5: browser content (Safari + Chrome)

    private struct AXNode {
        let role: String
        let subrole: String?
        let label: String
        let rect: CGRect
    }

    private struct ExternalAudit {
        let name: String
        let posted: CGPoint
        let mutated: CGPoint?
        let expected: CGPoint?
        let target: String
        let ok: Bool
    }

    private var externalAudit: [ExternalAudit] = []
    private var externalWindowBaseline: [Int] = []

    private func browserSteps() -> [(String, () -> Void)] {
        var s: [(String, () -> Void)] = []
        let html = FileManager.default.currentDirectoryPath + "/clickassist_test.html"
        func caseFor(_ appName: String, _ bundleID: String, _ tag: String) {
            s.append(("browser-\(tag):open", {
                self.openInApp(appName, html)
                let front = self.waitUntil(6.0) {
                    NSWorkspace.shared.frontmostApplication?.bundleIdentifier == bundleID
                }
                let gotTarget = self.waitUntil(6.0) {
                    self.cache?.current().valid == true
                        && self.cache?.current().targets.contains {
                            $0.role == "AXButton" && $0.label.contains("Activate ClickAssist")
                        } == true
                }
                self.check("G5-\(tag)-resolver-discovers-web-button", front && gotTarget,
                           "app=\(appName) frontmost=\(front) cacheApp=\(self.cache?.current().appName ?? "-") target=\(self.cache?.current().targets.first { $0.label.contains("Activate ClickAssist") }.map { "\($0.role) \($0.label) \($0.rect)" } ?? "nil")")
            }))
            s.append(("browser-\(tag):button", {
                guard let btn = self.cache?.current().targets.first(where: {
                    $0.role == "AXButton" && $0.label.contains("Activate ClickAssist")
                }) else { return }
                let probe = self.pickRedirectProbe(target: btn,
                    around: [8, 9, 10, 11, 12].map { CGPoint(x: btn.rect.maxX + CGFloat($0), y: btn.rect.midY) })
                guard let probe else {
                    self.check("G5-\(tag)-button-redirect-activates", false,
                               "no non-ambiguous near-miss probe around \(btn.rect)")
                    return
                }
                self.mark = self.sink.mark()
                self.postClickCG(probe)
                let marker = "CLICKED-\(tag)"
                let clicked = self.waitUntil(2.5) { self.axWindowTitle(pid: self.frontmostPid())?.contains(marker) == true }
                let expected = DecisionCore.clampPoint(probe, into: btn.rect, inset: btn.inset)
                let ok = self.auditDecision(name: "G5-\(tag)-button-redirect-activates",
                                             posted: probe, target: btn.key, expected: expected)
                    && clicked
                self.check("G5-\(tag)-button-redirect-activates", ok,
                           "posted=\(probe) target=\(btn.key) expectedClamp=\(expected) marker=\(clicked) title=\"\(self.axWindowTitle(pid: self.frontmostPid()) ?? "nil")\"")
            }))
            s.append(("browser-\(tag):password", {
                let pid = self.frontmostPid()
                guard let secure = self.axNodes(pid: pid).first(where: { $0.subrole == "AXSecureTextField" }) else {
                    self.check("G5-\(tag)-password-nearmiss-passthrough", false,
                               "password AXSecureTextField not found in \(appName)")
                    return
                }
                let offsets: [CGPoint] = [
                    CGPoint(x: secure.rect.maxX + 9, y: secure.rect.midY),
                    CGPoint(x: secure.rect.minX - 9, y: secure.rect.midY),
                    CGPoint(x: secure.rect.midX, y: secure.rect.maxY + 9),
                    CGPoint(x: secure.rect.midX, y: secure.rect.minY - 9)
                ]
                guard let probe = offsets.first(where: { self.routeIsNoCandidate($0) }) else {
                    self.check("G5-\(tag)-password-nearmiss-passthrough", false,
                               "no no-candidate probe around secure rect \(secure.rect)")
                    return
                }
                let secureInCache = self.cache?.current().targets.contains {
                    $0.key.contains("Secret") || $0.label.contains("Secret")
                } ?? false
                self.mark = self.sink.mark()
                self.postClickCG(probe)
                _ = self.waitUntil(0.6) { false }
                let mutations = self.sink.since(self.mark).filter { $0.contains("MUTATE") }
                let pass = self.decisionLine().map {
                    $0.hasPrefix("PASSTHROUGH") && $0.contains("no-candidate-in-radius")
                        && $0.contains("loc=\(ScreenSpace.fmt(probe))")
                } ?? false
                let focusedSecure = self.focusedSubrole(pid: pid) == "AXSecureTextField"
                let alive = NSRunningApplication(processIdentifier: pid) != nil
                if let line = self.decisionLine() {
                    self.externalAudit.append(ExternalAudit(name: "G5-\(tag)-password-passthrough",
                        posted: probe, mutated: nil, expected: nil, target: "secure-excluded",
                        ok: pass && mutations.isEmpty && !secureInCache && !focusedSecure && alive))
                    print("G5-\(tag)-password-decision \(line)")
                }
                self.check("G5-\(tag)-password-nearmiss-passthrough",
                           pass && mutations.isEmpty && !secureInCache && !focusedSecure && alive,
                           "posted=\(probe) secureRect=\(secure.rect) secureInCache=\(secureInCache) mutations=\(mutations.count) focusedSecure=\(focusedSecure) appAlive=\(alive)")
            }))
            s.append(("browser-\(tag):close", {
                self.ensureFrontmost("browser-close-pre")
                self.activateBundle(bundleID)
                _ = self.waitUntil(2.0) { NSWorkspace.shared.frontmostApplication?.bundleIdentifier == bundleID }
                let hadOurTab = self.axWindowTitles(pid: self.frontmostPid()).contains {
                    $0.contains("ClickAssistTest") || $0.contains("CLICKED-")
                }
                if hadOurTab { self.postKey(13, flags: .maskCommand) }   // cmd-w: close only our tab
                let closed = self.waitUntil(2.0) {
                    !self.axWindowTitles(pid: self.frontmostPid()).contains {
                        $0.contains("ClickAssistTest") || $0.contains("CLICKED-")
                    }
                }
                print("G5-\(tag)-tab-closed hadOurTab=\(hadOurTab) closed=\(closed)")
                self.ensureFrontmost("browser-close-post")
            }))
        }
        s.append(("browser:pre", {
            self.tap?.targetSource = self.cache.map { .cache($0) } ?? .staticTargets([])
            self.externalWindowBaseline = self.windowEventCounts()
            print("G5-BROWSER html=\(html) fileExists=\(FileManager.default.fileExists(atPath: html))")
        }))
        caseFor("Safari", "com.apple.Safari", "safari")
        caseFor("Google Chrome", "com.google.Chrome", "chrome")
        return s
    }

    // MARK: - Gate 6: Electron (VS Code)

    private func electronSteps() -> [(String, () -> Void)] {
        var s: [(String, () -> Void)] = []
        s.append(("electron:open", {
            self.activateBundle("com.microsoft.VSCode")
            let front = self.waitUntil(8.0) {
                NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.microsoft.VSCode"
            }
            let target = self.waitUntil(5.0) {
                self.cache?.current().valid == true
                    && self.cache?.current().targets.contains { $0.role == "AXMenuBarItem" } == true
            }
            self.check("G6-vscode-menu-target-resolved", front && target,
                       "frontmost=\(front) menuBarItems=\(self.cache?.current().targets.filter { $0.role == "AXMenuBarItem" }.map(\.key) ?? [])")
        }))
        s.append(("electron:menu", {
            guard let snap = self.cache?.current() else { return }
            let menus = snap.targets.filter { $0.role == "AXMenuBarItem" }
            var chosen: (CachedTarget, CGPoint)?
            for m in menus {
                let xs = [0.3, 0.5, 0.7].map { m.rect.minX + m.rect.width * CGFloat($0) }
                for x in xs {
                    for off in [8.0, 9.0, 10.0, 11.0, 12.0] {
                        let p = CGPoint(x: x, y: m.rect.maxY + off)
                        if self.pickRedirectProbe(target: m, around: [p]) != nil { chosen = (m, p); break }
                    }
                    if chosen != nil { break }
                }
                if chosen != nil { break }
            }
            guard let (menu, probe) = chosen else {
                self.check("G6-vscode-redirected-nearmiss-opens-menu", false,
                           "no redirect-safe menu-bar probe among \(menus.map { "\($0.key)\($0.rect)" })")
                return
            }
            self.mark = self.sink.mark()
            self.postClickCG(probe)
            let opened = self.waitUntil(2.5) {
                self.cache?.current().targets.contains {
                    $0.role == "AXMenuItem" && $0.rect.width >= 4 && $0.rect.height >= 4
                } == true
            }
            let expected = DecisionCore.clampPoint(probe, into: menu.rect, inset: menu.inset)
            let ok = self.auditDecision(name: "G6-vscode-redirected-nearmiss-opens-menu",
                                        posted: probe, target: menu.key, expected: expected) && opened
            self.check("G6-vscode-redirected-nearmiss-opens-menu", ok,
                       "posted=\(probe) target=\(menu.key) expectedClamp=\(expected) menuOpened=\(opened) menuItems=\(self.cache?.current().targets.filter { $0.role == "AXMenuItem" }.count ?? 0)")
        }))
        s.append(("electron:escape", {
            self.postKey(53, flags: [])   // ESC: dismiss the opened menu
            let dismissed = self.waitUntil(2.0) {
                self.cache?.current().targets.contains {
                    $0.role == "AXMenuItem" && $0.rect.width >= 4 && $0.rect.height >= 4
                } == false
            }
            let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.microsoft.VSCode"
            self.check("G6-vscode-state-restored", dismissed && front,
                       "escape=1 menuItems=\(self.cache?.current().targets.filter { $0.role == "AXMenuItem" }.count ?? -1) frontmost=\(NSWorkspace.shared.frontmostApplication?.localizedName ?? "-")")
            self.ensureFrontmost("electron-restore")
        }))
        return s
    }

    // MARK: - Gate 8 + restore before the overlay suite

    private func restoreSteps() -> [(String, () -> Void)] {
        var s: [(String, () -> Void)] = []
        s.append(("restore:window", {
            NSApp.activate(ignoringOtherApps: true)
            self.window.makeKeyAndOrderFront(nil)
            self.tap?.targetSource = self.cache.map { .cache($0) } ?? .staticTargets([])
            let ok = self.waitUntil(4.0) {
                NSWorkspace.shared.frontmostApplication?.processIdentifier == getpid()
                    && self.cache?.current().valid == true
                    && self.cache?.current().targets.contains { $0.key == "assistButton" } == true
            }
            self.check("G8-window-restored-after-external-phase", ok,
                       "frontmost=\(NSWorkspace.shared.frontmostApplication?.localizedName ?? "-") cacheTargets=\(self.cache?.current().targets.count ?? 0)")
        }))
        s.append(("audit:external", {
            let posted = self.externalAudit.count
            let asserted = self.externalAudit.filter(\.ok).count
            let after = self.windowEventCounts()
            let externalLeak = zip(after, self.externalWindowBaseline).map(-).reduce(0, +)
            let detail = self.externalAudit.map {
                "\($0.name):posted=\(ScreenSpace.fmt($0.posted))->mutated=\($0.mutated.map { ScreenSpace.fmt($0) } ?? "none")target=\($0.target)ok=\($0.ok)"
            }.joined(separator: " | ")
            self.check("G8-no-unintended-clicks", posted == 5 && asserted == posted && externalLeak == 0,
                       "posted=\(posted) asserted=\(asserted) leaksIntoHarnessWindow=\(externalLeak) events=[\(detail)]")
        }))
        return s
    }

    // MARK: - external-app helpers

    private func frontmostPid() -> pid_t {
        NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0
    }

    private func activateBundle(_ id: String) {
        NSRunningApplication.runningApplications(withBundleIdentifier: id)
            .first?.activate(options: [.activateIgnoringOtherApps])
    }

    private func openInApp(_ app: String, _ path: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        p.arguments = ["-a", app, path]
        try? p.run()
        p.waitUntilExit()
    }

    private func postClickCG(_ p: CGPoint, button: CGMouseButton = .left) {
        self.post(.mouseMoved, at: p, button: button, flags: [])
        self.post(button == .left ? .leftMouseDown : .rightMouseDown, at: p, button: button, flags: [])
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) {
            self.post(button == .left ? .leftMouseUp : .rightMouseUp, at: p, button: button, flags: [])
        }
    }

    private func postKey(_ code: CGKeyCode, flags: CGEventFlags) {
        let src = CGEventSource(stateID: .hidSystemState)
        for down in [true, false] {
            guard let e = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: down) else { continue }
            e.flags = flags
            e.post(tap: .cghidEventTap)
            usleep(20_000)
        }
    }

    private func waitUntil(_ timeout: TimeInterval, _ cond: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if cond() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.04))
        }
        return cond()
    }

    private func windowEventCounts() -> [Int] {
        let l = window.eventLog
        return [l.buttonDown.count, l.buttonUp.count, l.buttonDragged.count,
                l.backgroundDown.count, l.backgroundUp.count, l.auxDown.count]
    }

    private func nearPoint(_ a: CGPoint, _ b: CGPoint, eps: CGFloat = 0.0001) -> Bool {
        abs(a.x - b.x) <= eps && abs(a.y - b.y) <= eps
    }

    private func candidates(_ snap: CacheSnapshot) -> [DecisionCore.Candidate] {
        snap.targets.map { DecisionCore.Candidate(key: $0.key, rect: $0.rect, inset: $0.inset) }
    }

    private func pickRedirectProbe(target: CachedTarget, around points: [CGPoint]) -> CGPoint? {
        let cands = candidates(cache?.current() ?? .empty)
        let tol = tap?.tolerance ?? 12
        for p in points {
            if case .redirect(let c, let corrected, _) = DecisionCore.route(point: p, candidates: cands, tolerance: tol),
               c.key == target.key, target.rect.contains(corrected) {
                return p
            }
        }
        return nil
    }

    private func routeIsNoCandidate(_ p: CGPoint) -> Bool {
        guard let snap = cache?.current() else { return false }
        if case .noCandidate = DecisionCore.route(point: p, candidates: candidates(snap), tolerance: tap?.tolerance ?? 12) {
            return true
        }
        return false
    }

    @discardableResult
    private func auditDecision(name: String, posted: CGPoint, target: String, expected: CGPoint) -> Bool {
        let line = decisionLine()
        let mutated = line.flatMap { parsePoint($0, key: "mutated=") }
        let hasTarget = line?.contains("target=\(target)") == true
        let isMutate = line?.hasPrefix("MUTATE") == true
        let ok = isMutate && hasTarget && mutated.map { nearPoint($0, expected) } == true
        externalAudit.append(ExternalAudit(name: name, posted: posted, mutated: mutated,
                                           expected: expected, target: target, ok: ok))
        print("AUDIT \(name) posted=\(ScreenSpace.fmt(posted)) mutated=\(mutated.map { ScreenSpace.fmt($0) } ?? "none") expected=\(ScreenSpace.fmt(expected)) target=\(target) ok=\(ok) decision=\(line ?? "nil")")
        return ok
    }

    private func axAttribute(_ el: AXUIElement, _ name: String) -> CFTypeRef? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, name as CFString, &v) == .success else { return nil }
        return v
    }

    private func axString(_ el: AXUIElement, _ name: String) -> String? {
        guard let raw = axAttribute(el, name), CFGetTypeID(raw) == CFStringGetTypeID() else { return nil }
        return (raw as! CFString) as String
    }

    private func axFrame(_ el: AXUIElement) -> CGRect? {
        guard let pRaw = axAttribute(el, kAXPositionAttribute), CFGetTypeID(pRaw) == AXValueGetTypeID(),
              let sRaw = axAttribute(el, kAXSizeAttribute), CFGetTypeID(sRaw) == AXValueGetTypeID() else { return nil }
        var p = CGPoint.zero
        var s = CGSize.zero
        guard AXValueGetValue(pRaw as! AXValue, .cgPoint, &p),
              AXValueGetValue(sRaw as! AXValue, .cgSize, &s) else { return nil }
        return CGRect(origin: p, size: s)
    }

    private func axNodes(pid: pid_t) -> [AXNode] {
        guard pid > 0 else { return [] }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.3)
        var out: [AXNode] = []
        var budget = 1200
        func walk(_ el: AXUIElement, _ depth: Int) {
            guard budget > 0, depth <= 14 else { return }
            budget -= 1
            let role = axString(el, kAXRoleAttribute) ?? "-"
            let subrole = axString(el, kAXSubroleAttribute)
            let label = axString(el, kAXTitleAttribute)
                ?? axString(el, kAXDescriptionAttribute) ?? ""
            if let r = axFrame(el), r.width >= 2, r.height >= 2 {
                out.append(AXNode(role: role, subrole: subrole, label: label, rect: r))
            }
            if let raw = axAttribute(el, kAXChildrenAttribute),
               let kids = raw as? [AXUIElement] {
                for k in kids { walk(k, depth + 1) }
            }
        }
        if let raw = axAttribute(app, kAXWindowsAttribute), let wins = raw as? [AXUIElement] {
            for w in wins { walk(w, 0) }
        }
        if let raw = axAttribute(app, kAXMenuBarAttribute), CFGetTypeID(raw) == AXUIElementGetTypeID() {
            walk(raw as! AXUIElement, 0)
        }
        return out
    }

    private func axWindowTitles(pid: pid_t) -> [String] {
        guard pid > 0 else { return [] }
        let app = AXUIElementCreateApplication(pid)
        guard let raw = axAttribute(app, kAXWindowsAttribute), let wins = raw as? [AXUIElement] else { return [] }
        return wins.compactMap { axString($0, kAXTitleAttribute) }
    }

    private func axWindowTitle(pid: pid_t) -> String? {
        axWindowTitles(pid: pid).first
    }

    private func focusedSubrole(pid: pid_t) -> String? {
        guard pid > 0 else { return nil }
        let app = AXUIElementCreateApplication(pid)
        guard let raw = axAttribute(app, kAXFocusedUIElementAttribute),
              CFGetTypeID(raw) == AXUIElementGetTypeID() else { return nil }
        return axString(raw as! AXUIElement, kAXSubroleAttribute)
    }

    /// Pre-TCC behaviour: no tap exists, events must behave exactly as if we were absent.
    // MARK: - P2 suite (targeting overlay: same-decision proof + safety gates)

    private func p2Steps() -> [(String, () -> Void)] {
        var s: [(String, () -> Void)] = []
        guard let overlay else {
            s.append(("p2:absent", { self.check("P2-overlay-present", false, "overlay not wired (fail-open run)") }))
            return s
        }
        let log = window.eventLog

        // GATE 3: for a redirected probe, the overlay's rendered state records the SAME
        // candidate identity/frame/generation the router's decision used (shared EventLog).
        // The window was rearranged mid-suite (P1I), so the frame equality below also
        // proves the ring follows a re-published layout (GENERALIZATION unseen input).
        s.append(("p2:mode", {
            print("P2-SUITE overlay=separate-process decision-source=shared-published-snapshot")
            self.check("G7-overlay-out-of-process",
                       overlay.pid != getpid() && overlay.isAlive,
                       "helperPid=\(overlay.pid) tapPid=\(getpid()) separate=\(overlay.pid != getpid()) alive=\(overlay.isAlive)")
        }))
        s.append(("act:p2-redirect", {
            log.reset(); self.mark = self.sink.mark()
            self.postClick(self.p1NearMiss ?? self.nearMiss)
        }))
        s.append(("assert:p2-redirect", {
            let probe = self.p1NearMiss ?? self.nearMiss
            guard let line = self.decisionLine(), line.hasPrefix("MUTATE"),
                  let gen = self.value(line, key: "gen="), gen != "0",
                  let target = self.value(line, key: "target="), !target.isEmpty else {
                self.check("P2A-overlay-same-decision", false, "no MUTATE decision line: \(self.decisionLine() ?? "nil")")
                return
            }
            // Identity proof (not ordering): same published generation, same target,
            // same frame, pointer == the router's decision input.
            let overlayLine = self.sink.lines.first {
                $0.hasPrefix("OVERLAY_STATE") && $0.contains("gen=\(gen) ")
                    && $0.contains("action=show") && $0.contains("target=\(target)")
            }
            var frameOK = false
            var pointerOK = false
            if let ol = overlayLine, let btn = self.cache?.current().targets.first(where: { $0.key == target }) {
                frameOK = self.nearRect(self.parseRect(ol, key: "frame=") ?? .zero, btn.rect)
                let decidedAt = self.parsePoint(line, key: "orig=") ?? self.window.cgPoint(forContentPoint: probe)
                let shown = self.parsePoint(ol, key: "pointer=") ?? .zero
                pointerOK = abs(shown.x - decidedAt.x) <= 3 && abs(shown.y - decidedAt.y) <= 3
            }
            self.check("P2A-overlay-same-decision", overlayLine != nil && frameOK && pointerOK,
                       "decisionGen=\(gen) target=\(target) overlay=\(overlayLine ?? "nil") frameMatchesSnapshot=\(frameOK) pointerMatchesCursor=\(pointerOK)")
            self.check("P2B-redirect-still-works",
                       log.buttonDown.count == 1 && log.backgroundDown.isEmpty,
                       "deliveredDown=\(self.points(log.buttonDown)) bg=\(log.backgroundDown.count) gen=\(gen)")
        }))

        // GATE 6: overlay flags prove non-interactive; a probe click posted through the
        // region where the overlay sits still arrives at the underlying control.
        s.append(("act:p2-clickthrough", { log.reset(); self.mark = self.sink.mark(); self.postClick(self.inside) }))
        s.append(("assert:p2-clickthrough", {
            let flags = overlay.nonInteractiveFlags() ?? "panel-not-visible"
            self.check("P2C-overlay-noninteractive-flags",
                       flags.contains("ignoresMouseEvents=true") && flags.contains("canBecomeKey=false")
                       && flags.contains("canBecomeMain=false"),
                       "flags=[\(flags)]")
            self.check("P2D-click-through-overlay",
                       log.buttonDown.count == 1 && self.near(log.buttonDown.first, self.inside)
                       && log.backgroundDown.isEmpty && log.auxDown.isEmpty,
                       "postedThroughOverlayRegion down=\(self.points(log.buttonDown)) expected=\(self.pt(self.inside)) equality=orig==delivered")
        }))

        // GATE 4 (overlay half of ambiguity): tie case -> NO highlight while router passes.
        s.append(("act:p2-ambiguous", { log.reset(); self.mark = self.sink.mark(); self.postClick(self.ambiguous) }))
        s.append(("assert:p2-ambiguous", {
            let ols = self.sink.since(self.mark).filter { $0.hasPrefix("OVERLAY_STATE") }
            let noneLine = ols.first { $0.contains("action=none") && $0.contains("reason=ambiguous") }
            let noShow = !ols.contains { $0.contains("action=show") }
            self.check("P2E-ambiguous-no-highlight",
                       self.decisionContains("reason=ambiguous") && log.backgroundDown.count == 1
                       && log.buttonDown.isEmpty && noneLine != nil && noShow,
                       "router=\(self.decisionLine() ?? "nil") overlay=\(noneLine ?? "nil") showCount=\(ols.filter { $0.contains("action=show") }.count)")
        }))

        // GATE 7: valid highlight published, then invalidated BEFORE the click ->
        // overlay clears and the router passes through with reason=stale:...
        s.append(("act:p2-stale-invalidate", {
            self.resolver?.suspendRefresh(true)
            self.resolver?.invalidate(reason: "p2-stale-test")
            log.reset(); self.mark = self.sink.mark()
        }))
        s.append(("wait:p2-stale", {}))
        s.append(("act:p2-stale-click", { self.postClick(self.p1NearMiss ?? self.nearMiss) }))
        s.append(("assert:p2-stale-click", {
            let ols = self.sink.since(self.mark).filter { $0.hasPrefix("OVERLAY_STATE") }
            let cleared = ols.contains { $0.contains("action=none") && $0.contains("reason=stale:p2-stale-test") }
            let noShowAfterInvalidate = !ols.contains { $0.contains("action=show") }
            self.check("P2F-stale-between-render-and-click",
                       cleared && noShowAfterInvalidate && self.decisionContains("reason=stale:p2-stale-test")
                       && log.backgroundDown.count == 1 && log.buttonDown.isEmpty,
                       "overlayCleared=\(cleared) router=\(self.decisionLine() ?? "nil") deliveredBg=\(self.points(log.backgroundDown)) equality=orig==delivered")
            self.resolver?.suspendRefresh(false)
        }))

        // GATE 7 (P2a deferred): kill -9 the OUT-OF-PROCESS overlay mid-run -> the tap
        // still redirects; decisions are unaffected. Relaunch policy documented below.
        s.append(("act:p2-kill-overlay", {
            self.mark = self.sink.mark()
            overlay.sigkill()   // exactly kill -9, from a different pid than the tap
        }))
        s.append(("wait:p2-dead", {}))
        s.append(("act:p2-dead-click", {
            log.reset()
            self.postClick(self.p1NearMiss ?? self.nearMiss)
        }))
        s.append(("assert:p2-kill-overlay", {
            let lines = self.sink.since(self.mark)
            let deadLogged = lines.contains { $0.hasPrefix("OVERLAY_DEAD") }
            let mutated = lines.contains { $0.contains("MUTATE") && $0.contains("type=leftMouseDown") }
            self.check("P2G-overlay-dead-assist-survives",
                       deadLogged && mutated && log.buttonDown.count == 1 && log.backgroundDown.isEmpty,
                       "overlay=kill-9 tap=unaffected deliveredDown=\(self.points(log.buttonDown)) mutated=\(mutated) relaunch=none")
            self.check("P2H-dead-overlay-silent",
                       !lines.contains { $0.hasPrefix("OVERLAY_STATE") },
                       "overlayLinesAfterDeath=\(lines.filter { $0.hasPrefix("OVERLAY_STATE") }.count)")
        }))
        return s
    }

    private func failOpenSteps() -> [(String, () -> Void)] {
        var s: [(String, () -> Void)] = []
        let log = window.eventLog
        let canPost = CGPreflightPostEventAccess()
        s.append(("failopen:pre", {
            self.check("F0-no-tap", self.tap == nil, "tap=nil mode=pass-through")
        }))
        guard canPost else {
            s.append(("failopen:finish", {
                self.check("F1-failopen-pass-through", true,
                           "trusted=false cgPostAccess=false: no tap, our code never touches the event stream, no crash")
                print("SKIP F2-coordinate-equality: CGPreflightPostEventAccess=false (untrusted context refuses synthetic probes); measured in --simulate-untrusted run")
            }))
            return s
        }
        s.append(("act:inside", { log.reset(); self.postClick(self.inside) }))
        s.append(("assert:inside", {
            self.check("F1-inside-still-works", log.buttonDown.count == 1 && log.buttonUp.count == 1
                       && self.near(log.buttonDown.first, self.inside) && log.backgroundDown.isEmpty,
                       "deliveredDown=\(self.points(log.buttonDown))")
        }))
        s.append(("act:near-miss", { log.reset(); self.postClick(self.nearMiss) }))
        s.append(("assert:near-miss", {
            self.check("F2-failopen-no-behaviour-change",
                       log.backgroundDown.count == 1 && self.near(log.backgroundDown.first, self.nearMiss)
                       && log.buttonDown.isEmpty,
                       "posted=\(self.pt(self.nearMiss)) deliveredBgDown=\(self.points(log.backgroundDown)) equality=orig==delivered")
        }))
        return s
    }

    // MARK: - posting

    private func postClick(_ p: NSPoint, button: CGMouseButton = .left, flags: CGEventFlags = [],
                           clickState: Int = 1) {
        let cg = window.cgPoint(forContentPoint: p)
        post(.mouseMoved, at: cg, button: button, flags: flags, clickState: clickState)
        post(button == .left ? .leftMouseDown : .rightMouseDown, at: cg, button: button, flags: flags, clickState: clickState)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) {
            self.post(button == .left ? .leftMouseUp : .rightMouseUp, at: cg, button: button, flags: flags, clickState: clickState)
        }
    }

    private func postDrag(from: NSPoint, to: NSPoint, flags: CGEventFlags = []) {
        let cgFrom = window.cgPoint(forContentPoint: from)
        let cgTo = window.cgPoint(forContentPoint: to)
        post(.mouseMoved, at: cgFrom, button: .left, flags: flags)
        post(.leftMouseDown, at: cgFrom, button: .left, flags: flags)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) {
            self.post(.leftMouseDragged, at: cgTo, button: .left, flags: flags)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) {
                self.post(.leftMouseUp, at: cgTo, button: .left, flags: flags)
            }
        }
    }

    private func post(_ type: CGEventType, at p: CGPoint, button: CGMouseButton, flags: CGEventFlags,
                      clickState: Int = 1) {
        guard let e = CGEvent(mouseEventSource: CGEventSource(stateID: .hidSystemState),
                              mouseType: type,
                              mouseCursorPosition: p,
                              mouseButton: button) else { return }
        e.flags = flags
        // The window server computes clickState only from physical HID timing; synthetic
        // double-clicks must carry it explicitly (interval + slop still enforced here).
        e.setIntegerValueField(.mouseEventClickState, value: Int64(clickState))
        e.post(tap: .cghidEventTap)
    }

    // MARK: - plumbing

    private func pump() {
        guard !steps.isEmpty else { finish(); return }
        let step = steps.removeFirst()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            step.1()
            self.pump()
        }
    }

    private func check(_ name: String, _ ok: Bool, _ detail: String) {
        if ok { passes += 1; print("PASS \(name): \(detail)") }
        else { failures += 1; print("FAIL \(name): \(detail)") }
        fflush(stdout)
    }

    private func finish() {
        print("SUMMARY passes=\(passes) failures=\(failures)")
        print("RESULT: \(failures == 0 ? "PASS" : "FAIL")")
        print("EXIT \(failures == 0 ? 0 : 1)")
        fflush(stdout)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            self.tap?.stop()
            exit(self.failures == 0 ? 0 : 1)
        }
    }

    /// The mouse-DOWN decision of the current case (up lines are always secondary).
    private func decisionLine() -> String? {
        sink.since(mark).first {
            ($0.hasPrefix("MUTATE") || $0.hasPrefix("PASSTHROUGH")) && $0.contains("type=leftMouseDown")
        }
    }

    private func decisionContains(_ needle: String) -> Bool {
        sink.since(mark).contains { $0.contains("type=leftMouseDown") && $0.contains(needle) }
    }

    /// True when a RESOLVER_PUBLISH with the decision's generation was logged BEFORE it.
    private func generationPublishedBeforeDecision(_ line: String?) -> Bool {
        guard let line, let r = line.range(of: "gen=") else { return false }
        let gen = String(line[r.upperBound...].prefix { $0 != " " })
        guard !gen.isEmpty, gen != "0" else { return false }
        guard let idx = sink.lines.firstIndex(of: line) else { return false }
        return sink.lines[0..<idx].contains { $0.hasPrefix("RESOLVER_PUBLISH gen=\(gen) ") }
    }

    private func latencyUS(_ line: String?) -> Double? {
        guard let line, let r = line.range(of: "latency_us=") else { return nil }
        return Double(line[r.upperBound...].prefix { $0 != " " })
    }

    private func value(_ line: String, key: String) -> String? {
        guard let r = line.range(of: key) else { return nil }
        let v = String(line[r.upperBound...].prefix { $0 != " " })
        return v.isEmpty ? nil : v
    }

    private func parseRect(_ line: String, key: String) -> CGRect? {
        guard let r = line.range(of: key + "(") else { return nil }
        let body = line[r.upperBound...].prefix { $0 != ")" }
        let parts = body.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard parts.count == 4 else { return nil }
        return CGRect(x: parts[0], y: parts[1], width: parts[2], height: parts[3])
    }

    private func parsePoint(_ line: String, key: String) -> CGPoint? {
        guard let r = line.range(of: key + "(") else { return nil }
        let body = line[r.upperBound...].prefix { $0 != ")" }
        let parts = body.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard parts.count == 2 else { return nil }
        return CGPoint(x: parts[0], y: parts[1])
    }

    private func nearRect(_ a: CGRect, _ b: CGRect, _ eps: CGFloat = 1.0) -> Bool {
        abs(a.minX - b.minX) <= eps && abs(a.minY - b.minY) <= eps
            && abs(a.width - b.width) <= eps && abs(a.height - b.height) <= eps
    }

    private func ageMs(_ line: String?) -> Double? {
        guard let line, let r = line.range(of: "age_ms=") else { return nil }
        return Double(line[r.upperBound...].prefix { $0 != " " })
    }

    private func clamp(_ p: CGPoint, _ t: CachedTarget) -> CGPoint {
        let r = t.rect.insetBy(dx: t.inset, dy: t.inset)
        return CGPoint(x: min(max(p.x, r.minX), r.maxX), y: min(max(p.y, r.minY), r.maxY))
    }

    private func near(_ a: NSPoint?, _ b: NSPoint?, _ eps: CGFloat = 0.75) -> Bool {
        guard let a, let b else { return false }
        return abs(a.x - b.x) <= eps && abs(a.y - b.y) <= eps
    }

    private func points(_ ps: [NSPoint]) -> String {
        "[" + ps.map { self.pt($0) }.joined(separator: " ") + "]"
    }

    private func pt(_ p: NSPoint) -> String { String(format: "(%.1f,%.1f)", p.x, p.y) }
}
