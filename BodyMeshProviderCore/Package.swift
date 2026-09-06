// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "BodyMeshProviderCore",
    platforms: [
        .macOS("15.0"),
    ],
    products: [
        .library(
            name: "BodyMeshProviderCore",
            targets: ["BodyMeshProviderCore"]
        ),
    ],
    targets: [
        .target(
            name: "BodyMeshProviderCore"
        ),
        .testTarget(
            name: "BodyMeshProviderCoreTests",
            dependencies: ["BodyMeshProviderCore"]
        ),
    ]
)
