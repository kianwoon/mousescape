//
//  AppUpdater.swift
//  Mousecape
//
//  UI-facing state machine for "Check for Updates". All blocking work
//  (unzip, codesign check, bundle swap, launchctl) runs off the main actor.
//

import AppKit
import Observation

@MainActor
@Observable
final class AppUpdater {
    enum Phase: Equatable {
        case idle
        case checking
        case upToDate(current: String)
        case available(current: String, latest: String)
        case downloading(fraction: Double)
        case verifying
        case installing
        case restartingHelper
        case relaunching(helperNote: String?)
        case failed(message: String, downloadedApp: URL?)
    }

    private(set) var phase: Phase = .idle
    let config: UpdateConfig?

    private var pending: (release: GitHubRelease, version: SemanticVersion, asset: GitHubReleaseAsset)?

    init(config: UpdateConfig? = UpdateConfig.load()) {
        self.config = config
    }

    var isBusy: Bool {
        switch phase {
        case .checking, .downloading, .verifying, .installing, .restartingHelper, .relaunching: return true
        default: return false
        }
    }

    static var currentVersionString: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
    }

    // MARK: Check

    func checkForUpdates() {
        guard !isBusy else { return }
        guard let config else { return fail(AppUpdateError.configMissing) }
        let currentString = Self.currentVersionString
        guard let current = SemanticVersion(currentString) else {
            return fail(AppUpdateError.bundleVersionNotNewer(bundle: currentString, current: currentString))
        }
        phase = .checking
        pending = nil
        Task {
            do {
                let releases = try await AppUpdateInstaller(config: config).fetchReleases()
                guard let newest = UpdateReleaseSelection.newest(in: releases) else {
                    throw AppUpdateError.noReleases
                }
                guard UpdateReleaseSelection.isUpdate(newest.version, over: current) else {
                    phase = .upToDate(current: currentString)
                    return
                }
                guard let asset = UpdateReleaseSelection.appAsset(
                    of: newest.release, pattern: config.assetNamePattern,
                    versionPlaceholder: config.versionPlaceholder) else {
                    throw AppUpdateError.noAppAsset(newest.release.tagName)
                }
                pending = (newest.release, newest.version, asset)
                phase = .available(current: currentString, latest: newest.version.description)
            } catch {
                fail(error)
            }
        }
    }

    // MARK: Install

    func installPendingUpdate() {
        guard !isBusy, let config, let pending,
              let current = SemanticVersion(Self.currentVersionString),
              let bundleID = Bundle.main.bundleIdentifier else { return }
        let installer = AppUpdateInstaller(config: config)
        let target = Bundle.main.bundleURL
        phase = .downloading(fraction: 0)

        Task {
            var workDir: URL?
            do {
                let downloaded = try await installer.download(pending.asset) { fraction in
                    Task { @MainActor [weak self] in
                        if case .downloading = self?.phase { self?.phase = .downloading(fraction: fraction) }
                    }
                }
                workDir = downloaded.workDir

                phase = .verifying
                let app = try await Task.detached {
                    let app = try installer.extract(zip: downloaded.zip, workDir: downloaded.workDir,
                                                    expectedBundleID: bundleID)
                    _ = try installer.verify(app: app, expectedBundleID: bundleID, currentVersion: current)
                    return app
                }.value

                phase = .installing
                try await Task.detached { try installer.install(newApp: app, replacing: target) }.value

                phase = .restartingHelper
                let helper = await installer.restartHelper(installedApp: target)
                if let workDir { try? FileManager.default.removeItem(at: workDir) }

                let note: String?
                switch helper {
                case .verified: note = nil
                case .notLoaded: note = String(localized: "Helper was not running; it starts with the new app.")
                case .stale(let detail):
                    note = String(localized: "Helper restart could not be confirmed (\(detail)). Log out and back in if Click Assist misbehaves.")
                }
                phase = .relaunching(helperNote: note)
                try AppUpdateInstaller.scheduleRelaunch(of: target)
                // Give the user a moment to read a Helper warning before quitting.
                try? await Task.sleep(nanoseconds: note == nil ? 300_000_000 : 3_000_000_000)
                NSApp.terminate(nil)
            } catch {
                // Keep the verified app around when the user must install it by hand.
                if (error as? AppUpdateError)?.downloadedApp == nil, let workDir {
                    try? FileManager.default.removeItem(at: workDir)
                }
                fail(error)
            }
        }
    }

    func dismissStatus() {
        guard !isBusy else { return }
        phase = .idle
    }

    private func fail(_ error: Error) {
        let downloaded = (error as? AppUpdateError)?.downloadedApp
        phase = .failed(message: error.localizedDescription, downloadedApp: downloaded)
    }
}
