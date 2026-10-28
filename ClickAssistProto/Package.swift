// swift-tools-version: 6.0
// baseline-guard:allow new standalone prototype file, no prior baseline possible
import PackageDescription

let package = Package(
    name: "ClickAssistProto",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "ClickAssistProto",
            path: "Sources/ClickAssistProto",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
