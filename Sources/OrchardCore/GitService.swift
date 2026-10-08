import Foundation

public struct GitInfo: Equatable, Sendable {
    public let rootURL: URL
    public let branchName: String?
    public let lastModified: Date?

    public init(rootURL: URL, branchName: String?, lastModified: Date? = nil) {
        self.rootURL = rootURL
        self.branchName = branchName
        self.lastModified = lastModified
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

        let rootURL = URL(fileURLWithPath: root, isDirectory: true).resolvingSymlinksInPath().standardizedFileURL
        let branchName = try? await ProcessRunner.run(
            executableURL: URL(fileURLWithPath: "/usr/bin/git"),
            arguments: ["-C", rootURL.path, "branch", "--show-current"],
            currentDirectoryURL: nil
        )

        return GitInfo(
            rootURL: rootURL,
            branchName: branchName?.isEmpty == true ? nil : branchName,
            lastModified: await lastCommitDate(at: rootURL)
        )
    }

    private func lastCommitDate(at rootURL: URL) async -> Date? {
        guard let output = try? await ProcessRunner.run(
            executableURL: URL(fileURLWithPath: "/usr/bin/git"),
            arguments: ["-C", rootURL.path, "log", "-1", "--format=%ct"],
            currentDirectoryURL: nil
        ), let seconds = TimeInterval(output.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return nil
        }

        return Date(timeIntervalSince1970: seconds)
    }

    public func worktreeRootURLs(from repositoryURL: URL) async -> [URL] {
        guard let output = try? await ProcessRunner.run(
            executableURL: URL(fileURLWithPath: "/usr/bin/git"),
            arguments: ["-C", repositoryURL.path, "worktree", "list", "--porcelain", "-z"],
            currentDirectoryURL: nil
        ), !output.isEmpty else {
            return []
        }

        return Self.parseWorktreeRoots(output)
    }

    public func worktreeRootURLs(gitCommonDirectory: URL) async -> [URL] {
        guard let output = try? await ProcessRunner.run(
            executableURL: URL(fileURLWithPath: "/usr/bin/git"),
            arguments: ["--git-dir", gitCommonDirectory.path, "worktree", "list", "--porcelain", "-z"],
            currentDirectoryURL: nil
        ) else { return [] }
        return Self.parseWorktreeRoots(output)
    }

    private static func parseWorktreeRoots(_ output: String) -> [URL] {
        return output
            .components(separatedBy: "\0\0")
            .filter { !$0.components(separatedBy: "\0").contains("bare") }
            .flatMap { $0.components(separatedBy: "\0") }
            .compactMap { line -> URL? in
                guard line.hasPrefix("worktree ") else { return nil }
                let path = line.dropFirst("worktree ".count)
                return URL(fileURLWithPath: String(path), isDirectory: true).resolvingSymlinksInPath().standardizedFileURL
            }
    }
}
