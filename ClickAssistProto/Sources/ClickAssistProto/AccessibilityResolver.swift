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
final class AccessibilityResolver {
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

    func suspendRefresh(_ on: Bool) {
        stateLock.lock(); refreshSuspended = on; stateLock.unlock()
        if on { queue.sync {} } // drain any in-flight refresh so the next publish is ours
        log("RESOLVER_REFRESH suspended=\(on)")
    }

    func setEnabled(_ on: Bool) {
        stateLock.lock(); enabled = on; stateLock.unlock()
        if on {
            log("RESOLVER_ENABLED true")
            queue.async { [weak self] in self?.refresh(lastPointer: .zero) }
        } else {
            queue.sync {}   // drain an in-flight walk so its stale-valid publish lands FIRST
            publishInvalid(reason: "unavailable:resolver-disabled", pointer: .zero)
        }
    }

    /// Real-time invalidation: publish "do not route" immediately, refresh after.
    func invalidate(reason: String, prefixStale: Bool = true) {
        publishInvalid(reason: prefixStale ? "stale:\(reason)" : reason, pointer: currentPointer())
        queue.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.refresh(lastPointer: .zero)
        }
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
        ScreenSpace.cgPoint(fromCocoaScreen: NSEvent.mouseLocation)
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
        var budget = 600
        let deadline = t0 + 0.25
        let screenUnion = Self.screenUnionAX()

        if let raw = attr(appEl, kAXWindowsAttribute), let windows = axArray(raw) {
            for w in windows {
                walk(w, depth: 0, out: &out, budget: &budget, deadline: deadline,
                     screenUnion: screenUnion, appElement: appEl, pid: pid)
            }
        }
        if let raw = attr(appEl, kAXMenuBarAttribute), let bar = axElement(raw) {
            walk(bar, depth: 0, out: &out, budget: &budget, deadline: deadline,
                 screenUnion: screenUnion, appElement: appEl, pid: pid)
        }

        // Budget/deadline exhaustion publishes the PARTIAL set (still valid); only
        // AX API failure means "unavailable".
        let partial = budget <= 0

        let pointer = currentPointer()
        let near = out.filter { Self.boundaryDistance(pointer, $0.rect) <= 80 }.count
        let ms = (CACurrentMediaTime() - t0) * 1000
        let gen = nextGeneration()
        let snap = CacheSnapshot(generation: gen, targets: out, valid: true, reason: "fresh",
                                 stamp: CACurrentMediaTime(), resolverMs: ms, pointer: pointer,
                                 appName: appName, pid: pid)
        cache.publish(snap)

        log(String(format: "RESOLVER_PUBLISH gen=%llu app=\"%@\" pid=%d targets=%d nearPointer=%d resolver_ms=%.2f partial=%d",
                   gen, appName, pid, out.count, near, ms, partial ? 1 : 0))

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

    // MARK: - AX walk

    private func walk(_ el: AXUIElement, depth: Int, out: inout [CachedTarget], budget: inout Int,
                      deadline: CFTimeInterval, screenUnion: CGRect, appElement: AXUIElement, pid: pid_t) {
        guard budget > 0, depth <= 12, CACurrentMediaTime() < deadline else { return }
        budget -= 1

        if let role = stringAttr(el, kAXRoleAttribute), Self.eligibleRoles.contains(role) {
            // Secure text fields are never redirect candidates: a near miss must
            // pass through instead of being clamped into a password control.
            let subrole = stringAttr(el, kAXSubroleAttribute)
            let secure = subrole == (kAXSecureTextFieldSubrole as String)
            if secure {
                let title = stringAttr(el, kAXTitleAttribute)
                    ?? stringAttr(el, kAXDescriptionAttribute) ?? "-"
                if !loggedSecure.contains(title) {
                    loggedSecure.insert(title)
                    let r = frame(el).map { "\($0)" } ?? "nil"
                    log("RESOLVER_SKIP_SECURE label=\"\(title)\" subrole=AXSecureTextField rect=\(r) reason=never-redirect")
                }
            } else if let rect = frame(el), rect.width >= 4, rect.height >= 4,
               rect.width < 4000, rect.height < 2000, rect.intersects(screenUnion) {
                let ident = stringAttr(el, kAXIdentifierAttribute)
                let title = stringAttr(el, kAXTitleAttribute)
                let key = ident ?? title ?? "\(role)@\(Int(rect.minX)),\(Int(rect.minY))"
                let label = title ?? stringAttr(el, kAXDescriptionAttribute) ?? role
                out.append(CachedTarget(key: key, role: role, label: label, rect: rect, inset: 2))
            }
        }

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
