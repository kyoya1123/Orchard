import Foundation

public struct ProjectDetector: Sendable {
    public init() {}

    public func detect(from workingDirectoryURL: URL) throws -> XcodeProject {
        var currentURL = workingDirectoryURL.standardizedFileURL
        let fileManager = FileManager.default

        while true {
            if let workspace = try firstMatch(in: currentURL, extensionName: "xcworkspace") {
                return XcodeProject(rootURL: currentURL, fileURL: workspace, kind: .workspace)
            }

            if let project = try firstMatch(in: currentURL, extensionName: "xcodeproj") {
                return XcodeProject(rootURL: currentURL, fileURL: project, kind: .project)
            }

            let parent = currentURL.deletingLastPathComponent()
            if parent.path == currentURL.path || !fileManager.fileExists(atPath: parent.path) {
                break
            }
            currentURL = parent
        }

        throw OrchardError.message("作業ディレクトリの親階層に .xcworkspace / .xcodeproj が見つかりませんでした。")
    }

    private func firstMatch(in directoryURL: URL, extensionName: String) throws -> URL? {
        let contents = try FileManager.default.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: nil
        )

        return contents
            .filter { $0.pathExtension == extensionName }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .first
    }
}
