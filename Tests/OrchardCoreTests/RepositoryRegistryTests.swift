import Foundation
@testable import OrchardCore
import XCTest

@MainActor
final class RepositoryRegistryTests: XCTestCase {
    private func temporaryDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("orchard-registry-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root.resolvingSymlinksInPath()
    }

    @discardableResult
    private func git(_ root: URL, _ arguments: [String]) async throws -> String {
        try await ProcessRunner.run(executableURL: URL(fileURLWithPath: "/usr/bin/git"),
            arguments: ["-c", "core.hooksPath=/dev/null", "-c", "user.name=Orchard Test", "-c", "user.email=test@example.invalid", "-C", root.path] + arguments,
            currentDirectoryURL: nil)
    }

    private func project(at root: URL, name: String = "App") throws -> XcodeProject {
        let bundle = root.appendingPathComponent(name + ".xcodeproj")
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        try Data("// discovery fixture\n".utf8).write(to: bundle.appendingPathComponent("project.pbxproj"))
        return XcodeProject(rootURL: root, fileURL: bundle, kind: .project)
    }

    private func repository(at root: URL, nested: String = ".") async throws -> XcodeProject {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try await git(root, ["init", "-b", "main"])
        let result = try project(at: root.appendingPathComponent(nested).standardizedFileURL)
        try await git(root, ["add", "."])
        try await git(root, ["commit", "-m", "fixture"])
        return result
    }

    func testRegistrationSurvivesOriginalWorktreeDeletionAndFindsExternalWorktrees() async throws {
        let root = try temporaryDirectory()
        let repo = root.appendingPathComponent("repo")
        _ = try await repository(at: repo, nested: "ios")
        let external = root.appendingPathComponent("codex/worktrees/1234/repo")
        try await git(repo, ["worktree", "add", "-b", "feature", external.path])
        let registry = RepositoryRegistry(root: root.appendingPathComponent("registry"))
        try await registry.register(project: ProjectDetector().detect(from: external.appendingPathComponent("ios")))
        let registered = try await registry.load()
        XCTAssertEqual(registered.count, 1)
        XCTAssertEqual(registered.first?.directoryPath, repo.path)
        XCTAssertEqual(registered.first?.projectDirectories, ["ios"])
        let resolver = WorktreeContextResolver()
        let first = await resolver.resolve(fromConfiguredDirectoryURLs: [], registeredRepositories: registered)
        XCTAssertEqual(Set(first.map(\.branchName)), ["main", "feature"])

        try await git(repo, ["worktree", "remove", external.path])
        let later = root.appendingPathComponent("different/new-branch")
        try await git(repo, ["worktree", "add", "-b", "later", later.path])
        let after = await resolver.resolve(fromConfiguredDirectoryURLs: [], registeredRepositories: registered)
        XCTAssertEqual(Set(after.map(\.branchName)), ["main", "later"])
    }

    func testConcurrentRegistrationMergesProjectsAndRepositories() async throws {
        let root = try temporaryDirectory()
        let first = try await repository(at: root.appendingPathComponent("one"))
        let nested = try project(at: first.rootURL.appendingPathComponent("mobile"))
        let second = try await repository(at: root.appendingPathComponent("two"))
        let registry = RepositoryRegistry(root: root.appendingPathComponent("registry"))
        let projects = [first, nested, second]
        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<18 {
                let project = projects[index % projects.count]
                group.addTask { try await registry.register(project: project) }
            }
            try await group.waitForAll()
        }
        let entries = try await registry.load()
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries.first { $0.directoryPath == first.rootURL.path }?.projectDirectories, [".", "mobile"])
        let discovered = await WorktreeContextResolver().resolve(fromConfiguredDirectoryURLs: [], registeredRepositories: entries)
        XCTAssertEqual(discovered.count, 3)
    }

    func testSymlinksDeduplicateAndRepeatedUseDoesNotRewriteRecord() async throws {
        let root = try temporaryDirectory()
        let project = try await repository(at: root.appendingPathComponent("repo with space"))
        let registry = RepositoryRegistry(root: root.appendingPathComponent("registry"))
        try await registry.register(project: project)
        let file = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: registry.recordsDirectory, includingPropertiesForKeys: nil).first)
        let sentinel = Date(timeIntervalSince1970: 1_000)
        try FileManager.default.setAttributes([.modificationDate: sentinel], ofItemAtPath: file.path)
        let before = try FileManager.default.attributesOfItem(atPath: file.path)
        let alias = root.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(atPath: alias.path, withDestinationPath: project.rootURL.path)
        try await registry.register(project: ProjectDetector().detect(from: alias))
        let entries = try await registry.load()
        XCTAssertEqual(entries.count, 1)
        let after = try FileManager.default.attributesOfItem(atPath: file.path)
        XCTAssertEqual(after[.modificationDate] as? Date, sentinel)
        XCTAssertEqual(after[.systemFileNumber] as? NSNumber, before[.systemFileNumber] as? NSNumber)
    }

    func testDiscoveryPrefersExplicitThenCurrentProjectThenSharedRoots() async throws {
        let root = try temporaryDirectory()
        let first = try await repository(at: root.appendingPathComponent("one"), nested: "ios")
        let second = try await repository(at: root.appendingPathComponent("two"))
        let registry = RepositoryRegistry(root: root.appendingPathComponent("registry"))
        try await registry.register(project: first)
        let discovery = ProjectDiscovery()
        let explicit = await discovery.resolve(explicitDirectories: [second.rootURL], currentDirectory: first.rootURL,
            configuredDirectories: [], registry: registry)
        XCTAssertEqual(explicit.map { $0.project.fileURL.resolvingSymlinksInPath().path }, [second.fileURL.resolvingSymlinksInPath().path])
        let current = await discovery.resolve(explicitDirectories: [], currentDirectory: first.rootURL,
            configuredDirectories: [second.rootURL], registry: registry)
        XCTAssertEqual(current.map { $0.project.fileURL.resolvingSymlinksInPath().path }, [first.fileURL.resolvingSymlinksInPath().path])
        let repoRoot = await discovery.resolve(explicitDirectories: [], currentDirectory: first.rootURL.deletingLastPathComponent(),
            configuredDirectories: [second.rootURL], registry: registry)
        XCTAssertEqual(repoRoot.map { $0.project.fileURL.resolvingSymlinksInPath().path }, [first.fileURL.resolvingSymlinksInPath().path])
        let global = await discovery.resolve(explicitDirectories: [], currentDirectory: root,
            configuredDirectories: [second.rootURL], registry: registry)
        XCTAssertEqual(Set(global.map { $0.project.fileURL.resolvingSymlinksInPath().path }), [first.fileURL.resolvingSymlinksInPath().path, second.fileURL.resolvingSymlinksInPath().path])
    }

    func testNestedExplicitDirectoryDiscoversSiblingProjectsAndDeduplicatesManualRoots() async throws {
        let root = try temporaryDirectory()
        let repo = root.appendingPathComponent("repo")
        let first = try await repository(at: repo, nested: "ios")
        let other = root.appendingPathComponent("branch with space")
        try await git(repo, ["worktree", "add", "-b", "feature", other.path])
        let registry = RepositoryRegistry(root: root.appendingPathComponent("registry"))
        try await registry.register(project: first)
        let entries = try await registry.load()
        let result = await WorktreeContextResolver().resolve(fromConfiguredDirectoryURLs: [first.rootURL], registeredRepositories: entries)
        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(Set(result.map(\.branchName)), ["main", "feature"])
    }

    func testNonGitProjectsAreRegisteredButMissingProjectsAreRejected() async throws {
        let root = try temporaryDirectory()
        let project = try project(at: root.appendingPathComponent("standalone"))
        let registry = RepositoryRegistry(root: root.appendingPathComponent("registry"))
        let record = try await registry.register(project: project)
        XCTAssertNil(record.gitCommonDirectoryPath)
        let result = await WorktreeContextResolver().resolve(fromConfiguredDirectoryURLs: [], registeredRepositories: [record])
        XCTAssertEqual(result.map { $0.project.fileURL.resolvingSymlinksInPath().path }, [project.fileURL.resolvingSymlinksInPath().path])
        try FileManager.default.removeItem(at: project.fileURL)
        do {
            try await registry.register(project: project)
            XCTFail("A missing project must not be registered")
        } catch {}
        let missing = await WorktreeContextResolver().resolve(fromConfiguredDirectoryURLs: [], registeredRepositories: [record])
        XCTAssertTrue(missing.isEmpty)
    }

    func testBareRepositoryUsesLinkedWorktreeRatherThanBareDirectory() async throws {
        let root = try temporaryDirectory()
        let source = root.appendingPathComponent("source")
        _ = try await repository(at: source)
        let bare = root.appendingPathComponent("bare.git")
        try await git(root, ["clone", "--bare", source.path, bare.path])
        let branch = root.appendingPathComponent("checkout")
        try await git(bare, ["worktree", "add", branch.path, "main"])
        let registry = RepositoryRegistry(root: root.appendingPathComponent("registry"))
        let record = try await registry.register(project: ProjectDetector().detect(from: branch))
        XCTAssertEqual(record.directoryPath, branch.path)
        let discovered = await WorktreeContextResolver().resolve(fromConfiguredDirectoryURLs: [], registeredRepositories: [record])
        XCTAssertEqual(discovered.count, 1)
        XCTAssertEqual(discovered.first?.worktreeURL.path, branch.path)
    }
}
