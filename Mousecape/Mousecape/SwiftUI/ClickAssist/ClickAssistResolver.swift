// baseline-guard:allow new standalone prototype file, no prior baseline possible
import AppKit
import ApplicationServices
import CoreGraphics

/// Accessibility-driven candidate resolver. Runs entirely OFF the tap callback:
/// a serial background queue walks the AX tree of the app owning the window under
/// the POINTER (falling back to the frontmost app), converts frames (AX global
/// space == CGEvent global space, top-left origin), and publishes an immutable
/// snapshot into CacheStore. The tap only ever reads that snapshot.
///
/// Refresh triggers (throttled):
///  * periodic 150 ms tick (timer, leeway 40 ms)
///  * AX notifications: window moved / resized / destroyed / focused window changed
///  * app activation / deactivation (NSWorkspace, NSApplication)
/// Any of those publishes an INVALID snapshot first (fail-open) and then refreshes.
final class AccessibilityResolver: @unchecked Sendable {
    /// Roles that accept a click as a meaningful action. This is the SINGLE
    /// collection-time filter: the router and the overlay both read the published
    /// snapshot, so anything excluded here can never be routed or highlighted.
    /// Deliberately excluded: AXStaticText, AXGroup, AXScrollArea, AXWebArea,
    /// AXImage, AXRow/AXCell/AXOutline and every other container — a click on those
    /// is not a control activation, and highlighting them made the indicator noisy
    /// (observed: a 1296x67 text-line element highlighted in direct-hit mode).
    private static let eligibleRoles: Set<String> = [
        // Buttons / links
        "AXButton", "AXMenuButton", "AXLink",
        // Toggles
        "AXCheckBox", "AXRadioButton",
        // Menus
        "AXMenuItem", "AXMenuBarItem",
        // Selection / tabs
        "AXPopUpButton", "AXComboBox", "AXTab", "AXSegmentedControl",
        // Value controls
        "AXSlider", "AXDisclosureTriangle",
        // Editable text (secure fields are still rejected below)
        "AXTextField", "AXSearchField"
    ]

    private let cache: CacheStore
    private let log: (String) -> Void
    private let queue = DispatchQueue(label: "clickassist.resolver", qos: .utility)

    private let stateLock = NSLock()
    private var refreshSuspended = false
    private var enabled = true

    private var timer: DispatchSourceTimer?
    private var observer: AXObserver?
    private var observedPid: pid_t = 0
    private var generation: UInt64 = 0
    private var lastRects: [String] = []
    private var lastResolvedPid: pid_t = 0
    private var running = false
    private var loggedSecure: Set<String> = []
    /// Per-target last time the AX walk (or pointer seed) actually saw it. Used to
    /// keep a monotonic union across truncated walks.
    private var lastSeen: [String: CFTimeInterval] = [:]
    /// Last VALID published target set. Kept resolver-side so a transient invalid
    /// snapshot cannot erase the union before the next walk re-merges it.
    private var unionTargets: [CachedTarget] = []
    private var unionPid: pid_t = 0
    /// Set when a walk bails out because the 0.25 s deadline passed. Reset per
    /// refresh; drives both `partial` and the published `trunc=` reason.
    private var truncatedByDeadline = false
    /// Persisted breadth-first frontier. The head cursor survives refreshes, so
    /// successive 600-node slices advance into different subtrees instead of
    /// re-walking the same prefix. Bounded and reset on invalidation/app change.
    private var frontier: [(element: AXUIElement, depth: Int)] = []
    private var frontierHead = 0
    private var sliceIndex = 0
    private var coverageKeys: Set<String> = []
    private static let maxFrontierNodes = 20_000
    private static let frontierCompactionThreshold = 1_024
    /// Dedicated per-cycle budget for the pointer-window priority walk. Taken out
    /// of `nodeBudget`, so seed + pwin + rotation never exceed 600 nodes any cycle.
    private static let pointerWindowBudget = 300
    /// Depth bound for the pointer-window walk. Deep nested web/player trees
    /// (YouTube controls sit below several AXGroup/WebArea levels) need more than
    /// the rotation walk's 12-level frontier guard. Still bounded, and the node
    /// budget + deadline dominate: this only widens the shape, not the cost.
    private static let pointerWindowMaxDepth = 24
    /// Default depth bound for the shared `walk` (rotation-style consumers).
    private static let walkMaxDepth = 12
    /// A published target survives this long without being re-seen. Large Chromium
    /// trees need several slices to complete one pass, so this must exceed a pass
    /// (typically <2 s at 600 nodes/150 ms). Trade-off: a control that truly
    /// disappeared can linger in the union for up to this window before expiring.
    private static let targetFreshnessWindow: CFTimeInterval = 10.0
    private static let nodeBudget = 600
    private static let seedAncestryDepth = 8
    /// SOFT-invalidation coalescing window. Multiple AX-churn notifications inside
    /// it collapse into a single walk; routing stays on the previous snapshot until
    /// the tap's `DecisionCore.cacheMaxAge` (1 s) expires.
    private static let softCoalesceInterval: TimeInterval = 0.1
    /// Notification reasons treated as churn (soft). Everything else (focused
    /// window change, window moved/resized, plus all non-AX hard events) stays hard.
    private static let softNotificationReasons: Set<String> = [
        "uielementdestroyed", "layoutchanged", "valuechanged"
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

    init(cache: CacheStore, log: @escaping (String) -> Void) {
        self.cache = cache
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
            self.invalidate(reason: "app-switch")
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.log("RESOLVER_EVENT app-resigned-active")
            self.invalidate(reason: "app-resign-active")
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
        t.schedule(deadline: .now() + 0.05, repeating: 0.15, leeway: .milliseconds(40))
        t.setEventHandler { [weak self] in self?.refresh(lastPointer: .zero) }
        t.resume()
        timer = t
    }

    func stop() {
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

    /// Real-time invalidation: publish "do not route" immediately, refresh after.
    func invalidate(reason: String, prefixStale: Bool = true) {
        publishInvalid(reason: prefixStale ? "stale:\(reason)" : reason, pointer: currentPointer())
        // Rotation state is invalid after any invalidation (window move/destroy,
        // app/space switch): the persisted frontier would point at stale geometry.
        queue.async { [weak self] in self?.resetRotation() }
        queue.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.refresh(lastPointer: .zero)
        }
    }

    /// SOFT invalidation: AX churn (element destroyed / layout changed / value
    /// changed) must NOT publish a non-routable snapshot. The last snapshot keeps
    /// routing until the tap's 1 s max age expires, and at most ONE coalesced
    /// refresh is scheduled per `softCoalesceInterval`. Hard discontinuities
    /// (app/space change, self-app, disable, permission loss) still go through
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
        cache.publish(snap)
        log("RESOLVER_INVALIDATE gen=\(snap.generation) reason=\(reason) action=pass-through-until-refresh")
    }

    // MARK: - resolution

    private func currentPointer() -> CGPoint {
        CGEvent(source: nil)?.location ?? .zero
    }

    private func refresh(lastPointer: CGPoint) {
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

        // TARGET THE WINDOW UNDER THE POINTER, not the frontmost app. The user can
        // hover a visible window of a background app; resolving frontmost-only made
        // that hover produce no targets (observed: app="OpenCode" logged while the
        // pointer sat over a browser window). Chain: window-server owner pid ->
        // frontmost app -> (self pid) non-routable self pass-through below.
        let pointerPid = pointerWindowOwnerPid(pointer)
        let pid: pid_t
        if let pointerPid, pointerPid != getpid() {
            pid = pointerPid
        } else {
            pid = frontPid
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
            log("RESOLVER_EVENT app-switch-polled prev=\(lastResolvedPid) new=\(pid) front=\(frontPid) pointerWindow=\(pointerPid.map { String($0) } ?? "-")")
            invalidate(reason: "app-switch")
        }
        lastResolvedPid = pid

        let appEl = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appEl, 0.2)
        ensureObserver(pid: pid, appElement: appEl)

        var out: [CachedTarget] = []
        var budget = Self.nodeBudget
        let deadline = t0 + 0.25
        truncatedByDeadline = false
        let screenUnion = Self.screenUnionAX()

        // Diagnostics scratch for THIS cycle only (cleared next refresh): elements
        // the role filter rejected that sit near the pointer. Bounded by
        // rejectedScanCap examined nodes and rejectedNearCap retained entries.
        cyclePointer = pointer
        rejectedNear.removeAll()
        rejectedScanned = 0

        // Reset union + rotation when the frontmost app changes: never carry one
        // app's targets, keys or frontier into another app's snapshot.
        if unionPid != pid {
            lastSeen.removeAll()
            unionTargets.removeAll()
            resetRotation()
            unionPid = pid
        }

        let windows: [AXUIElement] = attr(appEl, kAXWindowsAttribute).flatMap(axArray) ?? []
        let menuBar: AXUIElement? = attr(appEl, kAXMenuBarAttribute).flatMap(axElement)

        // Pointer-region seed FIRST: resolve the element under the cursor and walk
        // its immediate ancestry, so the visibly hovered control is captured even
        // when the global walk later exhausts its budget in a huge web-content tree.
        let seedHit = seedAtPointer(appEl, pointer: pointer, out: &out, budget: &budget,
                                    deadline: deadline, screenUnion: screenUnion)

        // POINTER-WINDOW PRIORITY: Chromium web content often refuses AX hit-testing,
        // and the rotating global walk reaches a deep video-controls subtree only
        // every few cycles — so an already-seen control (e.g. the YouTube seek
        // slider) expires before it is seen again. Walk the AX window under the
        // pointer FIRST, every cycle, with its own budget, before any rotation.
        let pwin: AXUIElement? = windowUnderPointer(windows: windows, pointer: pointer, ownerPid: pid)
        let keysBeforePwin = Set(out.map { $0.key })
        var pwinSpent = 0
        var pwinStats = WalkStats()
        if let pwin {
            var pwinBudget = min(Self.pointerWindowBudget, budget)
            walk(pwin, depth: 0, out: &out, budget: &pwinBudget, deadline: deadline,
                 screenUnion: screenUnion, appElement: appEl, pid: pid,
                 maxDepth: Self.pointerWindowMaxDepth, stats: &pwinStats)
            pwinSpent = min(Self.pointerWindowBudget, budget) - pwinBudget
            budget -= pwinSpent   // total work stays inside the shared node budget
        }
        let pwinTargets = Set(out.map { $0.key }).subtracting(keysBeforePwin).count

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
        let rotationSkipped = budget <= 0 || CACurrentMediaTime() >= deadline
        let sliceId = rotationSkipped ? -1
            : walkSlice(roots: roots, out: &out, budget: &budget, deadline: deadline,
                        screenUnion: screenUnion, appElement: appEl, pid: pid)

        // Budget/deadline exhaustion publishes the PARTIAL set (still valid); only
        // AX API failure means "unavailable". Report WHY: a deadline cut used to be
        // logged as partial=0 because only the node budget was checked.
        let budgetHit = budget <= 0
        let deadlineHit = truncatedByDeadline || CACurrentMediaTime() >= deadline
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
        var order: [String] = []
        var byKey: [String: CachedTarget] = [:]
        for t in out where byKey[t.key] == nil {
            byKey[t.key] = t
            order.append(t.key)
            lastSeen[t.key] = now
            coverageKeys.insert(t.key)
        }
        let newCount = order.count
        var droppedExpired = 0
        for previous in unionTargets where byKey[previous.key] == nil {
            if let seen = lastSeen[previous.key], now - seen <= Self.targetFreshnessWindow {
                byKey[previous.key] = previous
                order.append(previous.key)
            } else {
                lastSeen.removeValue(forKey: previous.key)
                droppedExpired += 1
            }
        }
        lastSeen = lastSeen.filter { byKey[$0.key] != nil }
        out = order.compactMap { byKey[$0] }
        unionTargets = out

        let near = out.filter { Self.boundaryDistance(pointer, $0.rect) <= 80 }.count
        let ms = (CACurrentMediaTime() - t0) * 1000
        let visited = Self.nodeBudget - budget
        let gen = nextGeneration()
        let snap = CacheSnapshot(generation: gen, targets: out, valid: true, reason: "fresh",
                                 stamp: CACurrentMediaTime(), resolverMs: ms, pointer: pointer,
                                 appName: appName, pid: pid)
        cache.publish(snap)

        log(String(format: "RESOLVER_PUBLISH gen=%llu app=\"%@\" pid=%d targets=%d newTargets=%d nearPointer=%d nodes=%d seed=%d droppedExpired=%d resolver_ms=%.2f partial=%d trunc=%@ slice=%d coverage=%d pwin=%d pwinNodes=%d pwinDepth=%d pwinDepthCapped=%d rotationSkipped=%d",
                   gen, appName, pid, out.count, newCount, near, visited,
                   seedHit ? 1 : 0, droppedExpired, ms, partial ? 1 : 0,
                   trunc as NSString, sliceId, coverageKeys.count,
                   pwinTargets, pwinSpent, pwinStats.maxDepth,
                   pwinStats.depthCapped ? 1 : 0, rotationSkipped ? 1 : 0))

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

    /// System surfaces that own full-surface layer-0 windows and therefore used to
    /// win the front-to-back scan (observed: app="Dock" while the pointer was far
    /// from the Dock; app="Mousecape" pid=174 = WindowServer). Matched by identity
    /// (name + bundle id) as well as by activation policy, because pid-based checks
    /// and layer alone cannot distinguish these from a real app window.
    private static let systemOwnerNames: Set<String> = [
        "WindowServer", "Window Server", "Dock", "Control Center",
        "Notification Center", "SystemUIServer", "loginwindow"
    ]
    private static let systemOwnerBundleIDs: Set<String> = [
        "com.apple.WindowServer", "com.apple.dock", "com.apple.controlcenter",
        "com.apple.notificationcenterui", "com.apple.systemuiserver",
        "com.apple.loginwindow"
    ]

    /// Owning pid of the topmost on-screen window containing `pointer` that is a
    /// GENUINE application window, in front-to-back window-server order. Rejected
    /// candidates do not end the scan: the next window down is tried (bounded by
    /// the window list), so a WindowServer/Dock surface cannot mask the app beneath.
    ///
    /// Filter chain per entry, in order:
    ///  1. layer == 0 only — menu bar extras, panels, overlays, the Dock and
    ///     Control Center live above normal windows and are never app surfaces.
    ///  2. non-empty bounds containing the pointer, and alpha > 0 (invisible
    ///     windows must not capture the hover).
    ///  3. our own non-GUI surfaces (non-zero layer) are skipped, so the overlay
    ///     panel that follows the highlight never becomes the hovered window.
    ///  4. the owner must be a regular or accessory NSRunningApplication (not a
    ///     .prohibited system daemon), must not be a known system owner by name or
    ///     bundle id, and must have a reachable AX application element.
    /// Self windows at layer 0 are accepted here and caught by the self-RPC guard
    /// in `refresh`, preserving the existing non-routable pass-through behaviour.
    private func pointerWindowOwnerPid(_ pointer: CGPoint) -> pid_t? {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                    kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }
        let selfPid = getpid()
        for entry in list {
            guard let bounds = entry[kCGWindowBounds as String] as? [String: Any] else { continue }
            var rect = CGRect.zero
            guard CGRectMakeWithDictionaryRepresentation(bounds as CFDictionary, &rect),
                  rect.width > 0, rect.height > 0, rect.contains(pointer) else { continue }
            let layer = (entry[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0
            guard layer == 0 else { continue }
            if let alpha = (entry[kCGWindowAlpha as String] as? NSNumber)?.doubleValue, alpha <= 0 {
                continue
            }
            guard let pidNum = entry[kCGWindowOwnerPID as String] as? NSNumber else { continue }
            let owner = pid_t(truncating: pidNum)
            if owner == selfPid {
                // Our own layer-0 GUI window is a legitimate hover target candidate;
                // anything else of ours at layer 0 is still routed through the
                // self-RPC guard rather than guessed at.
                return owner
            }
            guard acceptableWindowOwner(owner) else { continue }
            return owner
        }
        return nil
    }

    /// Positive identity check for a window owner: a real, AX-reachable app. One
    /// cheap attribute query per candidate (no tree walk), so the bounded fallback
    /// over the window list stays cheap.
    private func acceptableWindowOwner(_ pid: pid_t) -> Bool {
        guard let app = NSRunningApplication(processIdentifier: pid) else { return false }
        switch app.activationPolicy {
        case .regular, .accessory: break
        default: return false   // .prohibited: system daemons, WindowServer, loginwindow
        }
        let name = app.localizedName ?? ""
        let bundle = app.bundleIdentifier ?? ""
        if Self.systemOwnerNames.contains(name) || Self.systemOwnerBundleIDs.contains(bundle) {
            return false
        }
        let appEl = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appEl, 0.2)
        var windows: CFTypeRef?
        return AXUIElementCopyAttributeValue(appEl, kAXWindowsAttribute as CFString, &windows) == .success
    }

    /// The AX window of `ownerPid` that corresponds to the window-server window
    /// under the pointer. Owner-constrained so another app's surface (Dock, panels)
    /// can never be matched to this app's AX window. Used both as the per-cycle
    /// pointer-window priority entry point and for Chromium's unhelpful hit-testing.
    private func windowUnderPointer(windows: [AXUIElement], pointer: CGPoint,
                                    ownerPid: pid_t) -> AXUIElement? {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                    kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }
        for entry in list {
            guard let pidNum = entry[kCGWindowOwnerPID as String] as? NSNumber,
                  pid_t(truncating: pidNum) == ownerPid else { continue }
            let layer = (entry[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0
            guard layer == 0 else { continue }
            guard let bounds = entry[kCGWindowBounds as String] as? [String: Any] else { continue }
            var rect = CGRect.zero
            guard CGRectMakeWithDictionaryRepresentation(bounds as CFDictionary, &rect),
                  rect.contains(pointer) else { continue }
            // AX frames use the same top-left global space as CGWindowBounds.
            if let exact = windows.first(where: { w in
                frame(w).map { $0.equalTo(rect) } ?? false
            }) { return exact }
            if let overlapping = windows.first(where: { w in
                frame(w).map { $0.intersects(rect) } ?? false
            }) { return overlapping }
            return nil
        }
        return nil
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

    /// Extract one element as a candidate if its role/geometry qualifies.
    @discardableResult
    private func collect(_ el: AXUIElement, out: inout [CachedTarget],
                         screenUnion: CGRect) -> Bool {
        guard let role = stringAttr(el, kAXRoleAttribute) else { return false }
        guard Self.eligibleRoles.contains(role) else {
            // Diagnostics only: remember near-pointer elements the role filter drops
            // (e.g. a <div> web button exposed as AXGroup). Bounded and per-cycle.
            noteRejectedNearPointer(el, role: role)
            return false
        }
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
            return false
        }
        guard let rect = frame(el), rect.width >= 4, rect.height >= 4,
              rect.width < 4000, rect.height < 2000, rect.intersects(screenUnion) else {
            return false
        }
        let ident = stringAttr(el, kAXIdentifierAttribute)
        let title = stringAttr(el, kAXTitleAttribute)
        let key = ident ?? title ?? "\(role)@\(Int(rect.minX)),\(Int(rect.minY))"
        let label = title ?? stringAttr(el, kAXDescriptionAttribute) ?? role
        out.append(CachedTarget(key: key, role: role, label: label, rect: rect, inset: 2))
        return true
    }

    /// Depth/budget statistics for one walk invocation (depth-limited diagnostics).
    private struct WalkStats {
        var maxDepth = 0
        var depthCapped = false
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

    private func axArray(_ raw: CFTypeRef) -> [AXUIElement]? {
        guard CFGetTypeID(raw) == CFArrayGetTypeID() else { return nil }
        return (raw as? [AXUIElement])
    }

    private func axElement(_ raw: CFTypeRef) -> AXUIElement? {
        guard CFGetTypeID(raw) == AXUIElementGetTypeID() else { return nil }
        return (raw as! AXUIElement)
    }

    private func frame(_ el: AXUIElement) -> CGRect? {
        guard let pRaw = attr(el, kAXPositionAttribute), CFGetTypeID(pRaw) == AXValueGetTypeID(),
              let sRaw = attr(el, kAXSizeAttribute), CFGetTypeID(sRaw) == AXValueGetTypeID() else { return nil }
        var p = CGPoint.zero
        var s = CGSize.zero
        guard AXValueGetValue(pRaw as! AXValue, .cgPoint, &p),
              AXValueGetValue(sRaw as! AXValue, .cgSize, &s) else { return nil }
        return CGRect(origin: p, size: s)
    }

    /// Union of all displays expressed in AX/CG global coordinates. Keeps stale or
    /// off-screen AX frames (closed menus, unmapped windows) out of the cache and makes
    /// secondary displays with negative or offset origins first-class.
    private static func screenUnionAX() -> CGRect {
        var union = CGRect.zero
        for s in NSScreen.screens {
            union = union.union(ScreenSpace.cgRect(fromCocoaScreen: s.frame))
        }
        return union
    }

    private static func boundaryDistance(_ p: CGPoint, _ r: CGRect) -> CGFloat {
        if r.contains(p) { return 0 }
        let dx = max(r.minX - p.x, 0, p.x - r.maxX)
        let dy = max(r.minY - p.y, 0, p.y - r.maxY)
        return sqrt(dx * dx + dy * dy)
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
