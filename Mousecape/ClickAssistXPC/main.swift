// baseline-guard:allow new standalone XPC service entry point, no prior baseline possible
//
//  main.swift
//  ClickAssistResolver.xpc
//
//  ALL Accessibility work lives here: the resolver walk, the legitimacy policy,
//  the live element side table and AXPress execution. The agent only receives
//  published JSON snapshots and sends activation requests.
//

import AppKit
import Foundation
import ApplicationServices
import Carbon.HIToolbox

/// The service must log where the AGENT logs: the resolver's diagnostics
/// (RESOLVER_PUBLISH / rejections) are the only way to see why a candidate is
/// missing, and os_log from an XPC service is invisible to the agent's file log.
private let svcLogURL = FileManager.default
    .homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Logs/Mousecape/ClickAssistAgent.log")
private let svcLogLock = NSLock()

private func svcLog(_ line: String) {
    NSLog("ClickAssistResolver: %@", line)
    let stamp = ISO8601DateFormatter().string(from: Date())
    let row = "\(stamp) [ClickAssist] \(line)\n"
    svcLogLock.lock()
    defer { svcLogLock.unlock() }
    try? FileManager.default.createDirectory(at: svcLogURL.deletingLastPathComponent(),
                                             withIntermediateDirectories: true)
    // O_APPEND: the Helper appends to this same file from another process.
    // seekToEnd + write is not atomic across processes — each writer
    // overwrote the other's lines (fragments, lost one-shot diagnostics such
    // as SLIDER_THUMB_PROMOTE). O_APPEND makes every write land at the end.
    let fd = open(svcLogURL.path, O_WRONLY | O_APPEND | O_CREAT, S_IRUSR | S_IWUSR | S_IRGRP | S_IROTH)
    guard fd >= 0 else { return }
    defer { close(fd) }
    let bytes = Array(row.utf8)
    _ = bytes.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
}

// MARK: - Per-connection coalescing sender

/// Sends snapshots to one client with latest-wins coalescing: while an encode/send
/// is in flight only the newest pending snapshot is retained.
private final class ClientSender: @unchecked Sendable {
    let connection: NSXPCConnection
    private let lock = NSLock()
    private var inFlight = false
    private var pending: Data?

    init(connection: NSXPCConnection) { self.connection = connection }

    func send(_ data: Data) {
        lock.lock()
        if inFlight {
            pending = data
            lock.unlock()
            return
        }
        inFlight = true
        lock.unlock()
        deliver(data)
    }

    private func deliver(_ data: Data) {
        let proxy = connection.remoteObjectProxyWithErrorHandler { [weak self] error in
            svcLog("XPC_SNAPSHOT_TX_ERROR \(error.localizedDescription)")
            self?.finish()
        }
        guard let proxy = proxy as? ClickAssistXPCProtocol else {
            finish()
            return
        }
        proxy.publishSnapshot(data) { [weak self] _ in
            self?.finish()
        }
    }

    private func finish() {
        lock.lock()
        inFlight = false
        let next = pending
        pending = nil
        lock.unlock()
        if let next { send(next) }
    }
}

// MARK: - Activation reply

private struct ActivationReply: Codable {
    let status: String   // done | rejected
    let reason: String
}

// MARK: - Service

private final class ClickAssistResolverService: NSObject, ClickAssistXPCProtocol, NSXPCListenerDelegate {
    /// Generated once at service start: identifies THIS process instance.
    private let epoch = UUID().uuidString
    private let cache = CacheStore()
    private let legitimacy = LegitimacyPolicy()
    private let workQueue = DispatchQueue(label: "clickassist.xpc.activate", qos: .userInitiated)
    private let stateLock = NSLock()
    private var senders: [ClientSender] = []
    private var gate = ActivationGate.State()
    private var oversizeCount = 0
    private var started = false

    private lazy var resolver: AccessibilityResolver = {
        AccessibilityResolver(cache: cache, legitimacy: legitimacy) { line in svcLog(line) }
    }()

    func start() {
        guard !started else { return }
        started = true
        resolver.start()
        cache.addObserver { [weak self] snapshot in
            self?.publish(snapshot)
        }
        svcLog("SERVICE_START epoch=\(epoch) pid=\(ProcessInfo.processInfo.processIdentifier)")
    }

    func pointerMoved() { resolver.pointerMoved() }

    // MARK: publish

    private func publish(_ snapshot: CacheSnapshot) {
        var wire = SnapshotWire(snapshot: snapshot, epoch: epoch)
        // Encode once to MEASURE, then re-encode with the measurement attached so
        // the client can attribute encode vs transport. JSON encode of a bounded
        // payload is sub-millisecond; this stays off the tap path.
        let encodeStart = CACurrentMediaTime()
        guard let probe = ClickAssistSnapshotCodec.encode(wire) else {
            stateLock.lock()
            oversizeCount += 1
            let n = oversizeCount
            stateLock.unlock()
            svcLog("SNAPSHOT_ENCODE_REJECT reason=oversize count=\(n) generation=\(snapshot.generation)")
            return
        }
        wire.encodeMs = (CACurrentMediaTime() - encodeStart) * 1000
        let data = ClickAssistSnapshotCodec.encode(wire) ?? probe
        // Snapshot the sender list; each sender coalesces independently.
        stateLock.lock()
        let current = senders
        stateLock.unlock()
        for sender in current { sender.send(data) }
    }

    // MARK: XPC surface

    func configure(_ json: Data, reply: @escaping (Bool) -> Void) {
        let obj = (try? JSONSerialization.jsonObject(with: json)) as? [String: Any] ?? [:]
        // Exclusion is by overlay WINDOW only. The agent pid is deliberately NOT
        // excluded: that hid the agent's own menu-bar item from the resolver.
        // The resolver's own process stays excluded structurally (getpid()).
        let ids = (obj["overlayWindowIDs"] as? [NSNumber])?.map { $0.intValue } ?? []
        resolver.setExclusions(windowIDs: Set(ids))
        svcLog("CONFIGURED excludedPids=[] overlayWindows=\(ids.count) ids=\(ids.sorted())")
        reply(true)
    }

    func ping(reply: @escaping (String) -> Void) {
        reply("pong")
    }

    func serviceInfo(reply: @escaping (Data) -> Void) {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1"
        let info: [String: Any] = [
            "version": version,
            "pid": Int(ProcessInfo.processInfo.processIdentifier),
            "epoch": epoch,
        ]
        let data = (try? JSONSerialization.data(withJSONObject: info)) ?? Data()
        reply(data)
    }

    /// Service → client publish; unused on the service side (client implements it).
    func publishSnapshot(_ data: Data, reply: @escaping (Bool) -> Void) {
        reply(true)
    }

    func activate(_ requestData: Data, reply: @escaping (Data) -> Void) {
        guard let request = try? JSONDecoder().decode(ActivationRequestWire.self,
                                                      from: requestData) else {
            reply(Self.reply(status: "rejected", reason: ActivationRejection.malformed.rawValue))
            return
        }
        let snapshot = cache.current()
        let now = CACurrentMediaTime()
        let target = snapshot.targets.first { $0.key == request.targetKey }
        let expectedElement = resolver.element(for: request.targetKey, pid: request.pid)
        let pid = request.pid
        let backgroundEligible: Bool
        if let click = request.backgroundClick, let target {
            backgroundEligible = snapshot.valid && snapshot.pid == pid && target.verdict == .confirmed
                && BackgroundClickPolicy.matches(click, rect: target.rect)
                && ClickAssistEvidence.activationState(evidenceGeneration: target.evidenceGeneration,
                    currentGeneration: snapshot.generation,
                    ageMs: (now - target.collectedAt) * 1000) == .fresh
        } else {
            backgroundEligible = false
        }
        if let click = request.backgroundClick, !backgroundEligible {
            svcLog("BACKGROUND_CLICK_REJECTED reason=invalid-evidence request=\(request.requestID) point=\(click.point) published=\(click.rect) cached=\(String(describing: target?.rect))")
            reply(Self.backgroundFailureReply(request, reason: "invalid-background-evidence"))
            return
        }

        stateLock.lock()
        let rejection = ActivationGate.admit(
            request, now: now, currentGeneration: snapshot.generation,
            targetExists: target != nil && expectedElement != nil,
            chromeEligible: target?.chromeEligible == true,
            backgroundEligible: backgroundEligible,
            state: &gate)
        stateLock.unlock()

        if let rejection {
            svcLog("AXPRESS_REJECTED reason=\(rejection.rawValue) target=\(request.targetKey) request=\(request.requestID) generation=\(request.generation) current=\(snapshot.generation)")
            reply(Self.backgroundFailureReply(request, reason: rejection.rawValue))
            return
        }

        workQueue.async { [weak self] in
            guard let self else { return }
            defer {
                self.stateLock.lock()
                ActivationGate.finish(&self.gate)
                self.stateLock.unlock()
            }
            let execNow = CACurrentMediaTime()
            guard execNow < request.deadline else {
                svcLog("AXPRESS_REJECTED reason=\(ActivationRejection.expired.rawValue) target=\(request.targetKey) request=\(request.requestID)")
                reply(Self.backgroundFailureReply(request, reason: ActivationRejection.expired.rawValue))
                return
            }
            let currentSnapshot = self.cache.current()
            guard request.backgroundClick != nil || currentSnapshot.generation == request.generation else {
                svcLog("AXPRESS_REJECTED reason=\(ActivationRejection.staleGeneration.rawValue) target=\(request.targetKey) request=\(request.requestID)")
                reply(Self.reply(status: "rejected", reason: ActivationRejection.staleGeneration.rawValue))
                return
            }
            guard let live = self.resolver.element(for: request.targetKey, pid: pid),
                  let expectedElement, CFEqual(live, expectedElement) else {
                svcLog("AXPRESS_REJECTED reason=\(ActivationRejection.unknownTarget.rawValue) target=\(request.targetKey) request=\(request.requestID)")
                reply(Self.backgroundFailureReply(request, reason: ActivationRejection.unknownTarget.rawValue))
                return
            }
            AXUIElementSetMessagingTimeout(live, 0.05)
            if let click = request.backgroundClick, let target {
                let outcome = self.performBackgroundClick(request, click: click, target: target,
                                                         element: live, snapshot: snapshot)
                svcLog("BACKGROUND_CLICK_RESULT request=\(request.requestID) target=\(request.targetKey) delivered=\(outcome.delivered ? 1 : 0) reason=\(outcome.reason)")
                reply(outcome.delivered ? Self.reply(status: "done", reason: outcome.reason)
                      : Self.backgroundFailureReply(request, reason: outcome.reason))
                return
            }
            let result = AXUIElementPerformAction(live, "AXPress" as CFString)
            svcLog("AXPRESS_DONE target=\(request.targetKey) request=\(request.requestID) success=\(result == .success ? 1 : 0) code=\(result.rawValue)")
            reply(Self.reply(status: "done", reason: "axpress"))
        }
    }

    /// True when `element` sits inside Chromium/WebKit web content (an
    /// AXWebArea ancestor within `BackgroundClickPolicy.webAXPressAncestorDepth`).
    private func isInWebArea(_ element: AXUIElement,
                             attribute: (AXUIElement, String) -> CFTypeRef?) -> Bool {
        var node: AXUIElement? = element
        var depth = 0
        while let current = node, depth < BackgroundClickPolicy.webAXPressAncestorDepth {
            depth += 1
            if (attribute(current, kAXRoleAttribute) as? String) == "AXWebArea" { return true }
            guard let parent = attribute(current, kAXParentAttribute),
                  CFGetTypeID(parent) == AXUIElementGetTypeID() else { return false }
            node = (parent as! AXUIElement)
        }
        return false
    }

    /// The original physical gesture is consumed before this request exists.
    /// Never retry an AXPress or a posted pair: delivery has exactly one owner.
    private func performBackgroundClick(_ request: ActivationRequestWire, click: BackgroundClickWire,
                                        target: CachedTarget, element: AXUIElement,
                                        snapshot: CacheSnapshot) -> (delivered: Bool, reason: String) {
        func attribute(_ e: AXUIElement, _ name: String) -> CFTypeRef? {
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(e, name as CFString, &value) == .success else { return nil }
            return value
        }
        guard !IsSecureEventInputEnabled() else { return (false, "secure-input") }
        guard let app = NSRunningApplication(processIdentifier: request.pid) else { return (false, "app-gone") }
        guard let rawWindow = attribute(element, kAXWindowAttribute),
              CFGetTypeID(rawWindow) == AXUIElementGetTypeID() else { return (false, "no-window") }
        guard let before = AXGeometry.frame(element) else { return (false, "frame-unreadable") }
        // The published rect may be the visible share of the AX frame (overlap
        // ownership); compare it as a subset, never edge-for-edge.
        let beforeGeometry = BackgroundClickPolicy.liveGeometry(click, live: before)
        guard beforeGeometry == .matches else {
            svcLog("BACKGROUND_CLICK_GEOMETRY request=\(request.requestID) stage=pre-activation check=\(beforeGeometry.rawValue) point=\(click.point) published=\(click.rect) live=\(before)")
            return (false, "geometry-\(beforeGeometry.rawValue)")
        }
        let window = rawWindow as! AXUIElement
        AXUIElementSetMessagingTimeout(window, 0.05)
        // Background Electron/Chromium web button: press it while the app is
        // still in the background, THEN activate. Activating first swallows the
        // press: Chromium returns AXPress success but the page drops the click
        // while it handles the activation (reproduced on Claude desktop's
        // approval-card Submit; pressing first works). Only when the press can
        // be legitimised without activation; otherwise the settle + mouse-pair
        // path below runs unchanged.
        if !app.isActive, BackgroundClickPolicy.webAXPressEnabled(role: target.role),
           isInWebArea(element, attribute: attribute),
           (attribute(element, kAXEnabledAttribute) as? Bool) != false,
           (attribute(element, "AXHidden") as? Bool) != true {
            let verdict = LegitimacyPolicy().validate(pid: request.pid, generation: request.generation,
                key: request.targetKey, candidate: before, candidateRole: target.role,
                destination: click.point,
                siblings: snapshot.targets.filter { $0.tier == .firstClass && $0.key != target.key }.map(\.rect),
                candidateElement: element, diagnostic: { svcLog($0) })
            if verdict == .confirmed, CACurrentMediaTime() < request.deadline, !IsSecureEventInputEnabled() {
                AXUIElementSetMessagingTimeout(element, BackgroundClickPolicy.webAXPressTimeout)
                let pressStart = CACurrentMediaTime()
                let result = AXUIElementPerformAction(element, "AXPress" as CFString)
                svcLog("BACKGROUND_WEB_AXPRESS request=\(request.requestID) role=\(target.role) code=\(result.rawValue) order=press-then-activate elapsedMs=\(Int((CACurrentMediaTime()-request.issuedAt)*1000)) pressMs=\(Int((CACurrentMediaTime()-pressStart)*1000))")
                if result == .success {
                    // Bring the app forward as a real click would; best effort,
                    // the press has already been delivered.
                    let axApp = AXUIElementCreateApplication(request.pid)
                    AXUIElementSetMessagingTimeout(axApp, 0.05)
                    if AXUIElementSetAttributeValue(axApp, kAXFrontmostAttribute as CFString, kCFBooleanTrue) != .success {
                        _ = app.activate(options: [])
                    }
                    _ = AXUIElementPerformAction(window, kAXRaiseAction as CFString)
                    return (true, "web-axpress-before-activation")
                }
            } else {
                svcLog("BACKGROUND_WEB_AXPRESS_SKIPPED request=\(request.requestID) verdict=\(verdict) fallback=settle-mouse-pair")
            }
        }
        // An XPC worker is not the foreground application. Express the user's
        // captured click through Accessibility as well as AppKit activation;
        // an accepted AppKit request alone does not establish keyboard focus.
        let axApp = AXUIElementCreateApplication(request.pid)
        AXUIElementSetMessagingTimeout(axApp, 0.05)
        let wasActive = app.isActive
        let frontResult = AXUIElementSetAttributeValue(axApp, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        guard app.isActive || frontResult == .success || app.activate(options: []) else {
            return (false, "activation-refused")
        }
        // Some native windows reject AXRaise even while already focused.
        // The live focused-window + hit-window checks below are authoritative,
        // not the return value of an attempted focus/raise request.
        let raiseResult = AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        if raiseResult != .success {
            svcLog("BACKGROUND_CLICK_RAISE request=\(request.requestID) code=\(raiseResult.rawValue) awaiting-live-window-proof=1")
        }
        for name in [kAXMainAttribute, kAXFocusedAttribute] {
            var settable = DarwinBoolean(false)
            if AXUIElementIsAttributeSettable(window, name as CFString, &settable) == .success,
               settable.boolValue {
                _ = AXUIElementSetAttributeValue(window, name as CFString, kCFBooleanTrue)
            }
        }
        // Focus changes are asynchronous. This wait is confined to the serial
        // activation worker; the event tap and resolver remain unblocked.
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.05)
        var windowReady = false
        while CACurrentMediaTime() < request.deadline, !IsSecureEventInputEnabled() {
            if (attribute(axApp, kAXFrontmostAttribute) as? Bool) == true {
                var hit: AXUIElement?
                if let focusedWindow = attribute(axApp, kAXFocusedWindowAttribute), CFEqual(focusedWindow, window),
                   AXUIElementCopyElementAtPosition(system, Float(click.x), Float(click.y), &hit) == .success,
                   let hit, let hitWindow = attribute(hit, kAXWindowAttribute), CFEqual(hitWindow, window) {
                    windowReady = true
                    break
                }
            }
            Thread.sleep(forTimeInterval: 0.01)
        }
        guard windowReady, CACurrentMediaTime() < request.deadline, !IsSecureEventInputEnabled(),
              (attribute(axApp, kAXFrontmostAttribute) as? Bool) == true else {
            svcLog("BACKGROUND_CLICK_FOCUS_DIAG request=\(request.requestID) expectedPID=\(request.pid) frontPID=\(NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0) liveFront=\(String(describing: attribute(axApp, kAXFrontmostAttribute))) windowReady=\(windowReady) axFront=\(frontResult.rawValue) elapsedMs=\(Int((CACurrentMediaTime()-request.issuedAt)*1000))")
            return (false, "focus-not-established")
        }
        guard let frame = AXGeometry.frame(element) else { return (false, "live-frame-unreadable") }
        let liveGeometry = BackgroundClickPolicy.liveGeometry(click, live: frame)
        guard liveGeometry == .matches else {
            svcLog("BACKGROUND_CLICK_GEOMETRY request=\(request.requestID) stage=post-activation check=\(liveGeometry.rawValue) point=\(click.point) published=\(click.rect) live=\(frame)")
            return (false, "live-geometry-\(liveGeometry.rawValue)")
        }
        guard (attribute(element, kAXEnabledAttribute) as? Bool) != false,
              (attribute(element, "AXHidden") as? Bool) != true else { return (false, "live-target-disabled-or-hidden") }
        // New policy instance forces a real post-activation hit-test; a cached
        // pre-focus verdict cannot authorize this delivery.
        let verdict = LegitimacyPolicy().validate(pid: request.pid, generation: request.generation,
            key: request.targetKey, candidate: frame, candidateRole: target.role,
            destination: click.point,
            siblings: snapshot.targets.filter { $0.tier == .firstClass && $0.key != target.key }.map(\.rect),
            candidateElement: element, diagnostic: { svcLog($0) })
        guard verdict == .confirmed, CACurrentMediaTime() < request.deadline,
              (attribute(axApp, kAXFrontmostAttribute) as? Bool) == true,
              !IsSecureEventInputEnabled() else { return (false, "post-focus-validation-failed") }
        if GeometryPolicy.usesNativeRowAction(target.role) {
            guard let action = NativeListActionDelivery.action(for: element, role: target.role) else {
                return (false, "native-row-capability-changed")
            }
            let result = NativeListActionDelivery.perform(action, on: element)
            let mode = action == .select ? "native-row-select-once" : "native-row-press-once"
            svcLog("NATIVE_ROW_ACTION request=\(request.requestID) mode=\(mode) code=\(result.rawValue)")
            return (result == .success, result == .success ? mode : "native-row-action-failed-no-retry")
        }
        if target.chromeEligible {
            let result = AXUIElementPerformAction(element, "AXPress" as CFString)
            return (result == .success, result == .success ? "axpress-once" : "axpress-failed-no-retry")
        }
        // Activated by this delivery: give the page time to start accepting input
        // and tell it where the pointer is before the press, otherwise an
        // Electron button logs delivered=1 and never reacts.
        var settleMs = 0
        if !wasActive {
            // The settle must run in full: capping it by the request deadline cut a
            // 500 ms setting to ~340 ms, which the approval card still ignored.
            let settle = BackgroundClickPolicy.settleOverrideSeconds()
                ?? BackgroundClickPolicy.postActivationSettle
            if settle > 0 { Thread.sleep(forTimeInterval: settle) }
            settleMs = Int(settle * 1000)
            if let moveSource = CGEventSource(stateID: .hidSystemState),
               let move = CGEvent(mouseEventSource: moveSource, mouseType: .mouseMoved,
                                  mouseCursorPosition: click.point, mouseButton: .left) {
                move.setIntegerValueField(.eventSourceUserData, value: BackgroundClickPolicy.eventMarker)
                move.flags = []
                move.post(tap: .cghidEventTap)
            }
            svcLog("BACKGROUND_CLICK_SETTLE request=\(request.requestID) settleMs=\(settleMs) activatedHere=1")
        }
        guard let source = CGEventSource(stateID: .hidSystemState),
              let down = CGEvent(mouseEventSource: source, mouseType: .leftMouseDown,
                                 mouseCursorPosition: click.point, mouseButton: .left),
              let up = CGEvent(mouseEventSource: source, mouseType: .leftMouseUp,
                               mouseCursorPosition: click.point, mouseButton: .left) else {
            return (false, "event-allocation-failed")
        }
        for event in [down, up] {
            event.setIntegerValueField(.eventSourceUserData, value: BackgroundClickPolicy.eventMarker)
            event.setIntegerValueField(.mouseEventClickState, value: 1)
            event.flags = []
            // Use WindowServer's normal input path so controls see native
            // mouse-button state/tracking. Direct-to-PID posting bypasses that
            // state and can focus a control without completing its action.
            event.post(tap: .cghidEventTap)
        }
        return (true, "mouse-pair-once")
    }

    /// Rejection reply for any request. A background request's physical click
    /// was consumed by the tap before this request existed: when nothing was
    /// posted or performed for it, deliver that click ONCE through the normal
    /// input path at the original point (what the app would have received had
    /// the tap never taken it) instead of losing it.
    private static func backgroundFailureReply(_ request: ActivationRequestWire, reason: String) -> Data {
        guard let click = request.backgroundClick else { return reply(status: "rejected", reason: reason) }
        guard BackgroundClickPolicy.shouldDeliverOriginalAfterRejection(reason) else {
            svcLog("BACKGROUND_CLICK_FALLBACK request=\(request.requestID) reason=\(reason) mode=none-owned-elsewhere")
            return reply(status: "rejected", reason: reason)
        }
        guard click.x.isFinite, click.y.isFinite,
              let source = CGEventSource(stateID: .hidSystemState),
              let down = CGEvent(mouseEventSource: source, mouseType: .leftMouseDown,
                                 mouseCursorPosition: click.point, mouseButton: .left),
              let up = CGEvent(mouseEventSource: source, mouseType: .leftMouseUp,
                               mouseCursorPosition: click.point, mouseButton: .left) else {
            svcLog("BACKGROUND_CLICK_FALLBACK request=\(request.requestID) reason=\(reason) mode=event-allocation-failed")
            return reply(status: "rejected", reason: reason)
        }
        for event in [down, up] {
            event.setIntegerValueField(.eventSourceUserData, value: BackgroundClickPolicy.eventMarker)
            event.setIntegerValueField(.mouseEventClickState, value: 1)
            event.flags = []
            event.post(tap: .cghidEventTap)
        }
        svcLog("BACKGROUND_CLICK_FALLBACK request=\(request.requestID) reason=\(reason) point=\(click.point) mode=native-pair-once")
        return reply(status: "done", reason: "native-fallback-\(reason)")
    }

    private static func reply(status: String, reason: String) -> Data {
        (try? JSONEncoder().encode(ActivationReply(status: status, reason: reason))) ?? Data()
    }

    // MARK: connections

    func listener(_ listener: NSXPCListener,
                  shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        let interface = NSXPCInterface(with: ClickAssistXPCProtocol.self)
        newConnection.exportedInterface = interface
        newConnection.exportedObject = self
        // The client exports the same protocol so the service can publish.
        newConnection.remoteObjectInterface = interface
        let sender = ClientSender(connection: newConnection)
        newConnection.invalidationHandler = { [weak self] in
            self?.remove(sender)
        }
        newConnection.interruptionHandler = { [weak self] in
            self?.remove(sender)
        }
        newConnection.resume()
        stateLock.lock()
        senders.append(sender)
        stateLock.unlock()
        svcLog("CLIENT_CONNECTED epoch=\(epoch) clients=\(senders.count)")
        start()
        return true
    }

    private func remove(_ sender: ClientSender) {
        stateLock.lock()
        senders.removeAll { $0 === sender }
        let remaining = senders.count
        stateLock.unlock()
        svcLog("CLIENT_DISCONNECTED clients=\(remaining)")
    }
}

private let service = ClickAssistResolverService()
private let listener = NSXPCListener.service()
listener.delegate = service
service.start()
listener.resume()
