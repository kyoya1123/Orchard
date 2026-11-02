import Foundation

public struct WorktreeContext: Equatable, Sendable {
    public let project: XcodeProject
    public let gitInfo: GitInfo?

    public init(project: XcodeProject, gitInfo: GitInfo?) {
        self.project = project
        self.gitInfo = gitInfo
    }

    public var id: String {
        "\(worktreeURL.path)|\(project.fileURL.path)"
    }

    public var worktreeURL: URL {
        gitInfo?.rootURL ?? project.rootURL
    }

    public var branchName: String {
        gitInfo?.branchName ?? "no branch"
    }

    public var lastModified: Date? {
        gitInfo?.lastModified
    }

    public var displayName: String {
        "\(worktreeURL.lastPathComponent) · \(branchName)"
    }
}

public struct WorktreeContextResolver: Sendable {
    private let projectDetector: ProjectDetector
    private let gitService: GitService

    public init(projectDetector: ProjectDetector = ProjectDetector(), gitService: GitService = GitService()) {
        self.projectDetector = projectDetector
        self.gitService = gitService
    }

    public func resolve(fromConfiguredDirectoryURLs directoryURLs: [URL],
                        registeredRepositories: [RegisteredRepository] = []) async -> [WorktreeContext] {
        var buckets: [String: WorktreeContext] = [:]
        var repositoryRoots = Set<URL>()
        var nestedProjectDirectories: [URL: Set<String>] = [:]
        // The same worktree is typically reached from several of the passes below.
        var gitInfoByPath: [String: GitInfo?] = [:]
        func info(from url: URL) async -> GitInfo? {
            if let cached = gitInfoByPath[url.path] { return cached }
            let info = await gitService.info(from: url)
            gitInfoByPath[url.path] = info
            return info
        }

        for directoryURL in directoryURLs.map({ $0.resolvingSymlinksInPath().standardizedFileURL }) {
            let gitInfo = await info(from: directoryURL)
            if let gitInfo {
                repositoryRoots.insert(gitInfo.rootURL)
            }
            // Preserve an explicit nested project (and non-Git projects).
            if let project = try? projectDetector.detect(from: directoryURL) {
                add(project: project, gitInfo: await info(from: project.rootURL), to: &buckets)
                if let root = gitInfo?.rootURL, project.rootURL.path.hasPrefix(root.path + "/") {
                    nestedProjectDirectories[root, default: []].insert(String(project.rootURL.path.dropFirst(root.path.count + 1)))
                }
            }

            for repositoryRoot in repositoryRootCandidates(inside: directoryURL) {
                repositoryRoots.insert(repositoryRoot)
            }
        }

        for repositoryRoot in repositoryRoots {
            let worktreeRoots = await gitService.worktreeRootURLs(from: repositoryRoot)
            let candidateRoots = worktreeRoots.isEmpty ? [repositoryRoot] : worktreeRoots

            let roots = candidateRoots + worktreeCandidateURLs(near: repositoryRoot)
            let projectCandidates = roots + roots.flatMap { root in
                (nestedProjectDirectories[repositoryRoot] ?? []).map { root.appendingPathComponent($0) }
            }
            for candidateRoot in projectCandidates {
                guard let project = try? projectDetector.detect(from: candidateRoot) else {
                    continue
                }

                add(project: project, gitInfo: await info(from: candidateRoot), to: &buckets)
            }
        }

        for repository in registeredRepositories {
            for directory in await repository.projectDirectoryURLs() {
                // A removed nested project must not accidentally select an
                // unrelated project above this worktree.
                guard let project = try? projectDetector.detect(from: directory),
                      project.rootURL.standardizedFileURL.path == directory.standardizedFileURL.path else { continue }
                add(project: project, gitInfo: await info(from: directory), to: &buckets)
            }
        }

        return buckets.values.sorted(by: sortWorktrees)
    }

    private func add(project: XcodeProject, gitInfo: GitInfo?, to buckets: inout [String: WorktreeContext]) {
        let context = WorktreeContext(project: project, gitInfo: gitInfo)
        if buckets[context.id] == nil {
            buckets[context.id] = context
        }
    }

    private func repositoryRootCandidates(inside directoryURL: URL) -> [URL] {
        var candidates: [URL] = []
        collectRepositoryRoots(
            from: directoryURL,
            currentDepth: 0,
            maxDepth: 2,
            into: &candidates
        )
        return Array(Set(candidates))
    }

    private func collectRepositoryRoots(
        from directoryURL: URL,
        currentDepth: Int,
        maxDepth: Int,
        into candidates: inout [URL]
    ) {
        guard currentDepth <= maxDepth else { return }

        if containsGitMetadata(in: directoryURL) {
            candidates.append(directoryURL)
            return
        }

        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return
        }

        for childURL in contents {
            guard (try? childURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
                continue
            }

            collectRepositoryRoots(
                from: childURL,
                currentDepth: currentDepth + 1,
                maxDepth: maxDepth,
                into: &candidates
            )
        }
    }

    private func worktreeCandidateURLs(near rootURL: URL) -> [URL] {
        let searchRoots = [
            rootURL.appendingPathComponent(".worktrees", isDirectory: true),
            rootURL.appendingPathComponent(".claude/worktrees", isDirectory: true)
        ]

        var candidates: [URL] = []

        for searchRoot in searchRoots where FileManager.default.fileExists(atPath: searchRoot.path) {
            collectCandidateURLs(
                from: searchRoot,
                currentDepth: 0,
                maxDepth: 3,
                into: &candidates
            )
        }

        return Array(Set(candidates))
    }

    private func collectCandidateURLs(
        from directoryURL: URL,
        currentDepth: Int,
        maxDepth: Int,
        into candidates: inout [URL]
    ) {
        guard currentDepth <= maxDepth,
              let contents = try? FileManager.default.contentsOfDirectory(
                at: directoryURL,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: []
              ) else {
            return
        }

        if containsGitMetadata(in: directoryURL) {
            candidates.append(directoryURL)
        }

        for childURL in contents {
            guard (try? childURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
                continue
            }

            collectCandidateURLs(
                from: childURL,
                currentDepth: currentDepth + 1,
                maxDepth: maxDepth,
                into: &candidates
            )
        }
    }

    private func containsGitMetadata(in directoryURL: URL) -> Bool {
        FileManager.default.fileExists(atPath: directoryURL.appendingPathComponent(".git").path)
    }

    private func sortWorktrees(_ lhs: WorktreeContext, _ rhs: WorktreeContext) -> Bool {
        // Most recently committed worktrees first. Entries without a known
        // commit date sort last, breaking ties by path for stable ordering.
        switch (lhs.lastModified, rhs.lastModified) {
        case let (lhsDate?, rhsDate?) where lhsDate != rhsDate:
            return lhsDate > rhsDate
        case (.some, .none):
            return true
        case (.none, .some):
            return false
        default:
            return lhs.worktreeURL.path < rhs.worktreeURL.path
        }
    }
}
