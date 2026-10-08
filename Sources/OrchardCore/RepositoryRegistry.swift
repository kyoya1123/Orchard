import CryptoKit
import Foundation

/// Discovery metadata only. Artifact ownership/retention is tracked separately.
public struct RegisteredRepository: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let directoryPath: String
    public let gitCommonDirectoryPath: String?
    public var projectDirectories: [String]

    public func projectDirectoryURLs() async -> [URL] {
        let roots: [URL]
        if let gitCommonDirectoryPath {
            // The worktree which first registered this repository may be gone.
            roots = await GitService().worktreeRootURLs(gitCommonDirectory: URL(fileURLWithPath: gitCommonDirectoryPath))
        } else {
            roots = [URL(fileURLWithPath: directoryPath)]
        }
        return roots.flatMap { root in
            projectDirectories.compactMap { relative -> URL? in
                guard relative == "." || (!relative.hasPrefix("/") && !relative.split(separator: "/").contains("..")) else { return nil }
                let url = root.appendingPathComponent(relative).standardizedFileURL
                var isDirectory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else { return nil }
                return url
            }
        }
    }
}

/// The GUI and all CLI processes share atomic, per-repository records. A
/// process lock merges nested project locations without losing concurrent adds.
public struct RepositoryRegistry: Sendable {
    public let root: URL
    public var recordsDirectory: URL { root.appendingPathComponent("repositories") }

    public init(root: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Orchard/Repositories-v1")) {
        self.root = root
    }

    public func prepare() async throws {
        try FileManager.default.createDirectory(at: recordsDirectory, withIntermediateDirectories: true)
    }

    public func load() async throws -> [RegisteredRepository] {
        guard FileManager.default.fileExists(atPath: recordsDirectory.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: recordsDirectory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
            .map { try JSONDecoder().decode(RegisteredRepository.self, from: Data(contentsOf: $0)) }
            .sorted { $0.id < $1.id }
    }

    @discardableResult
    public func register(project: XcodeProject) async throws -> RegisteredRepository {
        let projectRoot = project.rootURL.resolvingSymlinksInPath().standardizedFileURL
        guard FileManager.default.fileExists(atPath: project.fileURL.path) else {
            throw OrchardError.message("Cannot register a project that no longer exists: \(project.fileURL.path)")
        }
        let git = GitService()
        let entry: RegisteredRepository
        if let info = await git.info(from: projectRoot) {
            let common = try await ProcessRunner.run(executableURL: URL(fileURLWithPath: "/usr/bin/git"),
                arguments: ["-C", projectRoot.path, "rev-parse", "--path-format=absolute", "--git-common-dir"],
                currentDirectoryURL: nil)
            let commonURL = URL(fileURLWithPath: common).resolvingSymlinksInPath().standardizedFileURL
            let worktree = info.rootURL.resolvingSymlinksInPath().standardizedFileURL
            guard projectRoot.path == worktree.path || projectRoot.path.hasPrefix(worktree.path + "/") else {
                throw OrchardError.message("Project is outside its Git worktree.")
            }
            let relative = projectRoot.path == worktree.path ? "." : String(projectRoot.path.dropFirst(worktree.path.count + 1))
            let roots = await git.worktreeRootURLs(gitCommonDirectory: commonURL)
            entry = RegisteredRepository(id: "git:" + commonURL.path,
                directoryPath: (roots.first ?? worktree).resolvingSymlinksInPath().path,
                gitCommonDirectoryPath: commonURL.path, projectDirectories: [relative])
        } else {
            entry = RegisteredRepository(id: "project:" + projectRoot.path, directoryPath: projectRoot.path,
                gitCommonDirectoryPath: nil, projectDirectories: ["."])
        }

        let key = SHA256.hash(data: Data(entry.id.utf8)).map { String(format: "%02x", $0) }.joined()
        let lease = try await ArtifactLease.acquire(root.appendingPathComponent("locks/\(key).lock"), shared: false)
        defer { lease.close() }
        let file = recordsDirectory.appendingPathComponent(key + ".json")
        let previous = FileManager.default.fileExists(atPath: file.path)
            ? try JSONDecoder().decode(RegisteredRepository.self, from: Data(contentsOf: file)) : nil
        var merged = entry
        merged.projectDirectories = Array(Set((previous?.projectDirectories ?? []) + entry.projectDirectories)).sorted()
        if previous != merged {
            try await prepare()
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            try encoder.encode(merged).write(to: file, options: .atomic)
        }
        return merged
    }
}

/// Explicit scope wins; otherwise prefer the current project/repository. Only
/// outside a project do we fall back to all manually/automatically added roots.
public struct ProjectDiscovery: Sendable {
    public init() {}

    public func resolve(explicitDirectories: [URL], currentDirectory: URL,
                        configuredDirectories: [URL], registry: RepositoryRegistry = RepositoryRegistry()) async -> [WorktreeContext] {
        let entries = (try? await registry.load()) ?? []
        if !explicitDirectories.isEmpty {
            return await resolveScoped(explicitDirectories, entries: entries)
        }
        let currentGitInfo = await GitService().info(from: currentDirectory)
        if (try? ProjectDetector().detect(from: currentDirectory)) != nil || currentGitInfo != nil {
            return await resolveScoped([currentDirectory], entries: entries)
        }
        return await WorktreeContextResolver().resolve(fromConfiguredDirectoryURLs: configuredDirectories,
                                                       registeredRepositories: entries)
    }

    private func resolveScoped(_ directories: [URL], entries: [RegisteredRepository]) async -> [WorktreeContext] {
        var commonPaths = Set<String>()
        for directory in directories {
            if let common = try? await ProcessRunner.run(executableURL: URL(fileURLWithPath: "/usr/bin/git"),
                arguments: ["-C", directory.path, "rev-parse", "--path-format=absolute", "--git-common-dir"], currentDirectoryURL: nil) {
                commonPaths.insert(URL(fileURLWithPath: common).resolvingSymlinksInPath().path)
            }
        }
        let scoped = entries.filter { entry in
            if let common = entry.gitCommonDirectoryPath, commonPaths.contains(common) { return true }
            return directories.contains { directory in
                let path = directory.resolvingSymlinksInPath().standardizedFileURL.path
                return entry.directoryPath == path || entry.directoryPath.hasPrefix(path + "/")
            }
        }
        return await WorktreeContextResolver().resolve(fromConfiguredDirectoryURLs: directories, registeredRepositories: scoped)
    }
}
