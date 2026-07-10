//
//  SettingsView.swift
//  Mousecape
//
//  Settings view with left sidebar navigation
//  Integrated into main window via page switcher
//

import SwiftUI
import ServiceManagement

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
        if let dict = CFPreferencesCopyAppValue(Self.perCursorScalesKey as CFString, Self.preferenceDomain as CFString) as? [String: Double] {
            perCursorScales = dict
        } else {
            perCursorScales = [:]
        }
    }

    private func savePerCursorScales() {
        CFPreferencesSetAppValue(
            Self.perCursorScalesKey as CFString,
            perCursorScales as CFPropertyList,
            Self.preferenceDomain as CFString
        )
        CFPreferencesAppSynchronize(Self.preferenceDomain as CFString)
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
