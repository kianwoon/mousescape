// swift-tools-version:5.9
import PackageDescription

// Headless tests for the self-updater's pure logic (semantic-version ordering,
// newest-release and asset selection). Sources are SYMLINKS to the shipped app
// files in Mousecape/Mousecape/SwiftUI/Utilities, so there is one copy of the code.
// Run: cd Tools/UpdaterTests && swift test
let package = Package(
    name: "UpdaterTests",
    platforms: [.macOS(.v13)],
    targets: [
        .target(name: "UpdaterCore", path: "Sources/UpdaterCore"),
        .testTarget(name: "UpdaterTests", dependencies: ["UpdaterCore"], path: "Tests/UpdaterTests"),
    ]
)
