import Foundation

public struct XcodeProject: Equatable, Sendable {
    public enum Kind: Sendable {
        case workspace
        case project
    }

    public let rootURL: URL
    public let fileURL: URL
    public let kind: Kind

    public init(rootURL: URL, fileURL: URL, kind: Kind) {
        self.rootURL = rootURL
        self.fileURL = fileURL
        self.kind = kind
    }

    public var id: String {
        String(abs(fileURL.path.hashValue))
    }

    public var displayName: String {
        fileURL.lastPathComponent
    }

    public var xcodebuildArguments: [String] {
        switch kind {
        case .workspace:
            ["-workspace", fileURL.path]
        case .project:
            ["-project", fileURL.path]
        }
    }
}

public struct XcodeDestination: Identifiable, Equatable, Sendable {
    public enum Kind: String, Sendable {
        case device
        case simulator
    }

    public let id: String
    public let name: String
    public let runtime: String
    public let isAvailable: Bool
    public let kind: Kind

    public init(id: String, name: String, runtime: String, isAvailable: Bool, kind: Kind) {
        self.id = id
        self.name = name
        self.runtime = runtime
        self.isAvailable = isAvailable
        self.kind = kind
    }

    public var displayName: String {
        let prefix = kind == .device ? "Device" : "Simulator"
        return "\(name) (\(prefix), \(runtime))"
    }

    public var xcodebuildDestination: String {
        switch kind {
        case .device:
            "platform=iOS,id=\(id)"
        case .simulator:
            "platform=iOS Simulator,id=\(id)"
        }
    }
}

public struct RunnableApp: Equatable, Sendable {
    public let appURL: URL
    public let bundleIdentifier: String

    public init(appURL: URL, bundleIdentifier: String) {
        self.appURL = appURL
        self.bundleIdentifier = bundleIdentifier
    }
}

public struct XcodeBuildSettings: Sendable {
    public let entries: [[String: String]]

    public init(entries: [[String: String]]) {
        self.entries = entries
    }

    public var firstRunnableApp: RunnableApp? {
        for entry in entries {
            guard let targetBuildDirectory = entry["TARGET_BUILD_DIR"],
                  let wrapperName = entry["WRAPPER_NAME"],
                  wrapperName.hasSuffix(".app"),
                  let bundleIdentifier = entry["PRODUCT_BUNDLE_IDENTIFIER"],
                  !bundleIdentifier.isEmpty else {
                continue
            }

            return RunnableApp(
                appURL: URL(fileURLWithPath: targetBuildDirectory).appendingPathComponent(wrapperName),
                bundleIdentifier: bundleIdentifier
            )
        }

        return nil
    }
}
