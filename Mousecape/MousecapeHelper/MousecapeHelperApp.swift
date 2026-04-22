//
//  MousecapeHelperApp.swift
//  MousecapeHelper
//
//  Created by Claude Code on 2026-03-06.
//

import SwiftUI
import ServiceManagement

@main
struct MousecapeHelperApp: App {
    @NSApplicationDelegateAdaptor(HelperAppDelegate.self) var appDelegate
    @StateObject private var cursorState = CursorState()

    var body: some Scene {
        MenuBarExtra("Mousecape", image: "MenuBarIcon") {
            MenuBarContentView()
                .environmentObject(cursorState)
                .onAppear {
                    // Refresh state when menu opens
                    cursorState.refresh()
                }
        }
    }
}

class HelperAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Initialize logging
        #if DEBUG
        MCLoggerInit()
        #endif
        debugLog("MousecapeHelper started")

        // Start session monitoring to keep cursors persistent
        startSessionMonitor()
        debugLog("Session monitor started")

        // Watch for wake-from-sleep as a backup re-apply trigger
        // The CGDisplay reconfiguration callback handles most cases, but
        // on some hardware it fires late or not at all after wake.
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(workspaceDidWake(_:)),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )
        debugLog("Wake notification observer registered")
    }

    @objc private func workspaceDidWake(_ notification: Notification) {
        debugLog("System woke from sleep — re-applying cape in 2s...")
        // Delay 2s to let WindowServer settle after wake
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            var success = reapplyCapeForCurrentUser()
            if !success {
                // Retry up to 2 more times
                for attempt in 1...2 {
                    debugLog("Wake re-apply attempt \(attempt + 1)/3 failed, retrying in 2s...")
                    Thread.sleep(forTimeInterval: 2.0)
                    success = reapplyCapeForCurrentUser()
                    if success { break }
                }
            }
            debugLog("Wake re-apply final result: \(success ? "SUCCESS" : "FAILED")")
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        debugLog("MousecapeHelper terminating")
        // Remove display reconfiguration callback to prevent firing during teardown
        stopSessionMonitor()
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        #if DEBUG
        MCLoggerClose()
        #endif
    }
}
