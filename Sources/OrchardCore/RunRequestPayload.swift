import Foundation

/// A resolved run request the CLI hands to the GUI app to execute. The CLI does
/// the name resolution (worktree/scheme/destination) and writes this payload;
/// the always-on GUI then runs it in-process (holding the console, capturing
/// logs, showing it in the Runs list). This is how the default CLI run delegates
/// to the GUI without the CLI staying attached.
public struct RunRequestPayload: Codable, Sendable {
    public let id: String
    public let branchName: String
    public let worktreeDisplayName: String
    public let projectRootPath: String
    public let projectFilePath: String
    public let projectKind: String // "workspace" | "project"
    public let scheme: String
    public let destination: RunRecord.Destination

    public init(
        id: String,
        branchName: String,
        worktreeDisplayName: String,
        project: XcodeProject,
        scheme: String,
        destination: XcodeDestination
    ) {
        self.id = id
        self.branchName = branchName
        self.worktreeDisplayName = worktreeDisplayName
        self.projectRootPath = project.rootURL.path
        self.projectFilePath = project.fileURL.path
        self.projectKind = project.kind == .workspace ? "workspace" : "project"
        self.scheme = scheme
        self.destination = RunRecord.Destination(destination)
    }

    public func toXcodeProject() -> XcodeProject {
        XcodeProject(
            rootURL: URL(fileURLWithPath: projectRootPath, isDirectory: true),
            fileURL: URL(fileURLWithPath: projectFilePath),
            kind: projectKind == "workspace" ? .workspace : .project
        )
    }
}
