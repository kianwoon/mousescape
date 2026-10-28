// baseline-guard:allow new standalone prototype file, no prior baseline possible
import AppKit
import ApplicationServices
import CoreGraphics

setlinebuf(stdout)

struct Options {
    var selftest = false
    var dangerous = false
    var simulateUntrusted = false
    var tolerance: CGFloat = 12
    var tapLocation: CGEventTapLocation = .cghidEventTap

    static func parse(_ args: [String]) -> Options {
        var o = Options()
        o.selftest = args.contains("--selftest")
        o.dangerous = args.contains("--dangerous")
            || ProcessInfo.processInfo.environment["CLICKASSIST_ALLOW_DANGEROUS"] == "1"
        o.simulateUntrusted = args.contains("--simulate-untrusted")
        if let i = args.firstIndex(of: "--tolerance"), i + 1 < args.count, let v = Double(args[i + 1]) {
            o.tolerance = CGFloat(v)
        }
        if let i = args.firstIndex(of: "--tap-point"), i + 1 < args.count {
            o.tapLocation = args[i + 1] == "session" ? .cgSessionEventTap : .cghidEventTap
        }
        return o
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    let options: Options
    let sink = LogSink()
    let cache = CacheStore()
    var window: TestWindow?
    var tap: AssistTap?
    var resolver: AccessibilityResolver?
    var overlay: OverlayLink?
    var selfTest: SelfTest?

    init(options: Options) {
        self.options = options
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.activate(ignoringOtherApps: true)

        let w = TestWindow()
        window = w
        w.makeKeyAndOrderFront(nil)
        let target = w.buttonTarget()
        print("[ASSIST] window content=(640x360) at cocoa-origin=\(w.frame.origin)")
        print("[ASSIST] static target \(target.name) CG-rect=\(target.rect) inset=\(target.inset) tolerance=\(options.tolerance)")

        let tol = AssistTap.clampTolerance(options.tolerance)
        if tol != options.tolerance {
            print("[ASSIST] TOLERANCE_CLAMP requested=\(options.tolerance) clamped=\(tol) rule=range-8-16")
        }

        let trusted = AXIsProcessTrusted()
        print("[ASSIST] pid=\(getpid()) trusted=\(trusted)")

        if !trusted && !options.simulateUntrusted {
            print("[ASSIST] trust missing -> AXIsProcessTrustedWithOptions(prompt:true) (macOS shows the grant prompt); running pass-through meanwhile")
            let promptOptions = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(promptOptions)
        }

        let failOpen = options.simulateUntrusted || !trusted
        if failOpen {
            let reason = options.simulateUntrusted ? "simulated-untrusted" : "accessibility-untrusted"
            print("[ASSIST] FAILOPEN tap=nil passthrough=on reason=\(reason)")
        } else {
            let t = AssistTap(tolerance: tol) { [weak self] line in
                self?.sink.write(line)
            }
            t.targetSource = .staticTargets([target])
            if t.start(point: options.tapLocation) {
                tap = t

                let r = AccessibilityResolver(cache: cache) { [weak self] line in
                    self?.sink.write(line)
                }
                resolver = r
                r.start()

                let o = OverlayLink(tolerance: options.tolerance, log: { [weak self] line in
                    self?.sink.write(line)
                })
                cache.addObserver { [weak o] snap in o?.observe(snap) }
                overlay = o
                print("[ASSIST] overlay=separate-process handshake=background renders-from=published-snapshots click-through=asserted-before-show crash-isolated=true")
            } else {
                print("[ASSIST] FAILOPEN tap=nil passthrough=on reason=tap-create-failed")
            }
        }

        if options.selftest {
            let st = SelfTest(window: w, tap: tap, sink: sink,
                              cache: resolver == nil ? nil : cache,
                              resolver: resolver,
                              overlay: overlay,
                              allowDangerous: options.dangerous,
                              mode: tap == nil ? .failOpen : .trustedTap)
            selfTest = st
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { st.start() }
        } else {
            print("[ASSIST] interactive mode: cache-only router live; AX resolver refreshing every 150 ms. Ctrl-C to quit.")
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        resolver?.stop()
        tap?.stop()
        overlay?.shutdown()
    }
}

let options = Options.parse(CommandLine.arguments)
// Gate 7: overlay helper mode — a separate process, never the tap's process.
if let i = CommandLine.arguments.firstIndex(of: "--overlay-helper"),
   i + 1 < CommandLine.arguments.count {
    runOverlayHelper(socketPath: CommandLine.arguments[i + 1])
}
if CommandLine.arguments.contains("--help") {
    print("usage: ClickAssistProto [--selftest] [--dangerous] [--tolerance pt] [--tap-point hid|session] [--simulate-untrusted]")
    print("  --dangerous (or CLICKASSIST_ALLOW_DANGEROUS=1): enable Space-switch, browser, Electron and synthetic-keyboard cases. Plain --selftest never posts keyboard events, switches Spaces or touches external apps.")
    exit(0)
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let delegate = AppDelegate(options: options)
app.delegate = delegate
app.run()
