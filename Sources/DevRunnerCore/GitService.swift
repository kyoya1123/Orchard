import Foundation

public struct GitInfo: Equatable, Sendable {
    public let rootURL: URL
    public let branchName: String?

    public init(rootURL: URL, branchName: String?) {
        self.rootURL = rootURL
        self.branchName = branchName
    }
}

public struct GitService: Sendable {
    public init() {}

    public func info(from directoryURL: URL) async -> GitInfo? {
        guard let root = try? await ProcessRunner.run(
            executableURL: URL(fileURLWithPath: "/usr/bin/git"),
            arguments: ["-C", directoryURL.path, "rev-parse", "--show-toplevel"],
            currentDirectoryURL: nil
        ), !root.isEmpty else {
            return nil
        }

        let rootURL = URL(fileURLWithPath: root, isDirectory: true)
        let branchName = try? await ProcessRunner.run(
            executableURL: URL(fileURLWithPath: "/usr/bin/git"),
            arguments: ["-C", rootURL.path, "branch", "--show-current"],
            currentDirectoryURL: nil
        )

        return GitInfo(
            rootURL: rootURL,
            branchName: branchName?.isEmpty == true ? nil : branchName
        )
    }

    public func worktreeRootURLs(from repositoryURL: URL) async -> [URL] {
        guard let output = try? await ProcessRunner.run(
            executableURL: URL(fileURLWithPath: "/usr/bin/git"),
            arguments: ["-C", repositoryURL.path, "worktree", "list", "--porcelain"],
            currentDirectoryURL: nil
        ), !output.isEmpty else {
            return []
        }

        return output
            .split(separator: "\n")
            .compactMap { line -> URL? in
                guard line.hasPrefix("worktree ") else { return nil }
                let path = line.dropFirst("worktree ".count)
                return URL(fileURLWithPath: String(path), isDirectory: true)
            }
    }
}
