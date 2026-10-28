//
//  SettingsView.swift
//  Mousecape
//
//  Settings view with left sidebar navigation
//  Integrated into main window via page switcher
//

import SwiftUI
import AppKit
import ServiceManagement
import Carbon.HIToolbox
import Observation

struct SettingsView: View {
    @State private var selectedCategory: SettingsCategory = .general
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @Environment(AppState.self) private var appState

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            // Left sidebar: Category list
            List(SettingsCategory.allCases, selection: $selectedCategory) { category in
                Label(String(localized: String.LocalizationValue(category.title)), systemImage: category.icon)
                    .tag(category)
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            .navigationSplitViewColumnWidth(min: 150, ideal: 180, max: 220)
        } detail: {
            // Right: Settings content based on selected category
            settingsContent
                .scrollContentBackground(.hidden)
                .transition(.opacity.animation(.easeInOut(duration: 0.2)))
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button(action: {
                    appState.currentPage = .home
                }) {
                    Image(systemName: "chevron.left")
                }
                .help("Back")
            }
        }
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
    }

    @ViewBuilder
    private var settingsContent: some View {
        switch selectedCategory {
        case .general:
            GeneralSettingsView()
        case .appearance:
            AppearanceSettingsView()
        case .clickAssist:
            ClickAssistSettingsView()
        case .advanced:
            AdvancedSettingsView()
        }
    }
}

// MARK: - General Settings

struct GeneralSettingsView: View {
    @AppStorage("launchAtLogin") private var launchAtLogin = false
    @AppStorage("doubleClickAction") private var doubleClickAction = 0
    @State private var cursorScale: Double = 1.0
    @State private var scaleMode: ScaleMode = .global
    @State private var isLeftHanded: Bool = false
    @State private var applyTask: Task<Void, Never>?
    @State private var loginToggleError: String?
    @State private var showLoginError = false
    @State private var isPointerCustomized: Bool = isSystemPointerColorCustomized()
    @Environment(AppState.self) private var appState

    /// The key used by ObjC code for cursor scale
    private static let cursorScaleKey = "MCCursorScale"
    private static let scaleModeKey = "MCScaleMode"
    private static let perCursorScalesKey = "MCPerCursorScales"
    private static let handednessKey = "MCHandedness"
    private static let globalCursorScaleKey = "MCGlobalCursorScale"
    private static let preferenceDomain = "com.sdmj76.Mousecape"

    var body: some View {
        Form {
            if isPointerCustomized {
                Section {
                    HStack(spacing: 10) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.yellow)
                            .font(.title3)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(String(localized: "Pointer Color Conflict"))
                                .font(.headline)
                            Text(String(localized: "Mousecape cannot apply custom cursors because your system pointer color has been changed. Go to System Settings > Accessibility > Display > Pointer and tap \"Reset Color\"."))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button {
                            openAccessibilityPointerSettings()
                        } label: {
                            Text(String(localized: "Fix"))
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                    .padding(.vertical, 4)
                }
            }

            Section("Startup") {
                Toggle("Apply at Login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, newValue in
                        // Control MousecapeHelper's launch-at-login registration only
                        let helper = SMAppService.loginItem(identifier: "com.sdmj76.MousecapeHelper")
                        do {
                            if newValue {
                                try helper.register()
                                debugLog("Helper registered for launch-at-login")
                            } else {
                                try helper.unregister()
                                debugLog("Helper unregistered from launch-at-login")
                            }
                        } catch {
                            launchAtLogin = !newValue
                            loginToggleError = error.localizedDescription
                            showLoginError = true
                            debugLog("Failed to update helper status: \(error)")
                        }
                    }
            }

            Section("Double-click Action") {
                Picker("When double-clicking a Cape", selection: $doubleClickAction) {
                    Text("Apply Cape").tag(0)
                    Text("Edit Cape").tag(1)
                    Text("Do Nothing").tag(2)
                }
            }

            Section("Cursor Scale") {
                Picker("Scale Mode", selection: $scaleMode) {
                    ForEach(ScaleMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .onChange(of: scaleMode) { _, newValue in
                    saveScaleMode(newValue)
                    if newValue == .global {
                        // Reload the actual global scale from preferences (may differ from stale UI state)
                        loadCursorScale()
                        // Restore global scale
                        _ = setCursorScale(Float(cursorScale))
                        saveCursorScale(cursorScale)
                    }
                    // Do NOT call refreshSystemDefaultCursors() — per v1.2.0,
                    // settings changes should not auto-apply cursors.
                }

                if scaleMode == .global {
                    VStack(alignment: .leading) {
                        HStack {
                            Text("Global Scale:")
                            TextField("1.0", value: $cursorScale, format: .number.precision(.fractionLength(1)))
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 70)
                                .multilineTextAlignment(.trailing)
                            Text("x")
                        }
                        Slider(value: $cursorScale, in: 0.5...96.0, step: 0.1) {
                        } minimumValueLabel: {
                            Text("0.5x")
                        } maximumValueLabel: {
                            Text("96.0x")
                        } onEditingChanged: { editing in
                            if !editing {
                                // Scale saved via onChange below — no refreshSystemDefaultCursors()
                            }
                        }
                        .onChange(of: cursorScale) { _, newValue in
                            saveCursorScale(newValue)
                            _ = setCursorScale(Float(newValue))
                        }

                        Text("Scale changes are applied immediately.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    NavigationLink("Configure Per-Cursor Scales...") {
                        CustomScaleView()
                    }
                }
            }

            Section("Cursor Scale Hotkeys") {
                CursorHotkeySettingsContent()
                Text("Pressing a hotkey resizes only its chosen cursor system-wide.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Cursor") {
                Picker("Cursor Direction", selection: Binding(
                    get: { isLeftHanded },
                    set: { newValue in
                        isLeftHanded = newValue
                        saveHandedness(newValue)
                    }
                )) {
                    Text("Right Hand").tag(false)
                    Text("Left Hand").tag(true)
                }
                .pickerStyle(.segmented)

                Text("Left-hand mode mirror cursors horizontally.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .navigationTitle("General")
        .onAppear {
            loadScaleMode()  // This now also calls loadCursorScale()
            loadHandedness()
            isPointerCustomized = isSystemPointerColorCustomized()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willBecomeActiveNotification)) { _ in
            isPointerCustomized = isSystemPointerColorCustomized()
        }
        .alert("Login Item Error", isPresented: $showLoginError) {
            Button("OK") { }
        } message: {
            Text(loginToggleError ?? "")
        }
    }

    /// Load cursor scale from CFPreferences (same as ObjC code)
    private func loadCursorScale() {
        // In global mode, use the separate global scale preference (not MCCursorScale which custom mode overwrites)
        if scaleMode == .global {
            if let value = CFPreferencesCopyAppValue(Self.globalCursorScaleKey as CFString, Self.preferenceDomain as CFString) as? Double {
                cursorScale = value
            } else if let value = CFPreferencesCopyAppValue(Self.cursorScaleKey as CFString, Self.preferenceDomain as CFString) as? Double {
                cursorScale = value
            } else {
                cursorScale = 1.0
            }
        } else {
            // In custom mode, show the current system scale (maxScale from MCCursorScale)
            if let value = CFPreferencesCopyAppValue(Self.cursorScaleKey as CFString, Self.preferenceDomain as CFString) as? Double {
                cursorScale = value
            } else {
                cursorScale = 1.0
            }
        }
    }

    /// Save cursor scale to CFPreferences (same as ObjC code)
    private func saveCursorScale(_ value: Double) {
        // Save to separate global scale key so custom mode doesn't overwrite it
        CFPreferencesSetAppValue(
            Self.globalCursorScaleKey as CFString,
            value as CFNumber,
            Self.preferenceDomain as CFString
        )
        CFPreferencesAppSynchronize(Self.preferenceDomain as CFString)
        // Also save to MCCursorScale for applySavedCursorScale() and apply.m
        CFPreferencesSetAppValue(
            Self.cursorScaleKey as CFString,
            value as CFNumber,
            Self.preferenceDomain as CFString
        )
        CFPreferencesAppSynchronize(Self.preferenceDomain as CFString)
    }

    /// Load handedness from CFPreferences (same as ObjC MCFlag)
    private func loadHandedness() {
        if let value = CFPreferencesCopyAppValue(Self.handednessKey as CFString, Self.preferenceDomain as CFString) {
            isLeftHanded = (value as? NSNumber)?.boolValue ?? false
        } else {
            isLeftHanded = false
        }
    }

    /// Save handedness to CFPreferences and UserDefaults (for @AppStorage reactivity)
    private func saveHandedness(_ leftHanded: Bool) {
        let intValue = leftHanded ? 1 : 0
        CFPreferencesSetAppValue(
            Self.handednessKey as CFString,
            intValue as CFNumber,
            Self.preferenceDomain as CFString
        )
        CFPreferencesAppSynchronize(Self.preferenceDomain as CFString)
        // Also write to UserDefaults so @AppStorage("MCHandedness") in preview views updates reactively
        UserDefaults.standard.set(intValue, forKey: Self.handednessKey)
    }

    /// Load scale mode from CFPreferences and sync C global variable
    private func loadScaleMode() {
        if let value = CFPreferencesCopyAppValue(Self.scaleModeKey as CFString, Self.preferenceDomain as CFString) as? String,
           let mode = ScaleMode(rawValue: value) {
            scaleMode = mode
        } else {
            scaleMode = .global
        }
        // CRITICAL: Sync the C global variable so apply.m reads the correct mode
        setCustomScaleMode(scaleMode == .custom)
        // Reload cursor scale for the current mode
        loadCursorScale()
    }

    /// Save scale mode to CFPreferences
    private func saveScaleMode(_ mode: ScaleMode) {
        CFPreferencesSetAppValue(
            Self.scaleModeKey as CFString,
            mode.rawValue as CFString,
            Self.preferenceDomain as CFString
        )
        CFPreferencesAppSynchronize(Self.preferenceDomain as CFString)
        // Set direct C variable for reliable in-process communication with ObjC
        setCustomScaleMode(mode == .custom)
    }
}

struct AppearanceSettingsView: View {
    @AppStorage("showPreviewAnimations") private var showPreviewAnimations = true
    @AppStorage("showAuthorInfo") private var showAuthorInfo = true
    @AppStorage("previewGridColumns") private var previewGridColumns = 0
    @AppStorage("previewDisplayMode") private var previewDisplayMode = 0
    @State private var innerShadowEnabled: Bool = false
    @State private var outerGlowEnabled: Bool = false
    @State private var outerShadowEnabled: Bool = false
    @Environment(AppState.self) private var appState

    private static let innerShadowKey = "MCInnerShadow"
    private static let outerGlowKey = "MCOuterGlow"
    private static let outerShadowKey = "MCOuterShadow"
    private static let preferenceDomain = "com.sdmj76.Mousecape"

    var body: some View {
        Form {
            Section("List Display") {
                Toggle("Show Cursor Preview Animations", isOn: $showPreviewAnimations)
                Toggle("Show Cape Author Info", isOn: $showAuthorInfo)
            }

            Section("Preview Panel") {
                Picker("Display Mode", selection: $previewDisplayMode) {
                    Text("Simple (Windows Style)").tag(0)
                    Text("Advanced (macOS Style)").tag(1)
                }

                Picker("Preview Grid Columns", selection: $previewGridColumns) {
                    Text("Auto (based on window size)").tag(0)
                    Text("4 \(String(localized:"columns"))").tag(4)
                    Text("6 \(String(localized:"columns"))").tag(6)
                    Text("8 \(String(localized:"columns"))").tag(8)
                }
            }

            Section("Effects") {
                Toggle("Inner Shadow", isOn: $innerShadowEnabled)
                    .onChange(of: innerShadowEnabled) { _, newValue in
                        saveInnerShadow(newValue)
                    }

                Text("Adds an inner shadow effect to cursor edges for better visibility.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Toggle("Outer Glow", isOn: $outerGlowEnabled)
                    .onChange(of: outerGlowEnabled) { _, newValue in
                        saveOuterGlow(newValue)
                    }

                Text("Adds a soft glow around the cursor for better visibility on any background.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Toggle("Outer Shadow", isOn: $outerShadowEnabled)
                    .onChange(of: outerShadowEnabled) { _, newValue in
                        saveOuterShadow(newValue)
                    }

                Text("Adds a dark shadow around the cursor for contrast on light backgrounds.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .navigationTitle("Appearance")
        .onAppear {
            if let value = CFPreferencesCopyAppValue(Self.innerShadowKey as CFString, Self.preferenceDomain as CFString) {
                innerShadowEnabled = (value as? NSNumber)?.boolValue ?? false
            }
            if let value = CFPreferencesCopyAppValue(Self.outerGlowKey as CFString, Self.preferenceDomain as CFString) {
                outerGlowEnabled = (value as? NSNumber)?.boolValue ?? false
            }
            if let value = CFPreferencesCopyAppValue(Self.outerShadowKey as CFString, Self.preferenceDomain as CFString) {
                outerShadowEnabled = (value as? NSNumber)?.boolValue ?? false
            }
        }
    }

    private func saveInnerShadow(_ enabled: Bool) {
        let intValue = enabled ? 1 : 0
        CFPreferencesSetAppValue(Self.innerShadowKey as CFString, intValue as CFNumber, Self.preferenceDomain as CFString)
        CFPreferencesAppSynchronize(Self.preferenceDomain as CFString)
    }

    private func saveOuterGlow(_ enabled: Bool) {
        let intValue = enabled ? 1 : 0
        CFPreferencesSetAppValue(Self.outerGlowKey as CFString, intValue as CFNumber, Self.preferenceDomain as CFString)
        CFPreferencesAppSynchronize(Self.preferenceDomain as CFString)
    }

    private func saveOuterShadow(_ enabled: Bool) {
        let intValue = enabled ? 1 : 0
        CFPreferencesSetAppValue(Self.outerShadowKey as CFString, intValue as CFNumber, Self.preferenceDomain as CFString)
        CFPreferencesAppSynchronize(Self.preferenceDomain as CFString)
    }
}

// MARK: - Advanced Settings

struct AdvancedSettingsView: View {
    @State private var showResetConfirmation = false
    @State private var isExportingLogs = false
    @State private var showResetCursorSuccess = false
    @State private var showResetOrderSuccess = false
    @Environment(AppState.self) private var appState

    var body: some View {
        Form {
            Section("Storage") {
                LabeledContent("Cape Folder") {
                    Text("~/Library/Application Support/Mousecape/capes")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Button("Show in Finder") {
                    appState.openCapeFolder()
                }
            }

            Section("Reset") {
                HStack {
                    Button("Reset System Cursor") {
                        appState.resetToDefault()
                        showResetCursorSuccess = true
                    }

                    Button("Reset Sidebar Order") {
                        appState.resetCapeOrder()
                        showResetOrderSuccess = true
                    }

                    Button("Dump System Cursors") {
                        appState.dumpSystemCursors()
                    }

                    Button("Restore Default Settings", role: .destructive) {
                        showResetConfirmation = true
                    }
                }
                .confirmationDialog(
                    "Restore Default Settings",
                    isPresented: $showResetConfirmation,
                    titleVisibility: .visible
                ) {
                    Button("Restore Default Settings", role: .destructive) {
                        resetToDefaults()
                    }
                    Button("Cancel", role: .cancel) { }
                } message: {
                    Text("This will reset all settings to their default values. This action cannot be undone.")
                }
            }

            #if DEBUG
            Section("Debug") {
                LabeledContent("Log Folder") {
                    Text("~/Library/Logs/Mousecape")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                LabeledContent("Log Files") {
                    let files = DebugLogger.getAllLogFiles()
                    let size = DebugLogger.getTotalLogSize()
                    Text("\(files.count) files, \(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                HStack {
                    Button("Open Log Folder") {
                        NSWorkspace.shared.open(DebugLogger.logsDirectory)
                    }

                    Button("Export All Logs") {
                        exportLogs()
                    }
                    .disabled(isExportingLogs)

                    Button("Clear All Logs", role: .destructive) {
                        DebugLogger.clearAllLogs()
                    }
                }

                Text("Logs are automatically deleted after 24 hours. Logs contain debug information for troubleshooting cursor issues.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            #endif

            Section("About") {
                LabeledContent("Version") {
                    if let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String,
                       let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String {
                        Text("Mousecape v\(version) (\(build))")
                    } else {
                        Text("Mousecape v1.3.1")
                    }
                }
                LabeledContent("System Requirements") {
                    Text("macOS 15+")
                }
                LabeledContent("Original Author") {
                    Text("\u{00A9} 2014-2025 Alex Zielenski")
                }
                LabeledContent("SwiftUI Redesign") {
                    Text("\u{00A9} 2025 sdmj76")
                }

                HStack {
                    Button("Check for Updates") {
                        checkForUpdates()
                    }
                    Button("GitHub") {
                        if let url = URL(string: "https://github.com/sdmj76/Mousecape-swiftUI") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    Button("Report Issue") {
                        if let url = URL(string: "https://github.com/sdmj76/Mousecape-swiftUI/issues") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .navigationTitle("Advanced")
        .alert(
            "Reset System Cursor",
            isPresented: $showResetCursorSuccess
        ) {
            Button("OK", role: .cancel) { }
        } message: {
            Text("System cursor has been reset to default.")
        }
        .alert(
            "Reset Sidebar Order",
            isPresented: $showResetOrderSuccess
        ) {
            Button("OK", role: .cancel) { }
        } message: {
            Text("Sidebar order has been reset to alphabetical.")
        }
    }

    private func resetToDefaults() {
        // Reset all settings to defaults
        let defaults = UserDefaults.standard
        let domain = Bundle.main.bundleIdentifier!
        defaults.removePersistentDomain(forName: domain)
    }

    #if DEBUG
    private func exportLogs() {
        isExportingLogs = true

        DispatchQueue.global(qos: .userInitiated).async {
            guard let zipURL = DebugLogger.exportLogsAsZip() else {
                DispatchQueue.main.async {
                    isExportingLogs = false
                }
                return
            }

            DispatchQueue.main.async {
                isExportingLogs = false

                // Use NSSavePanel to let user choose save location
                let savePanel = NSSavePanel()
                savePanel.allowedContentTypes = [.zip]
                savePanel.nameFieldStringValue = zipURL.lastPathComponent
                savePanel.canCreateDirectories = true
                savePanel.title = String(localized: "Export Debug Logs")

                if savePanel.runModal() == .OK, let destURL = savePanel.url {
                    do {
                        // Remove existing file if any
                        try? FileManager.default.removeItem(at: destURL)
                        try FileManager.default.copyItem(at: zipURL, to: destURL)

                        // Clean up temp file
                        try? FileManager.default.removeItem(at: zipURL)

                        // Show in Finder
                        NSWorkspace.shared.selectFile(destURL.path, inFileViewerRootedAtPath: "")
                    } catch {
                        debugLog("Failed to save logs: \(error.localizedDescription)")
                    }
                } else {
                    // Clean up temp file if user cancelled
                    try? FileManager.default.removeItem(at: zipURL)
                }
            }
        }
    }
    #endif

    private func checkForUpdates() {
        // Open GitHub releases page for manual update checking
        if let url = URL(string: "https://github.com/sdmj76/Mousecape-swiftUI/releases") {
            NSWorkspace.shared.open(url)
        }
    }
}

// MARK: - Preview

#Preview {
    SettingsView()
        .environment(AppState.shared)
        .frame(width: 600, height: 500)
}

// MARK: - Custom Scale View

struct CustomScaleView: View {
    @Environment(AppState.self) private var appState
    @State private var perCursorScales: [String: Double] = [:]
    @State private var selectedCursorType: CursorType? = nil
    @State private var showSetAllAlert = false
    @State private var setAllValue: Double = 1.0
    @State private var hasUnsavedScaleChanges = false

    private static let perCursorScalesKey = "MCPerCursorScales"
    private static let cursorScaleKey = "MCCursorScale"
    private static let preferenceDomain = "com.sdmj76.Mousecape"

    var body: some View {
        HStack(spacing: 0) {
            // Left column: cursor type list
            List(CursorType.allCases, selection: $selectedCursorType) { cursorType in
                HStack {
                    Text(cursorType.displayName)
                    Spacer()
                    if let scale = perCursorScales[cursorType.rawValue], scale != 1.0 {
                        Text("\(scale, specifier: "%.1f")x")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
                .tag(cursorType)
            }
            .listStyle(.sidebar)
            .frame(minWidth: 220, idealWidth: 260)

            Divider()

            // Right column: scale control
            if let selected = selectedCursorType {
                VStack(alignment: .leading, spacing: 16) {
                    Text(selected.displayName)
                        .font(.title2)
                        .fontWeight(.semibold)

                    Text(selected.rawValue)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)

                    let currentScale = perCursorScales[selected.rawValue] ?? 1.0
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Scale:")
                                .font(.headline)
                            TextField("1.0", value: Binding(
                                get: { currentScale },
                                set: { newValue in
                                    perCursorScales[selected.rawValue] = newValue
                                    savePerCursorScales()
                                }
                            ), format: .number.precision(.fractionLength(1)))
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 70)
                                .multilineTextAlignment(.trailing)
                                .font(.headline)
                            Text("x")
                                .font(.headline)
                        }
                        Slider(value: Binding(
                            get: { currentScale },
                            set: { newValue in
                                perCursorScales[selected.rawValue] = newValue
                                savePerCursorScales()
                            }
                        ), in: 0.5...96.0, step: 0.5) {
                        } minimumValueLabel: {
                            Text("0.5x")
                        } maximumValueLabel: {
                            Text("96.0x")
                        } onEditingChanged: { isEditing in
                            if !isEditing {
                                recalculateMaxScaleAndApply()
                                hasUnsavedScaleChanges = false
                            }
                        }
                    }

                    HStack(spacing: 12) {
                        Button("Reset to 1.0x") {
                            updateScale(for: selected, to: 1.0)
                            hasUnsavedScaleChanges = false
                        }
                        .buttonStyle(.bordered)

                        Button("Set All to This") {
                            setAllValue = currentScale
                            showSetAllAlert = true
                        }
                        .buttonStyle(.bordered)
                    }

                    Spacer()

                    HStack {
                        Button("Reset All to 1.0x") {
                            resetAllScales()
                            hasUnsavedScaleChanges = false
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.red)
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                VStack {
                    Text("Select a cursor type")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                    Text("Choose a cursor from the list to configure its scale.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .navigationTitle("Custom Scales")
        .onAppear {
            loadPerCursorScales()
            hasUnsavedScaleChanges = false
        }
        .onDisappear {
            // Scale preferences are already saved — user double-clicks cape to apply
        }
        .alert("Set All Scales", isPresented: $showSetAllAlert) {
            Button("Cancel", role: .cancel) { }
            Button("Set All") {
                setAllScales(to: setAllValue)
                hasUnsavedScaleChanges = false
            }
        } message: {
            Text("Set all cursor scales to \(setAllValue, specifier: "%.1f")x?")
        }
    }

    private func loadPerCursorScales() {
        // TYPE-TOLERANT load (2026-08-27): the dict may hold values as
        // NSString (e.g. written by `defaults write -dict` scripts) instead
        // of NSNumber.  A strict `as? [String: Double]` then fails → the
        // page showed every cursor at 1.0x ("settings gone") and a save
        // from that state wiped the real values.  Accept both.
        guard let raw = CFPreferencesCopyValue(
            Self.perCursorScalesKey as CFString,
            Self.preferenceDomain as CFString,
            kCFPreferencesCurrentUser,
            kCFPreferencesCurrentHost
        ) as? [String: Any] else {
            perCursorScales = [:]
            return
        }
        var dict: [String: Double] = [:]
        for (k, v) in raw {
            if let d = v as? Double { dict[k] = d }
            else if let s = v as? String, let d = Double(s) { dict[k] = d }
            else if let n = v as? NSNumber { dict[k] = n.doubleValue }
        }
        perCursorScales = dict
    }

    private func savePerCursorScales() {
        // MERGE instead of overwrite (2026-08-27): the in-memory dict is an
        // onAppear snapshot and can be stale if anything else (Helper, CLI,
        // or a previous editor session) updated keys meanwhile.  Writing the
        // whole snapshot silently reverted those changes — the "my size got
        // overridden" report.  Merge: disk wins for keys we haven't touched
        // in this editor session, memory wins for the ones we changed.
        if let disk = CFPreferencesCopyValue(
            Self.perCursorScalesKey as CFString,
            Self.preferenceDomain as CFString,
            kCFPreferencesCurrentUser,
            kCFPreferencesCurrentHost
        ) as? [String: Double] {
            for (k, v) in disk where perCursorScales[k] == nil {
                perCursorScales[k] = v
            }
        }
        CFPreferencesSetValue(
            Self.perCursorScalesKey as CFString,
            perCursorScales as CFPropertyList,
            Self.preferenceDomain as CFString,
            kCFPreferencesCurrentUser,
            kCFPreferencesCurrentHost
        )
        CFPreferencesSynchronize(Self.preferenceDomain as CFString, kCFPreferencesCurrentUser, kCFPreferencesCurrentHost)
    }

    private func updateScale(for cursorType: CursorType, to value: Double) {
        perCursorScales[cursorType.rawValue] = value
        savePerCursorScales()
        recalculateMaxScaleAndApply()
    }

    private func resetAllScales() {
        perCursorScales = [:]
        savePerCursorScales()
        recalculateMaxScaleAndApply()
    }

    private func setAllScales(to value: Double) {
        for cursorType in CursorType.allCases {
            perCursorScales[cursorType.rawValue] = value
        }
        savePerCursorScales()
        recalculateMaxScaleAndApply()
    }

    private func recalculateMaxScaleAndApply() {
        // Custom mode: CGSSetCursorScale = 1.0, each cursor registers at its
        // desired point size directly (nativeSize × desiredScale).
        let baseScale = 1.0
        // Save baseScale to MCCustomMaxScale for listen.m/session restore
        CFPreferencesSetAppValue(
            "MCCustomMaxScale" as CFString,
            baseScale as CFNumber,
            Self.preferenceDomain as CFString
        )
        CFPreferencesAppSynchronize(Self.preferenceDomain as CFString)
        // Set system scale immediately for visual feedback (lightweight CGS call)
        _ = setCursorScale(Float(baseScale))
        // Do NOT call refreshSystemDefaultCursors() here — it re-registers all
        // cursors including cape ones, causing inner shadow to double.
        // Scale changes take effect on next explicit Apply (per v1.2.0 design).
    }
}

// MARK: - Cursor Scale Hotkeys

/// N user-managed global hotkeys, each mapping a chosen CursorType to a
/// per-cursor scale.  An entry = {cursor type, key combo, scale}; the combo +
/// scale are the whole mechanism — no cursor identifier, slot count or combo is
/// hardcoded.  Changes are persisted to CFPreferences (currentHost) and
/// announced to the Helper via a Darwin notification, which re-registers the
/// Carbon hotkeys at runtime.
struct CursorHotkeySettingsContent: View {

    private struct HotkeyEntry: Identifiable {
        var id: UUID
        var cursorType: CursorType
        var keyCode: UInt16?
        var modifiers: UInt32
        var scale: Double
    }

    private static let domain = "com.sdmj76.Mousecape"
    private static let hotkeysKey = "MCCursorScaleHotkeys"
    private static let legacyHotkeysKey = "MCArrowSHotkeys"
    private static let changedNotification = "com.sdmj76.Mousecape.cursorHotkeysChanged"
    private static let defaultScale = 2.0

    @State private var entries: [HotkeyEntry] = []
    @State private var recordingID: UUID? = nil
    @State private var monitor: Any? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Grid(alignment: .center, horizontalSpacing: 8, verticalSpacing: 8) {
                ForEach($entries) { entry in
                    GridRow {
                        picker(entry: entry)
                        hotkeyButton(entry: entry)
                        scaleField(entry: entry)
                        Text("x")
                        deleteButton(entry: entry)
                    }
                }
            }
            HStack {
                Button {
                    addEntry()
                } label: {
                    Label("Add Hotkey", systemImage: "plus")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                Spacer()
            }
        }
        .onAppear { load() }
        .onDisappear { cancelRecording() }
    }

    // MARK: Row controls

    @ViewBuilder
    private func picker(entry: Binding<HotkeyEntry>) -> some View {
        Picker("", selection: entry.cursorType) {
            ForEach(CursorType.allCases) { type in
                Text(type.displayName).tag(type)
            }
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .frame(maxWidth: 140)
        .onChange(of: entry.wrappedValue.cursorType) { _, _ in persist() }
    }

    @ViewBuilder
    private func hotkeyButton(entry: Binding<HotkeyEntry>) -> some View {
        Button {
            startRecording(entry.wrappedValue.id)
        } label: {
            Text(recordingID == entry.wrappedValue.id ? "Press keys…" : comboLabel(entry.wrappedValue))
                .frame(minWidth: 80)
        }
        .buttonStyle(.bordered)
        .controlSize(.regular)
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color.accentColor, lineWidth: recordingID == entry.wrappedValue.id ? 2 : 0)
        )
    }

    @ViewBuilder
    private func scaleField(entry: Binding<HotkeyEntry>) -> some View {
        TextField("", value: Binding(
            get: { entry.wrappedValue.scale },
            set: { newValue in
                entry.wrappedValue.scale = min(max(0.5, newValue), 96.0)
                persist()
            }
        ), format: .number.precision(.fractionLength(1)))
            .textFieldStyle(.roundedBorder)
            .controlSize(.regular)
            .labelsHidden()
            .frame(width: 70)
            .multilineTextAlignment(.trailing)
    }

    @ViewBuilder
    private func deleteButton(entry: Binding<HotkeyEntry>) -> some View {
        Button(role: .destructive) {
            deleteEntry(id: entry.wrappedValue.id)
        } label: {
            Image(systemName: "minus.circle.fill")
        }
        .buttonStyle(.borderless)
    }

    // MARK: Recording

    private func startRecording(_ id: UUID) {
        cancelRecording()
        recordingID = id
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { event in
            handleRecordEvent(event)
            return nil   // swallow while recording
        }
    }

    private func cancelRecording() {
        if let monitor = monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
        recordingID = nil
    }

    private func handleRecordEvent(_ event: NSEvent) {
        guard let id = recordingID,
              let index = entries.firstIndex(where: { $0.id == id }) else {
            cancelRecording()
            return
        }
        let keyCode = event.keyCode

        // Escape cancels recording.
        if keyCode == 53 { cancelRecording(); return }

        // Hotkey identity uses only intentional modifier bits.  Strip capsLock
        // and every non-modifier flag (function/numericPad/help) so the stored
        // Carbon mask never contains state bits like alphaLock.
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        var carbon: UInt32 = 0
        if flags.contains(.command) { carbon |= UInt32(cmdKey) }
        if flags.contains(.shift)   { carbon |= UInt32(shiftKey) }
        if flags.contains(.option)  { carbon |= UInt32(optionKey) }
        if flags.contains(.control) { carbon |= UInt32(controlKey) }
        let usableMask: UInt32 = 256 | 512 | 2048 | 4096 | 8192  // cmd|shift|option|control|fn
        carbon &= usableMask

        if carbon == 0 {
            // Plain Delete/Backspace (no modifier) clears the hotkey.
            if keyCode == 51 || keyCode == 117 {
                entries[index].keyCode = nil
                entries[index].modifiers = 0
                persist()
                cancelRecording()
            }
            // Otherwise keep waiting — a plain key would hijack normal typing.
            return
        }

        entries[index].keyCode = keyCode
        entries[index].modifiers = carbon
        persist()
        cancelRecording()
    }

    // MARK: Persistence

    private func load() {
        migrateLegacyIfNeeded()
        guard let raw = CFPreferencesCopyValue(
            Self.hotkeysKey as CFString,
            Self.domain as CFString,
            kCFPreferencesCurrentUser,
            kCFPreferencesCurrentHost
        ) as? [[String: Any]] else {
            entries = []
            return
        }
        var loaded: [HotkeyEntry] = []
        for slot in raw {
            guard let identifier = slot["identifier"] as? String,
                  let cursorType = CursorType(rawValue: identifier),
                  let keyCode = Self.number(slot["keyCode"]),
                  let modifiers = Self.number(slot["modifiers"]),
                  let scale = Self.number(slot["scale"])
            else { continue }
            let id = (slot["id"] as? String).flatMap(UUID.init(uuidString:)) ?? UUID()
            loaded.append(HotkeyEntry(
                id: id,
                cursorType: cursorType,
                keyCode: keyCode == 0 ? nil : UInt16(keyCode),
                modifiers: UInt32(modifiers),
                scale: scale
            ))
        }
        entries = loaded
    }

    private func persist() {
        let array: [[String: Any]] = entries.map { entry in
            [
                "id": entry.id.uuidString,
                "identifier": entry.cursorType.rawValue,
                "keyCode": Int(entry.keyCode ?? 0),
                "modifiers": Int(entry.modifiers),
                "scale": entry.scale
            ]
        }
        CFPreferencesSetValue(
            Self.hotkeysKey as CFString,
            array as CFPropertyList,
            Self.domain as CFString,
            kCFPreferencesCurrentUser,
            kCFPreferencesCurrentHost
        )
        CFPreferencesSynchronize(
            Self.domain as CFString,
            kCFPreferencesCurrentUser,
            kCFPreferencesCurrentHost
        )
        // Tell the Helper to re-register the Carbon hotkeys immediately.
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(Self.changedNotification as CFString),
            nil,
            nil,
            true
        )
    }

    private func addEntry() {
        entries.append(HotkeyEntry(id: UUID(), cursorType: .arrow, keyCode: nil, modifiers: 0, scale: Self.defaultScale))
        persist()
    }

    private func deleteEntry(id: UUID) {
        entries.removeAll { $0.id == id }
        persist()
    }

    /// One-time migration from the legacy 2-slot "MCArrowSHotkeys" dict to the
    /// new "MCCursorScaleHotkeys" array.  Idempotent; deletes the legacy key so
    /// no stale shadow remains.
    private func migrateLegacyIfNeeded() {
        if let existing = CFPreferencesCopyValue(
            Self.hotkeysKey as CFString,
            Self.domain as CFString,
            kCFPreferencesCurrentUser,
            kCFPreferencesCurrentHost
        ) as? [Any], !existing.isEmpty {
            return
        }
        guard let legacy = CFPreferencesCopyValue(
            Self.legacyHotkeysKey as CFString,
            Self.domain as CFString,
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
                "identifier": CursorType.arrowS.rawValue,
                "keyCode": Int(keyCode),
                "modifiers": Int(modifiers),
                "scale": scale
            ])
        }
        guard !migrated.isEmpty else { return }
        CFPreferencesSetValue(
            Self.hotkeysKey as CFString,
            migrated as CFPropertyList,
            Self.domain as CFString,
            kCFPreferencesCurrentUser,
            kCFPreferencesCurrentHost
        )
        CFPreferencesSynchronize(Self.domain as CFString, kCFPreferencesCurrentUser, kCFPreferencesCurrentHost)
        // Remove the legacy key so it can never shadow the new config.
        CFPreferencesSetValue(
            Self.legacyHotkeysKey as CFString,
            nil,
            Self.domain as CFString,
            kCFPreferencesCurrentUser,
            kCFPreferencesCurrentHost
        )
        CFPreferencesSynchronize(Self.domain as CFString, kCFPreferencesCurrentUser, kCFPreferencesCurrentHost)
    }

    /// Type-tolerant numeric parse: CFPreferences values may arrive as NSNumber,
    /// Double, or NSString (from `defaults write` CLI / script edits).
    private static func number(_ value: Any?) -> Double? {
        if let d = value as? Double { return d }
        if let s = value as? String { return Double(s) }
        if let n = value as? NSNumber { return n.doubleValue }
        return nil
    }

    // MARK: Display helpers

    private func comboLabel(_ entry: HotkeyEntry) -> String {
        guard let keyCode = entry.keyCode else { return "Not Set" }
        return modifierSymbols(entry.modifiers) + keyLabel(keyCode)
    }

    private func modifierSymbols(_ modifiers: UInt32) -> String {
        var symbols = ""
        if modifiers & UInt32(controlKey) != 0 { symbols += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { symbols += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { symbols += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { symbols += "⌘" }
        return symbols
    }

    private func keyLabel(_ keyCode: UInt16) -> String {
        switch Int(keyCode) {
        case kVK_ANSI_A: return "A"
        case kVK_ANSI_B: return "B"
        case kVK_ANSI_C: return "C"
        case kVK_ANSI_D: return "D"
        case kVK_ANSI_E: return "E"
        case kVK_ANSI_F: return "F"
        case kVK_ANSI_G: return "G"
        case kVK_ANSI_H: return "H"
        case kVK_ANSI_I: return "I"
        case kVK_ANSI_J: return "J"
        case kVK_ANSI_K: return "K"
        case kVK_ANSI_L: return "L"
        case kVK_ANSI_M: return "M"
        case kVK_ANSI_N: return "N"
        case kVK_ANSI_O: return "O"
        case kVK_ANSI_P: return "P"
        case kVK_ANSI_Q: return "Q"
        case kVK_ANSI_R: return "R"
        case kVK_ANSI_S: return "S"
        case kVK_ANSI_T: return "T"
        case kVK_ANSI_U: return "U"
        case kVK_ANSI_V: return "V"
        case kVK_ANSI_W: return "W"
        case kVK_ANSI_X: return "X"
        case kVK_ANSI_Y: return "Y"
        case kVK_ANSI_Z: return "Z"
        case kVK_ANSI_0: return "0"
        case kVK_ANSI_1: return "1"
        case kVK_ANSI_2: return "2"
        case kVK_ANSI_3: return "3"
        case kVK_ANSI_4: return "4"
        case kVK_ANSI_5: return "5"
        case kVK_ANSI_6: return "6"
        case kVK_ANSI_7: return "7"
        case kVK_ANSI_8: return "8"
        case kVK_ANSI_9: return "9"
        case kVK_ANSI_Minus: return "-"
        case kVK_ANSI_Equal: return "="
        case kVK_ANSI_LeftBracket: return "["
        case kVK_ANSI_RightBracket: return "]"
        case kVK_ANSI_Semicolon: return ";"
        case kVK_ANSI_Quote: return "'"
        case kVK_ANSI_Comma: return ","
        case kVK_ANSI_Period: return "."
        case kVK_ANSI_Slash: return "/"
        case kVK_ANSI_Backslash: return "\\"
        case kVK_ANSI_Grave: return "`"
        case kVK_Return: return "↩"
        case kVK_Tab: return "⇥"
        case kVK_Space: return "Space"
        case kVK_Delete: return "⌫"
        case kVK_ForwardDelete: return "⌦"
        case kVK_Escape: return "⎋"
        case kVK_LeftArrow: return "←"
        case kVK_RightArrow: return "→"
        case kVK_UpArrow: return "↑"
        case kVK_DownArrow: return "↓"
        case kVK_Home: return "↖"
        case kVK_End: return "↘"
        case kVK_PageUp: return "⇞"
        case kVK_PageDown: return "⇟"
        case kVK_F1: return "F1"
        case kVK_F2: return "F2"
        case kVK_F3: return "F3"
        case kVK_F4: return "F4"
        case kVK_F5: return "F5"
        case kVK_F6: return "F6"
        case kVK_F7: return "F7"
        case kVK_F8: return "F8"
        case kVK_F9: return "F9"
        case kVK_F10: return "F10"
        case kVK_F11: return "F11"
        case kVK_F12: return "F12"
        default: return "Key \(keyCode)"
        }
    }
}

// MARK: - Click Assist Settings

/// App-side Click Assist settings bridge. It only reads/writes preferences and
/// NEVER creates a tap, resolver or overlay: the persistent ClickAssistAgent is
/// the sole runtime host. The app target does not compile the engine/host
/// sources at all, so a second host cannot be started by accident.
@MainActor
@Observable
final class ClickAssistSettingsModel {
    static let shared = ClickAssistSettingsModel()

    private let prefs = ClickAssistPreferences()
    private(set) var config: ClickAssistConfig
    private var prefObserverRegistered = false

    private init() {
        config = prefs.readConfig()
        registerForPrefChanges()
    }

    /// Re-sync the explicit domain and re-read/validate ALL keys.
    func refreshFromPreferences() {
        CFPreferencesSynchronize(ClickAssistPreferences.domain as CFString,
                                 kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        registerForPrefChanges()
        config = prefs.readConfig()
    }

    var requestedSummary: String {
        "Requested: \(config.enabled ? "Enabled" : "Disabled") · " +
        String(format: "%.1f pt", config.tolerancePoints) +
        " · Indicator \(config.indicatorEnabled ? "On" : "Off")"
    }

    // MARK: - requests (prefs only; the agent reacts via Darwin notification)

    func requestEnabled(_ value: Bool) {
        guard value != config.enabled else { return }
        prefs.writeEnabled(value)
        config = prefs.readConfig()
    }

    func requestTolerancePoints(_ value: CGFloat) {
        let clamped = ClickAssistConfig.validated(enabled: config.enabled,
                                                  tolerancePoints: value,
                                                  indicatorEnabled: config.indicatorEnabled).tolerancePoints
        guard clamped != config.tolerancePoints else { return }
        prefs.writeTolerancePoints(clamped)
        config = prefs.readConfig()
    }

    func requestIndicatorEnabled(_ value: Bool) {
        guard value != config.indicatorEnabled else { return }
        prefs.writeIndicatorEnabled(value)
        config = prefs.readConfig()
    }

    // MARK: - external pref change observation

    private func registerForPrefChanges() {
        guard !prefObserverRegistered else { return }
        prefObserverRegistered = true
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                        Unmanaged.passUnretained(self).toOpaque(),
                                        Self.prefChangedCallback,
                                        ClickAssistPreferences.changedNotification as CFString,
                                        nil, .deliverImmediately)
    }

    private static let prefChangedCallback: CFNotificationCallback = { _, observer, _, _, _ in
        guard let observer else { return }
        let model = Unmanaged<ClickAssistSettingsModel>.fromOpaque(observer).takeUnretainedValue()
        Task { @MainActor in model.refreshFromPreferences() }
    }
}

/// Reads the agent's runtime status record (file = truth). The Darwin
/// notification is only a hint to re-read; the timer covers a missed hint and a
/// stale heartbeat covers an agent that died without cleaning up.
@MainActor
@Observable
final class ClickAssistStatusObserver {
    private(set) var text = "Not running — agent unavailable"
    private(set) var isActive = false

    private var timer: Timer?
    private var isObserving = false

    func start() {
        guard !isObserving else { return }
        isObserving = true
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            Unmanaged.passUnretained(self).toOpaque(),
            Self.changedCallback,
            ClickAssistStatusStore.changedNotification as CFString,
            nil, .deliverImmediately)
        timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        refresh()
    }

    func stop() {
        guard isObserving else { return }
        isObserving = false
        CFNotificationCenterRemoveObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            Unmanaged.passUnretained(self).toOpaque(),
            CFNotificationName(rawValue: ClickAssistStatusStore.changedNotification as CFString),
            nil)
        timer?.invalidate()
        timer = nil
    }

    func refresh() {
        guard let record = ClickAssistStatusStore.read() else {
            text = "Not running — agent unavailable"
            isActive = false
            return
        }
        // Stale heartbeat => the agent is not actually running, whatever the file says.
        guard Date().timeIntervalSince(record.heartbeat) <= ClickAssistStatusStore.staleThreshold else {
            text = "Not running — agent unavailable"
            isActive = false
            return
        }
        text = record.displayText()
        isActive = record.state == .active
    }

    private static let changedCallback: CFNotificationCallback = { _, observer, _, _, _ in
        guard let observer else { return }
        let status = Unmanaged<ClickAssistStatusObserver>.fromOpaque(observer).takeUnretainedValue()
        Task { @MainActor in status.refresh() }
    }
}

/// Click Assist settings controls. Values are read from the preference bridge's
/// validated snapshot (no @AppStorage shadow copy); every mutation writes the pref
/// domain and the agent picks it up via Darwin notification.
struct ClickAssistSettingsView: View {
    @State private var assist = ClickAssistSettingsModel.shared
    @State private var status = ClickAssistStatusObserver()
    @State private var agentLoginItem = SMAppService.loginItem(identifier: ClickAssistSettingsView.agentBundleIdentifier).status == .enabled
    @State private var loginItemError: String?
    @Environment(AppState.self) private var appState
    private static let agentBundleIdentifier = "com.sdmj76.ClickAssistAgent"

    var body: some View {
        Form {
            Section("Click Assist") {
                Toggle("Enable Click Assist", isOn: Binding(
                    get: { assist.config.enabled },
                    set: { appState.setClickAssistEnabled($0) }))

                HStack(spacing: 12) {
                    Text("Tolerance")
                    Slider(value: Binding(
                        get: { Double(assist.config.tolerancePoints) },
                        set: { assist.requestTolerancePoints(CGFloat($0)) }),
                           in: Double(ClickAssistConfig.toleranceRange.lowerBound)...Double(ClickAssistConfig.toleranceRange.upperBound),
                           step: 0.5)
                    Text(String(format: "%.1f pt", assist.config.tolerancePoints))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(width: 60, alignment: .trailing)
                }

                Toggle("Show targeting indicator", isOn: Binding(
                    get: { assist.config.indicatorEnabled },
                    set: { assist.requestIndicatorEnabled($0) }))
            }

            Section("Agent") {
                Toggle("Run Click Assist Agent at login", isOn: $agentLoginItem)
                    .onChange(of: agentLoginItem) { _, newValue in
                        updateLoginItem(newValue)
                    }
                Text("Keeps assist running after Mousecape quits.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let loginItemError {
                    Text(loginItemError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            Section("Status") {
                Text(assist.requestedSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    Circle()
                        .fill(status.isActive ? Color.green : Color.orange)
                        .frame(width: 8, height: 8)
                    Text(status.text)
                        .foregroundStyle(.secondary)
                }
                Text("Runtime reported by the Click Assist Agent; requested values above are your settings.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            assist.refreshFromPreferences()
            status.start()
            agentLoginItem = SMAppService.loginItem(identifier: Self.agentBundleIdentifier).status == .enabled
        }
        .onDisappear {
            status.stop()
        }
    }

    /// Register/unregister the embedded login item from the app side.
    private func updateLoginItem(_ enabled: Bool) {
        let service = SMAppService.loginItem(identifier: Self.agentBundleIdentifier)
        do {
            if enabled {
                try service.register()
            } else {
                try service.unregister()
            }
            loginItemError = nil
        } catch {
            loginItemError = error.localizedDescription
            agentLoginItem = (service.status == .enabled)
        }
    }
}
