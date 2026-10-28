// baseline-guard:allow new standalone prototype file, no prior baseline possible
import AppKit
import ApplicationServices
import CoreGraphics

// MARK: - Contract table (exact names / defaults / validation)
//
// Key                                  Type    Default   Validation
// MCClickAssistEnabled                 Bool    false     bool (missing => false)
// MCClickAssistTolerancePoints         Number  12        finite, clamped 8...16 (step 3)
// MCClickAssistIndicatorEnabled        Bool    true      bool (missing => true)
//
// Scope is deliberately one store: currentUser + anyHost. No host-specific shadow,
// no mirrored second domain.
struct ClickAssistConfig: Equatable {
    var enabled: Bool
    var tolerancePoints: CGFloat
    var indicatorEnabled: Bool

    static let defaultTolerance: CGFloat = 12
    static let toleranceRange: ClosedRange<CGFloat> = 8...16

    static func validated(enabled: Bool, tolerancePoints raw: CGFloat,
                          indicatorEnabled: Bool) -> ClickAssistConfig {
        let finite = raw.isFinite ? raw : defaultTolerance
        return ClickAssistConfig(enabled: enabled,
                                 tolerancePoints: min(max(finite, toleranceRange.lowerBound),
                                                      toleranceRange.upperBound),
                                 indicatorEnabled: indicatorEnabled)
    }
}

final class ClickAssistPreferences {
    static let domain = "com.sdmj76.Mousecape.ClickAssistProto"
    // Namespaced Darwin invalidation hint: derived from the pref domain, not a literal.
    static let changedNotification = domain + ".prefs-changed"
    static let enabledKey = "MCClickAssistEnabled"
    static let toleranceKey = "MCClickAssistTolerancePoints"
    static let indicatorKey = "MCClickAssistIndicatorEnabled"

    // Explicit scoped accessors: currentUser + anyHost only.
    private func read(_ key: String) -> CFPropertyList? {
        CFPreferencesCopyValue(key as CFString, Self.domain as CFString,
                               kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
    }

    private func write(_ key: String, _ value: CFPropertyList) {
        CFPreferencesSetValue(key as CFString, value, Self.domain as CFString,
                              kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        CFPreferencesSynchronize(Self.domain as CFString,
                                 kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        // Post AFTER set + synchronize so another process can re-sync and re-read.
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                             CFNotificationName(rawValue: Self.changedNotification as CFString),
                                             nil, nil, true)
    }

    func readConfig() -> ClickAssistConfig {
        ClickAssistConfig.validated(
            enabled: bool(Self.enabledKey, default: false),
            tolerancePoints: number(Self.toleranceKey, default: ClickAssistConfig.defaultTolerance),
            indicatorEnabled: bool(Self.indicatorKey, default: true))
    }

    func writeEnabled(_ value: Bool) {
        write(Self.enabledKey, NSNumber(value: value))
    }

    func writeTolerancePoints(_ value: CGFloat) {
        let clamped = ClickAssistConfig.validated(enabled: true, tolerancePoints: value,
                                                  indicatorEnabled: true).tolerancePoints
        write(Self.toleranceKey, NSNumber(value: Double(clamped)))
    }

    func writeIndicatorEnabled(_ value: Bool) {
        write(Self.indicatorKey, NSNumber(value: value))
    }

    private func bool(_ key: String, default def: Bool) -> Bool {
        guard let raw = read(key) else { return def }
        if CFGetTypeID(raw) == CFBooleanGetTypeID() {
            return CFBooleanGetValue((raw as! CFBoolean))
        }
        if let n = raw as? NSNumber { return n.boolValue }
        return def
    }

    private func number(_ key: String, default def: CGFloat) -> CGFloat {
        guard let raw = read(key), let n = raw as? NSNumber else { return def }
        let d = n.doubleValue
        return d.isFinite ? CGFloat(d) : def
    }
}

enum ClickAssistRuntimeStatus: Equatable {
    case active
    case pausedDisabled
    case pausedAccessibility
    case pausedSimulatedUntrusted
    case tapFailed
    case resolverUnavailable

    var text: String {
        switch self {
        case .active: return "Active — assist tap and resolver running"
        case .pausedDisabled: return "Paused — disabled in Settings"
        case .pausedAccessibility: return "Paused — Accessibility access required"
        case .pausedSimulatedUntrusted: return "Paused — simulated untrusted test mode"
        case .tapFailed: return "Paused — event tap could not start"
        case .resolverUnavailable: return "Paused — Accessibility resolver unavailable"
        }
    }
}

/// Owns the runtime engine and is the only place that applies a validated config
/// snapshot. Prefs are the source of truth; UI state is refreshed from `config`.
final class EngineRuntime {
    let options: Options
    let sink: LogSink
    let cache = CacheStore()
    let prefs = ClickAssistPreferences()
    let target: AssistTarget

    private(set) var config: ClickAssistConfig
    private(set) var tap: AssistTap?
    private(set) var resolver: AccessibilityResolver?
    private(set) var overlay: OverlayLink?
    private var trustPromptRequested = false
    private var prefObserverRegistered = false
    private var cacheObserverInstalled = false
    var onStatusChange: (() -> Void)?
    var onRuntimeChange: (() -> Void)?

    init(options: Options, sink: LogSink, target: AssistTarget) {
        self.options = options
        self.sink = sink
        self.target = target
        var c = prefs.readConfig()
        if options.selftest {
            // Test precedence: --selftest forces the engine on and keeps the original
            // deterministic test radius; it never persists those test overrides.
            c = ClickAssistConfig.validated(enabled: true,
                                            tolerancePoints: options.tolerance,
                                            indicatorEnabled: true)
        } else if options.toleranceExplicit {
            // CLI seed for this session only; a later Settings write persists and wins.
            c = ClickAssistConfig.validated(enabled: c.enabled,
                                            tolerancePoints: options.tolerance,
                                            indicatorEnabled: c.indicatorEnabled)
        }
        self.config = c
    }

    func start() {
        registerForPrefChanges()
        print("CONFIG_START source=prefs scope=currentUser+anyHost enabled=\(config.enabled) tolerance=\(config.tolerancePoints) indicator=\(config.indicatorEnabled) selftest=\(options.selftest) cliToleranceOverride=\(options.toleranceExplicit)")
        apply(config)
    }

    func reloadFromPreferences() {
        apply(prefs.readConfig())
    }

    /// Idempotent registration: a second call is a no-op, so handlers never stack.
    private func registerForPrefChanges() {
        guard !prefObserverRegistered else { return }
        prefObserverRegistered = true
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                        Unmanaged.passUnretained(self).toOpaque(),
                                        Self.prefChangedCallback,
                                        ClickAssistPreferences.changedNotification as CFString,
                                        nil, .deliverImmediately)
        sink.write("PREFS_NOTIFY registration name=\(ClickAssistPreferences.changedNotification) idempotent=true")
    }

    private func unregisterForPrefChanges() {
        guard prefObserverRegistered else { return }
        prefObserverRegistered = false
        CFNotificationCenterRemoveObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                           Unmanaged.passUnretained(self).toOpaque(),
                                           CFNotificationName(rawValue: ClickAssistPreferences.changedNotification as CFString),
                                           nil)
    }

    private static let prefChangedCallback: CFNotificationCallback = { _, observer, _, _, _ in
        guard let observer else { return }
        let engine = Unmanaged<EngineRuntime>.fromOpaque(observer).takeUnretainedValue()
        engine.preferencesChangedFromDarwin()
    }

    private func preferencesChangedFromDarwin() {
        DispatchQueue.main.async { [weak self] in self?.handleExternalPreferencesChanged() }
    }

    /// Re-sync the explicit domain, then re-read/validate ALL keys and publish.
    func handleExternalPreferencesChanged() {
        CFPreferencesSynchronize(ClickAssistPreferences.domain as CFString,
                                 kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        sink.write("PREFS_NOTIFY source=darwin sync=true keys=MCClickAssistEnabled,MCClickAssistTolerancePoints,MCClickAssistIndicatorEnabled action=revalidate-republish")
        reloadFromPreferences()
    }

    func requestEnabled(_ value: Bool) {
        prefs.writeEnabled(value)
        reloadFromPreferences()
    }

    func requestTolerancePoints(_ value: CGFloat) {
        prefs.writeTolerancePoints(value)
        reloadFromPreferences()
    }

    func requestIndicatorEnabled(_ value: Bool) {
        prefs.writeIndicatorEnabled(value)
        reloadFromPreferences()
    }

    var requestedSummary: String {
        "Requested: \(config.enabled ? "Enabled" : "Disabled") · " +
        String(format: "%.1f pt", config.tolerancePoints) +
        " · Indicator \(config.indicatorEnabled ? "On" : "Off")"
    }

    var runtimeStatus: ClickAssistRuntimeStatus {
        if !config.enabled { return .pausedDisabled }
        if options.simulateUntrusted { return .pausedSimulatedUntrusted }
        if !AXIsProcessTrusted() { return .pausedAccessibility }
        if tap == nil { return .tapFailed }
        if resolver == nil { return .resolverUnavailable }
        return .active
    }

    var runtimeSummary: String { runtimeStatus.text }

    private func apply(_ raw: ClickAssistConfig) {
        let old = config
        config = ClickAssistConfig.validated(enabled: raw.enabled,
                                             tolerancePoints: raw.tolerancePoints,
                                             indicatorEnabled: raw.indicatorEnabled)
        if !config.enabled {
            stopEngine()
            notify()
            return
        }
        if old.enabled, tap != nil {
            if old.tolerancePoints != config.tolerancePoints { applyToleranceChange(from: old.tolerancePoints) }
            if old.indicatorEnabled != config.indicatorEnabled {
                config.indicatorEnabled ? startOverlay() : stopOverlay()
            }
        } else {
            startEngine()
        }
        notify()
    }

    private func startEngine() {
        stopEngine()
        guard config.enabled else { return }
        if options.simulateUntrusted || !AXIsProcessTrusted() {
            if !trustPromptRequested, !options.simulateUntrusted {
                trustPromptRequested = true
                let prompt = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
                _ = AXIsProcessTrustedWithOptions(prompt)
            }
            print("ENGINE_PAUSED reason=accessibility-untrusted status=\"\(runtimeStatus.text)\"")
            return
        }
        let t = AssistTap(tolerance: config.tolerancePoints) { [weak self] line in
            self?.sink.write(line)
        }
        t.targetSource = .cache(cache)
        guard t.start(point: options.tapLocation) else {
            print("ENGINE_PAUSED reason=tap-create-failed")
            return
        }
        tap = t
        let r = AccessibilityResolver(cache: cache) { [weak self] line in
            self?.sink.write(line)
        }
        resolver = r
        r.start()
        if config.indicatorEnabled { startOverlay() }
        print("ENGINE_STARTED tolerance=\(config.tolerancePoints) indicator=\(config.indicatorEnabled) tap=hid range=8-16")
    }

    private func stopEngine() {
        resolver?.stop()
        resolver = nil
        tap?.stop()
        tap = nil
        stopOverlay()
    }

    private func applyToleranceChange(from old: CGFloat) {
        tap?.setTolerance(config.tolerancePoints)
        overlay?.setTolerance(config.tolerancePoints)
        let genBefore = cache.current().generation
        resolver?.invalidate(reason: "tolerance-change", prefixStale: false)
        let genAfter = cache.current().generation
        sink.write(String(format: "TOLERANCE_APPLY source=settings from=%.1f to=%.1f gen_before=%llu gen_after=%llu next=decision-under-new-radius",
                          old, config.tolerancePoints, genBefore, genAfter))
    }

    private func startOverlay() {
        guard overlay == nil else { return }
        let o = OverlayLink(tolerance: config.tolerancePoints) { [weak self] line in
            self?.sink.write(line)
        }
        overlay = o
        // One permanent forwarder: overlay identity changes, observer count stays 1.
        if !cacheObserverInstalled {
            cache.addObserver { [weak self] snap in self?.overlay?.observe(snap) }
            cacheObserverInstalled = true
        }
        print("INDICATOR_APPLY visible=true mode=overlay-process tolerance=\(config.tolerancePoints)")
    }

    private func stopOverlay() {
        guard let o = overlay else { return }
        o.shutdown()
        overlay = nil
        print("INDICATOR_APPLY visible=false mode=overlay-process reason=pref-disabled-or-engine-stopped")
    }

    private func notify() {
        onStatusChange?()
        onRuntimeChange?()
    }

    func shutdown() {
        unregisterForPrefChanges()
        stopEngine()
    }

    deinit { unregisterForPrefChanges() }
}

/// Settings window: requested configuration (prefs snapshot) is displayed separately
/// from runtime status, and every mutation goes through the prefs bridge.
final class SettingsWindowController: NSWindowController {
    private let engine: EngineRuntime
    private var enableButton: NSButton!
    private var indicatorButton: NSButton!
    private var toleranceSlider: NSSlider!
    private var toleranceValue: NSTextField!
    private var requestedLabel: NSTextField!
    private var runtimeLabel: NSTextField!
    private var runtimeCaption: NSTextField!
    private var hasShown = false
    private var hasPositionedWindow = false

    init(engine: EngineRuntime) {
        self.engine = engine
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 360),
                              styleMask: [.titled, .closable],
                              backing: .buffered, defer: false)
        window.title = "ClickAssist Settings"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        buildUI()
        engine.onStatusChange = { [weak self] in self?.refresh() }
        refresh()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func show() {
        if hasShown {
            engine.reloadFromPreferences()   // pick up writes made by any process since last view
        }
        hasShown = true
        refresh()
        placeWindowOnActiveScreen()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Keeps the whole window inside the active screen's visibleFrame. Chooses the
    /// screen with the largest overlap (fallback: main screen); centers when the
    /// window has never been placed, has a non-finite origin, or is off-screen.
    private func placeWindowOnActiveScreen() {
        guard let window else { return }
        let current = window.frame
        let screen = screenContaining(current) ?? NSScreen.main ?? NSScreen.screens.first
        guard let screen else { return }
        let visible = screen.visibleFrame
        let size = current.size
        let validOrigin = current.origin.x.isFinite && current.origin.y.isFinite
        let center = !hasPositionedWindow || !validOrigin || !visible.contains(current)

        var origin: NSPoint
        if center {
            origin = NSPoint(x: visible.midX - size.width / 2,
                             y: visible.midY - size.height / 2)
        } else {
            origin = current.origin
        }
        if size.width <= visible.width {
            origin.x = min(max(origin.x, visible.minX), visible.maxX - size.width)
        } else {
            origin.x = visible.minX   // taller/wider than the screen: keep left visible
        }
        if size.height <= visible.height {
            origin.y = min(max(origin.y, visible.minY), visible.maxY - size.height)
        } else {
            origin.y = visible.maxY - size.height   // keep the title bar visible
        }
        window.setFrameOrigin(origin)
        hasPositionedWindow = true
    }

    private func screenContaining(_ frame: NSRect) -> NSScreen? {
        let intersecting = NSScreen.screens.compactMap { screen -> (NSScreen, CGFloat)? in
            let overlap = screen.frame.intersection(frame)
            let area = overlap.width * overlap.height
            return area > 0 ? (screen, area) : nil
        }
        return intersecting.max { $0.1 < $1.1 }?.0
    }

    private func buildUI() {
        guard let content = window?.contentView else { return }
        content.wantsLayer = true

        let title = NSTextField(labelWithString: "ClickAssist configuration")
        title.font = .systemFont(ofSize: 15, weight: .semibold)
        title.frame = NSRect(x: 24, y: 316, width: 460, height: 20)
        content.addSubview(title)

        enableButton = NSButton(checkboxWithTitle: "Enable ClickAssist",
                                target: self, action: #selector(enabledChanged(_:)))
        enableButton.frame = NSRect(x: 24, y: 282, width: 300, height: 22)
        content.addSubview(enableButton)

        let tolLabel = NSTextField(labelWithString: "Tolerance (8–16 pt)")
        tolLabel.frame = NSRect(x: 24, y: 240, width: 200, height: 20)
        content.addSubview(tolLabel)

        toleranceSlider = NSSlider(value: Double(engine.config.tolerancePoints),
                                   minValue: 8, maxValue: 16,
                                   target: self, action: #selector(toleranceChanged(_:)))
        toleranceSlider.frame = NSRect(x: 24, y: 210, width: 360, height: 24)
        toleranceSlider.isContinuous = false
        content.addSubview(toleranceSlider)

        toleranceValue = NSTextField(labelWithString: "")
        toleranceValue.font = .monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        toleranceValue.frame = NSRect(x: 396, y: 212, width: 100, height: 20)
        content.addSubview(toleranceValue)

        indicatorButton = NSButton(checkboxWithTitle: "Show targeting indicator",
                                   target: self, action: #selector(indicatorChanged(_:)))
        indicatorButton.frame = NSRect(x: 24, y: 172, width: 320, height: 22)
        content.addSubview(indicatorButton)

        let requestedCaption = NSTextField(labelWithString: "Requested configuration")
        requestedCaption.font = .systemFont(ofSize: 11, weight: .semibold)
        requestedCaption.textColor = .secondaryLabelColor
        requestedCaption.frame = NSRect(x: 24, y: 136, width: 460, height: 16)
        content.addSubview(requestedCaption)

        requestedLabel = NSTextField(labelWithString: "")
        requestedLabel.frame = NSRect(x: 24, y: 112, width: 460, height: 20)
        content.addSubview(requestedLabel)

        runtimeCaption = NSTextField(labelWithString: "Runtime status")
        runtimeCaption.font = .systemFont(ofSize: 11, weight: .semibold)
        runtimeCaption.textColor = .secondaryLabelColor
        runtimeCaption.frame = NSRect(x: 24, y: 78, width: 460, height: 16)
        content.addSubview(runtimeCaption)

        runtimeLabel = NSTextField(labelWithString: "")
        runtimeLabel.font = .systemFont(ofSize: 13, weight: .medium)
        runtimeLabel.textColor = .secondaryLabelColor
        runtimeLabel.lineBreakMode = .byWordWrapping
        runtimeLabel.maximumNumberOfLines = 2
        runtimeLabel.frame = NSRect(x: 24, y: 44, width: 460, height: 34)
        content.addSubview(runtimeLabel)

        let note = NSTextField(labelWithString: "Settings apply live. The engine reads a validated snapshot from prefs; no restart is required.")
        note.font = .systemFont(ofSize: 10)
        note.textColor = .tertiaryLabelColor
        note.frame = NSRect(x: 24, y: 16, width: 460, height: 16)
        content.addSubview(note)
    }

    private func refresh() {
        enableButton?.state = engine.config.enabled ? .on : .off
        indicatorButton?.state = engine.config.indicatorEnabled ? .on : .off
        toleranceSlider?.doubleValue = Double(engine.config.tolerancePoints)
        toleranceValue?.stringValue = String(format: "%.1f pt", engine.config.tolerancePoints)
        requestedLabel?.stringValue = engine.requestedSummary
        runtimeLabel?.stringValue = engine.runtimeSummary
        runtimeLabel?.textColor = engine.runtimeStatus == .active ? .systemGreen : .systemOrange
    }

    @objc private func enabledChanged(_ sender: NSButton) {
        engine.requestEnabled(sender.state == .on)
        refresh()
    }

    @objc private func toleranceChanged(_ sender: NSSlider) {
        engine.requestTolerancePoints(CGFloat(sender.doubleValue))
        refresh()
    }

    @objc private func indicatorChanged(_ sender: NSButton) {
        engine.requestIndicatorEnabled(sender.state == .on)
        refresh()
    }
}
