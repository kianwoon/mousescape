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

final class ArrowSHotkeyManager {

    static let shared = ArrowSHotkeyManager()

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
        installHandlerIfNeeded()
        registerHotkeysFromPrefs()
        observeConfigChanges()
        NSLog("[MousecapeHelper] ArrowS hotkey manager started")
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
            NSLog("[MousecapeHelper] InstallEventHandler failed: OSStatus \(status)")
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
            return noErr
        }

        applyHotkey(index: Int(hotKeyID.id))
        return noErr
    }

    // MARK: Registration

    private func registerHotkeysFromPrefs() {
        unregisterHotkeys()

        let configs = loadConfig()
        // Deterministic order (1 then 2) for readable logs.
        for index in configs.keys.sorted() {
            let cfg = configs[index]!
            var ref: EventHotKeyRef?
            let hotKeyID = EventHotKeyID(signature: Self.signature, id: UInt32(index))
            let status = RegisterEventHotKey(
                cfg.keyCode,
                cfg.modifiers,
                hotKeyID,
                GetApplicationEventTarget(),
                0,
                &ref
            )
            if status == noErr, let ref = ref {
                hotKeyRefs.append(ref)
                NSLog("[MousecapeHelper] Registered ArrowS hotkey \(index): keyCode=\(cfg.keyCode) modifiers=\(cfg.modifiers) scale=\(cfg.scale)")
            } else {
                NSLog("[MousecapeHelper] RegisterEventHotKey \(index) failed: OSStatus \(status)")
            }
        }
    }

    private func unregisterHotkeys() {
        for ref in hotKeyRefs {
            UnregisterEventHotKey(ref)
        }
        hotKeyRefs.removeAll()
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
                    manager.registerHotkeysFromPrefs()
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
            return [:]
        }

        var result: [Int: HotkeyConfig] = [:]
        for (name, value) in raw {
            guard let index = hotkeyIndex(fromName: name),
                  let entry = value as? [String: Any]
            else { continue }

            let keyCode = (entry["keyCode"] as? NSNumber)?.uint32Value
            let modifiers = (entry["modifiers"] as? NSNumber)?.uint32Value
            let scale = (entry["scale"] as? NSNumber)?.doubleValue

            // Missing entry / empty combo / no modifier → hotkey disabled.
            guard let kc = keyCode, let mods = modifiers, mods != 0, let sc = scale else {
                continue
            }
            result[index] = HotkeyConfig(keyCode: kc, modifiers: mods, scale: sc)
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

    // MARK: Apply

    private func applyHotkey(index: Int) {
        // Re-read the scale from prefs every fire so Settings edits apply
        // without a Helper restart.
        guard let cfg = loadConfig()[index] else {
            NSLog("[MousecapeHelper] ArrowS hotkey \(index) fired but is not configured")
            return
        }

        NSLog("[MousecapeHelper] ArrowS hotkey \(index) fired: scale=\(cfg.scale)")

        // a. Write the per-cursor scale for ArrowS only (currentHost, matching
        //    the codebase's MCPerCursorScales scope).
        writeArrowSScale(cfg.scale)

        // b. Custom mode is required for per-cursor scales to take effect.
        ensureCustomScaleMode()

        // c. User-initiated apply (bypasses the shared wake cooldown).
        let success = applyCurrentCapeUserInitiated()
        NSLog("[MousecapeHelper] ArrowS hotkey \(index) apply \(success ? "succeeded" : "FAILED")")
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
        } else {
            dict[Self.arrowSIdentifier] = scale
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
        guard mode != "custom" else { return }

        setCustomScaleMode(true)
        _ = setCursorScale(1.0)
        NSLog("[MousecapeHelper] Switched scale mode to custom for ArrowS hotkey")
    }
}
