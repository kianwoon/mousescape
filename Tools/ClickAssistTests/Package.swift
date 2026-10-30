// swift-tools-version:5.9
// baseline-guard:allow new standalone SwiftPM package for the headless Click Assist suite; no prior baseline possible
import PackageDescription

// Headless regression suite for the Click Assist decision core.
//
// The sources in Sources/ClickAssistCore are SYMLINKS to the exact files the app
// ships (Mousecape/Mousecape/SwiftUI/ClickAssist/*). There is one copy of the
// code: editing the app file changes what `swift test` compiles, and nothing
// here needs the .xcodeproj.
let package = Package(
    name: "ClickAssistTests",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "ClickAssistCore", targets: ["ClickAssistCore"]),
    ],
    targets: [
        .target(name: "ClickAssistCore", path: "Sources/ClickAssistCore"),
        .testTarget(name: "ClickAssistTests",
                    dependencies: ["ClickAssistCore"],
                    path: "Tests/ClickAssistTests"),
    ]
)
