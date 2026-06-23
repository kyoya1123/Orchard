// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "DevRunner",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "dev-runner", targets: ["DevRunnerApp"])
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.3.0")
    ],
    targets: [
        .executableTarget(
            name: "DevRunnerApp",
            dependencies: [
                "DevRunnerCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser")
            ]
        ),
        .target(name: "DevRunnerCore"),
        .testTarget(
            name: "DevRunnerCoreTests",
            dependencies: ["DevRunnerCore"]
        )
    ]
)
