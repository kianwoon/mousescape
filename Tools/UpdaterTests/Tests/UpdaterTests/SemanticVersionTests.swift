import XCTest
@testable import UpdaterCore

final class SemanticVersionTests: XCTestCase {
    private func v(_ s: String, file: StaticString = #filePath, line: UInt = #line) -> SemanticVersion {
        guard let parsed = SemanticVersion(s) else {
            XCTFail("could not parse \(s)", file: file, line: line)
            return SemanticVersion(major: -1)
        }
        return parsed
    }

    func testParsesTagsAndBundleVersions() {
        XCTAssertEqual(v("v1.5.0"), SemanticVersion(major: 1, minor: 5, patch: 0))
        XCTAssertEqual(v("1.4.1"), SemanticVersion(major: 1, minor: 4, patch: 1))
        XCTAssertEqual(v("V2"), SemanticVersion(major: 2))
        XCTAssertEqual(v("1.4"), SemanticVersion(major: 1, minor: 4))
        XCTAssertEqual(v(" 1.4.2 \n"), SemanticVersion(major: 1, minor: 4, patch: 2))
        XCTAssertEqual(v("v1.4.2-click-assist").prerelease, ["click-assist"])
        XCTAssertEqual(v("1.0.0-beta.11").prerelease, ["beta", "11"])
        XCTAssertEqual(v("1.0.0+build.7"), v("1.0.0"))
        XCTAssertEqual(v("v1.4.2-click-assist").description, "1.4.2-click-assist")
    }

    func testRejectsNonVersions() {
        for bad in ["", "v", "latest", "1..2", "1.2.3.4", "1.x", "1.2.3-", "1.2.3-a..b", "-1.2", "１.2"] {
            XCTAssertNil(SemanticVersion(bad), bad)
        }
    }

    func testCoreOrdering() {
        XCTAssertLessThan(v("1.4.1"), v("1.5.0"))
        XCTAssertLessThan(v("1.9.9"), v("1.10.0"))   // numeric, not lexical
        XCTAssertLessThan(v("1.4"), v("1.4.1"))
        XCTAssertLessThan(v("0.9.9"), v("1.0.0"))
        XCTAssertFalse(v("1.5.0") < v("v1.5.0"))
        XCTAssertFalse(v("v1.5.0") < v("1.5.0"))
    }

    /// semver.org 11.4 example chain.
    func testPrereleasePrecedence() {
        let chain = ["1.0.0-alpha", "1.0.0-alpha.1", "1.0.0-alpha.beta", "1.0.0-beta",
                     "1.0.0-beta.2", "1.0.0-beta.11", "1.0.0-rc.1", "1.0.0"].map { v($0) }
        for (a, b) in zip(chain, chain.dropFirst()) {
            XCTAssertLessThan(a, b, "\(a) < \(b)")
            XCTAssertFalse(b < a, "\(b) !< \(a)")
        }
    }

    func testRealTagsOfThisRepo() {
        // The repo's real tags: a click-assist pre-release line next to plain releases.
        XCTAssertLessThan(v("v1.4.2-click-assist"), v("v1.4.2"))
        XCTAssertLessThan(v("v1.4.2-click-assist"), v("v1.5.0"))
        XCTAssertLessThan(v("v1.4.1"), v("v1.4.2-click-assist"))
        XCTAssertTrue(UpdateReleaseSelection.isUpdate(v("1.5.0"), over: v("1.4.1")))
        XCTAssertFalse(UpdateReleaseSelection.isUpdate(v("1.5.0"), over: v("1.5.0")))
        XCTAssertFalse(UpdateReleaseSelection.isUpdate(v("1.4.2-click-assist"), over: v("1.5.0")))
    }
}
