// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Keel",
    platforms: [.macOS(.v15)],
    targets: [
        // Allow-listed privileged operations, shared by the app and the helper.
        .target(name: "KeelShared", path: "Sources/KeelShared", swiftSettings: [.swiftLanguageMode(.v5)]),
        // Root helper: runs as a launchd daemon (SMAppService, signed builds) or one-shot via the admin prompt.
        .executableTarget(name: "KeelHelper", dependencies: ["KeelShared"], path: "Sources/KeelHelper", swiftSettings: [.swiftLanguageMode(.v5)]),
        .executableTarget(name: "Keel", dependencies: ["KeelShared"], path: "Sources/Keel", swiftSettings: [.swiftLanguageMode(.v5)])
    ]
)
