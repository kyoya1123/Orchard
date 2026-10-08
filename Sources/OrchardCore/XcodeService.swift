import Foundation

public struct XcodeService: Sendable {
    public init() {}

    public func schemes(project: XcodeProject) async throws -> [String] {
        let output = try await SourcePackageCache().withCache(project: project) { packageArguments in
            try await ProcessRunner.run(
                executableURL: URL(fileURLWithPath: "/usr/bin/xcodebuild"),
                arguments: project.xcodebuildArguments + packageArguments + ["-list", "-json"],
                currentDirectoryURL: project.rootURL
            )
        }

        let data = Data(output.utf8)
        let decoded = try JSONDecoder().decode(XcodeListResponse.self, from: data)
        let schemes = decoded.project?.schemes ?? decoded.workspace?.schemes ?? []
        return schemes.sorted()
    }

    public func destinations() async throws -> [XcodeDestination] {
        let output = try await ProcessRunner.run(
            executableURL: URL(fileURLWithPath: "/usr/bin/xcrun"),
            arguments: ["xcdevice", "list", "--timeout", "5"],
            currentDirectoryURL: nil
        )

        let data = Data(output.utf8)
        let decoded = try JSONDecoder().decode([XCDevice].self, from: data)

        return decoded
            .filter { $0.available && !$0.ignored && $0.supportedDestinationKind != nil }
            .map { device in
                XcodeDestination(
                    id: device.identifier,
                    name: device.name,
                    runtime: device.operatingSystemVersion,
                    isAvailable: device.available,
                    kind: device.supportedDestinationKind ?? .simulator,
                    modelCode: device.modelCode ?? ""
                )
            }
            .sorted {
                if $0.kind != $1.kind {
                    return $0.kind == .device
                }

                if $0.name == $1.name {
                    return $0.runtime > $1.runtime
                }

                return $0.name < $1.name
            }
    }

    public func simulatorDestinations() async throws -> [XcodeDestination] {
        try await destinations().filter { $0.kind == .simulator }
    }

    public func buildSettings(
        project: XcodeProject,
        scheme: String,
        destination: XcodeDestination
    ) async throws -> XcodeBuildSettings {
        try await SourcePackageCache().withCache(project: project) { packageArguments in
            try await buildSettings(project: project, scheme: scheme, destination: destination,
                                    packageArguments: packageArguments)
        }
    }

    // The caller owns the cache lease; do not acquire it again during build/run.
    func buildSettings(
        project: XcodeProject,
        scheme: String,
        destination: XcodeDestination,
        packageArguments: [String]
    ) async throws -> XcodeBuildSettings {
        let output = try await ProcessRunner.run(
            executableURL: URL(fileURLWithPath: "/usr/bin/xcodebuild"),
            arguments: project.xcodebuildArguments + packageArguments + [
                "-scheme", scheme,
                "-destination", destination.xcodebuildDestination,
                "-showBuildSettings",
                "-json"
            ],
            currentDirectoryURL: project.rootURL
        )

        let data = Data(output.utf8)
        let decoded = try JSONDecoder().decode([BuildSettingsEntry].self, from: data)
        return XcodeBuildSettings(entries: decoded.map(\.buildSettings))
    }
}

private struct XcodeListResponse: Decodable {
    let project: XcodeListContainer?
    let workspace: XcodeListContainer?
}

private struct XcodeListContainer: Decodable {
    let schemes: [String]?
}

private struct XCDevice: Decodable {
    let name: String
    let identifier: String
    let operatingSystemVersion: String
    let available: Bool
    let ignored: Bool
    let simulator: Bool
    let platform: String
    let modelCode: String?

    var supportedDestinationKind: XcodeDestination.Kind? {
        switch platform {
        case "com.apple.platform.iphoneos":
            simulator ? nil : .device
        case "com.apple.platform.iphonesimulator":
            simulator ? .simulator : nil
        default:
            nil
        }
    }
}

private struct BuildSettingsEntry: Decodable {
    let buildSettings: [String: String]
}
