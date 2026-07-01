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
    public let modelCode: String

    public init(id: String, name: String, runtime: String, isAvailable: Bool, kind: Kind, modelCode: String = "") {
        self.id = id
        self.name = name
        self.runtime = runtime
        self.isAvailable = isAvailable
        self.kind = kind
        self.modelCode = modelCode
    }

    public var displayName: String {
        let prefix = kind == .device ? "Device" : "Simulator"
        return "\(name) (\(prefix), \(runtime))"
    }

    /// SF Symbol that reflects the device's form factor. The model code
    /// (e.g. "iPad16,2", "iPhone18,1") is the reliable signal because a
    /// physical device's `name` can be a user-chosen nickname; we fall back
    /// to the name only when no model code is available.
    public var symbolName: String {
        let identifier = (modelCode.isEmpty ? name : modelCode).lowercased()

        if identifier.contains("ipad") {
            return "ipad"
        }
        if identifier.contains("iphone") {
            return "iphone"
        }
        if identifier.contains("ipod") {
            return "ipodtouch"
        }
        if identifier.contains("watch") {
            return "applewatch"
        }
        if identifier.contains("appletv") || identifier.contains("apple tv") {
            return "appletv"
        }
        if identifier.contains("realitydevice") || identifier.contains("vision") {
            return "vision.pro"
        }
        if identifier.contains("mac") {
            return "macbook"
        }

        return kind == .device ? "iphone" : "iphone.gen3"
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
