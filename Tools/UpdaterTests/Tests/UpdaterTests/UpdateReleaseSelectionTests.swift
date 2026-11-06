import XCTest
@testable import UpdaterCore

final class UpdateReleaseSelectionTests: XCTestCase {
    private let pattern = "Mousecape-v{version}.zip"
    private let placeholder = "{version}"

    private func release(_ tag: String, assets: [String], draft: Bool = false,
                         prerelease: Bool = false) -> GitHubRelease {
        GitHubRelease(tagName: tag, name: tag, draft: draft, prerelease: prerelease, htmlURL: nil,
                      assets: assets.map {
                          GitHubReleaseAsset(name: $0, size: 1,
                                             browserDownloadURL: URL(string: "https://example.invalid/\(tag)/\($0)")!)
                      })
    }

    /// Order and names as GitHub returned them for kianwoon/mousescape (2026-11-06):
    /// the most recently PUBLISHED release is v1.4.2-click-assist, the highest is v1.5.0.
    private var realReleases: [GitHubRelease] {
        [release("v1.5.0", assets: ["Mousecape-v1.5.0.zip"]),
         release("v1.4.2-click-assist", assets: ["Mousecape-1.4.2-click-assist.zip"]),
         release("v1.4.1-click-assist", assets: ["Mousecape-1.4.1-clickassist.zip"]),
         release("v1.4.1", assets: ["Mousecape_v1.4.1.zip"]),
         release("v1.3.2", assets: ["Mousecape.SwiftUI.zip"])]
    }

    func testNewestIsHighestVersionNotLatestPublished() {
        let newest = UpdateReleaseSelection.newest(in: realReleases.reversed())
        XCTAssertEqual(newest?.release.tagName, "v1.5.0")
    }

    func testDraftsGitHubPrereleasesAndJunkTagsAreSkipped() {
        let releases = realReleases + [release("v9.0.0", assets: ["x.zip"], draft: true),
                                       release("v8.0.0", assets: ["x.zip"], prerelease: true),
                                       release("nightly", assets: ["x.zip"])]
        XCTAssertEqual(UpdateReleaseSelection.newest(in: releases)?.release.tagName, "v1.5.0")
        XCTAssertNil(UpdateReleaseSelection.newest(in: []))
    }

    func testAssetMatchesPatternFirst() {
        let r = release("v1.6.0", assets: ["Source.zip", "Mousecape-v1.6.0.zip"])
        XCTAssertEqual(UpdateReleaseSelection.appAsset(of: r, pattern: pattern, versionPlaceholder: placeholder)?.name,
                       "Mousecape-v1.6.0.zip")
    }

    func testAssetFallsBackToTheOnlyZip() {
        let r = release("v1.4.1", assets: ["Mousecape_v1.4.1.zip", "checksums.txt"])
        XCTAssertEqual(UpdateReleaseSelection.appAsset(of: r, pattern: pattern, versionPlaceholder: placeholder)?.name,
                       "Mousecape_v1.4.1.zip")
    }

    func testAmbiguousOrMissingAssetIsNil() {
        let ambiguous = release("v1.6.0", assets: ["a.zip", "b.zip"])
        XCTAssertNil(UpdateReleaseSelection.appAsset(of: ambiguous, pattern: pattern, versionPlaceholder: placeholder))
        let none = release("v1.6.0", assets: ["notes.txt"])
        XCTAssertNil(UpdateReleaseSelection.appAsset(of: none, pattern: pattern, versionPlaceholder: placeholder))
    }

    func testDecodesGitHubJSON() throws {
        let json = """
        [{"tag_name":"v1.5.0","name":"1.5","draft":false,"prerelease":false,
          "html_url":"https://github.com/kianwoon/mousescape/releases/tag/v1.5.0",
          "assets":[{"name":"Mousecape-v1.5.0.zip","size":5343590,
            "browser_download_url":"https://github.com/kianwoon/mousescape/releases/download/v1.5.0/Mousecape-v1.5.0.zip"}]}]
        """
        let releases = try JSONDecoder().decode([GitHubRelease].self, from: Data(json.utf8))
        XCTAssertEqual(releases.first?.version, SemanticVersion(major: 1, minor: 5))
        XCTAssertEqual(releases.first?.assets.first?.size, 5343590)
    }
}
