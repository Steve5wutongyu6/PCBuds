// swift-tools-version: 6.4
import PackageDescription

// PCBuds targets macOS 27. MACOSX_DEPLOYMENT_TARGET and SDKROOT are pinned in
// Scripts/env.sh for both the SwiftPM and xcodebuild entry points.
let package = Package(
    name: "PCBuds",
    platforms: [.macOS(.v27)],
    products: [
        .library(name: "PCBudsKit", targets: ["PCBudsKit"]),
        .executable(name: "PCBuds", targets: ["PCBuds"]),
    ],
    targets: [
        .target(
            name: "PCBudsKit",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "PCBuds",
            dependencies: ["PCBudsKit", "PCBudsUI"],
            path: "Sources/PCBudsApp",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "PCBudsUI",
            dependencies: ["PCBudsKit"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "PCBudsKitTests",
            dependencies: ["PCBudsKit"],
            path: "Tests/PCBudsKitTests",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
