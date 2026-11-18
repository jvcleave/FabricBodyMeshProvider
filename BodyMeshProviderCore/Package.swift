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
    dependencies: [
        .package(url: "https://github.com/jvcleave/CMCaptureKit.git", exact: "0.1.1"),
    ],
    targets: [
        .target(
            name: "BodyMeshProviderCore",
            dependencies: [.product(name: "CMData", package: "CMCaptureKit")]
        ),
        .testTarget(
            name: "BodyMeshProviderCoreTests",
            dependencies: ["BodyMeshProviderCore"]
        ),
    ]
)
