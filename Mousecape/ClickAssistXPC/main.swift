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
    if let h = try? FileHandle(forWritingTo: svcLogURL) {
        h.seekToEndOfFile()
        h.write(row.data(using: .utf8) ?? Data())
        try? h.close()
    }
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
        let agentPid = (obj["agentPid"] as? NSNumber)?.int32Value ?? 0
        let ids = (obj["overlayWindowIDs"] as? [NSNumber])?.map { $0.intValue } ?? []
        var pids = Set<pid_t>()
        if agentPid > 0 { pids.insert(agentPid) }
        resolver.setExclusions(pids: pids, windowIDs: Set(ids))
        svcLog("CONFIGURED excludedPids=\(pids) overlayWindows=\(ids.count)")
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
        if request.backgroundClick != nil, !backgroundEligible {
            svcLog("BACKGROUND_CLICK_REJECTED reason=invalid-evidence request=\(request.requestID)")
            reply(Self.reply(status: "rejected", reason: "invalid-background-evidence"))
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
            reply(Self.reply(status: "rejected", reason: rejection.rawValue))
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
                reply(Self.reply(status: "rejected", reason: ActivationRejection.expired.rawValue))
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
                reply(Self.reply(status: "rejected", reason: ActivationRejection.unknownTarget.rawValue))
                return
            }
            AXUIElementSetMessagingTimeout(live, 0.05)
            if let click = request.backgroundClick, let target {
                let outcome = self.performBackgroundClick(request, click: click, target: target,
                                                         element: live, snapshot: snapshot)
                svcLog("BACKGROUND_CLICK_RESULT request=\(request.requestID) target=\(request.targetKey) delivered=\(outcome.delivered ? 1 : 0) reason=\(outcome.reason)")
                reply(Self.reply(status: outcome.delivered ? "done" : "rejected", reason: outcome.reason))
                return
            }
            let result = AXUIElementPerformAction(live, "AXPress" as CFString)
            svcLog("AXPRESS_DONE target=\(request.targetKey) request=\(request.requestID) success=\(result == .success ? 1 : 0) code=\(result.rawValue)")
            reply(Self.reply(status: "done", reason: "axpress"))
        }
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
        guard !IsSecureEventInputEnabled(),
              let app = NSRunningApplication(processIdentifier: request.pid),
              let rawWindow = attribute(element, kAXWindowAttribute),
              CFGetTypeID(rawWindow) == AXUIElementGetTypeID(),
              let before = AXGeometry.frame(element),
              BackgroundClickPolicy.matches(click, rect: before) else { return (false, "target-changed") }
        let window = rawWindow as! AXUIElement
        AXUIElementSetMessagingTimeout(window, 0.05)
        // An XPC worker is not the foreground application. Express the user's
        // captured click through Accessibility as well as AppKit activation;
        // an accepted AppKit request alone does not establish keyboard focus.
        let axApp = AXUIElementCreateApplication(request.pid)
        AXUIElementSetMessagingTimeout(axApp, 0.05)
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
        guard let frame = AXGeometry.frame(element), BackgroundClickPolicy.matches(click, rect: frame),
              (attribute(element, kAXEnabledAttribute) as? Bool) != false,
              (attribute(element, "AXHidden") as? Bool) != true else { return (false, "live-target-changed") }
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
