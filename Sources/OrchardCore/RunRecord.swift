import Foundation

/// A serialized snapshot of a run, written by the CLI to a shared on-disk store
/// so the GUI can display CLI-originated runs in its Runs list. The CLI keeps
/// running the build itself (terminal-complete, logs/exit code on stdout); this
/// record is a side-channel purely for GUI visibility.
public struct RunRecord: Codable, Identifiable, Sendable {
    public enum Status: String, Codable, Sendable {
        case running
        case completed
        case failed
        case stopped
    }

    /// Destination fields flattened for serialization (the model type isn't Codable).
    public struct Destination: Codable, Sendable {
        public let id: String
        public let name: String
        public let runtime: String
        public let kind: String // "device" | "simulator"
        public let modelCode: String

        public init(id: String, name: String, runtime: String, kind: String, modelCode: String) {
            self.id = id
            self.name = name
            self.runtime = runtime
            self.kind = kind
            self.modelCode = modelCode
        }

        public init(_ destination: XcodeDestination) {
            self.init(
                id: destination.id,
                name: destination.name,
                runtime: destination.runtime,
                kind: destination.kind.rawValue,
                modelCode: destination.modelCode
            )
        }

        public func toXcodeDestination() -> XcodeDestination {
            XcodeDestination(
                id: id,
                name: name,
                runtime: runtime,
                isAvailable: true,
                kind: kind == "device" ? .device : .simulator,
                modelCode: modelCode
            )
        }
    }

    public let id: String          // UUID string
    public let source: String      // "cli"
    public let branchName: String
    public let worktreeDisplayName: String
    public let projectRootPath: String
    public let projectFilePath: String
    public let projectKind: String // "workspace" | "project"
    public let scheme: String
    public let destination: Destination
    public let startedAt: Double   // epoch seconds
    public var updatedAt: Double
    public var status: Status
    public var activityText: String
    public var log: String
    /// PID of the CLI process that owns this run, so the GUI can stop it by
    /// sending SIGINT. Optional for backward compatibility with older records.
    public var pid: Int32?

    public init(
        id: String,
        source: String = "cli",
        branchName: String,
        worktreeDisplayName: String,
        project: XcodeProject,
        scheme: String,
        destination: XcodeDestination,
        startedAt: Double,
        updatedAt: Double,
        status: Status,
        activityText: String,
        log: String,
        pid: Int32? = nil
    ) {
        self.id = id
        self.source = source
        self.branchName = branchName
        self.worktreeDisplayName = worktreeDisplayName
        self.projectRootPath = project.rootURL.path
        self.projectFilePath = project.fileURL.path
        self.projectKind = project.kind == .workspace ? "workspace" : "project"
        self.scheme = scheme
        self.destination = Destination(destination)
        self.startedAt = startedAt
        self.updatedAt = updatedAt
        self.status = status
        self.activityText = activityText
        self.log = log
        self.pid = pid
    }

    public func toXcodeProject() -> XcodeProject {
        XcodeProject(
            rootURL: URL(fileURLWithPath: projectRootPath, isDirectory: true),
            fileURL: URL(fileURLWithPath: projectFilePath),
            kind: projectKind == "workspace" ? .workspace : .project
        )
    }

    public var isFinished: Bool {
        status != .running
    }
}
