// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ExtensionBridgeCore",
    platforms: [
        .iOS(.v16),
        .macOS(.v13),
    ],
    products: [
        .library(
            name: "ExtensionBridgeCore",
            targets: ["ExtensionBridgeCore"]
        ),
        .executable(
            name: "eb-swift-interop-helper",
            targets: ["ExtensionBridgeInteropHelper"]
        ),
    ],
    targets: [
        .target(
            name: "ExtensionBridgeCore",
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        .executableTarget(
            name: "ExtensionBridgeInteropHelper",
            dependencies: ["ExtensionBridgeCore"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        .testTarget(
            name: "ExtensionBridgeCoreTests",
            dependencies: ["ExtensionBridgeCore"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
    ]
)
