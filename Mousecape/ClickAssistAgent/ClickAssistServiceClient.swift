// baseline-guard:allow new agent-only XPC client (replaces the in-process resolver)
//
//  ClickAssistServiceClient.swift
//  ClickAssistAgent
//
//  XPC-fed CacheStore. The agent NEVER makes AX element calls: it decodes published
//  snapshots, feeds the same CacheStore the tap already reads, and forwards
//  activation requests to the resolver service. The tap callback only ever does
//  the existing trylock read; every call into this object is already off-callback.
//

import Foundation
import QuartzCore

/// Exported object so the service can push snapshots one-way. Lives entirely on
/// the client side; all methods other than `publishSnapshot` are inert here.
private final class ClickAssistClientEndpoint: NSObject, ClickAssistXPCProtocol {
    var onSnapshot: ((Data) -> Void)?

    func publishSnapshot(_ data: Data, reply: @escaping (Bool) -> Void) {
        onSnapshot?(data)
        reply(true)
    }

    func ping(reply: @escaping (String) -> Void) { reply("pong") }
    func serviceInfo(reply: @escaping (Data) -> Void) { reply(Data()) }
    /// Client side of the shared protocol: configuration is a service-side
    /// concern, so the client acknowledges and ignores it.
    func configure(_ json: Data, reply: @escaping (Bool) -> Void) { reply(true) }

    func activate(_ requestData: Data, reply: @escaping (Data) -> Void) {
        reply(Data())
    }
}

final class ClickAssistServiceClient: @unchecked Sendable {
    static let serviceName = "com.sdmj76.ClickAssistResolver"

    let cache: CacheStore
    private let log: (String) -> Void
    private let queue = DispatchQueue(label: "clickassist.xpc.client", qos: .utility)

    private let endpoint = ClickAssistClientEndpoint()
    private var connection: NSXPCConnection?
    private var breaker = ClickAssistCircuitBreaker()
    private var circuitOpen = false
    private var stopped = false
    private var watchdog: DispatchSourceTimer?

    /// Epoch/generation are client-local so stale-epoch and old-generation
    /// payloads can be dropped without trusting the service to self-police.
    private var currentEpoch: String?
    private var currentGeneration: UInt64 = 0
    private var lastNearDiagAt: CFTimeInterval = 0
    private var lastSnapshotAt: CFTimeInterval = 0
    private var evidenceMarkedInvalid = false
    private var silenceHandled = false
    private var repliedRequests: Set<String> = []
    /// Publication-gap measurement: interval between accepted snapshots that
    /// carried usable evidence. Fixed ring, written only on the client queue.
    private let snapGapRing = LatencyRing(capacity: 2048)
    private var lastUsableSnapshotAt: CFTimeInterval = 0
    private var lastSnapGapLogAt: CFTimeInterval = 0

    /// No successful snapshot for this long ⇒ evidence is invalid immediately.
    /// MEASURED, not guessed: the resolver's normal idle gap is p50 318 ms and
    /// p95 943 ms (SNAP_GAP telemetry) because the idle cadence is 700 ms plus a
    /// resolve of up to 252 ms. A 1.0 s limit therefore trips during ORDINARY
    /// idle operation: three unlucky cycles opened the circuit and disabled the
    /// assist until an explicit restart. The limit must sit above the engine's
    /// own rhythm, with headroom for one slow cycle plus transport.
    private static let snapshotSilenceLimit: CFTimeInterval = 2.5

    init(cache: CacheStore, log: @escaping (String) -> Void) {
        self.cache = cache
        self.log = log
        endpoint.onSnapshot = { [weak self] data in
            self?.queue.async { self?.receive(data) }
        }
    }

    // MARK: - lifecycle

    func start() {
        queue.async { [weak self] in
            guard let self, !self.stopped else { return }
            self.startWatchdog()
            self.connect()
        }
    }

    /// Explicit re-enable path: a new client (config toggle cycle / restart)
    /// starts with a fresh breaker and no open circuit.
    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            self.stopped = true
            self.watchdog?.cancel()
            self.watchdog = nil
            self.circuitOpen = false
            self.breaker.reset()
            self.connection?.invalidate()
            self.connection = nil
        }
    }

    private func startWatchdog() {
        guard watchdog == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 0.25, repeating: 0.25, leeway: .milliseconds(100))
        t.setEventHandler { [weak self] in self?.watch() }
        t.resume()
        watchdog = t
    }

    private func connect() {
        guard !stopped, !circuitOpen else { return }
        let conn = NSXPCConnection(serviceName: Self.serviceName)
        let interface = NSXPCInterface(with: ClickAssistXPCProtocol.self)
        conn.remoteObjectInterface = interface
        conn.exportedInterface = interface
        conn.exportedObject = endpoint
        conn.interruptionHandler = { [weak self] in
            self?.queue.async { self?.handleFailure(reason: "interrupted") }
        }
        conn.invalidationHandler = { [weak self] in
            self?.queue.async { self?.handleFailure(reason: "invalidated") }
        }
        conn.resume()
        connection = conn
        currentEpoch = nil
        currentGeneration = 0
        lastSnapshotAt = 0
        lastUsableSnapshotAt = 0
        lastSnapGapLogAt = 0
        evidenceMarkedInvalid = false
        silenceHandled = false
        log("XPC_CONNECTING service=\(Self.serviceName)")
        // XPC services spawn LAZILY on the first message. Without this handshake
        // the connection stays idle, launchd only creates a service stub, and no
        // snapshot is ever published. serviceInfo both spawns the service and
        // returns the epoch this instance will stamp its snapshots with.
        let issued = CACurrentMediaTime()
        guard let proxy = conn.remoteObjectProxy as? ClickAssistXPCProtocol else {
            log("XPC_UNAVAILABLE reason=proxy-unavailable")
            return
        }
        // Tell the service which processes/windows are OURS: the service cannot
        // know the agent's pid, so without this the agent's click-through overlay
        // claims pointer ownership and the real window beneath is never resolved.
        // Window IDs are unnecessary: every overlay window belongs to THIS
        // agent process, and the service excludes the agent pid wholesale. Asking
        // AppKit for window numbers here would touch NSApplication off the main
        // actor (crash: dispatch_assert_queue in Swift 6 isolation checking).
        let overlayIDs: [Int] = []
        let cfg: [String: Any] = ["agentPid": Int(ProcessInfo.processInfo.processIdentifier),
                                  "overlayWindowIDs": overlayIDs]
        if let cfgData = try? JSONSerialization.data(withJSONObject: cfg),
           let cproxy = conn.remoteObjectProxy as? ClickAssistXPCProtocol {
            cproxy.configure(cfgData) { _ in }
            log("XPC_CONFIGURE agentPid=\(ProcessInfo.processInfo.processIdentifier) overlayWindows=\(overlayIDs.count)")
        }
        proxy.serviceInfo { [weak self] data in
            guard let self else { return }
            self.queue.async {
                let latencyUs = (CACurrentMediaTime() - issued) * 1_000_000
                let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
                let version = obj["version"] as? String ?? "-"
                let pid = (obj["pid"] as? NSNumber)?.intValue ?? 0
                let epoch = obj["epoch"] as? String ?? "-"
                // The epoch is adopted from the FIRST SNAPSHOT only. Adopting it
                // from the handshake reply lets a second (stale) service instance
                // slip snapshots in between the reply and the first publish, which
                // alternates epochs and churns generations. One epoch per
                // connection; a new epoch only after invalidation/reconnect.
                _ = epoch
                self.log(String(format: "XPC_SERVICE_INFO version=%@ pid=%d epoch=%@ latency_us=%.0f",
                               version, pid, epoch, latencyUs))
            }
        }
    }

    private func handleFailure(reason: String) {
        guard !stopped else { return }
        // Ignore the invalidation we caused ourselves during stop/reconnect.
        guard let old = connection else { return }
        connection = nil
        old.invalidate()
        currentEpoch = nil
        currentGeneration = 0
        markEvidenceInvalid(reason: "service-\(reason)")
        let action = breaker.recordFailure(now: CACurrentMediaTime())
        switch action {
        case .retry(let delay):
            log("XPC_RECONNECT reason=\(reason) delay_s=\(Int(delay))")
            queue.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, !self.stopped, !self.circuitOpen else { return }
                self.connect()
            }
        case .open:
            circuitOpen = true
            log("CIRCUIT_OPEN failures=\(breaker.failures.count) window_s=\(Int(ClickAssistCircuitBreaker.failureWindow)) action=stop-reconnect")
        }
    }

    private func watch() {
        guard !stopped, lastSnapshotAt > 0 else { return }
        guard CACurrentMediaTime() - lastSnapshotAt > Self.snapshotSilenceLimit else { return }
        markEvidenceInvalid(reason: "service-no-snapshot")
        // A live connection that stops publishing is a failed recovery too.
        // Count it ONCE per silence window, then reconnect on the shared schedule.
        guard !silenceHandled else { return }
        silenceHandled = true
        handleFailure(reason: "no-snapshot")
    }

    /// Fail closed: unowned gestures pass through immediately; ownership already
    /// taken by the tap stays consumed regardless.
    private func markEvidenceInvalid(reason: String) {
        guard !evidenceMarkedInvalid else { return }
        evidenceMarkedInvalid = true
        let snap = CacheSnapshot(generation: currentGeneration, targets: [], valid: false,
                                 reason: reason, stamp: CACurrentMediaTime(), resolverMs: 0,
                                 pointer: .zero, appName: "-", pid: 0,
                                 epoch: currentEpoch ?? "-")
        cache.publish(snap)
        log("EVIDENCE_INVALID reason=\(reason)")
    }

    // MARK: - snapshot receive

    private func receive(_ data: Data) {
        guard !stopped else { return }
        let now = CACurrentMediaTime()
        let result = ClickAssistSnapshotCodec.decode(
            data, expectedEpoch: currentEpoch,
            currentGeneration: currentGeneration == 0 ? nil : currentGeneration,
            now: now)
        switch result {
        case .failure(let reject):
            log("XPC_SNAPSHOT_DROP reason=\(reject.rawValue) bytes=\(data.count) epoch=\(currentEpoch ?? "-")")
        case .success(let decoded):
            if currentEpoch == nil { currentEpoch = decoded.wire.epoch }
            currentGeneration = decoded.wire.generation
            lastSnapshotAt = now
            evidenceMarkedInvalid = false
            silenceHandled = false
            breaker.recordSuccess(now: now)
            // Diagnostics: what the SERVICE actually published nearest the pointer.
            // Answers "is the target in the snapshot at all, and what outranks it"
            // without needing the service's own log sink. Throttled to ~2/s.
            let now2 = CACurrentMediaTime()
            if now2 - lastNearDiagAt > 0.5 {
                lastNearDiagAt = now2
                let ptr = CGPoint(x: decoded.wire.pointerX ?? 0, y: decoded.wire.pointerY ?? 0)
                let near = decoded.wire.targets
                    .map { (key: $0.key, dist: DecisionCore.boundaryDistance(ptr, CGRect(x: $0.rect.x, y: $0.rect.y, width: $0.rect.w, height: $0.rect.h))) }
                    .sorted { $0.dist < $1.dist }
                    .prefix(3)
                    .map { "\($0.key):\(String(format: "%.1f", $0.dist))" }
                    .joined(separator: ",")
                let closeInfo: String = decoded.wire.targets
                    .filter { $0.key == "Close" }
                    .map { "Close@(\(Int($0.rect.x)),\(Int($0.rect.y)))d=\(String(format: "%.1f", DecisionCore.boundaryDistance(ptr, CGRect(x: $0.rect.x, y: $0.rect.y, width: $0.rect.w, height: $0.rect.h))))" }
                    .joined(separator: "|")
                log("SNAP_NEAR app=\(decoded.wire.appName ?? "-") pid=\(decoded.wire.pid) pointer=(\(Int(ptr.x)),\(Int(ptr.y))) targets=\(decoded.wire.targets.count) close=[\(closeInfo.isEmpty ? "absent" : closeInfo)] n3=[\(near)]")
            }
            cache.publish(decoded.wire.cacheSnapshot())
            log(String(format: "XPC_SNAPSHOT_RX targets=%d bytes=%d epoch=%@ age_ms=%.1f",
                       decoded.wire.targets.count, data.count,
                       decoded.wire.epoch as NSString, decoded.ageMs))
            // Usable = at least one target carried an actual verdict.
            let usable = decoded.wire.targets.contains {
                !$0.verdict.isEmpty && $0.verdict != ClickAssistVerdict.unknown.rawValue
            }
            if usable {
                if lastUsableSnapshotAt > 0 {
                    snapGapRing.record((now - lastUsableSnapshotAt) * 1_000_000)
                }
                lastUsableSnapshotAt = now
                if lastSnapGapLogAt == 0 { lastSnapGapLogAt = now }
                if now - lastSnapGapLogAt >= 5 {
                    let g = snapGapRing.snapshotAndReset()
                    if g.count > 0 {
                        log(String(format: "SNAP_GAP samples=%d p50_ms=%.0f p95_ms=%.0f max_ms=%.0f",
                                   g.count, g.p50Us / 1000, g.p95Us / 1000, g.maxUs / 1000))
                    }
                    lastSnapGapLogAt = now
                }
            }
        }
    }

    // MARK: - activation (advisory only; never blocks, never retries)

    /// Called with gesture ownership ALREADY taken. Dispatches to the client queue
    /// and returns immediately; the reply cannot change the gesture.
    func activate(_ request: AXPressRequest) {
        queue.async { [weak self] in
            guard let self else { return }
            let requestID = request.requestID.uuidString
            guard !self.circuitOpen, let connection = self.connection else {
                self.log("AXPRESS_OUTCOME_UNKNOWN request=\(requestID) reason=service-unavailable")
                return
            }
            let wire = ActivationRequestWire(requestID: requestID,
                                             targetKey: request.targetKey,
                                             pid: request.pid,
                                             generation: request.generation,
                                             issuedAt: request.issuedAt,
                                             deadlineMs: request.expiryMs)
            guard let data = try? JSONEncoder().encode(wire) else {
                self.log("AXPRESS_OUTCOME_UNKNOWN request=\(requestID) reason=encode-error")
                return
            }
            let proxy = connection.remoteObjectProxyWithErrorHandler { [weak self] error in
                self?.queue.async {
                    self?.log("AXPRESS_OUTCOME_UNKNOWN request=\(requestID) reason=\(error.localizedDescription)")
                }
            }
            guard let proxy = proxy as? ClickAssistXPCProtocol else {
                self.log("AXPRESS_OUTCOME_UNKNOWN request=\(requestID) reason=proxy-unavailable")
                return
            }
            // Safety net for a dead service that never invokes the reply block.
            self.queue.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                guard let self, !self.repliedRequests.contains(requestID) else { return }
                self.repliedRequests.insert(requestID)
                self.log("AXPRESS_OUTCOME_UNKNOWN request=\(requestID) reason=no-reply")
            }
            proxy.activate(data) { [weak self] replyData in
                self?.queue.async {
                    guard let self else { return }
                    self.repliedRequests.insert(requestID)
                    let obj = (try? JSONSerialization.jsonObject(with: replyData)) as? [String: Any]
                    let status = obj?["status"] as? String ?? "unknown"
                    let reason = obj?["reason"] as? String ?? "-"
                    if status == "done" {
                        self.log("AXPRESS_OUTCOME status=done request=\(requestID) target=\(request.targetKey)")
                    } else {
                        self.log("AXPRESS_OUTCOME status=rejected reason=\(reason) request=\(requestID) target=\(request.targetKey)")
                    }
                    if self.repliedRequests.count > 64 {
                        self.repliedRequests.removeAll(keepingCapacity: true)
                    }
                }
            }
        }
    }
}
