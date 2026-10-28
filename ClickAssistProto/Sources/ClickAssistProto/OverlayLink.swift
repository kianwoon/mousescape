// baseline-guard:allow new standalone prototype file, no prior baseline possible
import AppKit
import CoreGraphics
import Darwin

/// P2a moved out of process: the main process owns the tap/resolver and publishes
/// decision snapshots over a Unix-domain socket. A separate helper process renders
/// the overlay and sends its log lines back. Death of the helper cannot touch the
/// tap: the tap only reads CacheStore, and sends are best-effort/non-blocking.
final class OverlayLink {
    private let socketPath: String
    private var serverFD: Int32 = -1
    private var clientFD: Int32 = -1
    private var helper: Process?
    private let log: (String) -> Void
    private var tolerance: CGFloat
    private var dead = false
    private var ready = false
    private var lastFlags: String?
    private var readSource: DispatchSourceRead?
    private var buffer = Data()
    private let sendLock = NSLock()
    private let stateLock = NSLock()
    // DEFECT 2 FIX: the socket setup + helper handshake runs here, never on main.
    private let setupQueue = DispatchQueue(label: "clickassist.overlay.setup", qos: .utility)

    init(tolerance: CGFloat, log: @escaping (String) -> Void) {
        signal(SIGPIPE, SIG_IGN)
        self.tolerance = AssistTap.clampTolerance(tolerance)
        self.log = log
        let path = NSTemporaryDirectory() + "clickassist-overlay-\(getpid()).sock"
        self.socketPath = path
        setupQueue.async { [weak self] in self?.setup() }
    }

    deinit { closeSocket() }

    var pid: pid_t {
        stateLock.lock(); defer { stateLock.unlock() }
        return helper?.processIdentifier ?? 0
    }

    var isAlive: Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return ready && !dead && (helper?.isRunning ?? false)
    }

    /// DEFECT 2: all poll/accept/spawn work lives here on setupQueue.
    private func setup() {
        unlink(socketPath)
        let sfd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard sfd >= 0 else { failSetup("socket-create"); return }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathMax = MemoryLayout.size(ofValue: addr.sun_path)
        guard socketPath.utf8.count < pathMax else { close(sfd); failSetup("socket-path"); return }
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: pathMax) { dst in
                _ = strlcpy(dst, socketPath, pathMax)
            }
        }
        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(sfd, $0, len) }
        }
        guard bound == 0, listen(sfd, 1) == 0 else { close(sfd); failSetup("bind-listen"); return }
        stateLock.lock(); serverFD = sfd; stateLock.unlock()

        let p = Process()
        p.executableURL = Self.executableURL()
        p.arguments = ["--overlay-helper", socketPath]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { close(sfd); failSetup("spawn"); return }
        stateLock.lock()
        helper = p
        let cancelled = dead
        stateLock.unlock()
        if cancelled { Darwin.kill(p.processIdentifier, SIGKILL); close(sfd); return }

        var pfd = pollfd(fd: sfd, events: Int16(POLLIN), revents: 0)
        let readyFD = poll(&pfd, 1, 4000)
        guard readyFD > 0 else {
            Darwin.kill(p.processIdentifier, SIGKILL)
            close(sfd)
            failSetup("handshake-timeout")
            return
        }
        let cfd = accept(sfd, nil, nil)
        guard cfd >= 0 else {
            Darwin.kill(p.processIdentifier, SIGKILL)
            close(sfd)
            failSetup("accept")
            return
        }
        _ = fcntl(cfd, F_SETFL, O_NONBLOCK)

        let src = DispatchSource.makeReadSource(fileDescriptor: cfd,
                                                queue: DispatchQueue(label: "clickassist.overlay.read"))
        src.setEventHandler { [weak self] in self?.readAvailable() }
        src.resume()
        stateLock.lock()
        if dead {
            stateLock.unlock()
            close(cfd)
            Darwin.kill(p.processIdentifier, SIGKILL)
            return
        }
        clientFD = cfd
        readSource = src
        ready = true
        stateLock.unlock()
        log("OVERLAY_HELPER_LAUNCH pid=\(p.processIdentifier) socket=\(socketPath) handshake=background relaunch=none (optional observer; restart ClickAssistProto to respawn)")
    }

    private func failSetup(_ reason: String) {
        stateLock.lock()
        if dead { stateLock.unlock(); return }
        dead = true
        let fd = clientFD
        clientFD = -1
        stateLock.unlock()
        if fd >= 0 { close(fd) }
        log("OVERLAY_HELPER_DEAD reason=setup-\(reason) taps-unaffected=true relaunch=none (restart ClickAssistProto to respawn)")
    }

    func setTolerance(_ v: CGFloat) {
        stateLock.lock()
        tolerance = AssistTap.clampTolerance(v)
        stateLock.unlock()
    }

    /// Same published snapshot the tap reads; serialized on the resolver thread only.
    func observe(_ s: CacheSnapshot) {
        stateLock.lock()
        let isDead = dead
        let fd = clientFD
        let tol = tolerance
        stateLock.unlock()
        guard !isDead, fd >= 0 else { return }

        var obj: [String: Any] = [
            "generation": s.generation,
            "valid": s.valid,
            "reason": s.reason,
            "stamp": s.stamp,
            "tolerance": Double(tol),
            "targets": s.targets.map {
                ["key": $0.key,
                 "rect": [$0.rect.minX, $0.rect.minY, $0.rect.width, $0.rect.height],
                 "inset": $0.inset]
            }
        ]
        obj["appName"] = s.appName
        guard let json = try? JSONSerialization.data(withJSONObject: obj) else { return }
        var data = json
        data.append(0x0A)
        sendLock.lock()
        defer { sendLock.unlock() }
        let n = data.withUnsafeBytes {
            send(fd, $0.baseAddress, $0.count, Int32(MSG_DONTWAIT))
        }
        if n < 0, errno != EAGAIN, errno != EWOULDBLOCK {
            markDead(reason: "send-failed-errno-\(errno)")
        }
    }

    func nonInteractiveFlags() -> String? {
        stateLock.lock(); defer { stateLock.unlock() }
        return lastFlags
    }

    /// Graceful teardown (used by the old P2G case).
    func kill() { terminate(signal: SIGTERM, label: "SIGTERM") }

    /// Gate 7: hard crash of the overlay helper, exactly `kill -9`.
    func sigkill() { terminate(signal: SIGKILL, label: "SIGKILL") }

    func shutdown() {
        stateLock.lock()
        let alreadyDead = dead
        stateLock.unlock()
        if !alreadyDead { terminate(signal: SIGTERM, label: "SIGTERM-shutdown") }
    }

    private func terminate(signal sig: Int32, label: String) {
        stateLock.lock()
        if dead { stateLock.unlock(); return }
        dead = true
        let p = helper
        let pid = p?.processIdentifier ?? 0
        let fd = clientFD
        clientFD = -1
        stateLock.unlock()

        readSource?.cancel()
        readSource = nil
        if fd >= 0 { close(fd) }
        if pid > 0 { Darwin.kill(pid, sig) }
        log("OVERLAY_DEAD action=observer-dead signal=\(label) pid=\(pid) taps-unaffected=true relaunch=none")
        if let p {
            DispatchQueue.global(qos: .utility).async {
                p.waitUntilExit()
                let reason = p.terminationReason == .uncaughtSignal ? "uncaught-signal" : "exit"
                let status = p.terminationStatus
                DispatchQueue.main.async { [weak self] in
                    self?.log("OVERLAY_HELPER_REAPED pid=\(pid) reason=\(reason) status=\(status) relaunch=none (restart ClickAssistProto to respawn)")
                }
            }
        }
    }

    private func closeSocket() {
        stateLock.lock()
        let fd = clientFD
        clientFD = -1
        stateLock.unlock()
        if fd >= 0 { close(fd) }
        if serverFD >= 0 { close(serverFD); serverFD = -1 }
        unlink(socketPath)
    }

    private func markDead(reason: String) {
        stateLock.lock()
        if dead { stateLock.unlock(); return }
        dead = true
        let pid = helper?.processIdentifier ?? 0
        let fd = clientFD
        clientFD = -1
        stateLock.unlock()
        readSource?.cancel()
        readSource = nil
        if fd >= 0 { close(fd) }
        DispatchQueue.main.async { [weak self] in
            self?.log("OVERLAY_HELPER_DEAD pid=\(pid) reason=\(reason) taps-unaffected=true relaunch=none (restart ClickAssistProto to respawn)")
        }
    }

    private func readAvailable() {
        stateLock.lock()
        let fd = clientFD
        stateLock.unlock()
        guard fd >= 0 else { return }
        var buf = [UInt8](repeating: 0, count: 8192)
        let n = recv(fd, &buf, buf.count, 0)
        if n > 0 {
            buffer.append(buf, count: n)
            while let nl = buffer.firstIndex(of: 0x0A) {
                let lineData = buffer[..<nl]
                buffer.removeSubrange(...nl)
                guard let line = String(data: lineData, encoding: .utf8), !line.isEmpty else { continue }
                if line.hasPrefix("OVERLAY_FLAGS ") {
                    stateLock.lock()
                    lastFlags = String(line.dropFirst("OVERLAY_FLAGS ".count))
                    stateLock.unlock()
                }
                DispatchQueue.main.async { [weak self] in self?.log(line) }
            }
        } else if n == 0 {
            markDead(reason: "socket-eof")
        } else if errno != EAGAIN, errno != EWOULDBLOCK {
            markDead(reason: "socket-error-errno-\(errno)")
        }
    }

    private static func executableURL() -> URL {
        let arg = CommandLine.arguments[0]
        if arg.hasPrefix("/") { return URL(fileURLWithPath: arg) }
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(arg)
    }
}

// MARK: - helper process

private var helperDelegate: OverlayHelperDelegate?

func runOverlayHelper(socketPath: String) -> Never {
    signal(SIGPIPE, SIG_IGN)
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let d = OverlayHelperDelegate(socketPath: socketPath)
    helperDelegate = d
    app.delegate = d
    app.run()
    exit(0)
}

final class OverlayHelperDelegate: NSObject, NSApplicationDelegate {
    private let socketPath: String
    private var fd: Int32 = -1
    private var source: DispatchSourceRead?
    private var buffer = Data()
    private var overlay: HelperOverlay?

    init(socketPath: String) {
        self.socketPath = socketPath
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        fd = connectWithRetry(socketPath)
        guard fd >= 0 else { exit(2) }
        _ = fcntl(fd, F_SETFL, O_NONBLOCK)
        overlay = HelperOverlay { [weak self] line in self?.sendLine(line) }
        let src = DispatchSource.makeReadSource(fileDescriptor: fd,
                                                queue: DispatchQueue(label: "clickassist.overlay.helper.read"))
        src.setEventHandler { [weak self] in self?.read() }
        src.resume()
        source = src
    }

    private func read() {
        var buf = [UInt8](repeating: 0, count: 65536)
        let n = recv(fd, &buf, buf.count, 0)
        if n > 0 {
            buffer.append(buf, count: n)
            while let nl = buffer.firstIndex(of: 0x0A) {
                let lineData = buffer[..<nl]
                buffer.removeSubrange(...nl)
                guard let data = Data(lineData) as Data?,
                      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                let snap = decodeSnapshot(obj)
                let tol = CGFloat((obj["tolerance"] as? Double) ?? 12)
                DispatchQueue.main.async { [weak self] in self?.overlay?.render(snap, tolerance: tol) }
            }
        } else if n == 0 {
            exit(0)
        } else if errno != EAGAIN, errno != EWOULDBLOCK {
            exit(2)
        }
    }

    private func sendLine(_ line: String) {
        guard fd >= 0 else { return }
        var data = Data((line + "\n").utf8)
        data.withUnsafeBytes { _ = send(fd, $0.baseAddress, $0.count, Int32(MSG_DONTWAIT)) }
    }
}

private func decodeSnapshot(_ obj: [String: Any]) -> CacheSnapshot {
    let targets: [CachedTarget] = (obj["targets"] as? [[String: Any]] ?? []).compactMap { t in
        guard let key = t["key"] as? String,
              let r = t["rect"] as? [Double], r.count == 4 else { return nil }
        return CachedTarget(key: key, role: "helper", label: key,
                            rect: CGRect(x: r[0], y: r[1], width: r[2], height: r[3]),
                            inset: CGFloat((t["inset"] as? Double) ?? 2))
    }
    return CacheSnapshot(
        generation: (obj["generation"] as? NSNumber)?.uint64Value ?? 0,
        targets: targets,
        valid: (obj["valid"] as? Bool) ?? false,
        reason: (obj["reason"] as? String) ?? "-",
        stamp: (obj["stamp"] as? Double) ?? 0,
        resolverMs: 0,
        pointer: .zero,
        appName: (obj["appName"] as? String) ?? "-",
        pid: 0)
}

private func connectWithRetry(_ path: String) -> Int32 {
    for _ in 0..<80 {
        let s = socket(AF_UNIX, SOCK_STREAM, 0)
        guard s >= 0 else { return -1 }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathMax = MemoryLayout.size(ofValue: addr.sun_path)
        guard path.utf8.count < pathMax else { close(s); return -1 }
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: pathMax) { dst in
                _ = strlcpy(dst, path, pathMax)
            }
        }
        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let r = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(s, $0, len) }
        }
        if r == 0 { return s }
        close(s)
        usleep(50_000)
    }
    return -1
}

/// Rendering half of the old in-process TargetingOverlay (same DecisionCore, same
/// published snapshot). It has no access to the tap and cannot affect routing.
final class HelperOverlay {
    private let send: (String) -> Void
    private var panel: OverlayPanel?
    private var view: OverlayView?
    private var lastSig = ""

    init(send: @escaping (String) -> Void) {
        self.send = send
    }

    func render(_ s: CacheSnapshot, tolerance: CGFloat) {
        let ageMs = (CACurrentMediaTime() - s.stamp) * 1000
        let fresh = s.valid && ageMs <= DecisionCore.cacheMaxAge * 1000
        let pointer = CGEvent(source: nil)?.location ?? .zero
        var action = "none"
        var reason = s.valid ? String(format: "stale:age(%.0fms)", ageMs) : s.reason
        var targetKey: String?
        var frame: CGRect?
        var mode = "redirect"
        if fresh {
            let cands = s.targets.map { DecisionCore.Candidate(key: $0.key, rect: $0.rect, inset: $0.inset) }
            switch DecisionCore.route(point: pointer, candidates: cands, tolerance: tolerance) {
            case .redirect(let c, _, _):
                action = "show"; targetKey = c.key; frame = c.rect; reason = "redirect"
            case .directHit(let c, _):
                action = "show"; targetKey = c.key; frame = c.rect; reason = "direct-hit"; mode = "direct-hit"
            case .ambiguous:
                reason = "ambiguous"
            case .noCandidate:
                reason = "no-candidate-in-radius"
            }
        }
        let sig = "\(s.generation)|\(action)|\(targetKey ?? "-")|\(reason)"
        if sig != lastSig {
            lastSig = sig
            if action == "show", let targetKey, let frame {
                send(String(format: "OVERLAY_STATE gen=%llu action=show target=%@ frame=(%.1f,%.1f,%.1f,%.1f) tol=%.1f pointer=(%.1f,%.1f) reason=%@ mode=%@",
                            s.generation, targetKey as NSString, frame.origin.x, frame.origin.y,
                            frame.width, frame.height, tolerance, pointer.x, pointer.y,
                            reason as NSString, mode as NSString))
            } else {
                send(String(format: "OVERLAY_STATE gen=%llu action=none pointer=(%.1f,%.1f) reason=%@",
                            s.generation, pointer.x, pointer.y, reason as NSString))
            }
        }
        draw(action: action, frame: frame, pointer: pointer, tolerance: tolerance, mode: mode)
        if let p = panel, p.isVisible {
            send("OVERLAY_FLAGS ignoresMouseEvents=\(p.ignoresMouseEvents) canBecomeKey=\(p.canBecomeKey) canBecomeMain=\(p.canBecomeMain) level=\(p.level.rawValue)")
        }
    }

    private func draw(action: String, frame: CGRect?, pointer: CGPoint,
                      tolerance: CGFloat, mode: String) {
        guard action == "show", let frame else {
            view?.isBlank = true
            view?.needsDisplay = true
            return
        }
        let margin = tolerance + 14
        let cgPanel = frame.insetBy(dx: -margin, dy: -margin)
        let cocoa = NSRect(x: cgPanel.minX, y: ScreenSpace.mainHeight - cgPanel.maxY,
                           width: cgPanel.width, height: cgPanel.height)
        if panel == nil {
            let p = OverlayPanel(contentRect: cocoa, styleMask: .borderless, backing: .buffered, defer: false)
            p.isOpaque = false
            p.backgroundColor = .clear
            p.hasShadow = false
            p.ignoresMouseEvents = true
            p.acceptsMouseMovedEvents = false
            p.hidesOnDeactivate = false
            p.becomesKeyOnlyIfNeeded = true
            p.level = .statusBar
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            p.isReleasedWhenClosed = false
            let v = OverlayView(frame: NSRect(origin: .zero, size: cocoa.size))
            v.wantsLayer = true
            p.contentView = v
            panel = p
            view = v
        }
        guard let panel, let view else { return }
        if panel.frame != cocoa { panel.setFrame(cocoa, display: false) }
        view.cgFrame = frame
        view.cgPanelTopLeft = CGPoint(x: cgPanel.minX, y: cgPanel.minY)
        view.cgPointer = pointer
        view.tolerance = tolerance
        view.mode = mode
        view.isBlank = false
        view.needsDisplay = true
        // DEFECT 3 FIX: click-through flags are asserted BEFORE the panel is ever
        // ordered on screen. A panel that could capture clicks must never appear.
        guard panel.ignoresMouseEvents == true,
              panel.canBecomeKey == false,
              panel.canBecomeMain == false else {
            send("OVERLAY_PANEL_REFUSED ignoresMouseEvents=\(panel.ignoresMouseEvents) canBecomeKey=\(panel.canBecomeKey) canBecomeMain=\(panel.canBecomeMain) action=exit-nonzero")
            exit(3)
        }
        if !panel.isVisible { panel.orderFrontRegardless() }
    }
}
