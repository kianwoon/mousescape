// baseline-guard:allow service-side AX element side table (never compiled into the agent)
import AppKit
import ApplicationServices
import CoreGraphics

/// Thread-safe side table of live AX element references, keyed by owning pid and
/// published target key. Lives ONLY in the resolver XPC service process.
final class AXElementTable: @unchecked Sendable {
    private let lock = NSLock()
    private var map: [pid_t: [String: AXUIElement]] = [:]

    func set(_ elements: [String: AXUIElement], pid: pid_t) {
        lock.lock()
        map = [pid: elements]
        lock.unlock()
    }

    func clear() {
        lock.lock()
        map.removeAll()
        lock.unlock()
    }

    func element(for key: String, pid: pid_t) -> AXUIElement? {
        lock.lock()
        defer { lock.unlock() }
        return map[pid]?[key]
    }
}


/// Accessibility-driven candidate resolver. Runs entirely OFF the tap callback:
/// a serial background queue walks the AX tree of the app owning the window under
/// the POINTER (falling back to the frontmost app), converts frames (AX global
/// space == CGEvent global space, top-left origin), and publishes an immutable
/// snapshot into CacheStore. The tap only ever reads that snapshot.
///
/// Refresh triggers (throttled):
///  * periodic 50 ms tick (timer, leeway 5 ms)
///  * AX notifications: window moved / resized / destroyed / focused window changed
///  * app activation / deactivation (NSWorkspace, NSApplication)
/// Any of those publishes an INVALID snapshot first (fail-open) and then refreshes.
final class AccessibilityResolver: @unchecked Sendable {
    /// Processes whose windows must never be treated as the pointer's window.
    /// When the resolver runs inside an XPC service, `getpid()` is the SERVICE —
    /// the agent that owns the click-through overlay windows is a DIFFERENT
    /// process, so self-exclusion alone lets the overlay (or the agent itself)
    /// claim pointer ownership and the real app beneath is never resolved.
    /// Set once by the service from the client handshake.
    private let exclusionLock = NSLock()
    private var excludedOwnerPids: Set<pid_t> = []
    private var excludedWindowIDs: Set<Int> = []
    func setExclusions(pids: Set<pid_t>, windowIDs: Set<Int>) {
        exclusionLock.lock(); excludedOwnerPids = pids; excludedWindowIDs = windowIDs; exclusionLock.unlock()
    }
    private func isExcluded(owner pid: pid_t) -> Bool {
        if pid == getpid() { return true }
        exclusionLock.lock(); let e = excludedOwnerPids.contains(pid); exclusionLock.unlock()
        return e
    }
    // Admission geometry — role sets, envelopes, frame floor, giant/area bounds —
    // all live in `GeometryPolicy` (ClickAssistGeometry.swift). This class only
    // reads one `GeometryVerdict` per element and counts the rejection bucket.
    /// Two candidates whose frames overlap this completely are the SAME control
    /// exposed twice (e.g. AXImage + its AXGroup wrapper); the smaller area wins.
    private static let duplicateIoUThreshold: CGFloat = 0.85

    /// Same anyHost preference contract as the agent; the XPC target deliberately
    /// does not compile the app's UI configuration/status implementation.
    private var selectionTolerance: CGFloat {
        let raw = CFPreferencesCopyValue("MCClickAssistTolerancePoints" as CFString,
                                          "com.sdmj76.Mousecape" as CFString,
                                          kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        let value = (raw as? NSNumber)?.doubleValue ?? 12
        return ClickAssistTolerance.validated(CGFloat(value))
    }

    private let cache: CacheStore
    private let log: (String) -> Void
    /// The ONE legitimacy policy shared with the overlay. Called ONLY on this
    /// resolver queue (background) — never from the tap callback.
    private let legitimacy: LegitimacyPolicy?
    private let queue = DispatchQueue(label: "clickassist.resolver", qos: .utility)
    /// Live AX element references, service-process only. The agent never sees
    /// these; it receives published snapshot evidence over XPC instead.
    let elements = AXElementTable()

    private let stateLock = NSLock()
    private var refreshSuspended = false
    private var enabled = true

    private var timer: DispatchSourceTimer?
    private var movementSource: DispatchSourceUserDataAdd?
    private var movementRefreshPending = false
    private var observer: AXObserver?
    private var observedPid: pid_t = 0
    private var generation: UInt64 = 0
    private var lastRects: [String] = []
    private var lastResolvedPid: pid_t = 0
    private var running = false
    private var loggedSecure: Set<String> = []
    private var loggedRowCapabilities: Set<String> = []
    /// Per-target last time the AX walk (or pointer seed) actually saw it. Used to
    /// keep a monotonic union across truncated walks.
    private var lastSeen: [String: CFTimeInterval] = [:]
    /// Last VALID published target set. Kept resolver-side so a transient invalid
    /// snapshot cannot erase the union before the next walk re-merges it.
    private var unionTargets: [CachedTarget] = []
    /// Delivery side table: the live AX element behind each admitted candidate
    /// key, published into CacheStore at the end of each cycle. Persists across
    /// cycles so union-held targets keep a usable reference; pruned to the keys
    /// still present and cleared on app switch / invalidation.
    private var elementRefs: [String: AXUIElement] = [:]
    private var unionPid: pid_t = 0
    /// Per-pid stash of the union/rotation state. A LEGITIMATE pid switch parks the
    /// outgoing app's resolvable state here; flipping back restores it instead of
    /// rebuilding through 2-3 empty walk cycles. Transient window-boundary pid
    /// flips never reach this (pointer hysteresis below), so a stash hit means the
    /// user genuinely returned to a previously resolved app.
    private struct UnionStash {
        var targets: [CachedTarget]
        var lastSeen: [String: CFTimeInterval]
        var frontier: [(element: AXUIElement, depth: Int)]
        var frontierHead: Int
        var sliceIndex: Int
        var coverageKeys: Set<String>
        var lastUsed: CFTimeInterval
    }
    private var unionStashes: [pid_t: UnionStash] = [:]
    /// Bounded LRU so a long session cannot accumulate stale snapshots.
    private static let maxUnionStashes = 4
    /// Resolved-pid hysteresis. A NEW candidate pid (pointer window, or the
    /// frontmost fallback when the pointer window is momentarily unresolvable)
    /// must be observed on this many consecutive refresh cycles before it may
    /// trigger a switch (union swap + app-switch-polled). Overlapping-window
    /// boundaries flip the candidate between two pids — and sometimes between a
    /// pid and nil (fallback to frontmost) — every cycle; 2 consecutive samples
    /// filters both out. A genuine frontmost-app change switches immediately.
    private var lastFrontPid: pid_t = 0
    private var pendingResolvedPid: pid_t = 0
    private var pendingResolvedPidCount = 0
    private static let pointerPidHysteresisCycles = 2
    /// Set when a walk bails out because its deadline passed (pointer window
    /// 100 ms, rotation 250 ms). Reset per refresh; drives `partial`/`trunc=`.
    private var truncatedByDeadline = false
    /// Cooperative deadlines. The POINTER-WINDOW walk is the one on the
    /// first-appearance path, so it gets the tight 100 ms budget; the rotating
    /// global slice keeps 250 ms because it only fills the union in the background.
    private static let pointerWindowDeadlineMs: Double = 60
    private static let rotationDeadlineMs: Double = 250
    /// Persisted breadth-first frontier. The head cursor survives refreshes, so
    /// successive 600-node slices advance into different subtrees instead of
    /// re-walking the same prefix. Bounded and reset on invalidation/app change.
    private var frontier: [(element: AXUIElement, depth: Int)] = []
    private var frontierHead = 0
    private var sliceIndex = 0
    private var consecutiveLocalRotationSkips = 0
    private var coverageKeys: Set<String> = []
    private static let maxFrontierNodes = 20_000
    private static let frontierCompactionThreshold = 1_024
    /// Dedicated per-cycle budget for the pointer-window priority walk. Taken out
    /// of `nodeBudget`, so seed + pwin + rotation never exceed 600 nodes any cycle.
    private static let pointerWindowBudget = 300
    /// Depth bound for the pointer-window SUBTREE walk (children of the guided
    /// descent's deepest node). Deep nested web/player trees (YouTube controls sit
    /// below several AXGroup/WebArea levels) need more than the rotation walk's
    /// 12-level frontier guard. Expressed RELATIVE to the guided endpoint, so the
    /// total width of the walk is unchanged while the endpoint may be much deeper.
    private static let pointerWindowMaxDepth = 24
    /// Depth bound for the POINTER-GUIDED DESCENT itself. Guided descent costs ~1
    /// node per level (it reads children only to choose the single containing one),
    /// so depth is far cheaper than breadth: 48 levels ≈ 48 nodes out of the 300-node
    /// pointer-window budget, and the deadline still stops it first if AX stalls.
    /// x.com's feed player keeps its controls 56-61 levels below the window
    /// (measured live), so the bound leaves headroom above that.
    private static let pointerWindowGuidedMaxDepth = 80
    /// Sibling branches within this many points of the pointer are rescued to
    /// the absolute guided depth bound instead of the endpoint-relative one.
    private static let pointerRescueNearRadius: CGFloat = 150
    /// Hit-test ancestry rescue: levels climbed from the hit element, levels walked
    /// back down from that container, and the node budget it may spend per cycle.
    private static let hitAncestryClimb = 6
    private static let hitAncestryDescend = 8
    private static let hitAncestryBudget = 100
    /// Default depth bound for the shared `walk` (rotation-style consumers).
    private static let walkMaxDepth = 12
    /// Adaptive cadence. The walk is the dominant resolver cost (measured mean
    /// 119 ms/pass on a 150 ms cadence). Moving pointer -> keep the fast cadence;
    /// pointer still for longer than `idleMovementWindow` -> slow down and skip
    /// the rotation slice. Any movement snaps back on the very next tick.
    private static let fastCadence: TimeInterval = 0.05
    private static let idleCadence: TimeInterval = 0.4
    private static let idleMovementWindow: CFTimeInterval = 1.5
    /// Movement smaller than this is treated as noise (sub-pixel/drift).
    private static let pointerMoveEpsilon: CGFloat = ClickAssistEvidence.pointerMoveEpsilon
    /// Increments only when the pointer moves beyond `pointerMoveEpsilon`.
    /// Carried through resolver -> wire -> client so first-appearance latency is
    /// attributable to ONE pointer position.
    private var pointerGeneration: UInt64 = 0
    /// Last hit-window focus answer, reused by seed cycles at the same pointer.
    private var lastWindowFocus: (pid: pid_t, pointerGeneration: UInt64, focused: Bool)?
    private var lastPointerGenerationPoint: CGPoint?
    /// Queue-confined cadence state (resolver serial queue only).
    private var lastCyclePointer: CGPoint?
    private var lastMovementAt: CFTimeInterval = 0
    private var lastWalkAt: CFTimeInterval = 0
    private var cadenceIdle = false
    /// Candidates within the assist radius in the last published cycle (cadence
    /// input: a resting pointer over a control must keep the fast cadence).
    private var lastNearPointerCount = 0
    /// A published target survives this long without being re-seen. Large Chromium
    /// trees need several slices to complete one pass, so this must exceed a pass
    /// (typically <2 s at 600 nodes/150 ms). Trade-off: a control that truly
    /// disappeared can linger in the union for up to this window before expiring.
    private static let targetFreshnessWindow: CFTimeInterval = 10.0
    /// Pids we already probed for complete renderer accessibility (once per pid;
    /// Electron honors AXManualAccessibility, Chrome honors AXEnhancedUserInterface).
    private var manualA11yProbed: Set<pid_t> = []
    /// Targets within this radius of the pointer never expire (see the union merge).
    private static let pointerHoldRadius: CGFloat = 48
    private static let nodeBudget = 600
    private static let seedAncestryDepth = 8
    /// SOFT-invalidation coalescing window. Multiple AX-churn notifications inside
    /// it collapse into a single walk; routing stays on the previous snapshot until
    /// the tap's `DecisionCore.cacheMaxAge` (1 s) expires.
    private static let softCoalesceInterval: TimeInterval = 0.1
    /// Notification reasons treated as churn (soft). Everything else (window
    /// moved/resized, space change, plus all non-AX hard events) stays hard.
    /// Identity/activation churn moves no rects, so the last snapshot stays routable.
    private static let softNotificationReasons: Set<String> = [
        "uielementdestroyed", "layoutchanged", "valuechanged", "focusedwindowchanged"
    ]
    /// Queue-confined (resolver serial queue only): true while one coalesced
    /// soft refresh is pending, so a notification storm schedules exactly one walk.
    private var softRefreshScheduled = false
    /// Diagnostics only: rejected-role elements within this many points of the
    /// pointer are reported once per cycle (one dedicated log line). Caps keep the
    /// extra cost bounded — at most `rejectedScanCap` rejected nodes are measured
    /// (2 AX reads each, same as an eligible node) and at most `rejectedNearCap`
    /// are retained. Nothing survives the cycle.
    private static let rejectedNearRadius: CGFloat = 48
    private static let rejectedNearCap = 5
    private static let rejectedScanCap = 120
    private var cyclePointer = CGPoint.zero
    private var rejectedNear: [(role: String, label: String, rect: CGRect, dist: CGFloat)] = []
    private var rejectedScanned = 0
    /// Per-cycle display bounds in AX/CG points, handed to `GeometryPolicy`
    /// so every class is bounded by the displays it actually intersects.
    private var cycleDisplayBounds: [CGRect] = []
    /// On-screen window frames of the target app, read once per cycle. The
    /// window-fill rule uses the smallest one containing an element.
    private var cycleWindowBounds: [CGRect] = []
    /// Press groups proven to contain a control, keyed by frame, for the
    /// current target pid. Only positives are kept: controls such as a video
    /// player's can auto-hide, so a negative answer is not stable.
    private var knownContainers: Set<String> = []
    private var knownContainersPid: pid_t = 0
    /// Diagnostics: time spent this cycle on window frames / container probes.
    private var cycleWindowMs: Double = 0
    private var cycleProbeMs: Double = 0
    /// Diagnostics: container probe outcomes already logged (key per pid).
    private var loggedProbes: Set<String> = []
    /// Diagnostics only: tile-like elements (AXImage/AXGroup) rejected as too
    /// small, and near-identical duplicates merged, per cycle. Reset per
    /// refresh; published as `tileTooSmall=`/`deduped=`.
    private var tileTooSmall = 0
    /// Candidates rejected by the user size invariant (too big = wrong for sure).
    private var oversized = 0
    /// Tile-like candidates rejected for a sliver aspect ratio (not area).
    private var tileTooWide = 0
    /// Every rejection this cycle keyed by `RejectionReason.rawValue`, published
    /// as `rej=[reason:count,...]` so a bucket names its real cause.
    private var rejCounts: [String: Int] = [:]
    private var dedupedCount = 0

    /// Count one policy rejection. The three legacy named counters keep their
    /// pre-refactor names; the aggregate carries every reason.
    private func record(_ reason: RejectionReason) {
        rejCounts[reason.rawValue, default: 0] += 1
        switch reason {
        case .oversized: oversized += 1
        case .tileTooSmall: tileTooSmall += 1
        case .tileTooWide: tileTooWide += 1
        default: break
        }
    }

    init(cache: CacheStore, legitimacy: LegitimacyPolicy? = nil,
         log: @escaping (String) -> Void) {
        self.cache = cache
        self.legitimacy = legitimacy
        self.log = log
    }

    // MARK: - lifecycle

    func start() {
        guard !running else { return }
        running = true

        NotificationCenter.default.addObserver(forName: NSWorkspace.didActivateApplicationNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.log("RESOLVER_EVENT app-activated")
            self.softInvalidate(reason: "app-switch")
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.log("RESOLVER_EVENT app-resigned-active")
            self.softInvalidate(reason: "app-resign-active")
        }
        // Gate 4: a Space switch invalidates immediately. The frontmost app does not
        // change, so only this notification can distinguish a Space move from a click.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil, queue: .main) { [weak self] _ in
                guard let self else { return }
                self.log("RESOLVER_EVENT space-changed")
                self.invalidate(reason: "space-change")
            }

        let t = DispatchSource.makeTimerSource(queue: queue)
        // The tick itself is cheap; `tick()` decides whether this beat is due. The
        // effective cadence is fast (50 ms) while the pointer moves and idle
        // (400 ms, rotation skipped) once it has been still for `idleMovementWindow`.
        t.schedule(deadline: .now() + 0.05, repeating: Self.fastCadence, leeway: .milliseconds(5))
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
        // Listen only: input is never modified here. Dispatch-source merging
        // prevents high-rate mice from queuing one AX walk per mouse event.
        let movement = DispatchSource.makeUserDataAddSource(queue: queue)
        movement.setEventHandler { [weak self] in
            guard let self, self.running, !self.movementRefreshPending else { return }
            self.movementRefreshPending = true
            let requestedAt = CACurrentMediaTime()
            let delay = max(0, Self.fastCadence - (requestedAt - self.lastWalkAt))
            self.queue.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self else { return }
                self.movementRefreshPending = false
                self.tick(movementRequestedAt: requestedAt)
            }
        }
        movement.resume()
        movementSource = movement
    }

    func stop() {
        movementSource?.cancel()
        movementSource = nil
        timer?.cancel()
        timer = nil
        running = false
        if let observer, observedPid != 0 {
            let app = AXUIElementCreateApplication(observedPid)
            for note in [kAXFocusedWindowChangedNotification, kAXUIElementDestroyedNotification,
                         kAXWindowMovedNotification, kAXWindowResizedNotification] {
                AXObserverRemoveNotification(observer, app, note as CFString)
            }
        }
        observer = nil
        observedPid = 0
    }

    // MARK: - control surface

    func pointerMoved() { movementSource?.add(data: 1) }

    /// Real-time invalidation: publish "do not route" immediately, refresh after.
    func invalidate(reason: String, prefixStale: Bool = true) {
        publishInvalid(reason: prefixStale ? "stale:\(reason)" : reason, pointer: currentPointer())
        // Rotation state is invalid after any invalidation (window move/destroy,
        // app/space switch): the persisted frontier would point at stale geometry.
        // Hard discontinuity: stashed geometry for EVERY pid is stale too, so drop
        // the stashes with the frontier rather than resurrect old targets later.
        queue.async { [weak self] in
            self?.resetRotation()
            self?.unionStashes.removeAll()
        }
        queue.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.refresh(lastPointer: .zero)
        }
    }

    /// SOFT invalidation: AX churn (element destroyed / layout changed / value
    /// changed) and identity churn (app activation/resign, focused window change)
    /// must NOT publish a non-routable snapshot. The last snapshot keeps routing
    /// until the tap's 1 s max age expires, and at most ONE coalesced refresh is
    /// scheduled per `softCoalesceInterval`. Hard discontinuities (space change,
    /// window move/resize, self-app, disable, permission loss) still go through
    /// `invalidate` above and fail closed exactly as before.
    private func softInvalidate(reason: String) {
        queue.async { [weak self] in
            guard let self else { return }
            let coalesced = self.softRefreshScheduled
            self.log("RESOLVER_SOFT_INVALIDATE reason=\(reason) action=refresh-only coalesced=\(coalesced ? 1 : 0)")
            guard !coalesced else { return }
            self.softRefreshScheduled = true
            self.queue.asyncAfter(deadline: .now() + Self.softCoalesceInterval) { [weak self] in
                guard let self else { return }
                self.softRefreshScheduled = false
                // Same walk as any other refresh: union, rotation, bounded budget.
                // Any hard condition detected inside it (pid change, lost trust,
                // self-app) still publishes non-routable / hard-invalidates.
                self.refresh(lastPointer: .zero)
            }
        }
    }

    /// Clears the persisted slice frontier and coverage counters. Resolver-queue only.
    private func resetRotation() {
        frontier.removeAll()
        frontierHead = 0
        sliceIndex = 0
        coverageKeys.removeAll()
    }

    /// Park the ACTIVE union + rotation frontier under its pid (bounded LRU).
    /// Resolver-queue only. Evicts the least-recently-used pid past the cap.
    private func stashUnion(pid: pid_t, log: (String) -> Void) {
        unionStashes[pid] = UnionStash(targets: unionTargets, lastSeen: lastSeen,
                                       frontier: frontier, frontierHead: frontierHead,
                                       sliceIndex: sliceIndex, coverageKeys: coverageKeys,
                                       lastUsed: CACurrentMediaTime())
        while unionStashes.count > Self.maxUnionStashes {
            guard let victim = unionStashes.min(by: { $0.value.lastUsed < $1.value.lastUsed })?.key else { break }
            unionStashes.removeValue(forKey: victim)
            log("RESOLVER_EVENT app-switch-stash pid=\(victim) action=evict stashes=\(unionStashes.count)")
        }
        log("RESOLVER_EVENT app-switch-stash pid=\(pid) action=store targets=\(unionTargets.count) frontier=\(frontier.count) stashes=\(unionStashes.count)")
    }

    /// Restore a stashed union/rotation state in place. One-shot: a restored stash
    /// is consumed and re-created on the next departure. Returns false on miss
    /// (caller rebuilds from scratch). Resolver-queue only.
    private func restoreUnion(pid: pid_t) -> Bool {
        guard let stash = unionStashes.removeValue(forKey: pid) else { return false }
        unionTargets = stash.targets
        lastSeen = stash.lastSeen
        frontier = stash.frontier
        frontierHead = stash.frontierHead
        sliceIndex = stash.sliceIndex
        coverageKeys = stash.coverageKeys
        return true
    }

    /// Timer beat. Cheap on every tick; the expensive walk only runs when due.
    /// Movement is detected by comparing the current pointer with the previous
    /// beat's, so the first beat after movement runs the fast path immediately
    /// (no added latency) — the idle interval is only ever entered after
    /// `idleMovementWindow` of stillness.
    private func tick(movementRequestedAt: CFTimeInterval? = nil) {
        guard running, isRefreshAllowed else { return }
        let now = CACurrentMediaTime()
        let pointer = currentPointer()
        let moved: Bool
        if let previous = lastCyclePointer {
            let dx = pointer.x - previous.x
            let dy = pointer.y - previous.y
            moved = (dx * dx + dy * dy) > (Self.pointerMoveEpsilon * Self.pointerMoveEpsilon)
        } else {
            moved = true   // first sample: behave as movement
        }
        // A timer may already have serviced this movement while the coalesced
        // request waited. Never add a duplicate walk or count another PID beat.
        if movementRequestedAt != nil, !moved { return }
        if movementRequestedAt != nil, now - lastWalkAt < Self.fastCadence { return }
        lastCyclePointer = pointer
        if moved { lastMovementAt = now }

        // An idle pointer is only truly idle when NOTHING is in assist range.
        // Evidence has a 700 ms display window (ClickAssistEvidence.displayMaxAgeMs)
        // while the idle cadence is 700 ms, so a resting pointer that HAS a candidate in
        // range would otherwise see its evidence expire between walks — rings and
        // assists would die exactly where the user is aiming. Keep the fast
        // cadence while the previous cycle had candidates near the pointer.
        let idle = !moved && (now - lastMovementAt) > Self.idleMovementWindow
            && lastNearPointerCount == 0
        if idle != cadenceIdle {
            cadenceIdle = idle
            log(String(format: "RESOLVER_CADENCE %@ interval_ms=%.0f reason=%@",
                       idle ? "idle" : "fast",
                       (idle ? Self.idleCadence : Self.fastCadence) * 1000,
                       (idle ? "idle" : "movement") as NSString))
        }
        // Idle: slow cadence, and skip the rotation slice (pointer window only).
        if idle, now - lastWalkAt < Self.idleCadence { return }
        lastWalkAt = now
        if let requestedAt = movementRequestedAt {
            timer?.schedule(deadline: .now() + Self.fastCadence,
                            repeating: Self.fastCadence, leeway: .milliseconds(5))
            log(String(format: "RESOLVER_MOVEMENT_TRIGGER wait_ms=%.2f", (now - requestedAt) * 1000))
        }
        refresh(lastPointer: .zero, rotationAllowed: !idle)
    }

    private var isRefreshAllowed: Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return enabled && !refreshSuspended
    }

    private var isEnabled: Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return enabled
    }

    // MARK: - snapshot publication

    private func nextGeneration() -> UInt64 {
        generation += 1
        return generation
    }

    private func publishInvalid(reason: String, pointer: CGPoint) {
        let prev = cache.current()
        let snap = CacheSnapshot(generation: nextGeneration(), targets: [], valid: false,
                                 reason: reason, stamp: CACurrentMediaTime(), resolverMs: 0,
                                 pointer: pointer, appName: prev.appName, pid: prev.pid)
        elementRefs.removeAll()
        elements.clear()
        cache.publish(snap)
        log("RESOLVER_INVALIDATE gen=\(snap.generation) reason=\(reason) action=pass-through-until-refresh")
    }

    // MARK: - resolution

    private func currentPointer() -> CGPoint {
        CGEvent(source: nil)?.location ?? .zero
    }

    /// `rotationAllowed` is false only on idle timer beats: the pointer window is
    /// still walked, but the rotating global slice is skipped to cut idle CPU.
    private func refresh(lastPointer: CGPoint, rotationAllowed: Bool = true) {
        guard running, isRefreshAllowed else { return }

        let t0 = CACurrentMediaTime()
        guard AXIsProcessTrusted() else {
            publishUnreachable(reason: "unavailable:no-trust", t0: t0)
            return
        }
        guard let front = NSWorkspace.shared.frontmostApplication else {
            publishUnreachable(reason: "unavailable:no-frontmost-app", t0: t0)
            return
        }
        let frontPid = front.processIdentifier
        let pointer = currentPointer()
        // Pointer generation: the trace ID for THIS pointer position. Increment
        // only beyond the 2 pt epsilon, so sub-pixel drift cannot fragment one
        // hover into many generations.
        if let previous = lastPointerGenerationPoint {
            let dx = pointer.x - previous.x
            let dy = pointer.y - previous.y
            if (dx * dx + dy * dy) > (Self.pointerMoveEpsilon * Self.pointerMoveEpsilon) {
                pointerGeneration += 1
                lastPointerGenerationPoint = pointer
            }
        } else {
            pointerGeneration += 1
            lastPointerGenerationPoint = pointer
        }

        // TARGET THE WINDOW UNDER THE POINTER, not the frontmost app. The user can
        // hover a visible window of a background app; resolving frontmost-only made
        // that hover produce no targets (observed: app="OpenCode" logged while the
        // pointer sat over a browser window). Chain: window-server owner pid ->
        // frontmost app -> (self pid) non-routable self pass-through below.
        // POINTER OWNERSHIP FOLLOWS REAL CLICK ROUTING. A system-wide AX hit test
        // identifies the element a click would actually reach, skipping
        // click-through full-screen overlays (capture/screenshot HUDs) that the
        // CG z-order reports above the real window. Only on failure/timeout do we
        // fall back to the historical CG-order selection.
        let pointerOwner = pointerOwnerPid(pointer)
        let rawPointerPid = pointerOwner.pid
        let pidSrc = pointerOwner.source
        let pointerPid: pid_t? = (rawPointerPid != nil && rawPointerPid != getpid()) ? rawPointerPid : nil
        let candidate = pointerPid ?? frontPid
        // Frontmost-app changes are real user intent: switch immediately, exactly
        // as before. Everything else (pointer-window pid, and the frontmost
        // fallback while the pointer window is momentarily unresolvable) must be
        // stable for `pointerPidHysteresisCycles` consecutive cycles. Overlapping-
        // window boundaries alternate the candidate every cycle, so they never
        // reach the threshold and the active union survives.
        let frontChanged = lastFrontPid != 0 && frontPid != lastFrontPid
        lastFrontPid = frontPid
        let pid: pid_t
        var hysteresisHeld = false
        if candidate == lastResolvedPid || lastResolvedPid == 0 {
            pendingResolvedPid = 0
            pendingResolvedPidCount = 0
            pid = candidate
        } else if frontChanged {
            pendingResolvedPid = 0
            pendingResolvedPidCount = 0
            pid = candidate
        } else if candidate == pendingResolvedPid {
            pendingResolvedPidCount += 1
            if pendingResolvedPidCount >= Self.pointerPidHysteresisCycles {
                pendingResolvedPid = 0
                pendingResolvedPidCount = 0
                pid = candidate
            } else {
                pid = lastResolvedPid
                hysteresisHeld = true
            }
        } else {
            pendingResolvedPid = candidate
            pendingResolvedPidCount = 1
            pid = lastResolvedPid
            hysteresisHeld = true
        }
        if hysteresisHeld {
            // Evidence for acceptance gate (a): the flip was suppressed this cycle.
            log("RESOLVER_EVENT app-switch-held held=\(pid) pending=\(candidate) rawPointer=\(rawPointerPid.map { String($0) } ?? "-") hysteresisCount=\(pendingResolvedPidCount) front=\(frontPid)")
        }
        // Name is derived from the CHOSEN pid only — never from `front`. A frontmost
        // name next to a pointer-window pid is exactly the log lie this fixes
        // (observed: app="Dock" pid=14258, app="Mousecape" pid=174 = WindowServer).
        let targetApp = NSRunningApplication(processIdentifier: pid)
        let appName = targetApp?.localizedName ?? targetApp?.bundleIdentifier ?? "pid:\(pid)"

        // Structural self-RPC guard: a query to our own process must be serviced by
        // our own main thread, which can be inside AX notification handling. Never
        // issue AX element/attribute/observer calls for self; publish non-routable.
        if pid == getpid() {
            lastResolvedPid = pid
            publishSelfApp(t0: t0)
            return
        }

        // Poll-based switch detection: NSWorkspace activation notifications are not
        // reliably delivered on all OS versions; the 150 ms timer is authoritative.
        // This now also covers pointer-driven target changes (hovering another app's
        // window), so the union/rotation reset path is identical for both causes.
        if lastResolvedPid != 0, pid != lastResolvedPid {
            log("RESOLVER_EVENT app-switch-polled prev=\(lastResolvedPid) new=\(pid) front=\(frontPid) pointerWindow=\(pointerPid.map { String($0) } ?? "-") hysteresisCount=\(Self.pointerPidHysteresisCycles)")
            // Activation/pointer-pid churn moves no rects: keep the prior snapshot
            // routable and let this same refresh publish the re-targeted union.
            softInvalidate(reason: "app-switch")
        }
        lastResolvedPid = pid

        let appEl = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appEl, 0.2)
        ensureObserver(pid: pid, appElement: appEl)
        // First-encounter probe (once per pid): Chromium/Electron builds only a
        // PARTIAL renderer tree unless forced. Setting AXManualAccessibility
        // (Electron) / AXEnhancedUserInterface (Chrome) asks the app for the
        // COMPLETE tree — tab bodies, generic clickable divs (AXGroup+AXPress) —
        // which the partial tree omits entirely. Electron rebuilds ~2 s later.
        // Unsupported attributes are ignored by non-Chromium apps (harmless).
        if !manualA11yProbed.contains(pid), pid > 0 {
            manualA11yProbed.insert(pid)
            let probe = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(probe, 0.2)
            AXUIElementSetAttributeValue(probe, "AXManualAccessibility" as CFString, kCFBooleanTrue)
            AXUIElementSetAttributeValue(probe, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
            log("RESOLVER_EVENT manual-a11y pid=\(pid) requested=AXManualAccessibility+AXEnhancedUserInterface")
        }

        var out: [CachedTarget] = []
        var budget = Self.nodeBudget
        let rotationDeadline = t0 + Self.rotationDeadlineMs / 1000
        let pointerDeadline = t0 + Self.pointerWindowDeadlineMs / 1000
        truncatedByDeadline = false
        cycleDisplayBounds = Self.displayBoundsAX()
        let windowStart = CACurrentMediaTime()
        cycleWindowBounds = windowBoundsAX(pid: pid)
        cycleWindowMs = (CACurrentMediaTime() - windowStart) * 1000
        cycleProbeMs = 0
        let screenUnion = cycleDisplayBounds.reduce(CGRect.null) { $0.union($1) }

        // Diagnostics scratch for THIS cycle only (cleared next refresh): elements
        // the role filter rejected that sit near the pointer. Bounded by
        // rejectedScanCap examined nodes and rejectedNearCap retained entries.
        cyclePointer = pointer
        rejectedNear.removeAll()
        rejectedScanned = 0
        tileTooSmall = 0
        tileTooWide = 0
        rejCounts.removeAll()
        dedupedCount = 0

        // Per-pid union swap. This is now reached only on a LEGITIMATE switch
        // (pointer hysteresis filters boundary flips, frontmost changes are real).
        // Park the outgoing app's state and restore the incoming app's stash, so a
        // user flipping A -> B -> A never pays 2-3 empty rebuild cycles for A.
        // Sets are never mixed across pids: exactly one app's union is active.
        if unionPid != pid {
            let outgoing = unionPid
            if outgoing != 0 {
                stashUnion(pid: outgoing, log: log)
            }
            let restored = restoreUnion(pid: pid)
            if !restored {
                lastSeen.removeAll()
                unionTargets.removeAll()
                resetRotation()
            }
            unionPid = pid
            // Element references are pid-specific; never carry them across an app
            // switch. The next walks repopulate and the tap falls back to synthetic.
            elementRefs.removeAll()
            log("RESOLVER_EVENT app-switch-union prev=\(outgoing) new=\(pid) stash=\(restored ? "hit" : "miss") stashes=\(unionStashes.count)")
        }

        let priorElementRefs = elementRefs
        let windows: [AXUIElement] = attr(appEl, kAXWindowsAttribute).flatMap(axArray) ?? []
        let menuBar: AXUIElement? = attr(appEl, kAXMenuBarAttribute).flatMap(axElement)
        // Open NSMenus are usually NOT in kAXWindowsAttribute; a dropdown belongs to
        // the application element as an AXMenu child (higher CG window layer, e.g.
        // pop-up menu level ~101). Include it as a walk root so open menu items are
        // reachable by the guided/rotating walk. Walked under the same node budget
        // and deadline as every other root.
        let openMenu: AXUIElement? = attr(appEl, "AXMenu").flatMap(axElement)

        // Pointer-region seed FIRST: resolve the element under the cursor and walk
        // its immediate ancestry, so the visibly hovered control is captured even
        // when the global walk later exhausts its budget in a huge web-content tree.
        let pointerWalkStart = CACurrentMediaTime()
        let seedHit = seedAtPointer(appEl, pointer: pointer, out: &out, budget: &budget,
                                    deadline: pointerDeadline, screenUnion: screenUnion)

        // A direct seed still needs the SAME legitimacy proof as any published
        // winner. Only current-cycle seed entries participate, never the union.
        // Final union selection/validation below remains authoritative.
        var directSeed = false
        if seedHit, consecutiveLocalRotationSkips < 4, legitimacy != nil,
           !out.contains(where: { GeometryPolicy.usesNativeRowAction($0.role) }) {
            var seedCandidates = out.map {
                DecisionCore.Candidate(key: $0.key, rect: $0.rect, inset: $0.inset,
                    tier: $0.tier, role: $0.role, label: $0.label)
            }
            if case .winner(let winner, _) = DecisionCore.resolve(point: pointer,
                candidates: seedCandidates, tolerance: selectionTolerance),
               winner.dist == 0, winner.candidate.tier == .firstClass,
               let index = seedCandidates.firstIndex(where: { $0.key == winner.candidate.key }),
               let element = elementRefs[winner.candidate.key] {
                let target = winner.candidate
                let destination = DecisionCore.snapMode(for: target) == .center
                    ? DecisionCore.centerPoint(into: target.rect)
                    : DecisionCore.clampPoint(pointer, into: target.rect, inset: target.inset)
                // Separate preliminary proof: it must not populate the final
                // validator's cache before the full union/sibling set is known.
                let seedVerdict = LegitimacyPolicy().validate(pid: pid, generation: generation + 1,
                    key: target.key, candidate: target.rect, candidateRole: target.role,
                    destination: destination,
                    siblings: out.filter { $0.tier == .firstClass && $0.key != target.key }.map(\.rect),
                    candidateElement: element, diagnostic: { msg in
                        // Rejection reasons are always logged (diagnosing a flapping floating control).
                        if msg.hasPrefix("VERDICT_REJECT") { self.log("SEED \(target.key.prefix(24)) \(msg)") }
                    })
                seedCandidates[index] = DecisionCore.Candidate(key: target.key, rect: target.rect,
                    inset: target.inset, tier: target.tier, role: target.role, label: target.label,
                    verdict: seedVerdict)
                directSeed = DecisionCore.canDeferPointerWalk(point: pointer,
                    freshCandidates: seedCandidates, tolerance: selectionTolerance,
                    consecutiveLocalSkips: consecutiveLocalRotationSkips)
            }
        }

        // POINTER-WINDOW PRIORITY: Chromium web content often refuses AX hit-testing,
        // and the rotating global walk reaches a deep video-controls subtree only
        // every few cycles — so an already-seen control (e.g. the YouTube seek
        // slider) expires before it is seen again. Walk the AX window under the
        // pointer FIRST, every cycle, with its own budget, before any rotation.
        let pwinResult = directSeed ? (window: Optional<AXUIElement>.none, mode: "confirmed-seed")
            : windowUnderPointer(windows: windows, pointer: pointer, ownerPid: pid)
        let pwin: AXUIElement? = pwinResult.window
        let pwinMode = pwinResult.mode
        // Focus fact for the tap's one-click policy, read only for a live
        // hit-window (two cheap reads on elements already held). A seed cycle
        // reuses the last hit-window answer while the pointer has not moved
        // (live: seed and hit-window cycles alternate, so a click often lands
        // right after a seed cycle). None and ax-contain keep the default: focused.
        var pointerWindowFocused = true
        if pwinMode == "confirmed-seed", let last = lastWindowFocus,
           last.pid == pid, last.pointerGeneration == pointerGeneration {
            pointerWindowFocused = last.focused
        }
        if let pwin, pwinMode == "hit-window" {
            let isStandard = (attr(pwin, kAXSubroleAttribute) as? String) == (kAXStandardWindowSubrole as String)
            let focusedMatches = attr(appEl, kAXFocusedWindowAttribute)
                .flatMap(axElement).map { CFEqual($0, pwin) }
            pointerWindowFocused = GeometryPolicy.pointerWindowFocused(mode: pwinMode,
                isStandardWindow: isStandard, focusedMatches: focusedMatches)
            lastWindowFocus = (pid, pointerGeneration, pointerWindowFocused)
        }
        let keysBeforePwin = Set(out.map { $0.key })
        var pwinSpent = 0
        var pwinStats = WalkStats()
        if let pwin {
            var pwinBudget = min(Self.pointerWindowBudget, budget)
            walkGuided(pwin, pointer: pointer, out: &out, budget: &pwinBudget, deadline: pointerDeadline,
                       screenUnion: screenUnion, appElement: appEl, pid: pid,
                       maxDepth: Self.pointerWindowGuidedMaxDepth,
                       subtreeDepth: Self.pointerWindowMaxDepth, stats: &pwinStats)
            // Band BFS after the guided descent: catches the controls branch the
            // guided path cannot reach (video players). Pruned by geometry, so it
            // costs tens of nodes, not thousands.
            var bandBudget = min(budget, 220)
            let bandStart = bandBudget
            walkBand(pwin, pointer: pointer, radius: 48, out: &out, budget: &bandBudget,
                     deadline: pointerDeadline, screenUnion: screenUnion, appElement: appEl, pid: pid,
                     maxDepth: Self.pointerWindowGuidedMaxDepth, stats: &pwinStats)
            let bandSpent = bandStart - bandBudget
            pwinSpent = (min(Self.pointerWindowBudget, budget) - pwinBudget) + bandSpent
            budget -= pwinSpent   // total work stays inside the shared node budget
            if pwinMode == "hit-window", pwinStats.guidedFallbackReason == "no-containing-child" {
                let hitSpent = walkHitAncestry(appEl, pointer: pointer, out: &out,
                    budget: min(budget, Self.hitAncestryBudget), deadline: pointerDeadline,
                    screenUnion: screenUnion, pid: pid, stats: &pwinStats)
                pwinSpent += hitSpent
                budget -= hitSpent
            }
        }
        let pwinTargets = Set(out.map { $0.key }).subtracting(keysBeforePwin).count
        let pointerWalkMs = (CACurrentMediaTime() - pointerWalkStart) * 1000

        // Rotating BFS slice: resumes the persisted frontier so each cycle visits a
        // different part of the tree instead of re-walking the same 600-node prefix.
        // If the pointer-window walk consumed the budget (or the deadline), the
        // rotation is skipped this cycle so total work cannot exceed the bound.
        var roots = windows
        if let pwin, let idx = roots.firstIndex(where: { CFEqual($0, pwin) }) {
            roots.remove(at: idx)
            roots.insert(pwin, at: 0)
        }
        if let menuBar { roots.append(menuBar) }
        if let openMenu { roots.append(openMenu) }
        // A fresh local winner should reach validation/publication immediately.
        // The rotating frontier is retained and resumes whenever local discovery
        // needs help; cached/stale union entries cannot suppress that discovery.
        let freshLocalCandidates = out.map {
            DecisionCore.Candidate(key: $0.key, rect: $0.rect, inset: $0.inset,
                                   tier: $0.tier, role: $0.role, label: $0.label)
        }
        let needsDiscovery = DecisionCore.needsGlobalDiscovery(point: pointer,
            freshCandidates: freshLocalCandidates, tolerance: selectionTolerance,
            consecutiveLocalSkips: consecutiveLocalRotationSkips)
        let rotationSkipped = !rotationAllowed || !needsDiscovery
            || budget <= 0 || CACurrentMediaTime() >= rotationDeadline
        if !needsDiscovery && rotationAllowed {
            consecutiveLocalRotationSkips += 1
        } else if !rotationSkipped {
            consecutiveLocalRotationSkips = 0
        }
        let sliceId = rotationSkipped ? -1
            : walkSlice(roots: roots, out: &out, budget: &budget, deadline: rotationDeadline,
                        screenUnion: screenUnion, appElement: appEl, pid: pid)

        // Budget/deadline exhaustion publishes the PARTIAL set (still valid); only
        // AX API failure means "unavailable". Report WHY: a deadline cut used to be
        // logged as partial=0 because only the node budget was checked.
        let budgetHit = budget <= 0
        let deadlineHit = truncatedByDeadline || CACurrentMediaTime() >= rotationDeadline
        let trunc: String
        if budgetHit && deadlineHit { trunc = "both" }
        else if budgetHit { trunc = "budget" }
        else if deadlineHit { trunc = "deadline" }
        else { trunc = "none" }
        let partial = trunc != "none"

        // Monotonic union: a truncated walk must never drop a target that was
        // present before. Merge the new walk with the previously published set,
        // refreshing last-seen for anything seen now and expiring only targets
        // stale beyond the freshness window.
        let now = CACurrentMediaTime()
        let priorByKey: [String: CachedTarget] =
            Dictionary(unionTargets.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
        var order: [String] = []
        var byKey: [String: CachedTarget] = [:]
        for t in out where byKey[t.key] == nil {
            // A walk that did not re-validate this target carries its LAST
            // evidence (and collection timestamp) forward; only the geometry is
            // new. Evidence age is therefore never renewed by publication.
            var merged = t
            if let prior = priorByKey[t.key], prior.collectedAt > 0 {
                merged.verdict = prior.verdict
                merged.chromeEligible = prior.chromeEligible
                merged.evidenceGeneration = prior.evidenceGeneration
                merged.collectedAt = prior.collectedAt
            }
            byKey[t.key] = merged
            order.append(t.key)
            lastSeen[t.key] = now
            coverageKeys.insert(t.key)
        }
        let newCount = order.count
        var droppedExpired = 0
        for previous in unionTargets where byKey[previous.key] == nil {
            // Sticky-under-pointer: while the pointer hovers a target, that target
            // must not expire out of the union. Deep player controls are visited
            // only every few rotation cycles (they are unreachable by the guided
            // descent), so a 10 s expiry made a hovered seek bar blink in and out.
            // Legitimacy validation still re-checks the renderer before any ring
            // or redirect, so a stale rect cannot become a wrong action.
            let heldByPointer = Self.boundaryDistance(pointer, previous.rect) <= Self.pointerHoldRadius
            if heldByPointer {
                let element = elementRefs[previous.key]
                let liveFrame = element.flatMap { frame($0) }
                if FrameContinuity.needsGeometryRefresh(cached: previous.rect, live: liveFrame) {
                    // Chromium reuses elements while a new video/window layout
                    // moves their frame. Replace the old key/rect BEFORE choosing
                    // evidence, rather than validating the obsolete winner forever.
                    lastSeen.removeValue(forKey: previous.key)
                    droppedExpired += 1
                    var refreshed: [CachedTarget] = []
                    if let element { collect(element, out: &refreshed, screenUnion: screenUnion) }
                    for target in refreshed where byKey[target.key] == nil {
                        byKey[target.key] = target
                        order.append(target.key)
                        lastSeen[target.key] = now
                        coverageKeys.insert(target.key)
                    }
                    log("RESOLVER_GEOMETRY_REFRESH old=\(previous.key) new=\(refreshed.first?.key ?? "removed")")
                    continue
                }
            }
            if let seen = lastSeen[previous.key],
               now - seen <= Self.targetFreshnessWindow || heldByPointer {
                byKey[previous.key] = previous
                order.append(previous.key)
                if heldByPointer { lastSeen[previous.key] = now }
            } else {
                lastSeen.removeValue(forKey: previous.key)
                droppedExpired += 1
            }
        }
        lastSeen = lastSeen.filter { byKey[$0.key] != nil }
        out = order.compactMap { byKey[$0] }
        // Collapse near-identical duplicates (AXImage + its AXGroup wrapper) BEFORE
        // publication, so the ambiguity guard never sees the same control twice.
        // Applies to the merged set; never drops a distinct neighbouring tile.
        let dedupe = dedupeNearIdentical(out)
        out = dedupe.kept
        dedupedCount = dedupe.removed
        // Native sidebar buttons can require AXPress instead of a relocated
        // mouse event. Only inspect buttons inside an already-admitted native
        // selectable row; browser controls keep their existing delivery path.
        let nativeRows = out.filter { $0.role == "AXSelectableRow" }.map(\.rect)
        for idx in out.indices where out[idx].role == "AXButton" {
            let old = out[idx]
            guard let element = elementRefs[old.key] else { continue }
            // Keep only the delivery hint across transient AX failures, bound
            // to the same live element. It is not permission to act: the worker
            // always rechecks the native capability and actual hit after focus.
            let sameNativeElement = priorByKey[old.key]?.role == "AXNativeRowButton"
                && priorElementRefs[old.key].map { CFEqual($0, element) } == true
            guard sameNativeElement || (nativeRows.contains(where: { $0.contains(old.rect) })
                && NativeListActionDelivery.action(for: element, role: old.role) == .press) else { continue }
            out[idx] = CachedTarget(key: old.key, role: "AXNativeRowButton", label: old.label,
                rect: old.rect, inset: old.inset, tier: old.tier, verdict: old.verdict,
                chromeEligible: false, evidenceGeneration: old.evidenceGeneration,
                collectedAt: old.collectedAt)
        }
        unionTargets = out
        // Drop element references for keys that did not survive this cycle's
        // union/dedupe — never leave a delivery aim pointing at a gone element.
        let liveKeys = Set(out.map { $0.key })
        elementRefs = elementRefs.filter { liveKeys.contains($0.key) }

        let near = out.filter { Self.boundaryDistance(pointer, $0.rect) <= 80 }.count
        lastNearPointerCount = near
        let ms = (CACurrentMediaTime() - t0) * 1000
        let visited = Self.nodeBudget - budget
        let gen = nextGeneration()
        var validatedKeys: Set<String> = []
        // Confirm the nearest candidate. A proven mismatch is omitted from
        // this snapshot, then the same shared selection runs again. Unknown AX
        // answers stop the search; they never authorize a farther redirect.
        // Visual containers never ring: see GeometryPolicy.isVisualContainer.
        let controlRects = out.filter { $0.tier == .firstClass }.map(\.rect)
        let beforeContainers = out.count
        out.removeAll { $0.role == "AXPressGroup" && GeometryPolicy.isVisualContainer($0.rect, among: controlRects) }
        for _ in 0..<(beforeContainers - out.count) { record(.containsControls) }
        let evidenceStart = CACurrentMediaTime()
        if let legitimacy {
            for _ in 0..<ClickAssistEvidence.maxEvidenceCandidatesPerCycle {
                let candidates = out.map {
                    DecisionCore.Candidate(key: $0.key, rect: $0.rect, inset: $0.inset,
                                           tier: $0.tier, role: $0.role, label: $0.label)
                }
                guard case .winner(let winner, _) = DecisionCore.resolve(
                    point: pointer, candidates: candidates, tolerance: selectionTolerance),
                    let idx = out.firstIndex(where: { $0.key == winner.candidate.key }),
                    let el = elementRefs[out[idx].key] else { break }
                let siblings = out.filter { $0.tier == .firstClass }.map(\.rect)
                let target = out[idx]
                let probe = DecisionCore.Candidate(key: target.key, rect: target.rect,
                                                   inset: target.inset, tier: target.tier,
                                                   role: target.role, label: target.label)
                let destination = DecisionCore.snapMode(for: probe) == .center
                    ? DecisionCore.centerPoint(into: target.rect)
                    : DecisionCore.clampPoint(pointer, into: target.rect, inset: target.inset)
                out[idx].verdict = legitimacy.validate(
                    pid: pid, generation: gen, key: target.key, candidate: target.rect,
                    candidateRole: target.role, destination: destination,
                    siblings: siblings.filter { $0 != target.rect }, candidateElement: el,
                    diagnostic: { msg in
                        if msg.hasPrefix("VERDICT_REJECT") { self.log("FINAL \(target.key.prefix(24)) \(msg)") }
                        else if gen % 20 == 0 { self.log(msg) }
                    })
                out[idx].chromeEligible = chromeEligible(el, role: target.role)
                out[idx].evidenceGeneration = gen
                out[idx].collectedAt = CACurrentMediaTime()
                validatedKeys.insert(target.key)
                if out[idx].verdict == .mismatch {
                    log("RESOLVER_REJECTED_WINNER key=\(target.key) verdict=mismatch")
                    out.remove(at: idx)
                    continue
                }
                break
            }
        }
        let evidenceMs = (CACurrentMediaTime() - evidenceStart) * 1000
        // Carried evidence stays usable until its COLLECTION age expires (the
        // display/activation windows), not because a later cycle republished.
        for idx in out.indices where out[idx].collectedAt > 0 {
            out[idx].evidenceGeneration = gen
        }
        let partialNoRenew = partial
            ? out.filter { $0.collectedAt > 0 && !validatedKeys.contains($0.key) }.count
            : 0
        // PAYLOAD FILTER: the ring and the click only ever use candidates within
        // the assist radius of the pointer. Publishing the whole page (700-900
        // targets) cost 7-29 ms of JSON encode per cycle, which is ring latency.
        // Keep everything within reach of a plausible click (radius + one screen
        // step of slack) and drop the rest; the union still holds them, so they
        // come back as soon as the pointer is near.
        let publishRadius: CGFloat = 160
        let published = out.filter {
            Self.boundaryDistance(pointer, $0.rect) <= publishRadius
        }
        let snap = CacheSnapshot(generation: gen, targets: published, valid: true, reason: "fresh",
                                 stamp: CACurrentMediaTime(), resolverMs: ms, pointer: pointer,
                                 appName: appName, pid: pid,
                                 pointerGeneration: pointerGeneration,
                                 cycleStartAt: t0, walkMs: pointerWalkMs,
                                 evidenceMs: evidenceMs, evidenceN: validatedKeys.count,
                                 trunc: trunc, pointerWindowFocused: pointerWindowFocused)
        elements.set(elementRefs, pid: pid)
        cache.publish(snap)

        // Per-cycle pointer-window deadline accounting. Sampled to bound volume,
        // but ALWAYS emitted when the walk overshot the 100 ms deadline by >50%.
        if pointerWalkMs > Self.pointerWindowDeadlineMs * 1.5 || gen % 20 == 0 {
            log(ClickAssistTraceFormatter.resolverCycle(
                gen: gen, walkMs: pointerWalkMs,
                deadlineMs: Self.pointerWindowDeadlineMs,
                evidenceN: validatedKeys.count, evidenceMs: evidenceMs))
        }

        let rej = rejCounts.isEmpty ? "-"
            : rejCounts.sorted { $0.key < $1.key }
                .map { "\($0.key):\($0.value)" }.joined(separator: ",")
        log(String(format: "RESOLVER_PUBLISH gen=%llu app=\"%@\" pid=%d wins=%d win_ms=%.1f probe_ms=%.1f targets=%d newTargets=%d nearPointer=%d nodes=%d seed=%d droppedExpired=%d resolver_ms=%.2f partial=%d trunc=%@ slice=%d coverage=%d pwin=%d pwinNodes=%d pwinDepth=%d pwinDepthCapped=%d pwinGuidedBound=%d pwinGuided=%d pwinGuidedSteps=%d pwinGuidedHits=%d pwinFallback=%d pwinFallbackReason=%@ rotationSkipped=%d tileTooSmall=%d tileTooWide=%d deduped=%d partialNoRenew=%d rej=%@ pwinMode=%@ pidSrc=%@ winFocused=%d",
                   gen, appName, pid, cycleWindowBounds.count, cycleWindowMs, cycleProbeMs, out.count, newCount, near, visited,
                   seedHit ? 1 : 0, droppedExpired, ms, partial ? 1 : 0,
                   trunc as NSString, sliceId, coverageKeys.count,
                   pwinTargets, pwinSpent, pwinStats.maxDepth,
                   pwinStats.depthCapped ? 1 : 0, pwinStats.guidedBound,
                   pwinStats.guidedLevel,
                   pwinStats.guidedSteps, pwinStats.guidedHits,
                   pwinStats.guidedFallback ? 1 : 0,
                   (pwinStats.guidedFallbackReason ?? "-") as NSString,
                   rotationSkipped ? 1 : 0,
                   tileTooSmall, tileTooWide, dedupedCount, partialNoRenew, rej as NSString,
                   pwinMode as NSString,
                   pidSrc as NSString, pointerWindowFocused ? 1 : 0))

        // Diagnostics only: why a hovered control never became a candidate. Separate
        // line so RESOLVER_PUBLISH stays byte-compatible for existing parsers.
        if !rejectedNear.isEmpty {
            let items = rejectedNear
                .map { "\($0.role)@\(ScreenSpace.fmt($0.rect.origin)):\(Int($0.rect.width))x\(Int($0.rect.height)):d=\(String(format: "%.1f", $0.dist)):label=\"\($0.label)\"" }
                .joined(separator: " | ")
            log(String(format: "RESOLVER_REJECTED_NEAR gen=%llu pointer=%@ radius=%.0f scanned=%d count=%d items=[%@]",
                       gen, ScreenSpace.fmt(pointer) as NSString, Self.rejectedNearRadius,
                       rejectedScanned, rejectedNear.count, items as NSString))
        }

        let rects = out.map { "\($0.key):\(ScreenSpace.fmt($0.rect.origin)):\(Int($0.rect.width))x\(Int($0.rect.height))" }
        if rects != lastRects {
            lastRects = rects
            for t in out.prefix(12) {
                log("RESOLVER_TARGET key=\(t.key) role=\(t.role) label=\"\(t.label)\" rect=\(t.rect) inset=\(t.inset)")
            }
        }
    }

    private func publishUnreachable(reason: String, t0: CFTimeInterval) {
        let gen = nextGeneration()
        let snap = CacheSnapshot(generation: gen, targets: [], valid: false, reason: reason,
                                 stamp: CACurrentMediaTime(), resolverMs: (CACurrentMediaTime() - t0) * 1000,
                                 pointer: currentPointer(), appName: "-", pid: 0)
        elementRefs.removeAll()
        elements.clear()
        cache.publish(snap)
        log("RESOLVER_UNAVAILABLE gen=\(gen) reason=\(reason) action=pass-through")
    }

    /// Deterministic fail-open state for the harness itself: no AX calls at all.
    private func publishSelfApp(t0: CFTimeInterval) {
        let gen = nextGeneration()
        let snap = CacheSnapshot(generation: gen, targets: [], valid: false, reason: "self-app",
                                 stamp: CACurrentMediaTime(),
                                 resolverMs: (CACurrentMediaTime() - t0) * 1000,
                                 pointer: currentPointer(), appName: "self", pid: getpid())
        elementRefs.removeAll()
        elements.clear()
        cache.publish(snap)
        log("RESOLVER_SELF_APP gen=\(gen) pid=\(getpid()) axQueries=0 action=pass-through")
    }

    // MARK: - AX walk

    /// Consume up to `budget` nodes from the persisted breadth-first frontier,
    /// advancing the head cursor so the next cycle continues deeper/differently.
    /// When the frontier drains, a new pass restarts from the roots.
    private func walkSlice(roots: [AXUIElement], out: inout [CachedTarget], budget: inout Int,
                           deadline: CFTimeInterval, screenUnion: CGRect,
                           appElement: AXUIElement, pid: pid_t) -> Int {
        if frontierHead >= frontier.count {
            frontier.removeAll()
            frontierHead = 0
            sliceIndex = 0
            coverageKeys.removeAll()
            for root in roots { frontier.append((root, 0)) }
        }
        let sliceId = sliceIndex
        sliceIndex += 1

        while frontierHead < frontier.count, budget > 0 {
            guard CACurrentMediaTime() < deadline else {
                truncatedByDeadline = true
                break
            }
            let node = frontier[frontierHead]
            frontierHead += 1
            budget -= 1
            collect(node.element, out: &out, screenUnion: screenUnion)

            // Window move/resize notifications are registered on window elements.
            if let role = stringAttr(node.element, kAXRoleAttribute), role == "AXWindow",
               let observer, pid == observedPid {
                for note in [kAXWindowMovedNotification, kAXWindowResizedNotification] {
                    AXObserverAddNotification(observer, node.element, note as CFString,
                                              Unmanaged.passUnretained(self).toOpaque())
                }
            }

            if node.depth < 12,
               let raw = attr(node.element, kAXChildrenAttribute),
               let kids = axArray(raw) {
                for k in kids where frontier.count < Self.maxFrontierNodes {
                    frontier.append((k, node.depth + 1))
                }
            }
        }

        // Compact consumed prefix occasionally so the array does not grow forever.
        if frontierHead > Self.frontierCompactionThreshold, frontierHead * 2 > frontier.count {
            frontier.removeFirst(frontierHead)
            frontierHead = 0
        }
        return sliceId
    }

    /// Pointer ownership = real click routing. A system-wide AX hit test returns
    /// the element a click would actually reach, which follows the visible/clickable
    /// window rather than CG z-order — click-through capture overlays (Cua Driver,
    /// cua-spacesd, screenshot/recording HUDs) are invisible to it. This is the
    /// ONLY source: CGWindowListCopyWindowInfo answers nil inside this XPC service
    /// (logged 2026-11-02), so there is no window-list fallback.
    private func pointerOwnerPid(_ pointer: CGPoint) -> (pid: pid_t?, source: String) {
        if let hit = systemWideHitPid(pointer), hit > 0, !isExcluded(owner: hit) {
            return (hit, "ax-hit")
        }
        return (nil, "ax-hit-failed")
    }

    /// `AXUIElementCopyElementAtPosition` on the SYSTEM-WIDE element: the same
    /// routing a real click takes. 100 ms messaging timeout keeps the fast path
    /// inside the 250 ms resolver deadline (typically single-digit ms).
    private func systemWideHitPid(_ pointer: CGPoint) -> pid_t? {
        let sysWide = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(sysWide, 0.1)
        var element: AXUIElement?
        guard AXUIElementCopyElementAtPosition(sysWide, Float(pointer.x), Float(pointer.y),
                                               &element) == .success,
              let element else { return nil }
        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success, pid > 0 else { return nil }
        return pid
    }

    /// The AX window of `ownerPid` under the pointer. The live hit's AXWindow is
    /// primary; AX frame containment is the fallback (CGWindowList answers nil
    /// inside this service). Owner-constrained so another app's surface (Dock,
    /// panels) can never be matched to this app's AX window. Used both as the
    /// per-cycle pointer-window priority entry point and for Chromium's unhelpful
    /// hit-testing.
    private func windowUnderPointer(windows: [AXUIElement], pointer: CGPoint,
                                    ownerPid: pid_t) -> (window: AXUIElement?, mode: String) {
        // Overlapping windows from the same browser cannot be distinguished
        // by frame containment. The live hit's AXWindow supplies that identity.
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.05)
        var hit: AXUIElement?
        if AXUIElementCopyElementAtPosition(system, Float(pointer.x), Float(pointer.y), &hit) == .success,
           let hit, let hitFrame = frame(hit),
           let rawWindow = attr(hit, kAXWindowAttribute),
           CFGetTypeID(rawWindow) == AXUIElementGetTypeID() {
            let window = rawWindow as! AXUIElement
            var hitPID: pid_t = 0
            AXUIElementGetPid(hit, &hitPID)
            if let windowFrame = frame(window),
               GeometryPolicy.hitWindowIsCoherent(expectedPID: ownerPid, hitPID: hitPID,
                   hitFrame: hitFrame, windowFrame: windowFrame, pointer: pointer),
               let kids = attr(window, kAXChildrenAttribute).flatMap(axArray), !kids.isEmpty {
                return (window, "hit-window")
            }
        }
        return axWindowContainingPointer(windows, pointer: pointer)
    }

    /// AX-containment fallback for `windowUnderPointer`: the smallest-area AX
    /// window whose frame contains the pointer. Containment is the only guard —
    /// hollow fullscreen strips have negative origins and do not contain it.
    private func axWindowContainingPointer(_ windows: [AXUIElement],
                                           pointer: CGPoint) -> (window: AXUIElement?, mode: String) {
        // LARGEST containing window wins: a background window under the same
        // pixel is smaller than the fullscreen window that actually covers the
        // screen, and picking the smallest (observed) made the ring report a
        // background window's controls instead of the fullscreen video.
        var best: (window: AXUIElement, area: CGFloat)?
        for w in windows {
            guard let f = frame(w), f.contains(pointer) else { continue }
            let area = f.width * f.height
            if best == nil || area > best!.area { best = (w, area) }
        }
        if let best { return (best.window, "ax-contain") }
        return (nil, "none")
    }

    /// Pointer-band BFS: breadth-first over `root`, enqueuing only children whose
    /// rect intersects the pointer's ±radius box. A video player's DOM is huge but
    /// geometrically shallow near the cursor, so the band prunes it to the few
    /// containers that can actually be under or beside the pointer — deep player
    /// controls become reachable within the per-cycle budget, which the guided
    /// descent (which stops at the video element's leaf) never manages.
    private func walkBand(_ root: AXUIElement, pointer: CGPoint, radius: CGFloat,
                          out: inout [CachedTarget], budget: inout Int,
                          deadline: CFTimeInterval, screenUnion: CGRect,
                          appElement: AXUIElement, pid: pid_t, maxDepth: Int,
                          stats: inout WalkStats) {
        let band = CGRect(x: pointer.x - radius, y: pointer.y - radius,
                          width: radius * 2, height: radius * 2)
        var queue: [(AXUIElement, Int)] = [(root, 0)]
        var head = 0
        while head < queue.count, budget > 0, CACurrentMediaTime() < deadline {
            let (el, depth) = queue[head]
            head += 1
            budget -= 1
            stats.maxDepth = max(stats.maxDepth, depth)
            stats.bandNodes += 1
            collect(el, out: &out, screenUnion: screenUnion)
            guard depth < maxDepth else { continue }
            guard let raw = attr(el, kAXChildrenAttribute), let kids = axArray(raw) else { continue }
            for kid in kids {
                guard budget > 0, CACurrentMediaTime() < deadline else { break }
                if let r = frame(kid), r.width > 0, r.height > 0, r.intersects(band) {
                    queue.append((kid, depth + 1))
                }
            }
            if queue.count > 4000 { break }   // hard bound on the frontier
        }
    }

    /// Resolve the element under the pointer and walk its ancestry (child → parent).
    /// This spend is tiny (≤ seedAncestryDepth nodes) and happens before the global
    /// walk, so the hovered control survives any later budget cut.
    private func seedAtPointer(_ appEl: AXUIElement, pointer: CGPoint, out: inout [CachedTarget],
                               budget: inout Int, deadline: CFTimeInterval,
                               screenUnion: CGRect) -> Bool {
        var element: AXUIElement?
        guard AXUIElementCopyElementAtPosition(appEl, Float(pointer.x), Float(pointer.y), &element) == .success,
              var current = element else { return false }
        var found = false
        var depth = 0
        while budget > 0, depth < Self.seedAncestryDepth, CACurrentMediaTime() < deadline {
            budget -= 1
            if collect(current, out: &out, screenUnion: screenUnion) { found = true }
            guard let parentRaw = attr(current, kAXParentAttribute),
                  let parent = axElement(parentRaw) else { break }
            current = parent
            depth += 1
        }
        if CACurrentMediaTime() >= deadline { truncatedByDeadline = true }
        return found
    }

    /// Records one role-filter rejection if it sits within `rejectedNearRadius` of
    /// the pointer. Diagnostics only: never affects `out`, the union, or routing.
    /// Cost ceiling: `rejectedScanCap` frame reads per cycle, `rejectedNearCap`
    /// retained entries; the label read happens only for in-radius elements.
    private func noteRejectedNearPointer(_ el: AXUIElement, role: String) {
        guard rejectedNear.count < Self.rejectedNearCap,
              rejectedScanned < Self.rejectedScanCap else { return }
        rejectedScanned += 1
        guard let rect = frame(el), rect.width > 0, rect.height > 0 else { return }
        let dist = Self.boundaryDistance(cyclePointer, rect)
        guard dist <= Self.rejectedNearRadius else { return }
        let label = stringAttr(el, kAXTitleAttribute)
            ?? stringAttr(el, kAXDescriptionAttribute) ?? "-"
        rejectedNear.append((role: role, label: label, rect: rect, dist: dist))
    }

    /// Merge near-identical candidates: the same control is often exposed twice
    /// (an AXImage and its tile-sized AXGroup wrapper with the same frame). Two
    /// candidates whose IoU exceeds `duplicateIoUThreshold` are treated as one and
    /// the SMALLER area is kept (the more specific element). Distinct neighbours
    /// share at most a border, so their IoU stays far below the threshold.
    ///
    /// Deterministic: candidates are considered smallest-area first, ties broken by
    /// key, so the survivor never depends on walk order. The returned array keeps
    /// the original publication order of the surviving targets.
    private func dedupeNearIdentical(_ targets: [CachedTarget]) -> (kept: [CachedTarget], removed: Int) {
        guard targets.count > 1 else { return (targets, 0) }
        let ordered = targets.indices.sorted { a, b in
            let areaA = targets[a].rect.width * targets[a].rect.height
            let areaB = targets[b].rect.width * targets[b].rect.height
            if areaA != areaB { return areaA < areaB }
            // Equal frame: a genuine control role wins over the wrapper container
            // (Brave exposes a tab as AXRadioButton plus an equal-frame keyless
            // AXGroup; the group used to win the key tie and demote the tab to
            // second class, so tabs/close buttons never ringed as controls).
            let tierA = targets[a].tier == .firstClass ? 0 : 1
            let tierB = targets[b].tier == .firstClass ? 0 : 1
            if tierA != tierB { return tierA < tierB }
            return targets[a].key < targets[b].key
        }
        var keepIndices: [Int] = []
        var dropped = Set<Int>()
        for i in ordered {
            let rect = targets[i].rect
            let duplicate = keepIndices.contains {
                Self.intersectionOverUnion(rect, targets[$0].rect) > Self.duplicateIoUThreshold
            }
            if duplicate { dropped.insert(i) } else { keepIndices.append(i) }
        }
        guard !dropped.isEmpty else { return (targets, 0) }
        let kept = targets.enumerated().filter { !dropped.contains($0.offset) }.map { $0.element }
        return (kept, dropped.count)
    }

    /// IoU of two AX frames (0 when they do not intersect). Used only by dedupe.
    private static func intersectionOverUnion(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let inter = a.intersection(b)
        guard !inter.isNull, inter.width > 0, inter.height > 0 else { return 0 }
        let interArea = inter.width * inter.height
        let unionArea = a.width * a.height + b.width * b.height - interArea
        guard unionArea > 0 else { return 0 }
        return interArea / unionArea
    }

    /// Extract one element as a candidate if its role/geometry qualifies.
    /// ALL admission logic lives in `GeometryPolicy.classify` — this method only
    /// reads the AX inputs, applies the policy, and counts the rejection bucket.
    @discardableResult
    private func collect(_ el: AXUIElement, out: inout [CachedTarget],
                         screenUnion: CGRect) -> Bool {
        guard let role = stringAttr(el, kAXRoleAttribute) else { return false }
        // Role family first, so a role reject is diagnosed even without a frame.
        guard GeometryPolicy.isCandidateRole(role) else {
            record(.role)
            noteRejectedNearPointer(el, role: role)
            return false
        }
        // Action names are an AX API, not an attribute. A title or tile-sized
        // rectangle alone must never turn a structural web element into a target.
        var hasPressAction = false
        if !GeometryPolicy.isActionable(role: role, hasPressAction: false) {
            var actions: CFArray?
            if AXUIElementCopyActionNames(el, &actions) == .success {
                hasPressAction = (actions as? [String])?.contains("AXPress") == true
            }
        }
        var nativeSelectableRow = false
        if GeometryPolicy.rowRoles.contains(role), !hasPressAction {
            var selectionSettable = DarwinBoolean(false)
            let selectedResult = AXUIElementIsAttributeSettable(el, kAXSelectedAttribute as CFString,
                                                               &selectionSettable)
            let rowName = stringAttr(el, kAXDescriptionAttribute) ?? stringAttr(el, kAXTitleAttribute) ?? "-"
            if loggedRowCapabilities.insert("\(lastResolvedPid)|\(rowName)").inserted {
                var rowActions: CFArray?
                _ = AXUIElementCopyActionNames(el, &rowActions)
                log("NATIVE_ROW_CAP name=\(rowName.replacingOccurrences(of: "\n", with: "/")) selectedResult=\(selectedResult.rawValue) settable=\(selectionSettable.boolValue) selected=\(String(describing: attr(el, kAXSelectedAttribute))) subrole=\(stringAttr(el, kAXSubroleAttribute) ?? "-") actions=\(String(describing: rowActions))")
            }
            if selectedResult == .success, selectionSettable.boolValue {
                var node: AXUIElement? = el
                var inList = false
                var inWeb = false
                for _ in 0..<24 {
                    guard let current = node else { break }
                    let ancestorRole = stringAttr(current, kAXRoleAttribute) ?? ""
                    inList = inList || ancestorRole == "AXList" || ancestorRole == "AXOutline"
                    inWeb = inWeb || ancestorRole == "AXWebArea"
                    if inWeb || ancestorRole == "AXWindow" { break }
                    guard let rawParent = attr(current, kAXParentAttribute),
                          CFGetTypeID(rawParent) == AXUIElementGetTypeID() else { break }
                    node = (rawParent as! AXUIElement)
                }
                nativeSelectableRow = GeometryPolicy.isNativeSelectableRow(role: role,
                    selectionSettable: true, inNativeList: inList, inWebContent: inWeb)
            }
        }
        guard GeometryPolicy.isActionable(role: role, hasPressAction: hasPressAction) || nativeSelectableRow,
              (attr(el, kAXEnabledAttribute) as? Bool) != false else { return false }
        // Secure text fields are never redirect candidates: a near miss must
        // pass through instead of being clamped into a password control.
        let subrole = stringAttr(el, kAXSubroleAttribute)
        if subrole == (kAXSecureTextFieldSubrole as String) {
            let title = stringAttr(el, kAXTitleAttribute)
                ?? stringAttr(el, kAXDescriptionAttribute) ?? "-"
            if !loggedSecure.contains(title) {
                loggedSecure.insert(title)
                let r = frame(el).map { "\($0)" } ?? "nil"
                log("RESOLVER_SKIP_SECURE label=\"\(title)\" subrole=AXSecureTextField rect=\(r) reason=never-redirect")
            }
            record(.secure)
            return false
        }
        guard let rect = frame(el) else { return false }
        let verdict = GeometryPolicy.classify(role: role, hasPressAction: hasPressAction,
                                              rect: rect,
                                              displayBounds: cycleDisplayBounds,
                                              windowBounds: cycleWindowBounds)
        if let rejection = verdict.rejection {
            record(rejection)
            // The two silent buckets stay silent (today: no note, no counter).
            if rejection != .nonFinite, rejection != .degenerate {
                noteRejectedNearPointer(el, role: role)
            }
            return false
        }
        guard let cls = verdict.candidateClass, rect.intersects(screenUnion) else { return false }
        // Every admitted press group is probed: targets persist across
        // cycles, so a box admitted unprobed would keep its ring (seen live).
        if cls == .pressGroup, containsControl(el, key: "\(Int(rect.minX)),\(Int(rect.minY)),\(Int(rect.width))x\(Int(rect.height))") {
            record(.containsControls)
            noteRejectedNearPointer(el, role: role)
            return false
        }
        // A press group is published as a group, not as a container role.
        let admittedRole = nativeSelectableRow ? "AXSelectableRow"
            : (hasPressAction && !GeometryPolicy.isActionable(role: role, hasPressAction: false)
                ? "AXPressGroup" : role)
        let ident = stringAttr(el, kAXIdentifierAttribute)
        let title = stringAttr(el, kAXTitleAttribute)
        // IDENTITY: a label alone is not an identity. "Close" names every tab
        // ✕ in every window, so a label-keyed union silently keeps ONE of them —
        // observed live: the snapshot carried only a Close 162 pt away in another
        // window and the hovered ✕ never reached the ring. Without an explicit
        // AXIdentifier the key always carries the frame origin, making every
        // element distinct while staying stable across cycles of the same element.
        let key: String
        if let ident, !ident.isEmpty {
            key = ident
        } else {
            key = "\(title ?? admittedRole)@\(Int(rect.minX)),\(Int(rect.minY))"
        }
        let label = title ?? stringAttr(el, kAXDescriptionAttribute) ?? role
        // Tier comes from the policy class: control roles and capability-admitted
        // press groups are first-class; envelope-only admissions are second-class.
        out.append(CachedTarget(key: key, role: admittedRole, label: label, rect: rect,
                                inset: 2, tier: GeometryPolicy.tier(for: cls)))
        // Delivery side table: the tap needs the live element reference to decide
        // AXPress vs synthetic. Same-process reference, stored outside the snapshot.
        elementRefs[key] = el
        return true
    }

    /// Depth/budget statistics for one walk invocation (depth-limited diagnostics).
    private struct WalkStats {
        var maxDepth = 0
        var depthCapped = false
        /// Deepest level the pointer-guided descent reached (0 = root only).
        var guidedLevel = 0
        /// Levels examined during the descent (bounded by budget/deadline/depth).
        var guidedSteps = 0
        /// Levels where a containing child was found and the descent advanced.
        var guidedHits = 0
        /// True when the descent stopped without hitting the depth bound (leaf,
        /// no containing child, budget, or deadline) and fell back to a plain walk.
        var guidedFallback = false
        var guidedFallbackReason: String?
        var bandNodes = 0
        /// Descent bound in force this cycle, published so a cap hit is legible
        /// as `pwinDepthCapped=1 pwinGuidedBound=<value>`.
        var guidedBound = 0
    }

    /// POINTER-GUIDED DESCENT + bounded subtree walk for the pointer window.
    ///
    /// A blind depth-first walk on a wide Chromium tree spends the whole 300-node
    /// pointer-window budget on sibling fan-out before it reaches the deep control
    /// (observed on WhatsApp Web: `pwinNodes=300`, `pwinDepthCapped=1`, only 17
    /// targets, while the real control sat under nested `AXGroup` containers).
    /// AX hit-testing (`AXUIElementCopyElementAtPosition`) is unreliable there, so
    /// the pointer itself drives the choice instead:
    ///
    ///  1. From the pointer window's element, descend one level at a time into the
    ///     child whose AX frame CONTAINS the pointer (smallest containing child
    ///     wins), collecting eligible targets along the path, bounded by the guided
    ///     depth bound (`pointerWindowGuidedMaxDepth` = 80: ~1 node per level).
    ///  2. No child contains the pointer (or the node is a leaf / budget or
    ///     deadline is exhausted) -> stop and fall back to today's bounded walk at
    ///     that node; the reason is recorded for the publish log.
    ///  3. From the deepest node reached, walk its children with the remaining
    ///     pointer-window budget, still limited to `subtreeDepth` levels below it.
    ///
    /// Total cost stays inside the caller's node budget and deadline; the global
    /// rotation slice, role filter, decision maths and tolerance are untouched.
    private func walkGuided(_ root: AXUIElement, pointer: CGPoint, out: inout [CachedTarget],
                            budget: inout Int, deadline: CFTimeInterval, screenUnion: CGRect,
                            appElement: AXUIElement, pid: pid_t, maxDepth: Int, subtreeDepth: Int,
                            stats: inout WalkStats) {
        var current = root
        var depth = 0
        // The deepest node whose children were scanned. When the descent dies
        // because NO child contains the pointer (video players: the hovered
        // control lives in a SIBLING branch — the video element is a leaf), the
        // sibling branches are walked here so the controls are reachable without
        // waiting for the rotation slice.
        var lastParentWithKids: AXUIElement?
        var cappedByDepth = false
        stats.guidedBound = maxDepth

        // 1) Guided descent: at each level choose the smallest child containing the pointer.
        while budget > 0 {
            guard CACurrentMediaTime() < deadline else {
                truncatedByDeadline = true
                stats.guidedFallbackReason = "deadline"
                break
            }
            budget -= 1
            stats.guidedSteps += 1
            stats.maxDepth = max(stats.maxDepth, depth)
            collect(current, out: &out, screenUnion: screenUnion)

            // Stop before reading children when the node budget is already spent.
            guard budget > 0 else {
                stats.guidedFallbackReason = "budget"
                break
            }
            guard depth < maxDepth else {
                cappedByDepth = true
                stats.depthCapped = true
                break
            }
            guard let raw = attr(current, kAXChildrenAttribute), let kids = axArray(raw) else {
                stats.guidedFallbackReason = (depth == 0) ? "root-leaf" : "leaf"
                break
            }
            lastParentWithKids = current
            // Smallest containing child: an AXGroup wrapper and its real control can
            // both contain the pointer; the tightest frame is the inner control.
            var best: AXUIElement?
            var bestArea = CGFloat.greatestFiniteMagnitude
            for kid in kids {
                guard let r = frame(kid), r.width > 0, r.height > 0, r.contains(pointer) else { continue }
                let area = r.width * r.height
                if area < bestArea {
                    bestArea = area
                    best = kid
                }
            }
            guard let next = best else {
                stats.guidedFallbackReason = "no-containing-child"
                break
            }
            stats.guidedHits += 1
            current = next
            depth += 1
        }
        if budget <= 0, stats.guidedFallbackReason == nil {
            stats.guidedFallbackReason = "budget"
        }
        stats.guidedLevel = depth
        stats.guidedFallback = !cappedByDepth

        // 2) Sibling-branch rescue: the guided path ended at a level where no
        // child contained the pointer (or at a leaf). Walk the deepest scanned
        // parent's children so a sibling branch (player controls next to the
        // video element) is explored. Budget-bounded; the deadline still rules.
        if stats.guidedFallbackReason == "no-containing-child" || stats.guidedFallbackReason == "leaf",
           let parent = lastParentWithKids, budget > 0, CACurrentMediaTime() < deadline,
           let rawP = attr(parent, kAXChildrenAttribute), let siblings = axArray(rawP) {
            var rescue = min(budget, 160)
            let rescueStart = rescue
            // Only branches near the pointer can hold the hovered control, and a
            // player's controls sit far below the endpoint (x.com: ~58 levels
            // from the window), so near branches may use the absolute bound.
            let near = CGRect(x: pointer.x, y: pointer.y, width: 0, height: 0)
                .insetBy(dx: -Self.pointerRescueNearRadius, dy: -Self.pointerRescueNearRadius)
            // Near branches first, so far-away fan-out cannot spend the budget
            // before the branch holding the hovered control is reached.
            let nearFlags = siblings.map { sibling in frame(sibling).map { $0.intersects(near) } ?? false }
            let order = siblings.indices.sorted { (nearFlags[$0] ? 0 : 1, $0) < (nearFlags[$1] ? 0 : 1, $1) }
            for index in order where rescue > 0 {
                let k = siblings[index]
                let isNear = nearFlags[index]
                walk(k, depth: depth + 1, out: &out, budget: &rescue, deadline: deadline,
                     screenUnion: screenUnion, appElement: appElement, pid: pid,
                     maxDepth: isNear ? maxDepth : depth + subtreeDepth, stats: &stats)
            }
            budget -= min(budget, 160) - rescue
            log("PWIN_RESCUE siblings=\(siblings.count) depth=\(depth) spent=\(rescueStart - rescue) reason=\(stats.guidedFallbackReason ?? "-")")
        }

        // 3) Bounded subtree walk from the deepest node, unchanged width: the same
        // `subtreeDepth` levels of children, now relative to the deeper endpoint.
        guard budget > 0, CACurrentMediaTime() < deadline else { return }
        if let raw = attr(current, kAXChildrenAttribute), let kids = axArray(raw) {
            for k in kids {
                walk(k, depth: depth + 1, out: &out, budget: &budget, deadline: deadline,
                     screenUnion: screenUnion, appElement: appElement, pid: pid,
                     maxDepth: depth + subtreeDepth, stats: &stats)
            }
        }
    }

    /// Pointer hit-test rescue for pages whose guided descent dies mid-tree (x.com
    /// player: no child frame contains the pointer, yet the hit-test lands on the
    /// player's own control strip ~58 levels down). The hit element is already
    /// deep in the right branch: climb a few levels from it and walk that
    /// container's subtree, so the neighbouring controls (seek slider, buttons)
    /// are collected. Returns the nodes spent.
    private func walkHitAncestry(_ appElement: AXUIElement, pointer: CGPoint, out: inout [CachedTarget],
                                 budget: Int, deadline: CFTimeInterval, screenUnion: CGRect,
                                 pid: pid_t, stats: inout WalkStats) -> Int {
        guard budget > 0, CACurrentMediaTime() < deadline else { return 0 }
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(appElement, Float(pointer.x), Float(pointer.y), &hit) == .success,
              var top = hit else { return 0 }
        for _ in 0..<Self.hitAncestryClimb {
            guard let parent = attr(top, kAXParentAttribute),
                  CFGetTypeID(parent) == AXUIElementGetTypeID() else { break }
            top = parent as! AXUIElement
        }
        var remaining = budget
        walk(top, depth: 0, out: &out, budget: &remaining, deadline: deadline,
             screenUnion: screenUnion, appElement: appElement, pid: pid,
             maxDepth: Self.hitAncestryClimb + Self.hitAncestryDescend, stats: &stats)
        return budget - remaining
    }

    /// Depth-first walk used by the pointer-window priority pass. `maxDepth` is a
    /// parameter so the pointer window can be explored deeper than the global
    /// rotation walk (which stays at its own 12-level frontier guard).
    private func walk(_ el: AXUIElement, depth: Int, out: inout [CachedTarget], budget: inout Int,
                      deadline: CFTimeInterval, screenUnion: CGRect, appElement: AXUIElement, pid: pid_t,
                      maxDepth: Int = AccessibilityResolver.walkMaxDepth, stats: inout WalkStats) {
        guard budget > 0 else { return }
        guard depth <= maxDepth else {
            stats.depthCapped = true
            return
        }
        guard CACurrentMediaTime() < deadline else {
            truncatedByDeadline = true
            return
        }
        budget -= 1
        stats.maxDepth = max(stats.maxDepth, depth)

        collect(el, out: &out, screenUnion: screenUnion)

        // Window move/resize notifications are registered on window elements.
        if let role = stringAttr(el, kAXRoleAttribute), role == "AXWindow", let observer, pid == observedPid {
            for note in [kAXWindowMovedNotification, kAXWindowResizedNotification] {
                AXObserverAddNotification(observer, el, note as CFString,
                                          Unmanaged.passUnretained(self).toOpaque())
            }
        }

        if let raw = attr(el, kAXChildrenAttribute), let kids = axArray(raw) {
            for k in kids {
                walk(k, depth: depth + 1, out: &out, budget: &budget, deadline: deadline,
                     screenUnion: screenUnion, appElement: appElement, pid: pid,
                     maxDepth: maxDepth, stats: &stats)
            }
        }
    }

    // MARK: - observers

    private func ensureObserver(pid: pid_t, appElement: AXUIElement) {
        if pid == observedPid, observer != nil { return }
        if let old = observer, observedPid != 0 {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(old), .defaultMode)
        }
        observer = nil
        observedPid = pid

        var obs: AXObserver?
        guard AXObserverCreate(pid, axObserverCallback, &obs) == .success, let obs else {
            log("RESOLVER_OBSERVER_FAILED pid=\(pid) (falling back to timer only)")
            observedPid = 0
            return
        }
        for note in [kAXFocusedWindowChangedNotification, kAXUIElementDestroyedNotification] {
            AXObserverAddNotification(obs, appElement, note as CFString,
                                      Unmanaged.passUnretained(self).toOpaque())
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .defaultMode)
        observer = obs
        log("RESOLVER_OBSERVER_ACTIVE pid=\(pid)")
    }

    fileprivate func handleAXNotification(_ name: String) {
        let short = name
            .replacingOccurrences(of: "AX", with: "")
            .replacingOccurrences(of: "Notification", with: "")
            .lowercased()
        log("RESOLVER_EVENT ax=\(short)")
        // Element churn is soft: keep the published snapshot routable and coalesce
        // a refresh. Focus/window-geometry changes remain hard (fail closed).
        if Self.softNotificationReasons.contains(short) {
            softInvalidate(reason: short)
        } else {
            invalidate(reason: short)
        }
    }

    // MARK: - AX helpers

    private func attr(_ el: AXUIElement, _ name: String) -> CFTypeRef? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, name as CFString, &v) == .success else { return nil }
        return v
    }

    private func stringAttr(_ el: AXUIElement, _ name: String) -> String? {
        guard let raw = attr(el, name), CFGetTypeID(raw) == CFStringGetTypeID() else { return nil }
        return (raw as! CFString) as String
    }

    /// Structural AXPress eligibility, computed on this background queue: role is
    /// AXButton, the control is enabled, and its ancestry reaches the window
    /// through chrome (AXTabGroup / AXToolbar) with no AXWebArea anywhere.
    private func chromeEligible(_ el: AXUIElement, role: String) -> Bool {
        guard role == "AXButton" else { return false }
        AXUIElementSetMessagingTimeout(el, 0.05)
        if let enabled = attr(el, kAXEnabledAttribute) as? Bool, !enabled { return false }
        var node: AXUIElement? = el
        var sawChrome = false
        var depth = 0
        while let current = node, depth < 64 {
            depth += 1
            guard let r = stringAttr(current, kAXRoleAttribute) else { return false }
            if r == "AXWebArea" { return false }
            if r == "AXTabGroup" || r == "AXToolbar" { sawChrome = true }
            if r == "AXWindow" { break }
            guard let parent = attr(current, kAXParentAttribute),
                  CFGetTypeID(parent) == AXUIElementGetTypeID() else { return false }
            node = (parent as! AXUIElement)
        }
        return sawChrome
    }

    private func axArray(_ raw: CFTypeRef) -> [AXUIElement]? {
        guard CFGetTypeID(raw) == CFArrayGetTypeID() else { return nil }
        return (raw as? [AXUIElement])
    }

    private func axElement(_ raw: CFTypeRef) -> AXUIElement? {
        guard CFGetTypeID(raw) == AXUIElementGetTypeID() else { return nil }
        return (raw as! AXUIElement)
    }

    private func frame(_ el: AXUIElement) -> CGRect? {
        AXGeometry.frame(el)   // single validated reader (ClickAssistGeometry.swift)
    }

    /// Union of all displays expressed in AX/CG global coordinates. Keeps stale or
    /// off-screen AX frames (closed menus, unmapped windows) out of the cache and makes
    /// secondary displays with negative or offset origins first-class.
    /// Every display as an AX/CG-space rect (a list, not a union: the geometry
    /// policy needs to know WHICH displays a rect lands on).
    private static func displayBoundsAX() -> [CGRect] {
        NSScreen.screens.map { ScreenSpace.cgRect(fromCocoaScreen: $0.frame) }
    }

    /// Bounded breadth-first look for a clickable control inside `el`.
    private func containsControl(_ el: AXUIElement, key: String) -> Bool {
        let probeStart = CACurrentMediaTime()
        defer { cycleProbeMs += (CACurrentMediaTime() - probeStart) * 1000 }
        if knownContainersPid != lastResolvedPid {
            knownContainers.removeAll()
            loggedProbes.removeAll()
            knownContainersPid = lastResolvedPid
        }
        // Frame keys change with every scroll; keep the diagnostic memo bounded.
        if loggedProbes.count >= GeometryPolicy.containerCacheLimit { loggedProbes.removeAll() }
        if knownContainers.contains(key) { return true }
        let containerFrame = frame(el)
        // One visual box can be several nested same-size AX nodes (YouTube: the
        // press-capable video surface sits inside a same-size player whose
        // controls are the surface's siblings). Probe from the outermost node.
        var root = el
        if let box = containerFrame {
            var steps = 0
            while steps < GeometryPolicy.containerProbeNodeBudget,
                  let raw = attr(root, kAXParentAttribute), CFGetTypeID(raw) == AXUIElementGetTypeID() {
                let parent = raw as! AXUIElement
                guard let parentFrame = frame(parent), FrameContinuity.delta(parentFrame, box) <= 1 else { break }
                root = parent
                steps += 1
            }
        }
        var queue = attr(root, kAXChildrenAttribute).flatMap(axArray) ?? []
        let directChildren = queue.count
        var visited = 0
        var seenRoles: [String] = []
        while !queue.isEmpty, visited < GeometryPolicy.containerProbeNodeBudget {
            let node = queue.removeFirst()
            visited += 1
            guard let role = stringAttr(node, kAXRoleAttribute) else { continue }
            if seenRoles.count < 8 { seenRoles.append(role) }
            var pressable = GeometryPolicy.isActionable(role: role, hasPressAction: false)
            var pressByAction = false
            if !pressable, role == "AXGroup" {
                var actions: CFArray?
                pressByAction = AXUIElementCopyActionNames(node, &actions) == .success
                    && (actions as? [String])?.contains("AXPress") == true
                pressable = pressByAction
            }
            // Frame/state are read only after the cheap role/action test.
            if pressable, isRealControl(node, role: role, pressByAction: pressByAction,
                                        container: containerFrame) {
                return markContainer(key, found: role, how: "walk visited=\(visited) children=\(directChildren)")
            }
            queue.append(contentsOf: attr(node, kAXChildrenAttribute).flatMap(axArray) ?? [])
        }
        // A long subtree (a chat transcript: its message buttons sit ~180 nodes
        // deep) outruns the walk. Chromium answers a visible-controls search in
        // one call (~2 ms live); each result gets the same real-target test.
        if let box = containerFrame {
            let query: [String: Any] = ["AXSearchKey": "AXControlSearchKey",
                                        "AXResultsLimit": GeometryPolicy.containerProbeNodeBudget,
                                        "AXDirection": "AXDirectionNext",
                                        "AXImmediateDescendantsOnly": false,
                                        "AXVisibleOnly": true]
            var raw: CFTypeRef?
            if AXUIElementCopyParameterizedAttributeValue(root, "AXUIElementsForSearchPredicate" as CFString,
                                                          query as CFDictionary, &raw) == .success,
               let found = (raw as? [AXUIElement])?.first(where: { node in
                   guard let role = stringAttr(node, kAXRoleAttribute),
                         GeometryPolicy.isActionable(role: role, hasPressAction: false),
                         let f = frame(node), box.contains(f) else { return false }
                   return isRealControl(node, role: role, pressByAction: false, container: box)
               }) {
                return markContainer(key, found: stringAttr(found, kAXRoleAttribute) ?? "?", how: "search")
            }
        }
        if loggedProbes.insert("\(lastResolvedPid)|\(key)|0").inserted {
            log("CONTAINER_PROBE key=\(key) found=none visited=\(visited) children=\(directChildren) roles=\(seenRoles.joined(separator: ","))")
        }
        return false
    }

    /// A control counts only if it would itself be a ring target: a same-box
    /// nested wrapper, hidden, disabled or off-screen node is not a reason to
    /// reject the card.
    private func isRealControl(_ node: AXUIElement, role: String, pressByAction: Bool,
                               container: CGRect?) -> Bool {
        guard let f = frame(node),
              !(container.map { FrameContinuity.delta($0, f) <= 1 } ?? false),
              GeometryPolicy.classify(role: role, hasPressAction: pressByAction, rect: f,
                                      displayBounds: cycleDisplayBounds,
                                      windowBounds: cycleWindowBounds).accepted else { return false }
        return attr(node, kAXEnabledAttribute) as? Bool != false
            && attr(node, "AXHidden") as? Bool != true
    }

    private func markContainer(_ key: String, found role: String, how: String) -> Bool {
        if knownContainers.count >= GeometryPolicy.containerCacheLimit { knownContainers.removeAll() }
        knownContainers.insert(key)
        if loggedProbes.insert("\(lastResolvedPid)|\(key)|1").inserted {
            log("CONTAINER_PROBE key=\(key) found=\(role) via=\(how)")
        }
        return true
    }

    /// The target app's window frames, read through Accessibility once per
    /// cycle. CGWindowListCopyWindowInfo returned no windows inside this
    /// service (wins=0 observed live: other apps' windows are filtered without
    /// Screen Recording), which silently fell back to whole-display reference.
    private func windowBoundsAX(pid: pid_t) -> [CGRect] {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, GeometryPolicy.legitimacyHitTimeout)
        let windows = attr(app, kAXWindowsAttribute).flatMap(axArray) ?? []
        return windows.compactMap { frame($0) }
    }

    private static func boundaryDistance(_ p: CGPoint, _ r: CGRect) -> CGFloat {
        if r.contains(p) { return 0 }
        let dx = max(r.minX - p.x, 0, p.x - r.maxX)
        let dy = max(r.minY - p.y, 0, p.y - r.maxY)
        return sqrt(dx * dx + dy * dy)
    }

    // MARK: - Service accessors (XPC host)

    /// Latest published snapshot (service-side, blocking is off the tap path).
    func currentSnapshot() -> CacheSnapshot { cache.current() }

    /// The live AX element behind a published target key.
    func element(for key: String, pid: pid_t) -> AXUIElement? {
        elements.element(for: key, pid: pid)
    }
}

/// C callback for AXObserver; hops onto the main run loop (the observer source is
/// scheduled there), then invalidates the snapshot.
private func axObserverCallback(_ observer: AXObserver,
                                _ element: AXUIElement,
                                _ notification: CFString,
                                _ refcon: UnsafeMutableRawPointer?) {
    guard let refcon else { return }
    let me = Unmanaged<AccessibilityResolver>.fromOpaque(refcon).takeUnretainedValue()
    me.handleAXNotification(notification as String)
}
