// baseline-guard:allow new standalone prototype file, no prior baseline possible
import Carbon.HIToolbox
import AppKit
import os.lock
import CoreGraphics
import Foundation
import QuartzCore

/// A snap target with a fixed rect, retained for the P0 regression harness.
struct AssistTarget: Sendable {
    let name: String
    let rect: CGRect
    let inset: CGFloat

    func correctedPoint(for p: CGPoint) -> CGPoint {
        let r = rect.insetBy(dx: inset, dy: inset)
        return CGPoint(x: min(max(p.x, r.minX), r.maxX),
                       y: min(max(p.y, r.minY), r.maxY))
    }
}

/// Where routing candidates come from. `.cache` is the production path (AX resolver);
/// `.staticTargets` exists only so the P0 self-test stays a regression test.
enum TargetSource: Sendable {
    case staticTargets([AssistTarget])
    case cache(CacheStore)
}

/// Mutable CGEventTap. The callback's ONLY inputs are an in-memory snapshot and a
/// bool; it performs zero Accessibility calls and zero on-demand resolution.
final class AssistTap: @unchecked Sendable {
    private(set) var tap: CFMachPort?
    private var source: CFRunLoopSource?
    /// Run loop hosting the tap source (and therefore the callback). Main by
    /// default (app / legacy agent). A host whose main thread must never gate
    /// input delivery (MousecapeHelper: wake/apply work runs there) passes a
    /// dedicated run loop; then every tap-state mutation is marshalled onto it so
    /// the callback stays the single owner of its state.
    private var hostRunLoop: CFRunLoop = CFRunLoopGetMain()
    private var latched: GestureLatch?
    /// Set when a center-snapped down turned into a drag: the rest of that
    /// gesture is passed through unmutated (no drag-to-snapped-center hijack).
    private var unlatchedForDrag = false
    /// Set while the tap is intentionally disabled (P3 interruption gate): the system
    /// delivers tapDisabledByUserInput for a manual CGEvent.tapEnable(false), which
    /// must NOT auto-re-enable.
    private var manuallyDisabled = false
    /// Latched at a mouse-down that was delivered via AXPress. While non-nil the
    /// rest of that gesture (drag/up) is swallowed, so AXPress can never pair with
    /// a synthetic event. The token also guarantees one AXPress per gesture.
    private var pressGestureToken: UUID?
    /// Set when a gesture's DOWN failed the conservative support gate (non-primary
    /// button, modifier, multi-click, or secure input). Every later event of that
    /// gesture stays a passthrough: a gesture that began unsupported stays
    /// unsupported end-to-end.
    private var gestureUnsupported = false
    private struct PendingBackgroundClick {
        let down: CGEvent
        let candidate: DecisionCore.Candidate
        let pid: pid_t
        let point: CGPoint
    }
    private var pendingBackgroundClick: PendingBackgroundClick?
    private var focusObserver: NSObjectProtocol?
    private var focusLock = os_unfair_lock_s()
    private var foregroundPID: pid_t = 0

    private func setForegroundPID(_ pid: pid_t) {
        os_unfair_lock_lock(&focusLock)
        foregroundPID = pid
        os_unfair_lock_unlock(&focusLock)
    }
    private func currentForegroundPID() -> pid_t? {
        guard os_unfair_lock_trylock(&focusLock) else { return nil }
        defer { os_unfair_lock_unlock(&focusLock) }
        return foregroundPID
    }
    private func captureBackgroundClick(_ candidate: DecisionCore.Candidate, res: Resolution,
                                        original: CGPoint, destination: CGPoint, event: CGEvent) -> Bool {
        let foreground = currentForegroundPID()
        let now = CACurrentMediaTime()
        // Judge the point the click will actually land on: a halo press the tap
        // re-aims to the ring center is inside the target, so it must capture
        // too (judging `original` left it to native routing = needs two clicks).
        guard activationSink != nil,
              BackgroundClickPolicy.eligible(targetPID: res.pid, foregroundPID: foreground,
                candidate: candidate, generation: res.generation, point: destination, now: now,
                nativeTolerance: tolerance, targetWindowFocused: res.pointerWindowFocused),
              let down = event.copy() else {
            // A background down that falls through here gets only native
            // activation (the "needs two clicks" symptom); record why.
            if foreground != res.pid || !res.pointerWindowFocused {
                let evidence = ClickAssistEvidence.activationState(evidenceGeneration: candidate.evidenceGeneration,
                    currentGeneration: res.generation, ageMs: (now - candidate.collectedAt) * 1000)
                log("BACKGROUND_CLICK_SKIPPED target=\(candidate.key) role=\(candidate.role) verdict=\(candidate.verdict) evidence=\(evidence.rawValue) ageMs=\(Int((now - candidate.collectedAt) * 1000)) contains=\(candidate.rect.contains(destination) ? 1 : 0) origContains=\(candidate.rect.contains(original) ? 1 : 0) fgPID=\(foreground.map(String.init) ?? "locked") pid=\(res.pid) sink=\(activationSink != nil ? 1 : 0) winFocused=\(res.pointerWindowFocused ? 1 : 0)")
            }
            return false
        }
        pendingBackgroundClick = PendingBackgroundClick(down: down, candidate: candidate,
            pid: res.pid, point: destination)
        log("BACKGROUND_CLICK_CAPTURED target=\(candidate.key) pid=\(res.pid) winFocused=\(res.pointerWindowFocused ? 1 : 0) original=consumed")
        return true
    }
    /// Off-callback activation transport (XPC to the resolver service). The tap
    /// hands ownership to the service; the reply is advisory only.
    var activationSink: ((AXPressRequest) -> Void)?
    /// The callback's own last successfully read snapshot: the non-blocking read
    /// path returns it when the publish lock is contended.
    private var lastSnapshot = CacheSnapshot.empty

    var assistEnabled = true
    private(set) var tolerance: CGFloat
    let log: (String) -> Void
    /// Passive callback-duration ring. Written on the tap thread, read/sorted by
    /// the engine's off-callback stats timer.
    let latency = LatencyRing()

    var targetSource: TargetSource = .staticTargets([])

    private static let downTypes: Set<CGEventType> = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
    private static let upTypes: Set<CGEventType> = [.leftMouseUp, .rightMouseUp, .otherMouseUp]
    private static let dragTypes: Set<CGEventType> = [.leftMouseDragged, .rightMouseDragged, .otherMouseDragged]

    static let mask: CGEventMask =
        (1 << CGEventType.leftMouseDown.rawValue) |
        (1 << CGEventType.leftMouseUp.rawValue) |
        (1 << CGEventType.leftMouseDragged.rawValue) |
        (1 << CGEventType.rightMouseDown.rawValue) |
        (1 << CGEventType.rightMouseUp.rawValue) |
        (1 << CGEventType.rightMouseDragged.rawValue) |
        (1 << CGEventType.otherMouseDown.rawValue) |
        (1 << CGEventType.otherMouseUp.rawValue) |
        (1 << CGEventType.otherMouseDragged.rawValue)

    init(tolerance: CGFloat, log: @escaping (String) -> Void) {
        self.tolerance = AssistTap.clampTolerance(tolerance)
        self.log = log
    }

    /// P2b: runtime-configurable assist radius. Any value outside 8...32 is CLAMPED
    /// (logged); semantics stay boundary-distance <= tolerance inside DecisionCore.
    static func clampTolerance(_ v: CGFloat) -> CGFloat { ClickAssistTolerance.validated(v) }

    @discardableResult
    func setTolerance(_ v: CGFloat) -> CGFloat {
        let clamped = AssistTap.clampTolerance(v)
        onHost { [self] in tolerance = clamped }
        return clamped
    }

    /// True when the caller is already on the run loop that hosts the callback
    /// (always the case for main-hosted taps called from main).
    private var isOnHost: Bool { CFEqual(CFRunLoopGetCurrent(), hostRunLoop) }

    /// Runs `body` on the host run loop: inline when already there, otherwise
    /// enqueued with a wake-up. Never waits, so a caller on main can never be
    /// stalled by the tap thread.
    private func onHost(_ body: @escaping () -> Void) {
        if isOnHost { body(); return }
        CFRunLoopPerformBlock(hostRunLoop, CFRunLoopMode.commonModes.rawValue, body)
        CFRunLoopWakeUp(hostRunLoop)
    }

    /// Best-effort synchronous fallback; `stop()` is the normal teardown path.
    /// `stop()` on a dedicated host keeps `self` alive until teardown has run
    /// there, so deinit normally finds nothing left to tear down.
    deinit { teardown() }

    /// P3 interruption gate: toggle the tap without touching latched state.
    @discardableResult
    func setTapEnabled(_ on: Bool) -> Bool {
        guard isOnHost else {
            onHost { [self] in _ = setTapEnabled(on) }
            return on
        }
        guard let tap else { return false }
        manuallyDisabled = !on
        CGEvent.tapEnable(tap: tap, enable: on)
        log("TAP_\(on ? "ENABLED" : "DISABLED") manual reason=p3-interruption-test")
        return on
    }

    // MARK: - tap lifecycle

    @discardableResult
    func start(point: CGEventTapLocation = .cghidEventTap, runLoop: CFRunLoop? = nil) -> Bool {
        guard tap == nil else { return true }
        hostRunLoop = runLoop ?? CFRunLoopGetMain()
        setForegroundPID(NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0)
        focusObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: nil) { [weak self] note in
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                self?.setForegroundPID(app?.processIdentifier ?? 0)
            }
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let port = CGEvent.tapCreate(
            tap: point,
            place: .headInsertEventTap,
            // kCGEventTapOptionDefault == mutable, NOT listen-only.
            options: .defaultTap,
            eventsOfInterest: AssistTap.mask,
            callback: AssistTap.callback,
            userInfo: refcon
        ) else {
            log("TAP_CREATE_FAILED point=\(point == .cghidEventTap ? "hid" : "session")")
            return false
        }
        tap = port
        let s = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        source = s
        CFRunLoopAddSource(hostRunLoop, s, .commonModes)
        CFRunLoopWakeUp(hostRunLoop)
        CGEvent.tapEnable(tap: port, enable: true)
        log("TAP_ACTIVE mutable=defaultTap point=\(point == .cghidEventTap ? "hid" : "session") host=\(isOnHost ? "main" : "dedicated") tolerance=\(tolerance) snapshotMiss=\(cacheStoreForDelivery?.snapshotTrylockMiss ?? 0)")
        // Runtime invariant marker: the callback is a pure snapshot consumer; AX
        // runs only on the resolver queue (evidence) and the serial worker (press).
        log("TAP_AX_FREE invariant=callback-zero-ax displayMaxAgeMs=\(Int(ClickAssistEvidence.displayMaxAgeMs)) activationMaxAgeMs=\(Int(ClickAssistEvidence.activationMaxAgeMs)) pressExpiryMs=\(Int(AXPressGate.defaultExpiryMs))")
        return true
    }

    /// Tears the tap down ON its host run loop. On a dedicated host the block
    /// retains `self`, so an in-flight callback never sees a freed refcon.
    func stop() {
        onHost { [self] in teardown() }
    }

    private func teardown() {
        if let focusObserver { NSWorkspace.shared.notificationCenter.removeObserver(focusObserver) }
        focusObserver = nil
        pendingBackgroundClick = nil
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source { CFRunLoopRemoveSource(hostRunLoop, source, .commonModes) }
        if let tap { CFMachPortInvalidate(tap) }
        tap = nil
        source = nil
    }

    // MARK: - callback

    private static let callback: CGEventTapCallBack = { proxy, type, event, refcon in
        guard let refcon else { return Unmanaged.passUnretained(event) }
        let me = Unmanaged<AssistTap>.fromOpaque(refcon).takeUnretainedValue()
        return me.handle(proxy: proxy, type: type, event: event)
    }

    /// Shared routing math lives in DecisionCore; the callback's in-memory work is
    /// unchanged (same comparisons, same arithmetic, no new I/O or locks).
    private typealias Candidate = DecisionCore.Candidate

    private var cacheStoreForDelivery: CacheStore? {
        if case .cache(let store) = targetSource { return store }
        return nil
    }

    private struct Resolution {
        let candidates: [Candidate]
        let valid: Bool
        let reason: String
        let generation: UInt64
        let ageMs: Double
        let source: String
        let pid: pid_t
        /// Resolver's pointer-window focus fact; see `CacheSnapshot`.
        var pointerWindowFocused: Bool = true
    }

    /// Pure in-memory snapshot read. No IPC, no AX, no allocation beyond a retain.
    private func resolution() -> Resolution {
        switch targetSource {
        case .staticTargets(let ts):
            return Resolution(candidates: ts.map { Candidate(key: $0.name, rect: $0.rect, inset: $0.inset,
                                                              tier: .firstClass, label: $0.name) },
                              valid: true, reason: "static", generation: 0, ageMs: 0,
                              source: "static", pid: 0)
        case .cache(let store):
            let s = store.current(else: &lastSnapshot)
            let ageMs = (CACurrentMediaTime() - s.stamp) * 1000
            let fresh = s.valid && ageMs <= DecisionCore.cacheMaxAge * 1000
            let reason = s.valid ? (fresh ? "fresh" : String(format: "stale:age(%.0fms)", ageMs)) : s.reason
            return Resolution(candidates: s.targets.map { Candidate(key: $0.key, rect: $0.rect,
                                                                     inset: $0.inset, tier: $0.tier,
                                                                     role: $0.role, label: $0.label,
                                                                     verdict: $0.verdict,
                                                                     chromeEligible: $0.chromeEligible,
                                                                     evidenceGeneration: $0.evidenceGeneration,
                                                                     collectedAt: $0.collectedAt) },
                              valid: fresh, reason: reason, generation: s.generation,
                              ageMs: ageMs, source: "cache", pid: s.pid,
                              pointerWindowFocused: s.pointerWindowFocused)
        }
    }

    /// What may be done with ONE candidate aimed at ONE destination point.
    private struct DeliveryPlan {
        enum Kind {
            /// Exactly one AXPress on the plan's element, then consume the gesture.
            case axPress(CGPoint)
            /// Legacy synthetic delivery: mutate the event to this point.
            case synthetic(CGPoint)
            /// Nothing may be delivered; the caller takes its passthrough path.
            case rejected
        }
        let kind: Kind
        let verdict: ClickAssistVerdict
        /// Passthrough token when evidence is missing/expired/failed.
        let rejectReason: String?
    }

    /// THE single delivery decision, PURE COMPUTATION over published evidence.
    /// No AX call, no hit-test, no fresh-frame read. The resolver publishes
    /// `verdict`, `chromeEligible` and `evidenceGeneration` for the nearest
    /// targets; anything missing, stale or from another generation is refused
    /// (`evidence-missing` / `evidence-expired`) rather than refreshed.
    ///
    /// `requiresConfirmation: false` is the direct-hit self path (admitted by the
    /// router's own hit). The static P0 harness has no policy/evidence and keeps
    /// its legacy confirmed/synthetic behaviour.
    private func resolveDelivery(for candidate: Candidate, destination: CGPoint,
                                 res: Resolution,
                                 requiresConfirmation: Bool = true,
                                 allowsSynthetic: Bool) -> DeliveryPlan {
        let isStatic = res.source == "static"
        let evidence = isStatic
            ? ClickAssistEvidence.State.fresh
            : ClickAssistEvidence.activationState(
                evidenceGeneration: candidate.evidenceGeneration,
                currentGeneration: res.generation,
                ageMs: candidate.collectedAt > 0
                    ? (CACurrentMediaTime() - candidate.collectedAt) * 1000
                    : res.ageMs)
        if requiresConfirmation, evidence != .fresh {
            return DeliveryPlan(kind: .rejected, verdict: candidate.verdict,
                                rejectReason: evidence == .missing
                                    ? "evidence-missing" : "evidence-expired")
        }
        let verdict: ClickAssistVerdict = requiresConfirmation
            ? candidate.verdict : .confirmed
        let chromeEligible = !isStatic && candidate.chromeEligible
        let evidenceOK = !requiresConfirmation
            || verdict == .confirmed || verdict == .confirmedWeak
        if evidenceOK, chromeEligible {
            return DeliveryPlan(kind: .axPress(destination), verdict: verdict,
                                rejectReason: nil)
        }
        // Strong evidence only: a synthetic click aimed at a weak answer is unsafe.
        // A chrome-eligible target with missing/expired evidence never degrades to
        // synthetic — it was refused above or stays unavailable here.
        if requiresConfirmation, verdict == .confirmed, allowsSynthetic, !chromeEligible {
            return DeliveryPlan(kind: .synthetic(destination),
                                verdict: verdict, rejectReason: nil)
        }
        return DeliveryPlan(kind: .rejected, verdict: verdict,
                            rejectReason: evidenceOK ? "evidence-missing"
                                                     : "legitimacy-\(verdict.rawValue)")
    }

    /// Diagnostics helper for the no-candidate branch only: the nearest
    /// `limit` eligible candidates with boundary distance, sorted ascending.
    /// Pure — reads the existing candidate array, allocates nothing else.
    private static func nearestCandidates(_ candidates: [Candidate], to point: CGPoint,
                                          limit: Int = 3) -> String {
        let listed = candidates
            .map { (key: $0.key, dist: DecisionCore.boundaryDistance(point, $0.rect)) }
            .sorted { $0.dist < $1.dist }
            .prefix(limit)
            .map { "\($0.key):\(String(format: "%.1f", $0.dist))" }
        return listed.isEmpty ? "-" : listed.joined(separator: ",")
    }

    /// Ownership: while an AXPress token is set the tap owns the gesture end-to-end,
    /// so a mid-gesture downgrade to passthrough must never hand the receiver an up
    /// with no down. Returns true when the event was consumed. An unexpected new
    /// down clears the token (the only non-up clear besides interruption).
    private func consumeAXPressOwned(isDown: Bool, isDrag: Bool, isUp: Bool,
                                     label: String, original: CGPoint, observed: String,
                                     started: CFTimeInterval) -> Bool {
        guard pressGestureToken != nil else { return false }
        if isUp {
            pressGestureToken = nil
            emit("PASSTHROUGH", type: label, original: original, mutated: nil,
                 reason: "axpress-swallow-up", res: resolution(), started: started,
                 extra: observed + " mode=axpress consumed=up owner=retained")
            return true
        }
        if isDrag { return true }
        pressGestureToken = nil   // unexpected new down
        return false
    }

    private func handle(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if event.getIntegerValueField(.eventSourceUserData) == BackgroundClickPolicy.eventMarker {
            return Unmanaged.passUnretained(event)
        }
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            // A gesture interrupted by tap disablement can never be repaired: all
            // its state must die so no stale translation, swallowed up, or
            // duplicate activation survives. With the state cleared, the tap stays
            // in native passthrough until a fresh down arrives.
            let reason = type == .tapDisabledByTimeout ? "timeout" : "user-input"
            latency.noteTapDisable(timeout: type == .tapDisabledByTimeout)
            latched = nil
            unlatchedForDrag = false
            pressGestureToken = nil
            gestureUnsupported = false
            pendingBackgroundClick = nil
            log("TAP_INTERRUPTED reason=\(reason) state=cleared")
            if type == .tapDisabledByUserInput, manuallyDisabled {
                log("TAP_STAYSDISABLED reason=manual-p3-interruption")
                return Unmanaged.passUnretained(event)
            }
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            log("TAP_REENABLED reason=\(reason)")
            return Unmanaged.passUnretained(event)
        }

        let isDown = AssistTap.downTypes.contains(type)
        let isUp = AssistTap.upTypes.contains(type)
        let isDrag = AssistTap.dragTypes.contains(type)
        guard isDown || isUp || isDrag else { return Unmanaged.passUnretained(event) }

        let started = CACurrentMediaTime()
        defer { latency.record((CACurrentMediaTime() - started) * 1_000_000) }
        let original = event.location
        let label = AssistTap.name(type)
        let button = event.getIntegerValueField(.mouseEventButtonNumber)
        let clicks = event.getIntegerValueField(.mouseEventClickState)
        let gestureFlags = event.flags.intersection(
            [.maskCommand, .maskControl, .maskAlternate, .maskShift])
        let observed = "btn=\(button) flags=0x\(String(gestureFlags.rawValue, radix: 16)) clicks=\(clicks)"

        // Secure input: a password prompt must never receive a relocated click,
        // and secure input is the system-wide signal for it. Evaluated per event
        // (cheap), never polled.
        if IsSecureEventInputEnabled() {
            if pendingBackgroundClick != nil {
                pendingBackgroundClick = nil
                pressGestureToken = UUID()
            }
            if consumeAXPressOwned(isDown: isDown, isDrag: isDrag, isUp: isUp,
                                   label: label, original: original, observed: observed,
                                   started: started) { return nil }
            if isDown { gestureUnsupported = true }
            if isUp { gestureUnsupported = false }
            emit("PASSTHROUGH", type: label, original: original, mutated: nil,
                 reason: "secure-input", res: resolution(), started: started,
                 extra: observed)
            return Unmanaged.passUnretained(event)
        }

        // Conservative gesture gate: assist ONLY a plain primary single click.
        // AXPress and coordinate relocation cannot faithfully reproduce modifier
        // or multi-click semantics, so assisting them risks a wrong activation;
        // they must stay native. A gesture that began unsupported stays
        // unsupported end-to-end (its drags and up pass through too).
        // KNOWN LIMITATION (unguaranteed by design): if the FIRST click of a
        // double-click was assisted it landed at a different point, so the
        // receiver may not recognise the pair; clickState > 1 stays native.
        let supported = button == 0 && gestureFlags.isEmpty && clicks <= 1
        let continuedUnsupported = gestureUnsupported && !isDown
        if !supported || continuedUnsupported {
            if pendingBackgroundClick != nil {
                pendingBackgroundClick = nil
                pressGestureToken = UUID()
            }
            if consumeAXPressOwned(isDown: isDown, isDrag: isDrag, isUp: isUp,
                                   label: label, original: original, observed: observed,
                                   started: started) { return nil }
            if isDown { gestureUnsupported = true }
            if isUp { gestureUnsupported = false }
            emit("PASSTHROUGH", type: label, original: original, mutated: nil,
                 reason: "gesture-unsupported", res: resolution(), started: started,
                 extra: observed + (continuedUnsupported ? " continuity=1" : ""))
            return Unmanaged.passUnretained(event)
        }
        if isDown { gestureUnsupported = false }

        if let pending = pendingBackgroundClick {
            if isDrag {
                if BackgroundClickPolicy.isClickPointerNoise(role: pending.candidate.role,
                    down: pending.down.location, current: original) {
                    log("CLICK_JITTER_HELD mode=background target=\(pending.candidate.key)")
                    return nil
                }
                // A drag is not an activation-click. Release the captured native
                // down ahead of this drag, preserving the app's normal gesture.
                pendingBackgroundClick = nil
                log("BACKGROUND_CLICK_DRAG_RELEASE target=\(pending.candidate.key) distance=\(hypot(original.x - pending.down.location.x, original.y - pending.down.location.y))")
                pending.down.setIntegerValueField(.eventSourceUserData, value: BackgroundClickPolicy.eventMarker)
                pending.down.tapPostEvent(proxy)
                gestureUnsupported = true
                return Unmanaged.passUnretained(event)
            }
            if isUp {
                pendingBackgroundClick = nil
                let latest = resolution()
                if assistEnabled, latest.valid, latest.pid == pending.pid,
                   let target = latest.candidates.first(where: { $0.key == pending.candidate.key }),
                   FrameContinuity.delta(target.rect, pending.candidate.rect) <= 1,
                   // Judge the press location: up may sit up to the tremor
                   // epsilon away, past the edge of a small button.
                   (target.rect.contains(pending.down.location)
                    || (GeometryPolicy.usesNativeRowAction(target.role)
                        && DecisionCore.boundaryDistance(pending.down.location, target.rect) <= tolerance)),
                   target.verdict == .confirmed,
                   ClickAssistEvidence.activationState(evidenceGeneration: target.evidenceGeneration,
                    currentGeneration: latest.generation,
                    ageMs: (CACurrentMediaTime() - target.collectedAt) * 1000) == .fresh {
                    var request = AXPressRequest(targetKey: target.key, pid: latest.pid,
                        generation: latest.generation, issuedAt: CACurrentMediaTime(), expiryMs: 400)
                    request.backgroundClick = BackgroundClickWire(x: pending.point.x, y: pending.point.y,
                                                                  rect: target.rect)
                    dispatchAXPress(request: request)
                    log("BACKGROUND_CLICK_QUEUED target=\(target.key) request=\(request.requestID) original=consumed")
                } else {
                    log("BACKGROUND_CLICK_CANCELLED reason=target-or-evidence-changed original=consumed")
                }
                return nil
            }
            pendingBackgroundClick = nil
        }

        // AXPress gesture consumption: the down that fired AXPress was swallowed,
        // so its drags and matching up must be swallowed too. Returning nil from
        // the callback consumes the event outright. The token is cleared on the up
        // (or on an unexpected new down), so at most one AXPress per gesture.
        if pressGestureToken != nil {
            if isUp {
                pressGestureToken = nil
                emit("PASSTHROUGH", type: label, original: original, mutated: nil,
                     reason: "axpress-swallow-up", res: resolution(), started: started,
                     extra: "mode=axpress consumed=up")
                return nil
            }
            if isDrag { return nil }
            pressGestureToken = nil
        }

        guard assistEnabled else {
            latched = nil
            emit("PASSTHROUGH", type: label, original: original, mutated: nil,
                 reason: "assist-disabled", res: resolution(), started: started)
            return Unmanaged.passUnretained(event)
        }

        let res = resolution()
        // Measured callback budget: evidence/route work must stay cheap. Past
        // 8 ms the event is handed back untouched — this is a guard, never
        // permission to call AX.
        let cbUs = (CACurrentMediaTime() - started) * 1_000_000
        if cbUs > 8_000 {
            emit("PASSTHROUGH", type: label, original: original, mutated: nil,
                 reason: "ax-deadline", res: res, started: started,
                 extra: String(format: "cb_us=%.1f", cbUs))
            return Unmanaged.passUnretained(event)
        }

        if isDown {
            latched = nil
            unlatchedForDrag = false

            guard res.valid else {
                // An AXPress token never outlives its gesture; a new down already
                // cleared it above, so no token can swallow the next up in a new app.
                emit("PASSTHROUGH", type: label, original: original, mutated: nil,
                     reason: res.reason, res: res, started: started, extra: "validity=invalid")
                return Unmanaged.passUnretained(event)
            }

            switch DecisionCore.route(point: original, candidates: res.candidates, tolerance: tolerance) {
            case .directHit(let hit, let others):
                if captureBackgroundClick(hit, res: res, original: original, destination: original, event: event) {
                    return nil
                }
                // Self delivery: when the hit element is ITSELF a chrome-gated
                // AXButton (e.g. the real 16x16 tab-close glyph), a synthetic
                // click is ignored by Chromium. AXPress acts on the element, so
                // deliver it directly. Web surfaces fail the gate (AXWebArea).
                let selfPlan = resolveDelivery(for: hit,
                                               destination: DecisionCore.centerPoint(into: hit.rect),
                                               res: res, requiresConfirmation: false,
                                               allowsSynthetic: false)
                if case .axPress(let dest) = selfPlan.kind,
                   performAXPressDelivery(best: hit,
                                          corrected: dest,
                                          snap: DecisionCore.snapMode(for: hit),
                                          dist: 0, cands: 1, res: res, label: label,
                                          original: original, started: started,
                                          extra: "self=1 ") {
                    return nil
                }
                let hitPlan = resolveDelivery(for: hit, destination: original, res: res,
                                              allowsSynthetic: false)
                var extra = "element=\(hit.key) boundary=0.0 action=passthrough legitimacy=\(hitPlan.verdict.rawValue)"
                if let other = others.first { extra += " other=\(other.key) other_dist=\(String(format: "%.1f", other.dist))" }
                emit("PASSTHROUGH", type: label, original: original, mutated: nil,
                     reason: "direct-hit", res: res, started: started, extra: extra)
                return Unmanaged.passUnretained(event)
            case .noCandidate:
                // Diagnostics only: how far was the CLOSEST eligible control? The
                // candidate set is the already-filtered snapshot, so a short list
                // here means either genuine distance (a) or a filtered-out role (c).
                // Computed strictly inside this branch — no cost on any other path.
                let nearest = AssistTap.nearestCandidates(res.candidates, to: original)
                emit("PASSTHROUGH", type: label, original: original, mutated: nil,
                     reason: "no-candidate-in-radius", res: res, started: started,
                     extra: "tol=\(tolerance) targets=\(res.candidates.count) nearest3=[\(nearest)]")
                return Unmanaged.passUnretained(event)
            case .ambiguous(let scored, let tie):
                // An exact tie has no indicated winner and must not be promoted
                // into a different click target by a delivery-only rule.
                let listed = scored.prefix(3)
                    .map { "\($0.candidate.key):\(String(format: "%.1f", $0.dist))" }
                    .joined(separator: ",")
                emit("PASSTHROUGH", type: label, original: original, mutated: nil,
                     reason: "ambiguous", res: res, started: started,
                     extra: "cands=[\(listed)] tie=\(String(format: "%.1f", tie)) tol=\(tolerance)")
                return Unmanaged.passUnretained(event)
            case .redirect:
                // Deliver only the shared indicated winner. Unknown/mismatched
                // evidence never causes a redirect to a farther target.
                let scored = DecisionCore.displayCandidates(point: original,
                                                            candidates: res.candidates,
                                                            tolerance: tolerance, limit: 3)
                var confirmed: [(DecisionCore.ScoredCandidate, CGPoint, DecisionCore.Snap, DeliveryPlan)] = []
                var firstFailure: (String, ClickAssistVerdict, String?)?
                for choice in scored {
                    let snap = DecisionCore.snapMode(for: choice.candidate)
                    let dest = snap == .center
                        ? DecisionCore.centerPoint(into: choice.candidate.rect)
                        : DecisionCore.clampPoint(original, into: choice.candidate.rect,
                                                  inset: choice.candidate.inset)
                    let plan = resolveDelivery(for: choice.candidate, destination: dest,
                                               res: res, allowsSynthetic: true)
                    switch plan.kind {
                    case .axPress, .synthetic:
                        confirmed.append((choice, dest, snap, plan))
                    case .rejected:
                        if firstFailure == nil {
                            firstFailure = (choice.candidate.key, plan.verdict, plan.rejectReason)
                        }
                    }
                }
                guard let winner = confirmed.first else {
                    let failure = firstFailure ?? ("-", .unknown, nil)
                    emit("PASSTHROUGH", type: label, original: original, mutated: nil,
                         reason: failure.2 ?? "legitimacy-\(failure.1.rawValue)", res: res, started: started,
                         extra: "legitimacy=\(failure.1.rawValue) target=\(failure.0) cands=0 winner=0")
                    return Unmanaged.passUnretained(event)
                }
                let best = winner.0.candidate
                let snap = winner.2
                let plan = winner.3
                let weakEvidence = plan.verdict == .confirmedWeak
                // Frame evidence is the PUBLISHED cached rect; the resolver checks
                // movement/continuity on its own queue. Never refresh here.
                let corrected = winner.1
                if captureBackgroundClick(best, res: res, original: original, destination: corrected, event: event) {
                    return nil
                }

                // Chrome-button delivery: structural gate, then EXACTLY ONE
                // AXPress. Synthetic CGEvents are ignored by Chromium chrome.
                if case .axPress = plan.kind,
                   performAXPressDelivery(best: best, corrected: corrected,
                                          snap: snap, dist: winner.0.dist,
                                          cands: confirmed.count, res: res, label: label,
                                          original: original, started: started,
                                          extra: weakEvidence ? "legitimacy=confirmedWeak " : "") {
                    return nil
                }
                // Weak evidence is AXPress-only: a synthetic click here would be
                // aimed on the very hit-test answer that could not be confirmed.
                if weakEvidence {
                    emit("PASSTHROUGH", type: label, original: original, mutated: nil,
                         reason: "legitimacy-confirmedWeak", res: res, started: started,
                         extra: "legitimacy=confirmedWeak target=\(best.key) cands=0 winner=0")
                    return Unmanaged.passUnretained(event)
                }

                let delta = CGVector(dx: corrected.x - original.x, dy: corrected.y - original.y)
                event.location = corrected
                latched = GestureLatch(delta: delta, target: best.key, snap: snap,
                                       edgeCore: false)
                latched?.originalDown = original
                emit("MUTATE", type: label, original: original, mutated: corrected,
                     reason: "redirect", res: res, started: started,
                     extra: "delta=\(ScreenSpace.fmt(delta)) dist=\(String(format: "%.1f", winner.0.dist)) target=\(best.key) mode=return-modified-event mode=synthetic snap=\(snap.rawValue) tier=\(best.tier == .firstClass ? 1 : 2) legitimacy=confirmed cands=\(confirmed.count) winner=1")
                return Unmanaged.passUnretained(event)
            }
        }

        // Drag guard: a center snap is a CLICK assist. The moment that gesture
        // drags, the user is moving/pressing something at their own coordinates —
        // stop redirecting for the remainder (dragged events and the up stay
        // native). Edge-snapped gestures (sliders) keep the latched translation.
        if (isDrag || isUp), unlatchedForDrag {
            if isUp { unlatchedForDrag = false }
            return Unmanaged.passUnretained(event)
        }
        if isDrag, let l = latched, l.snap == .center {
            if hypot(original.x - l.originalDown.x, original.y - l.originalDown.y)
                <= ClickAssistEvidence.pointerMoveEpsilon {
                log("CLICK_JITTER_HELD mode=foreground target=\(l.target)")
                return nil
            }
            latched = nil
            unlatchedForDrag = true
            emit("PASSTHROUGH", type: label, original: original, mutated: nil,
                 reason: "unlatched-on-drag", res: res, started: started,
                 extra: "gesture=unlatched-on-drag target=\(l.target)")
            return Unmanaged.passUnretained(event)
        }

        // Drag / up: one latched translation for the whole gesture.
        if let l = latched {
            let corrected = CGPoint(x: original.x + l.delta.dx, y: original.y + l.delta.dy)
            event.location = corrected
            emit("MUTATE", type: label, original: original, mutated: corrected,
                 reason: "redirect", res: res, started: started,
                 extra: "delta=\(ScreenSpace.fmt(l.delta)) gesture=latched-constant target=\(l.target) mode=return-modified-event snap=\(l.snap.rawValue)\(l.edgeCore ? " edgecore=1" : "")")
            if isUp { latched = nil }
            return Unmanaged.passUnretained(event)
        }

        emit("PASSTHROUGH", type: label, original: original, mutated: nil,
             reason: "no-active-gesture", res: res, started: started)
        return Unmanaged.passUnretained(event)
    }

    // MARK: - AXPress delivery gate (chrome only)

    /// Delivers one gesture via AXPress: exactly one service request, then latch the
    /// per-gesture token so the matching up (and any drag) is swallowed by the
    /// top-of-handle guard. Shared by the redirect and direct-hit promotion paths.
    /// Takes ownership NOW (token + consume the down) and dispatches the request
    /// over XPC. The service re-checks deadline, generation and element identity
    /// before activating. Returns true (the down is consumed) as soon as
    /// ownership is taken; the service reply is advisory only.
    @discardableResult
    private func performAXPressDelivery(best: Candidate,
                                        corrected: CGPoint, snap: DecisionCore.Snap,
                                        dist: Double, cands: Int, res: Resolution,
                                        label: String, original: CGPoint,
                                        started: CFTimeInterval, extra: String) -> Bool {
        let request = AXPressRequest(targetKey: best.key, pid: res.pid,
                                     generation: res.generation,
                                     issuedAt: CACurrentMediaTime())
        pressGestureToken = request.requestID
        latched = nil
        unlatchedForDrag = false
        emit("MUTATE", type: label, original: original, mutated: corrected,
             reason: "redirect", res: res, started: started,
             extra: "target=\(best.key) dist=\(String(format: "%.1f", dist)) snap=\(snap.rawValue) tier=\(best.tier == .firstClass ? 1 : 2) legitimacy=confirmed cands=\(cands) winner=1 \(extra)mode=axpress request=\(request.requestID.uuidString)")
        dispatchAXPress(request: request)
        return true
    }

    /// Off-callback activation. Ownership is already taken; the service owns all
    /// validation and AXPress execution. The reply is advisory: the callback never
    /// waits for it, and a rejection never retries or synthesizes.
    private func dispatchAXPress(request: AXPressRequest) {
        activationSink?(request)
    }

    /// Finds the nearest chrome button contained in a direct-hit candidate and
    /// still inside the assist radius. Margin-tolerant: the hit rect is inflated
    /// by 2 pt. Eligibility is the PUBLISHED `chromeEligible` evidence — no AX
    /// read happens here.
    /// `restrictedTo` narrows the search to the candidates an ambiguity tie is
    /// actually about; nil means the caller supplies its own anchor (the
    /// direct-hit branch's containment).
    private func promotedTarget(res: Resolution, point: CGPoint,
                                containedIn: CGRect?,
                                restrictedTo: Set<String>? = nil) -> Candidate? {
        let containing = containedIn?.insetBy(dx: -2, dy: -2)
        var best: (candidate: Candidate, dist: CGFloat)?
        for c in res.candidates {
            if let restrictedTo, !restrictedTo.contains(c.key) { continue }
            let dist = DecisionCore.boundaryDistance(point, c.rect)
            guard dist <= tolerance else { continue }
            if let containing, !containing.contains(c.rect) { continue }
            guard c.chromeEligible else { continue }
            if let b = best {
                let area = c.rect.width * c.rect.height
                let bestArea = b.candidate.rect.width * b.candidate.rect.height
                if dist < b.dist || (dist == b.dist && area < bestArea) {
                    best = (c, dist)
                }
            } else {
                best = (c, dist)
            }
        }
        return best?.candidate
    }

    private func emit(_ kind: String, type: String, original: CGPoint, mutated: CGPoint?,
                      reason: String, res: Resolution, started: CFTimeInterval, extra: String = "") {
        let latency = (CACurrentMediaTime() - started) * 1_000_000
        var line = "\(kind) type=\(type) "
        if kind == "MUTATE" {
            line += "orig=\(ScreenSpace.fmt(original)) mutated=\(ScreenSpace.fmt(mutated ?? original)) "
        } else {
            line += "loc=\(ScreenSpace.fmt(original)) "
        }
        line += "reason=\(reason) "
        if !extra.isEmpty { line += extra + " " }
        line += String(format: "latency_us=%.2f gen=%llu age_ms=%.1f source=%@",
                       latency, res.generation, res.ageMs, res.source)
        if kind == "PASSTHROUGH" {
            line += " equality=orig==delivered"
        }
        log(line)
    }

    private static func name(_ t: CGEventType) -> String {
        switch t {
        case .leftMouseDown: return "leftMouseDown"
        case .leftMouseUp: return "leftMouseUp"
        case .leftMouseDragged: return "leftMouseDragged"
        case .rightMouseDown: return "rightMouseDown"
        case .rightMouseUp: return "rightMouseUp"
        case .rightMouseDragged: return "rightMouseDragged"
        case .otherMouseDown: return "otherMouseDown"
        case .otherMouseUp: return "otherMouseUp"
        case .otherMouseDragged: return "otherMouseDragged"
        default: return "type\(t.rawValue)"
        }
    }
}
