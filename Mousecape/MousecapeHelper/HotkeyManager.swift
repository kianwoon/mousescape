//
//  HotkeyManager.swift
//  MousecapeHelper
//
//  Two global hotkeys that set the per-cursor scale of the "Arrow S" cursor
//  (com.apple.coregraphics.ArrowS).  Both the key combo AND the scale are
//  user-configured in the GUI Settings, persisted under the CFPreferences key
//  "MCArrowSHotkeys" (domain com.sdmj76.Mousecape, currentHost).
//
//  Uses Carbon RegisterEventHotKey so we do NOT need Accessibility /
//  Input-Monitoring permission and fire system-wide even when Mousecape is
//  not frontmost.  The Owner is this Helper (menu-bar login item, always on).
//

import Foundation
import AppKit
import Carbon.HIToolbox
import os

final class ArrowSHotkeyManager {

    static let shared = ArrowSHotkeyManager()

    // Visible (public-privacy) diagnostic channel. NSLog from this launchd
    // instance does not surface in the unified log, so we log through os_log
    // with an explicit subsystem + public privacy for every field.
    private static let log = Logger(subsystem: "com.sdmj76.MousecapeHelper", category: "ArrowSHotkeys")

    // MARK: Constants

    private static let domain = "com.sdmj76.Mousecape" as CFString
    private static let hotkeysKey = "MCArrowSHotkeys" as CFString
    private static let perCursorScalesKey = "MCPerCursorScales" as CFString
    private static let scaleModeKey = "MCScaleMode" as CFString
    private static let arrowSIdentifier = "com.apple.coregraphics.ArrowS"
    private static let changedNotification = "com.sdmj76.Mousecape.arrowSHotkeysChanged"

    // Four-character signature 'MCAS' for our EventHotKeyIDs.
    private static let signature: OSType = 0x4D434153

    private struct HotkeyConfig {
        let keyCode: UInt32
        let modifiers: UInt32
        let scale: Double
    }

    // MARK: State

    private var hotKeyRefs: [EventHotKeyRef] = []
    private var eventHandlerRef: EventHandlerRef?
    private var cfObserverContext: UnsafeMutableRawPointer?

    private init() {}

    // MARK: Lifecycle

    func start() {
        Self.log.log("ArrowS hotkey manager start() invoked")
        installHandlerIfNeeded()
        registerHotkeysFromPrefs()
        observeConfigChanges()
        Self.log.log("ArrowS hotkey manager started")
    }

    // MARK: Carbon event handler

    private func installHandlerIfNeeded() {
        guard eventHandlerRef == nil else { return }

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            { (_, event, userData) -> OSStatus in
                guard let userData = userData else { return noErr }
                let manager = Unmanaged<ArrowSHotkeyManager>
                    .fromOpaque(userData).takeUnretainedValue()
                return manager.handleHotkeyEvent(event)
            },
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &eventHandlerRef
        )

        if status != noErr {
            Self.log.error("InstallEventHandler failed: OSStatus \(status, privacy: .public)")
        }
    }

    private func handleHotkeyEvent(_ event: EventRef?) -> OSStatus {
        guard let event = event else { return noErr }

        var hotKeyID = EventHotKeyID()
        let status = GetEventParameter(
            event,
            EventParamName(kEventParamDirectObject),
            EventParamType(typeEventHotKeyID),
            nil,
            MemoryLayout<EventHotKeyID>.size,
            nil,
            &hotKeyID
        )
        guard status == noErr, hotKeyID.signature == Self.signature else {
            Self.log.log("Hotkey event ignored: status=\(status, privacy: .public) signature=\(hotKeyID.signature, privacy: .public)")
            return noErr
        }

        Self.log.log("Hotkey event fired: id=\(hotKeyID.id, privacy: .public)")
        applyHotkey(index: Int(hotKeyID.id))
        return noErr
    }

    // MARK: Registration

    private func registerHotkeysFromPrefs() {
        unregisterHotkeys()

        let configs = loadConfig()
        Self.log.log("Re/registering ArrowS hotkeys: \(configs.count, privacy: .public) configured slot(s)")
        // Hotkey identity uses only intentional modifier bits: cmd|shift|option|control|fn.
        // alphaLock (caps-lock state) and any other junk must never participate.
        let usableMask: UInt32 = 256 | 512 | 2048 | 4096 | 8192
        // Deterministic order (1 then 2) for readable logs.
        for index in configs.keys.sorted() {
            let cfg = configs[index]!
            let cleanMods = cfg.modifiers & usableMask
            Self.log.log("Slot \(index, privacy: .public) config: keyCode=\(cfg.keyCode, privacy: .public) modifiers_raw=\(cfg.modifiers, privacy: .public) modifiers_clean=\(cleanMods, privacy: .public) scale=\(cfg.scale, privacy: .public)")
            var ref: EventHotKeyRef?
            let hotKeyID = EventHotKeyID(signature: Self.signature, id: UInt32(index))
            let status = RegisterEventHotKey(
                cfg.keyCode,
                cleanMods,
                hotKeyID,
                GetApplicationEventTarget(),
                0,
                &ref
            )
            if status == noErr, let ref = ref {
                hotKeyRefs.append(ref)
                Self.log.log("Registered ArrowS hotkey \(index, privacy: .public): keyCode=\(cfg.keyCode, privacy: .public) modifiers=\(cleanMods, privacy: .public) scale=\(cfg.scale, privacy: .public)")
            } else {
                Self.log.error("RegisterEventHotKey \(index, privacy: .public) FAILED: OSStatus \(status, privacy: .public) (rawMods=\(cfg.modifiers, privacy: .public) cleanMods=\(cleanMods, privacy: .public))")
            }
        }
    }

    private func unregisterHotkeys() {
        for ref in hotKeyRefs {
            UnregisterEventHotKey(ref)
        }
        hotKeyRefs.removeAll()
    }

    private func handleConfigChanged() {
        Self.log.log("Config changed notification received — re-registering")
        registerHotkeysFromPrefs()
    }

    // MARK: Config change observation (Darwin notification)

    private func observeConfigChanges() {
        let context = Unmanaged.passUnretained(self).toOpaque()
        cfObserverContext = context

        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            context,
            { (_, observer, _, _, _) in
                guard let observer = observer else { return }
                let manager = Unmanaged<ArrowSHotkeyManager>
                    .fromOpaque(observer).takeUnretainedValue()
                // Carbon registration touches the app event target — do it on main.
                DispatchQueue.main.async {
                    manager.handleConfigChanged()
                }
            },
            Self.changedNotification as CFString,
            nil,
            .deliverImmediately
        )
    }

    deinit {
        if let context = cfObserverContext {
            CFNotificationCenterRemoveObserver(
                CFNotificationCenterGetDarwinNotifyCenter(),
                context,
                CFNotificationName(Self.changedNotification as CFString),
                nil
            )
        }
        unregisterHotkeys()
        if let handler = eventHandlerRef {
            RemoveEventHandler(handler)
        }
    }

    // MARK: Config load

    private func loadConfig() -> [Int: HotkeyConfig] {
        guard let raw = CFPreferencesCopyValue(
            Self.hotkeysKey,
            Self.domain,
            kCFPreferencesCurrentUser,
            kCFPreferencesCurrentHost
        ) as? [String: Any] else {
            Self.log.log("MCArrowSHotkeys not present/parseable in currentHost — no slots")
            return [:]
        }

        Self.log.log("MCArrowSHotkeys raw read: \(raw.count, privacy: .public) raw slot(s)")
        var result: [Int: HotkeyConfig] = [:]
        for (name, value) in raw {
            guard let index = hotkeyIndex(fromName: name),
                  let entry = value as? [String: Any]
            else { continue }

            // Type-tolerant (see AppState.getPerCursorScale / SettingsView.loadPerCursorScales):
            // values may be NSString after `defaults write` CLI or script edits — accept
            // Double/String/NSNumber forms for keyCode, modifiers and scale.
            guard let keyCode = Self.number(entry["keyCode"]),
                  let modifiers = Self.number(entry["modifiers"]),
                  let scale = Self.number(entry["scale"]),
                  modifiers != 0
            else { continue }
            result[index] = HotkeyConfig(
                keyCode: UInt32(keyCode),
                modifiers: UInt32(modifiers),
                scale: scale
            )
        }
        return result
    }

    private func hotkeyIndex(fromName name: String) -> Int? {
        switch name {
        case "hotkey1": return 1
        case "hotkey2": return 2
        default: return nil
        }
    }

    /// Type-tolerant numeric parse: CFPreferences values may arrive as NSNumber,
    /// Double, or NSString (from `defaults write` CLI / script edits).
    private static func number(_ value: Any?) -> Double? {
        if let d = value as? Double { return d }
        if let s = value as? String { return Double(s) }
        if let n = value as? NSNumber { return n.doubleValue }
        return nil
    }

    // MARK: Apply

    private func applyHotkey(index: Int) {
        // Re-read the scale from prefs every fire so Settings edits apply
        // without a Helper restart.
        guard let cfg = loadConfig()[index] else {
            Self.log.log("Hotkey \(index, privacy: .public) fired but is not configured")
            return
        }

        Self.log.log("Hotkey \(index, privacy: .public) applying: scale=\(cfg.scale, privacy: .public)")

        // a. Write the per-cursor scale for ArrowS only (currentHost, matching
        //    the codebase's MCPerCursorScales scope).
        writeArrowSScale(cfg.scale)

        // b. Custom mode is required for per-cursor scales to take effect.
        ensureCustomScaleMode()

        // c. User-initiated apply (bypasses the shared wake cooldown).
        let success = applyCurrentCapeUserInitiated()
        Self.log.log("Hotkey \(index, privacy: .public) apply result: \(success ? "succeeded" : "FAILED", privacy: .public)")
    }

    private func writeArrowSScale(_ rawScale: Double) {
        let scale = min(max(0.5, rawScale), 96.0)

        var dict = (CFPreferencesCopyValue(
            Self.perCursorScalesKey,
            Self.domain,
            kCFPreferencesCurrentUser,
            kCFPreferencesCurrentHost
        ) as? [String: Any]) ?? [:]

        if abs(scale - 1.0) < 0.01 {
            // Keep the dict clean: 1.0 means "no override".
            dict.removeValue(forKey: Self.arrowSIdentifier)
            Self.log.log("ArrowS scale removed from MCPerCursorScales (scale≈1.0)")
        } else {
            dict[Self.arrowSIdentifier] = scale
            Self.log.log("ArrowS scale written to MCPerCursorScales: \(scale, privacy: .public)")
        }

        CFPreferencesSetValue(
            Self.perCursorScalesKey,
            dict as CFPropertyList,
            Self.domain,
            kCFPreferencesCurrentUser,
            kCFPreferencesCurrentHost
        )
        CFPreferencesSynchronize(
            Self.domain,
            kCFPreferencesCurrentUser,
            kCFPreferencesCurrentHost
        )
    }

    private func ensureCustomScaleMode() {
        // scale.m's customScaleMode() reads MCScaleMode from currentHost ONLY
        // (CFPreferencesCopyValue with kCFPreferencesCurrentHost — no anyHost
        // fallback).  So the authoritative value lives in currentHost; write it
        // through setCustomScaleMode() (the same call GeneralSettingsView uses).
        let mode = CFPreferencesCopyValue(
            Self.scaleModeKey,
            Self.domain,
            kCFPreferencesCurrentUser,
            kCFPreferencesCurrentHost
        ) as? String
        guard mode != "custom" else {
            Self.log.log("Scale mode already custom — no switch needed")
            return
        }

        Self.log.log("Scale mode is \(mode ?? "nil", privacy: .public) — switching to custom")
        setCustomScaleMode(true)
        _ = setCursorScale(1.0)
        Self.log.log("Switched scale mode to custom for ArrowS hotkey")
    }
}
