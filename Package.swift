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
    targets: [
        .executableTarget(
            name: "DevRunnerApp",
            dependencies: ["DevRunnerCore"]
        ),
        .target(name: "DevRunnerCore"),
        .testTarget(
            name: "DevRunnerCoreTests",
            dependencies: ["DevRunnerCore"]
        )
    ]
)
