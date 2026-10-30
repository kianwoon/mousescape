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

        stateLock.lock()
        let rejection = ActivationGate.admit(
            request, now: now, currentGeneration: snapshot.generation,
            targetExists: target != nil && expectedElement != nil,
            chromeEligible: target?.chromeEligible == true,
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
            guard currentSnapshot.generation == request.generation else {
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
            let result = AXUIElementPerformAction(live, "AXPress" as CFString)
            svcLog("AXPRESS_DONE target=\(request.targetKey) request=\(request.requestID) success=\(result == .success ? 1 : 0) code=\(result.rawValue)")
            reply(Self.reply(status: "done", reason: "axpress"))
        }
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
