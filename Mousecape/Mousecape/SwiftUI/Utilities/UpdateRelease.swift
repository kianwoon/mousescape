//
//  UpdateRelease.swift
//  Mousecape
//
//  GitHub release model + the pure decisions the updater makes from it:
//  which release is newest, and which asset of that release is the app zip.
//  Foundation only — unit-tested by Tools/UpdaterTests.
//

import Foundation

struct GitHubReleaseAsset: Decodable, Equatable, Sendable {
    let name: String
    let size: Int
    let browserDownloadURL: URL

    enum CodingKeys: String, CodingKey {
        case name, size
        case browserDownloadURL = "browser_download_url"
    }
}

struct GitHubRelease: Decodable, Equatable, Sendable {
    let tagName: String
    let name: String?
    let draft: Bool
    let prerelease: Bool
    let htmlURL: URL?
    let assets: [GitHubReleaseAsset]

    enum CodingKeys: String, CodingKey {
        case name, draft, prerelease, assets
        case tagName = "tag_name"
        case htmlURL = "html_url"
    }

    var version: SemanticVersion? { SemanticVersion(tagName) }
}

enum UpdateReleaseSelection {
    /// The highest-versioned published release. `/releases/latest` is NOT used:
    /// GitHub orders it by publish date, so an older line published later (e.g.
    /// v1.4.2-click-assist after v1.5.0) would win. Drafts, GitHub-flagged
    /// pre-releases and tags that are not versions are skipped.
    static func newest(in releases: [GitHubRelease]) -> (release: GitHubRelease, version: SemanticVersion)? {
        releases
            .filter { !$0.draft && !$0.prerelease }
            .compactMap { r in r.version.map { (release: r, version: $0) } }
            .max { $0.version < $1.version }
    }

    /// Picks the downloadable app zip of a release.
    /// 1. The asset whose name equals `pattern` with `{version}` replaced by the tag
    ///    version (tag without the leading "v").
    /// 2. Otherwise the release's only `.zip` asset.
    /// Returns nil when nothing matches or several zips make the choice ambiguous.
    static func appAsset(of release: GitHubRelease, pattern: String,
                         versionPlaceholder: String) -> GitHubReleaseAsset? {
        let tagVersion = release.tagName.hasPrefix("v") || release.tagName.hasPrefix("V")
            ? String(release.tagName.dropFirst()) : release.tagName
        let expected = pattern.replacingOccurrences(of: versionPlaceholder, with: tagVersion)
        if let exact = release.assets.first(where: { $0.name == expected }) {
            return exact
        }
        let zips = release.assets.filter { $0.name.lowercased().hasSuffix(".zip") }
        return zips.count == 1 ? zips[0] : nil
    }

    /// Whether `candidate` should be offered over the running `current` version.
    static func isUpdate(_ candidate: SemanticVersion, over current: SemanticVersion) -> Bool {
        current < candidate
    }
}
