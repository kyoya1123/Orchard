// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "Orchard",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "orchard", targets: ["OrchardApp"])
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.3.0")
    ],
    targets: [
        .executableTarget(
            name: "OrchardApp",
            dependencies: [
                "OrchardCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser")
            ]
        ),
        .target(name: "OrchardCore"),
        .testTarget(
            name: "OrchardCoreTests",
            dependencies: ["OrchardCore"]
        )
    ]
)
