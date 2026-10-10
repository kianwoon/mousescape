//
//  HotkeyManager.swift
//  MousecapeHelper
//
//  N user-managed global hotkeys, each mapping a CursorType to a per-cursor
//  scale.  An entry = {identifier, key combo, scale}; the combo AND scale are
//  user-configured in the GUI Settings, persisted under the CFPreferences key
//  "MCCursorScaleHotkeys" (domain com.sdmj76.Mousecape, currentHost) as an
//  ARRAY of dicts:
//    { id: String (UUID), identifier: String (CursorType rawValue),
//      keyCode: Int (0 = disabled), modifiers: Int (Carbon mask, 0 = disabled),
//      scale: Double }
//
//  Uses Carbon RegisterEventHotKey so we do NOT need Accessibility /
//  Input-Monitoring permission and fire system-wide even when Mousecape is
//  not frontmost.  The Owner is this Helper (menu-bar login item, always on).
//
//  The mechanism is pure data: no hardcoded cursor identifier, slot count or
//  combo anywhere.
//

import Foundation
import AppKit
import Carbon.HIToolbox
import os

final class CursorHotkeyManager {

    static let shared = CursorHotkeyManager()

    // Visible (public-privacy) diagnostic channel. NSLog from this launchd
    // instance does not surface in the unified log, so we log through os_log
    // with an explicit subsystem + public privacy for every field.
    private static let log = Logger(subsystem: "com.sdmj76.MousecapeHelper", category: "CursorHotkeys")

    // MARK: Constants

    private static let domain = "com.sdmj76.Mousecape" as CFString
    private static let hotkeysKey = "MCCursorScaleHotkeys" as CFString
    private static let legacyHotkeysKey = "MCArrowSHotkeys" as CFString
    private static let perCursorScalesKey = "MCPerCursorScales" as CFString
    private static let scaleModeKey = "MCScaleMode" as CFString
    private static let changedNotification = "com.sdmj76.Mousecape.cursorHotkeysChanged"

    // The one identifier the legacy (2-slot) config always meant — used only by
    // the one-time migration, never by the registration/apply mechanism.
    private static let legacyIdentifier = "com.apple.coregraphics.ArrowS"

    // Hotkey identity uses only intentional modifier bits: cmd|shift|option|control|fn.
    // alphaLock (caps-lock state) and any other junk must never participate.
    private static let usableMask: UInt32 = 256 | 512 | 2048 | 4096 | 8192

    // Four-character signature 'MCHK' for our EventHotKeyIDs.
    private static let signature: OSType = 0x4D43484B

    private struct HotkeyEntry {
        let id: String
        let identifier: String
        let keyCode: UInt32
        let modifiers: UInt32
        let scale: Double
    }

    // MARK: State

    private var hotKeyRefs: [EventHotKeyRef] = []
    // Carbon id (index+1) → entry UUID for the CURRENTLY-registered generation.
    // Always describes exactly the refs in hotKeyRefs; reset on every
    // unregister/re-register.  Fire resolution must go through this map (never
    // array position) so a mid-list delete can't alias onto a different entry.
    private var generationMap: [UInt32: String] = [:]
    private var eventHandlerRef: EventHandlerRef?
    private var cfObserverContext: UnsafeMutableRawPointer?

    private init() {}

    // MARK: Lifecycle

    func start() {
        Self.log.log("Cursor hotkey manager start() invoked")
        installHandlerIfNeeded()
        migrateLegacyIfNeeded()
        registerHotkeysFromPrefs()
        observeConfigChanges()
        Self.log.log("Cursor hotkey manager started")
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
                let manager = Unmanaged<CursorHotkeyManager>
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
        applyHotkey(carbonId: hotKeyID.id)
        return noErr
    }

    // MARK: Registration

    private func registerHotkeysFromPrefs() {
        unregisterHotkeys()

        let entries = loadConfig()
        Self.log.log("Re/registering cursor hotkeys: \(entries.count, privacy: .public) entr(y/ies)")

        var seenCombos = Set<UInt64>()
        for (index, entry) in entries.enumerated() {
            let cleanMods = entry.modifiers & Self.usableMask

            // Disabled entry: no combo recorded.
            if entry.keyCode == 0 || cleanMods == 0 {
                Self.log.log("Entry \(index, privacy: .public) disabled (keyCode=\(entry.keyCode, privacy: .public) cleanMods=\(cleanMods, privacy: .public)) — skipped")
                continue
            }

            // Duplicate combo guard: first entry wins, never let a dup reach Carbon.
            let comboKey = (UInt64(entry.keyCode) << 32) | UInt64(cleanMods)
            if seenCombos.contains(comboKey) {
                Self.log.log("Entry \(index, privacy: .public) duplicate combo (keyCode=\(entry.keyCode, privacy: .public) cleanMods=\(cleanMods, privacy: .public)) — skipped")
                continue
            }
            seenCombos.insert(comboKey)

            var ref: EventHotKeyRef?
            let hotKeyID = EventHotKeyID(signature: Self.signature, id: UInt32(index + 1))
            let status = RegisterEventHotKey(
                entry.keyCode,
                cleanMods,
                hotKeyID,
                GetApplicationEventTarget(),
                0,
                &ref
            )
            if status == noErr, let ref = ref {
                hotKeyRefs.append(ref)
                generationMap[UInt32(index + 1)] = entry.id
                Self.log.log("Registered hotkey id=\(index + 1, privacy: .public): identifier=\(entry.identifier, privacy: .public) keyCode=\(entry.keyCode, privacy: .public) modifiers=\(cleanMods, privacy: .public) scale=\(entry.scale, privacy: .public)")
            } else {
                Self.log.error("RegisterEventHotKey id=\(index + 1, privacy: .public) FAILED: OSStatus \(status, privacy: .public) (identifier=\(entry.identifier, privacy: .public) rawMods=\(entry.modifiers, privacy: .public) cleanMods=\(cleanMods, privacy: .public))")
            }
        }
    }

    private func unregisterHotkeys() {
        for ref in hotKeyRefs {
            UnregisterEventHotKey(ref)
        }
        hotKeyRefs.removeAll()
        generationMap.removeAll()
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
                let manager = Unmanaged<CursorHotkeyManager>
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

    private func loadConfig() -> [HotkeyEntry] {
        guard let raw = CFPreferencesCopyValue(
            Self.hotkeysKey,
            Self.domain,
            kCFPreferencesCurrentUser,
            kCFPreferencesCurrentHost
        ) as? [[String: Any]] else {
            Self.log.log("MCCursorScaleHotkeys not present/parseable in currentHost — no entries")
            return []
        }

        Self.log.log("MCCursorScaleHotkeys raw read: \(raw.count, privacy: .public) raw entr(y/ies)")

        var result: [HotkeyEntry] = []
        for slot in raw {
            // Type-tolerant (see AppState.getPerCursorScale / SettingsView.loadPerCursorScales):
            // values may be NSString after `defaults write` CLI or script edits.
            guard let identifier = slot["identifier"] as? String, !identifier.isEmpty,
                  let keyCode = Self.number(slot["keyCode"]),
                  let modifiers = Self.number(slot["modifiers"]),
                  let scale = Self.number(slot["scale"])
            else { continue }
            let id = (slot["id"] as? String) ?? UUID().uuidString
            result.append(HotkeyEntry(
                id: id,
                identifier: identifier,
                keyCode: UInt32(keyCode),
                modifiers: UInt32(modifiers),
                scale: scale
            ))
        }
        return result
    }

    /// One-time migration from the legacy 2-slot "MCArrowSHotkeys" dict to the
    /// new "MCCursorScaleHotkeys" array.  Idempotent; deletes the legacy key so
    /// no stale shadow remains.
    private func migrateLegacyIfNeeded() {
        if let existing = CFPreferencesCopyValue(
            Self.hotkeysKey,
            Self.domain,
            kCFPreferencesCurrentUser,
            kCFPreferencesCurrentHost
        ) as? [Any], !existing.isEmpty {
            return
        }

        guard let legacy = CFPreferencesCopyValue(
            Self.legacyHotkeysKey,
            Self.domain,
            kCFPreferencesCurrentUser,
            kCFPreferencesCurrentHost
        ) as? [String: Any], !legacy.isEmpty else {
            return
        }

        var migrated: [[String: Any]] = []
        for name in ["hotkey1", "hotkey2"] {
            guard let slot = legacy[name] as? [String: Any],
                  let keyCode = Self.number(slot["keyCode"]),
                  let modifiers = Self.number(slot["modifiers"]),
                  let scale = Self.number(slot["scale"])
            else { continue }
            migrated.append([
                "id": UUID().uuidString,
                "identifier": Self.legacyIdentifier,
                "keyCode": Int(keyCode),
                "modifiers": Int(modifiers),
                "scale": scale
            ])
        }

        guard !migrated.isEmpty else { return }

        CFPreferencesSetValue(
            Self.hotkeysKey,
            migrated as CFPropertyList,
            Self.domain,
            kCFPreferencesCurrentUser,
            kCFPreferencesCurrentHost
        )
        CFPreferencesSynchronize(Self.domain, kCFPreferencesCurrentUser, kCFPreferencesCurrentHost)
        // Remove the legacy key so it can never shadow the new config.
        CFPreferencesSetValue(
            Self.legacyHotkeysKey,
            nil,
            Self.domain,
            kCFPreferencesCurrentUser,
            kCFPreferencesCurrentHost
        )
        CFPreferencesSynchronize(Self.domain, kCFPreferencesCurrentUser, kCFPreferencesCurrentHost)
        Self.log.log("Migrated \(migrated.count, privacy: .public) legacy ArrowS hotkey(s) to MCCursorScaleHotkeys; removed legacy key")
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

    private func applyHotkey(carbonId: UInt32) {
        // Re-read the config fresh from prefs every fire so Settings edits
        // apply without a Helper restart.  Resolve the entry by UUID via the
        // registration-generation map — NOT by array position — so a mid-list
        // delete cannot alias this fire onto a different entry.
        let entries = loadConfig()
        guard let uuid = generationMap[carbonId],
              let entry = entries.first(where: { $0.id == uuid }) else {
            Self.log.log("Stale hotkey fire ignored (entry deleted): id=\(carbonId, privacy: .public)")
            return
        }

        Self.log.log("Hotkey id=\(carbonId, privacy: .public) applying: entry=\(entry.id, privacy: .public) identifier=\(entry.identifier, privacy: .public) scale=\(entry.scale, privacy: .public)")

        // a. Write the per-cursor scale for this entry's cursor only (currentHost,
        //    matching the codebase's MCPerCursorScales scope).
        writeCursorScale(identifier: entry.identifier, rawScale: entry.scale)

        // b. Custom mode is required for per-cursor scales to take effect.
        ensureCustomScaleMode()

        // c. User-initiated apply (bypasses the shared wake cooldown).
        let success = applyCurrentCapeUserInitiated()
        Self.log.log("Hotkey id=\(carbonId, privacy: .public) apply result: \(success ? "succeeded" : "FAILED", privacy: .public)")
    }

    private func writeCursorScale(identifier: String, rawScale: Double) {
        let scale = min(max(0.5, rawScale), 96.0)

        var dict = (CFPreferencesCopyValue(
            Self.perCursorScalesKey,
            Self.domain,
            kCFPreferencesCurrentUser,
            kCFPreferencesCurrentHost
        ) as? [String: Any]) ?? [:]

        if abs(scale - 1.0) < 0.01 {
            // Keep the dict clean: 1.0 means "no override".
            dict.removeValue(forKey: identifier)
            Self.log.log("Scale removed from MCPerCursorScales for \(identifier, privacy: .public) (scale≈1.0)")
        } else {
            dict[identifier] = scale
            Self.log.log("Scale written to MCPerCursorScales for \(identifier, privacy: .public): \(scale, privacy: .public)")
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
        Self.log.log("Switched scale mode to custom for cursor hotkey")
    }
}
