import Foundation

public struct WorktreeContext: Equatable, Identifiable, Sendable {
    public let project: XcodeProject
    public let gitInfo: GitInfo?
    public let terminalContexts: [TerminalContext]
    public let sourceDescription: String

    public init(
        project: XcodeProject,
        gitInfo: GitInfo?,
        terminalContexts: [TerminalContext],
        sourceDescription: String = "discovered"
    ) {
        self.project = project
        self.gitInfo = gitInfo
        self.terminalContexts = terminalContexts
        self.sourceDescription = sourceDescription
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

    public var sessionCount: Int {
        terminalContexts.count
    }

    public var isFocused: Bool {
        terminalContexts.contains { $0.isFocused }
    }

    public var lastModified: Date? {
        gitInfo?.lastModified
    }

    public var displayName: String {
        let focusedPrefix = isFocused ? "Focused · " : ""
        return "\(focusedPrefix)\(worktreeURL.lastPathComponent) · \(branchName)"
    }

    public var detail: String {
        let sessionLabel = switch sessionCount {
        case 0:
            sourceDescription
        case 1:
            "1 session"
        default:
            "\(sessionCount) sessions"
        }
        return "\(project.displayName) · \(sessionLabel)"
    }
}

public struct WorktreeContextResolver: Sendable {
    private let projectDetector: ProjectDetector
    private let gitService: GitService

    public init(projectDetector: ProjectDetector = ProjectDetector(), gitService: GitService = GitService()) {
        self.projectDetector = projectDetector
        self.gitService = gitService
    }

    public func resolve(from terminalContexts: [TerminalContext]) async -> [WorktreeContext] {
        var buckets: [String: (project: XcodeProject, gitInfo: GitInfo?, contexts: [TerminalContext], source: String)] = [:]
        var discoveryRoots = Set<URL>()

        for context in terminalContexts {
            discoveryRoots.insert(context.workingDirectoryURL)
            let contextGitInfo = await gitService.info(from: context.workingDirectoryURL)
            if let rootURL = contextGitInfo?.rootURL {
                discoveryRoots.insert(rootURL)
            }

            guard let project = try? projectDetector.detect(from: context.workingDirectoryURL) else {
                continue
            }

            add(
                project: project,
                gitInfo: contextGitInfo,
                context: context,
                sourceDescription: "Ghostty",
                to: &buckets
            )
        }

        for root in discoveryRoots {
            for candidateURL in worktreeCandidateURLs(near: root) {
                guard let project = try? projectDetector.detect(from: candidateURL) else {
                    continue
                }

                let gitInfo = await gitService.info(from: candidateURL)
                add(
                    project: project,
                    gitInfo: gitInfo,
                    context: nil,
                    sourceDescription: "discovered",
                    to: &buckets
                )
            }
        }

        return buckets.values
            .map {
                WorktreeContext(
                    project: $0.project,
                    gitInfo: $0.gitInfo,
                    terminalContexts: $0.contexts,
                    sourceDescription: $0.source
                )
            }
            .sorted(by: sortWorktrees)
    }

    public func resolve(fromConfiguredDirectoryURLs directoryURLs: [URL],
                        registeredRepositories: [RegisteredRepository] = []) async -> [WorktreeContext] {
        var buckets: [String: (project: XcodeProject, gitInfo: GitInfo?, contexts: [TerminalContext], source: String)] = [:]
        var repositoryRoots = Set<URL>()
        var nestedProjectDirectories: [URL: Set<String>] = [:]

        for directoryURL in directoryURLs.map({ $0.resolvingSymlinksInPath().standardizedFileURL }) {
            let gitInfo = await gitService.info(from: directoryURL)
            if let gitInfo {
                repositoryRoots.insert(gitInfo.rootURL)
            }
            // Preserve an explicit nested project (and non-Git projects).
            if let project = try? projectDetector.detect(from: directoryURL) {
                add(project: project, gitInfo: await gitService.info(from: project.rootURL), context: nil,
                    sourceDescription: "configured", to: &buckets)
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

                let gitInfo = await gitService.info(from: candidateRoot)
                add(
                    project: project,
                    gitInfo: gitInfo,
                    context: nil,
                    sourceDescription: "configured",
                    to: &buckets
                )
            }
        }

        for repository in registeredRepositories {
            for directory in await repository.projectDirectoryURLs() {
                // A removed nested project must not accidentally select an
                // unrelated project above this worktree.
                guard let project = try? projectDetector.detect(from: directory),
                      project.rootURL.standardizedFileURL.path == directory.standardizedFileURL.path else { continue }
                add(project: project, gitInfo: await gitService.info(from: directory), context: nil,
                    sourceDescription: "CLI", to: &buckets)
            }
        }

        return buckets.values
            .map {
                WorktreeContext(
                    project: $0.project,
                    gitInfo: $0.gitInfo,
                    terminalContexts: $0.contexts,
                    sourceDescription: $0.source
                )
            }
            .sorted(by: sortWorktrees)
    }

    private func add(
        project: XcodeProject,
        gitInfo: GitInfo?,
        context: TerminalContext?,
        sourceDescription: String,
        to buckets: inout [String: (project: XcodeProject, gitInfo: GitInfo?, contexts: [TerminalContext], source: String)]
    ) {
        let key = "\(gitInfo?.rootURL.path ?? project.rootURL.path)|\(project.fileURL.path)"

        if var bucket = buckets[key] {
            if let context, !bucket.contexts.contains(context) {
                bucket.contexts.append(context)
            }
            if bucket.source == "discovered" {
                bucket.source = sourceDescription
            }
            buckets[key] = bucket
        } else {
            buckets[key] = (
                project: project,
                gitInfo: gitInfo,
                contexts: context.map { [$0] } ?? [],
                source: sourceDescription
            )
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
