//
//  AboutSectionView.swift
//  Mousecape
//
//  Settings → Advanced → About: version, requirements, developer credit,
//  project links and the self-updater ("Check for Updates").
//

import SwiftUI

struct AboutSectionView: View {
    @State private var updater = AppUpdater()
    @State private var confirmInstall = false

    private var versionText: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        // CFBundleVersion is not set by this project; show it only when a build provides one.
        guard let build = info?["CFBundleVersion"] as? String, !build.isEmpty, build != version else {
            return "Mousecape v\(version)"
        }
        return "Mousecape v\(version) (\(build))"
    }

    /// "15.0" -> "macOS 15+", read from the built Info.plist (LSMinimumSystemVersion).
    private var requirementsText: String {
        let minimum = Bundle.main.infoDictionary?["LSMinimumSystemVersion"] as? String ?? ""
        let major = minimum.split(separator: ".").first.map(String.init) ?? minimum
        return "macOS \(major)+"
    }

    var body: some View {
        Section {
            LabeledContent("Version") { Text(versionText) }
            LabeledContent("System Requirements") { Text(requirementsText) }
            LabeledContent("Developer") { Text(verbatim: "kianwoon") }

            HStack {
                Button("Check for Updates") { updater.checkForUpdates() }
                    .disabled(updater.config == nil || updater.isBusy)
                Button("GitHub") { open(updater.config?.repositoryPageURL) }
                    .disabled(updater.config == nil)
                Button("Report Issue") { open(updater.config?.issuesPageURL) }
                    .disabled(updater.config == nil)
            }

            statusRow
        } header: {
            Text("About")
        } footer: {
            Text("Special thanks to Alex Zielenski and sdmj76 for the inspiration and initial contribution.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .confirmationDialog("Install Update?", isPresented: $confirmInstall) {
            Button("Download and Install") { updater.installPendingUpdate() }
            Button("Cancel", role: .cancel) { }
        } message: {
            if case .available(let current, let latest) = updater.phase {
                Text("Mousecape v\(latest) will replace v\(current). Mousecape and its Helper restart afterwards.")
            }
        }
    }

    @ViewBuilder
    private var statusRow: some View {
        switch updater.phase {
        case .idle:
            EmptyView()
        case .checking:
            HStack { ProgressView().controlSize(.small); Text("Checking for updates…") }
        case .upToDate(let current):
            statusLine("Mousecape v\(current) is up to date.", systemImage: "checkmark.circle", tint: .green)
        case .available(_, let latest):
            HStack {
                statusLine("Update available: v\(latest)", systemImage: "arrow.down.circle", tint: .accentColor)
                Spacer()
                Button("Release Notes") { open(updater.config?.releasesPageURL) }
                Button("Install…") { confirmInstall = true }
                    .buttonStyle(.borderedProminent)
            }
        case .downloading(let fraction):
            ProgressView(value: fraction) { Text("Downloading update…") }
        case .verifying:
            HStack { ProgressView().controlSize(.small); Text("Verifying download…") }
        case .installing:
            HStack { ProgressView().controlSize(.small); Text("Installing…") }
        case .restartingHelper:
            HStack { ProgressView().controlSize(.small); Text("Restarting Mousecape Helper…") }
        case .relaunching(let note):
            VStack(alignment: .leading, spacing: 4) {
                statusLine("Update installed. Relaunching…", systemImage: "checkmark.circle", tint: .green)
                if let note { Text(note).font(.caption).foregroundStyle(.secondary) }
            }
        case .failed(let message, let downloadedApp):
            HStack(alignment: .top) {
                statusLine(message, systemImage: "exclamationmark.triangle", tint: .orange)
                Spacer()
                if let downloadedApp {
                    Button("Show in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([downloadedApp])
                    }
                }
                Button("Dismiss") { updater.dismissStatus() }
            }
        }
    }

    private func statusLine(_ text: String, systemImage: String, tint: Color) -> some View {
        Label {
            Text(text).textSelection(.enabled)
        } icon: {
            Image(systemName: systemImage).foregroundStyle(tint)
        }
    }

    private func open(_ url: URL?) {
        if let url { NSWorkspace.shared.open(url) }
    }
}
