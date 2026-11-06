//
//  UpdateConfig.swift
//  Mousecape
//
//  Self-updater configuration. Every value comes from the `MCUpdater` dictionary in
//  Mousecape-Info.plist; the views and the updater never carry repo names or URLs.
//  `APIBaseURL` can be overridden per user with
//  `defaults write com.sdmj76.Mousecape <APIBaseURLOverrideDefaultsKey> <url>`
//  (used to exercise the install path against a local test server). Whatever the
//  source, a downloaded app must still satisfy the running app's designated code
//  requirement before it is installed.
//

import Foundation

struct UpdateConfig: Sendable {
    let apiBaseURL: URL
    let webBaseURL: URL
    let repoOwner: String
    let repoName: String
    let assetNamePattern: String
    let versionPlaceholder: String
    let releasesPageSize: Int
    let requestTimeout: TimeInterval
    let helperBundleRelativePath: String
    let helperLaunchdLabel: String
    let helperRestartVerifyAttempts: Int

    static let infoDictionaryKey = "MCUpdater"

    /// Loads from the main bundle. Nil when the Info.plist block is missing or
    /// malformed — the About section then disables update checks instead of guessing.
    static func load(bundle: Bundle = .main, defaults: UserDefaults = .standard) -> UpdateConfig? {
        guard let dict = bundle.object(forInfoDictionaryKey: infoDictionaryKey) as? [String: Any] else {
            return nil
        }
        func string(_ key: String) -> String? {
            (dict[key] as? String).flatMap { $0.isEmpty ? nil : $0 }
        }
        func int(_ key: String) -> Int? { (dict[key] as? NSNumber)?.intValue }

        var apiString = string("APIBaseURL")
        if let overrideKey = string("APIBaseURLOverrideDefaultsKey"),
           let override = defaults.string(forKey: overrideKey), !override.isEmpty {
            apiString = override
        }

        guard let apiString, let api = URL(string: apiString),
              let webString = string("WebBaseURL"), let web = URL(string: webString),
              let owner = string("RepoOwner"), let name = string("RepoName"),
              let pattern = string("AssetNamePattern"),
              let placeholder = string("VersionPlaceholder"),
              let pageSize = int("ReleasesPageSize"), pageSize > 0,
              let timeout = int("RequestTimeoutSeconds"), timeout > 0,
              let helperPath = string("HelperBundleRelativePath"),
              let helperLabel = string("HelperLaunchdLabel"),
              let attempts = int("HelperRestartVerifyAttempts"), attempts > 0
        else { return nil }

        return UpdateConfig(apiBaseURL: api, webBaseURL: web, repoOwner: owner, repoName: name,
                            assetNamePattern: pattern, versionPlaceholder: placeholder,
                            releasesPageSize: pageSize, requestTimeout: TimeInterval(timeout),
                            helperBundleRelativePath: helperPath, helperLaunchdLabel: helperLabel,
                            helperRestartVerifyAttempts: attempts)
    }

    /// GET <api>/repos/<owner>/<repo>/releases?per_page=<n>
    var releasesURL: URL {
        var components = URLComponents(
            url: apiBaseURL.appendingPathComponent("repos")
                .appendingPathComponent(repoOwner)
                .appendingPathComponent(repoName)
                .appendingPathComponent("releases"),
            resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "per_page", value: String(releasesPageSize))]
        return components?.url ?? apiBaseURL
    }

    var repositoryPageURL: URL {
        webBaseURL.appendingPathComponent(repoOwner).appendingPathComponent(repoName)
    }

    var issuesPageURL: URL { repositoryPageURL.appendingPathComponent("issues") }

    var releasesPageURL: URL { repositoryPageURL.appendingPathComponent("releases") }
}

/// System tools the installer shells out to. Absolute paths so a modified PATH
/// can never substitute a binary.
enum UpdaterTool {
    static let ditto = "/usr/bin/ditto"
    static let xattr = "/usr/bin/xattr"
    static let launchctl = "/bin/launchctl"
    static let lsof = "/usr/sbin/lsof"
    static let shell = "/bin/sh"
    static let open = "/usr/bin/open"
    static let quarantineAttribute = "com.apple.quarantine"
}
