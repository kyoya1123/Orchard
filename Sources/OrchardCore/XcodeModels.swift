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
    public let kind: Kind
    public let modelCode: String

    public init(id: String, name: String, runtime: String, kind: Kind, modelCode: String = "") {
        self.id = id
        self.name = name
        self.runtime = runtime
        self.kind = kind
        self.modelCode = modelCode
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
        runnableEntry().map { entry in
            RunnableApp(
                appURL: URL(fileURLWithPath: entry.targetBuildDirectory).appendingPathComponent(entry.wrapperName),
                bundleIdentifier: entry.bundleIdentifier
            )
        }
    }

    /// The app `firstRunnableApp` chose, relocated from `BUILD_DIR` into a
    /// copy of the build's `Build/Products` directory.
    public func runnableApp(inProducts products: URL) -> RunnableApp? {
        guard let entry = runnableEntry(),
              let buildDirectory = entry.entry["BUILD_DIR"], !buildDirectory.isEmpty else {
            return nil
        }
        let build = URL(fileURLWithPath: buildDirectory).standardizedFileURL.pathComponents
        let target = URL(fileURLWithPath: entry.targetBuildDirectory).standardizedFileURL.pathComponents
        guard target.count >= build.count, Array(target.prefix(build.count)) == build else {
            return nil
        }
        let directory = target.dropFirst(build.count)
            .reduce(products) { $0.appendingPathComponent($1, isDirectory: true) }
        return RunnableApp(
            appURL: directory.appendingPathComponent(entry.wrapperName),
            bundleIdentifier: entry.bundleIdentifier
        )
    }

    private func runnableEntry() -> (
        entry: [String: String], targetBuildDirectory: String, wrapperName: String, bundleIdentifier: String
    )? {
        for entry in entries {
            guard let targetBuildDirectory = entry["TARGET_BUILD_DIR"],
                  let wrapperName = entry["WRAPPER_NAME"],
                  wrapperName.hasSuffix(".app"),
                  let bundleIdentifier = entry["PRODUCT_BUNDLE_IDENTIFIER"],
                  !bundleIdentifier.isEmpty else {
                continue
            }
            return (entry, targetBuildDirectory, wrapperName, bundleIdentifier)
        }
        return nil
    }
}
