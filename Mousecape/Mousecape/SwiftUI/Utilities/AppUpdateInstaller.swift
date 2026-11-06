//
//  AppUpdateInstaller.swift
//  Mousecape
//
//  The side-effecting half of the self-updater: download → extract → verify →
//  swap the bundle in place → restart the Helper login item from the NEW binary →
//  relaunch. Ordering guarantee: the installed app is only moved aside after the
//  new bundle is fully downloaded, extracted and verified, and it is moved back if
//  the swap fails.
//

import Foundation
import Security

enum AppUpdateError: LocalizedError {
    case configMissing
    case badHTTPStatus(Int, URL)
    case noReleases
    case noAppAsset(String)
    case extractFailed(String)
    case appNotFoundInArchive
    case wrongBundleIdentifier(found: String?, expected: String)
    case bundleVersionNotNewer(bundle: String, current: String)
    case helperMissing
    case signatureInvalid(OSStatus)
    case runningAppUnsigned
    case notWritable(URL, downloadedApp: URL)
    case swapFailed(String)

    var errorDescription: String? {
        switch self {
        case .configMissing:
            return String(localized: "Update settings are missing from this build.")
        case .badHTTPStatus(let code, let url):
            return String(localized: "Server returned HTTP \(code) for \(url.absoluteString).")
        case .noReleases:
            return String(localized: "No published release was found.")
        case .noAppAsset(let tag):
            return String(localized: "Release \(tag) has no single Mousecape zip to download.")
        case .extractFailed(let detail):
            return String(localized: "Could not unzip the update: \(detail)")
        case .appNotFoundInArchive:
            return String(localized: "The downloaded zip does not contain exactly one Mousecape.app.")
        case .wrongBundleIdentifier(let found, let expected):
            return String(localized: "Downloaded app is \(found ?? "unknown"), expected \(expected).")
        case .bundleVersionNotNewer(let bundle, let current):
            return String(localized: "The downloaded app reports version \(bundle), which is not newer than \(current). The release was probably built without a version bump.")
        case .helperMissing:
            return String(localized: "The downloaded app is missing its MousecapeHelper login item.")
        case .signatureInvalid(let status):
            return String(localized: "The downloaded app's code signature does not match this app (OSStatus \(status)).")
        case .runningAppUnsigned:
            return String(localized: "This copy of Mousecape is ad-hoc signed, so an update cannot be verified against it.")
        case .notWritable(let dir, _):
            return String(localized: "Mousecape can't write to \(dir.path). The verified update was kept so you can install it by hand.")
        case .swapFailed(let detail):
            return String(localized: "Replacing the app failed; the original app was restored. \(detail)")
        }
    }

    /// For `.notWritable`: the verified app the user can drag into place.
    var downloadedApp: URL? {
        if case .notWritable(_, let app) = self { return app }
        return nil
    }
}

/// Outcome of restarting the Helper login item from the freshly installed bundle.
enum HelperRestartResult: Equatable, Sendable {
    /// Running Helper's executable inode == installed file's inode.
    case verified(pid: pid_t)
    /// The Helper job is not loaded (login item disabled) — nothing to restart.
    case notLoaded
    /// Kickstarted, but the running Helper still maps a different file.
    case stale(detail: String)
}

struct AppUpdateInstaller: Sendable {
    let config: UpdateConfig

    // MARK: Check

    func fetchReleases() async throws -> [GitHubRelease] {
        var request = URLRequest(url: config.releasesURL, timeoutInterval: config.requestTimeout)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw AppUpdateError.badHTTPStatus(http.statusCode, config.releasesURL)
        }
        return try JSONDecoder().decode([GitHubRelease].self, from: data)
    }

    // MARK: Download + extract

    /// Downloads into a NEW empty directory under the user's temp dir.
    func download(_ asset: GitHubReleaseAsset,
                  progress: @escaping @Sendable (Double) -> Void) async throws -> (zip: URL, workDir: URL) {
        let workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MousecapeUpdate-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: false)

        var request = URLRequest(url: asset.browserDownloadURL, timeoutInterval: config.requestTimeout)
        request.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
        let delegate = DownloadProgressDelegate(expectedBytes: Int64(asset.size), onProgress: progress)
        let (tmp, response) = try await URLSession.shared.download(for: request, delegate: delegate)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            try? FileManager.default.removeItem(at: tmp)
            throw AppUpdateError.badHTTPStatus(http.statusCode, asset.browserDownloadURL)
        }
        let zip = workDir.appendingPathComponent(asset.name)
        try FileManager.default.moveItem(at: tmp, to: zip)
        progress(1)
        return (zip, workDir)
    }

    /// `ditto -xk` into `<workDir>/extracted`, then finds exactly one *.app whose
    /// bundle id matches. Absolute paths only — never cd into the archive.
    func extract(zip: URL, workDir: URL, expectedBundleID: String) throws -> URL {
        let dest = workDir.appendingPathComponent("extracted", isDirectory: true)
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: false)
        let result = try Self.run(UpdaterTool.ditto, ["-xk", zip.path, dest.path])
        guard result.status == 0 else { throw AppUpdateError.extractFailed(result.output) }

        // The app may sit at the top level or one folder down (zip of a folder).
        let fm = FileManager.default
        var apps: [URL] = []
        for item in (try? fm.contentsOfDirectory(at: dest, includingPropertiesForKeys: nil)) ?? [] {
            if item.pathExtension == "app" { apps.append(item); continue }
            if item.lastPathComponent == "__MACOSX" { continue }
            let inner = (try? fm.contentsOfDirectory(at: item, includingPropertiesForKeys: nil)) ?? []
            apps += inner.filter { $0.pathExtension == "app" }
        }
        let matching = apps.filter { Bundle(url: $0)?.bundleIdentifier == expectedBundleID }
        guard matching.count == 1, let app = matching.first else {
            if let other = apps.first, apps.count == 1 {
                throw AppUpdateError.wrongBundleIdentifier(found: Bundle(url: other)?.bundleIdentifier,
                                                            expected: expectedBundleID)
            }
            throw AppUpdateError.appNotFoundInArchive
        }
        return app
    }

    // MARK: Verify

    /// Gate before anything on disk is replaced:
    /// bundle id, Helper present, bundle version newer than the running one, and a
    /// strict deep signature check against the RUNNING app's designated requirement
    /// (same identifier + same signing certificate — which is also what keeps the
    /// Accessibility grant for Click Assist valid after the swap).
    func verify(app: URL, expectedBundleID: String, currentVersion: SemanticVersion) throws -> SemanticVersion {
        guard let bundle = Bundle(url: app), bundle.bundleIdentifier == expectedBundleID else {
            throw AppUpdateError.wrongBundleIdentifier(found: Bundle(url: app)?.bundleIdentifier,
                                                        expected: expectedBundleID)
        }
        let versionString = bundle.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
        guard let bundleVersion = SemanticVersion(versionString),
              UpdateReleaseSelection.isUpdate(bundleVersion, over: currentVersion) else {
            throw AppUpdateError.bundleVersionNotNewer(bundle: versionString, current: currentVersion.description)
        }
        let helper = app.appendingPathComponent(config.helperBundleRelativePath)
        guard Bundle(url: helper)?.executableURL.map({ FileManager.default.fileExists(atPath: $0.path) }) == true else {
            throw AppUpdateError.helperMissing
        }
        try Self.checkSignatureMatchesRunningApp(app)
        return bundleVersion
    }

    static func checkSignatureMatchesRunningApp(_ app: URL) throws {
        var selfCode: SecCode?
        var selfStatic: SecStaticCode?
        var requirement: SecRequirement?
        guard SecCodeCopySelf([], &selfCode) == errSecSuccess, let selfCode,
              SecCodeCopyStaticCode(selfCode, [], &selfStatic) == errSecSuccess, let selfStatic,
              SecCodeCopyDesignatedRequirement(selfStatic, [], &requirement) == errSecSuccess,
              let requirement else {
            throw AppUpdateError.runningAppUnsigned
        }
        // An ad-hoc signature's designated requirement is its own cdhash, which no
        // other build can ever satisfy — say so instead of a confusing mismatch.
        var reqText: CFString?
        if SecRequirementCopyString(requirement, [], &reqText) == errSecSuccess,
           let text = reqText as String?, text.hasPrefix("cdhash") {
            throw AppUpdateError.runningAppUnsigned
        }

        var newStatic: SecStaticCode?
        let created = SecStaticCodeCreateWithPath(app as CFURL, [], &newStatic)
        guard created == errSecSuccess, let newStatic else { throw AppUpdateError.signatureInvalid(created) }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode)
        let status = SecStaticCodeCheckValidity(newStatic, flags, requirement)
        guard status == errSecSuccess else { throw AppUpdateError.signatureInvalid(status) }
    }

    // MARK: Install

    /// Swaps `newApp` into `target` (the running bundle's location).
    /// 1. ditto-copy into a hidden staging bundle NEXT TO the target (same volume,
    ///    so the swap is two renames) and re-verify the staged copy;
    /// 2. rename target → hidden backup; rename staging → target
    ///    (on failure: rename the backup back);
    /// 3. strip quarantine; delete the backup.
    func install(newApp: URL, replacing target: URL) throws {
        let fm = FileManager.default
        let parent = target.deletingLastPathComponent()
        guard fm.isWritableFile(atPath: parent.path) else {
            throw AppUpdateError.notWritable(parent, downloadedApp: newApp)
        }
        let token = UUID().uuidString
        let staged = parent.appendingPathComponent(".\(target.deletingPathExtension().lastPathComponent)-update-\(token).app")
        let backup = parent.appendingPathComponent(".\(target.deletingPathExtension().lastPathComponent)-backup-\(token).app")

        let copy = try Self.run(UpdaterTool.ditto, [newApp.path, staged.path])
        guard copy.status == 0 else {
            try? fm.removeItem(at: staged)
            throw AppUpdateError.notWritable(parent, downloadedApp: newApp)
        }
        do {
            try Self.checkSignatureMatchesRunningApp(staged)
        } catch {
            try? fm.removeItem(at: staged)
            throw error
        }

        do {
            try fm.moveItem(at: target, to: backup)
        } catch {
            try? fm.removeItem(at: staged)
            throw AppUpdateError.swapFailed(error.localizedDescription)
        }
        do {
            try fm.moveItem(at: staged, to: target)
        } catch {
            try? fm.moveItem(at: backup, to: target)
            try? fm.removeItem(at: staged)
            throw AppUpdateError.swapFailed(error.localizedDescription)
        }

        _ = try? Self.run(UpdaterTool.xattr, ["-dr", UpdaterTool.quarantineAttribute, target.path])
        try? fm.removeItem(at: backup)
    }

    // MARK: Helper

    /// `launchctl kickstart -k` the Helper so launchd starts it from the NEW file,
    /// then confirm the running Helper's executable inode equals the installed one
    /// (AGENTS.md §1 stale-Helper trap: a KeepAlive relaunch can race the copy).
    func restartHelper(installedApp: URL) async -> HelperRestartResult {
        let helperURL = installedApp.appendingPathComponent(config.helperBundleRelativePath)
        guard let executable = Bundle(url: helperURL)?.executableURL,
              let installedInode = Self.inode(of: executable) else {
            return .stale(detail: String(localized: "Installed Helper executable not found."))
        }
        let domain = "gui/\(getuid())/\(config.helperLaunchdLabel)"
        guard let printed = try? Self.run(UpdaterTool.launchctl, ["print", domain]), printed.status == 0 else {
            return .notLoaded
        }
        guard let kick = try? Self.run(UpdaterTool.launchctl, ["kickstart", "-k", domain]), kick.status == 0 else {
            return .stale(detail: String(localized: "launchctl kickstart failed."))
        }

        var lastDetail = ""
        for _ in 0..<config.helperRestartVerifyAttempts {
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard let pid = Self.launchdPID(domain: domain) else {
                lastDetail = String(localized: "Helper not running yet.")
                continue
            }
            if let running = Self.textInode(pid: pid, executableName: executable.lastPathComponent),
               running == installedInode {
                return .verified(pid: pid)
            }
            lastDetail = String(localized: "Helper pid \(pid) still maps an old executable.")
        }
        return .stale(detail: lastDetail)
    }

    // MARK: Relaunch

    /// Detached shell waits for this process to exit, then opens the new bundle.
    static func scheduleRelaunch(of app: URL) throws {
        let script = "while /bin/kill -0 \"$1\" 2>/dev/null; do /bin/sleep 0.2; done; exec \"$3\" -n \"$2\""
        let process = Process()
        process.executableURL = URL(fileURLWithPath: UpdaterTool.shell)
        process.arguments = ["-c", script, "sh", String(getpid()), app.path, UpdaterTool.open]
        try process.run()
    }

    // MARK: Process helpers

    struct RunResult { let status: Int32; let output: String }

    @discardableResult
    static func run(_ tool: String, _ args: [String]) throws -> RunResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return RunResult(status: process.terminationStatus,
                         output: String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
    }

    static func inode(of url: URL) -> UInt64? {
        var st = stat()
        guard stat(url.path, &st) == 0 else { return nil }
        return UInt64(st.st_ino)
    }

    /// `launchctl print` reports "pid = N" for a running job.
    static func launchdPID(domain: String) -> pid_t? {
        guard let result = try? run(UpdaterTool.launchctl, ["print", domain]), result.status == 0 else { return nil }
        for line in result.output.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("pid = "), let pid = pid_t(trimmed.dropFirst("pid = ".count)) {
                return pid
            }
        }
        return nil
    }

    /// Inode of the `txt` mapping whose path ends in "/MacOS/<executableName>".
    /// lsof -F records: "i<inode>" precedes "n<path>" for each file.
    static func textInode(pid: pid_t, executableName: String) -> UInt64? {
        guard let result = try? run(UpdaterTool.lsof, ["-a", "-p", String(pid), "-d", "txt", "-F", "in"]),
              result.status == 0 else { return nil }
        var currentInode: UInt64?
        for line in result.output.split(separator: "\n") {
            if line.hasPrefix("i") {
                currentInode = UInt64(line.dropFirst())
            } else if line.hasPrefix("n"), line.hasSuffix("/MacOS/" + executableName) {
                return currentInode
            }
        }
        return nil
    }
}

/// Task-scoped download delegate: reports byte progress to the UI.
private final class DownloadProgressDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let expectedBytes: Int64
    private let onProgress: @Sendable (Double) -> Void

    init(expectedBytes: Int64, onProgress: @escaping @Sendable (Double) -> Void) {
        self.expectedBytes = expectedBytes
        self.onProgress = onProgress
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        let total = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : expectedBytes
        guard total > 0 else { return }
        onProgress(min(1, Double(totalBytesWritten) / Double(total)))
    }

    // Required by the protocol; the async download(for:delegate:) API returns the file.
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {}
}
