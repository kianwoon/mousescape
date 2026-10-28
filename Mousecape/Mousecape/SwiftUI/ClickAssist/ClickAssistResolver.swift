// baseline-guard:allow new standalone prototype file, no prior baseline possible
import AppKit
import ApplicationServices
import CoreGraphics

/// Accessibility-driven candidate resolver. Runs entirely OFF the tap callback:
/// a serial background queue walks the frontmost app's AX tree, converts frames (AX
/// global space == CGEvent global space, top-left origin), and publishes an immutable
/// snapshot into CacheStore. The tap only ever reads that snapshot.
///
/// Refresh triggers (throttled):
///  * periodic 150 ms tick (timer, leeway 40 ms)
///  * AX notifications: window moved / resized / destroyed / focused window changed
///  * app activation / deactivation (NSWorkspace, NSApplication)
/// Any of those publishes an INVALID snapshot first (fail-open) and then refreshes.
final class AccessibilityResolver: @unchecked Sendable {
    /// Roles that accept a click as a meaningful action.
    private static let eligibleRoles: Set<String> = [
        "AXButton", "AXLink", "AXCheckBox", "AXMenuItem", "AXPopUpButton",
        "AXRadioButton", "AXMenuBarItem",
        // P3 gesture-surface controls
        "AXSlider", "AXScrollBar", "AXTextField", "AXTextArea"
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
    /// Bounded spend for the pointer-window fallback probe (Chromium hit-testing).
    /// Kept separate from the main budget so rotation always gets ≥ 480 nodes.
    private static let seedWindowProbeBudget = 120
    /// A published target survives this long without being re-seen. Large Chromium
    /// trees need several slices to complete one pass, so this must exceed a pass
    /// (typically <2 s at 600 nodes/150 ms). Trade-off: a control that truly
    /// disappeared can linger in the union for up to this window before expiring.
    private static let targetFreshnessWindow: CFTimeInterval = 10.0
    private static let nodeBudget = 600
    private static let seedAncestryDepth = 8

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
        let pid = front.processIdentifier
        let appName = front.localizedName ?? front.bundleIdentifier ?? "pid:\(pid)"

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
        if lastResolvedPid != 0, pid != lastResolvedPid {
            log("RESOLVER_EVENT app-switch-polled prev=\(lastResolvedPid) new=\(pid)")
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
        let pointer = currentPointer()

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

        // Seed fallback: Chromium web content often refuses AX hit-testing. Ask the
        // window server which window is under the pointer and spend a small bounded
        // probe on that window's subtree so its controls are prioritised.
        let seedWindow: AXUIElement? = seedHit ? nil
            : windowUnderPointer(windows: windows, pointer: pointer)
        var probeSpent = 0
        if let seedWindow {
            var probeBudget = Self.seedWindowProbeBudget
            walk(seedWindow, depth: 0, out: &out, budget: &probeBudget, deadline: deadline,
                 screenUnion: screenUnion, appElement: appEl, pid: pid)
            probeSpent = Self.seedWindowProbeBudget - probeBudget
        }

        // Rotating BFS slice: resumes the persisted frontier so each cycle visits a
        // different part of the tree instead of re-walking the same 600-node prefix.
        var roots = windows
        if let seedWindow, let idx = roots.firstIndex(where: { CFEqual($0, seedWindow) }) {
            roots.remove(at: idx)
            roots.insert(seedWindow, at: 0)
        }
        if let menuBar { roots.append(menuBar) }
        let sliceId = walkSlice(roots: roots, out: &out, budget: &budget, deadline: deadline,
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
        let visited = (Self.nodeBudget - budget) + probeSpent
        let gen = nextGeneration()
        let snap = CacheSnapshot(generation: gen, targets: out, valid: true, reason: "fresh",
                                 stamp: CACurrentMediaTime(), resolverMs: ms, pointer: pointer,
                                 appName: appName, pid: pid)
        cache.publish(snap)

        log(String(format: "RESOLVER_PUBLISH gen=%llu app=\"%@\" pid=%d targets=%d newTargets=%d nearPointer=%d nodes=%d seed=%d droppedExpired=%d resolver_ms=%.2f partial=%d trunc=%@ slice=%d coverage=%d",
                   gen, appName, pid, out.count, newCount, near, visited,
                   seedHit ? 1 : 0, droppedExpired, ms, partial ? 1 : 0,
                   trunc as NSString, sliceId, coverageKeys.count))

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

    /// Window-server fallback for apps whose web content refuses AX hit-testing:
    /// find the on-screen window under the pointer and map it to its AX window.
    private func windowUnderPointer(windows: [AXUIElement], pointer: CGPoint) -> AXUIElement? {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                    kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }
        for entry in list {
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

    /// Extract one element as a candidate if its role/geometry qualifies.
    @discardableResult
    private func collect(_ el: AXUIElement, out: inout [CachedTarget],
                         screenUnion: CGRect) -> Bool {
        guard let role = stringAttr(el, kAXRoleAttribute), Self.eligibleRoles.contains(role) else {
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

    private func walk(_ el: AXUIElement, depth: Int, out: inout [CachedTarget], budget: inout Int,
                      deadline: CFTimeInterval, screenUnion: CGRect, appElement: AXUIElement, pid: pid_t) {
        guard budget > 0, depth <= 12 else { return }
        guard CACurrentMediaTime() < deadline else {
            truncatedByDeadline = true
            return
        }
        budget -= 1

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
                     screenUnion: screenUnion, appElement: appElement, pid: pid)
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
        invalidate(reason: short)
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
