import Foundation
@testable import OrchardCore
import XCTest

final class SourcePackageCacheTests: XCTestCase, @unchecked Sendable {
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Orchard SPM Tests-\(UUID().uuidString)").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func write(_ text: String, at url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    private func git(_ arguments: [String], at url: URL) async throws -> String {
        try await ProcessRunner.run(executableURL: URL(fileURLWithPath: "/usr/bin/git"),
                                    arguments: arguments, currentDirectoryURL: url)
    }

    private func fixture(at root: URL, trackedWorkspace: Bool = false) async throws -> (packages: URL, resolved: Data) {
        let packages = root.appendingPathComponent("SourcePackages")
        let checkout = packages.appendingPathComponent("checkouts/package")
        try write("let value = 1\n", at: checkout.appendingPathComponent("Source.swift"))
        if trackedWorkspace { try write("shared project", at: checkout.appendingPathComponent(".swiftpm/xcode/shared")) }
        _ = try await git(["init", "-q"], at: checkout)
        _ = try await git(["add", "."], at: checkout)
        _ = try await git(["-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "-qm", "initial"], at: checkout)
        let revision = try await git(["rev-parse", "HEAD"], at: checkout)
        let location = "https://example.invalid/package.git"
        let resolved = try JSONSerialization.data(withJSONObject: [
            "version": 3, "pins": [["identity": "package", "kind": "remoteSourceControl", "location": location,
                                      "state": ["revision": revision]]]
        ])
        let state: [String: Any] = ["version": 7, "object": [
            "dependencies": [["packageRef": ["identity": "package", "kind": "remoteSourceControl", "location": location],
                              "state": ["name": "sourceControlCheckout", "checkoutState": ["revision": revision]],
                              "subpath": "package"]],
            "artifacts": [["path": packages.appendingPathComponent("artifacts/binary").path]]
        ]]
        try JSONSerialization.data(withJSONObject: state).write(to: packages.appendingPathComponent("workspace-state.json"))
        try write("binary", at: packages.appendingPathComponent("artifacts/binary"))
        return (packages, resolved)
    }

    private func context(at root: URL, packages: URL, resolved: Data, key: String = String(repeating: "a", count: 64)) throws -> SourcePackageCache.Context {
        let lockfile = root.appendingPathComponent("Package.resolved")
        try resolved.write(to: lockfile)
        return .init(lockfile: lockfile, resolved: resolved, packages: packages,
                     repositoryCache: root.appendingPathComponent("cache"), key: key,
                     projectLock: root.appendingPathComponent("project.lock"))
    }

    func testKeyChangesWithPinsAndToolchain() {
        let data = Data("lockfile".utf8)
        let key = SourcePackageCache.cacheKey(resolved: data, toolchain: "Xcode A")
        XCTAssertEqual(key, SourcePackageCache.cacheKey(resolved: data, toolchain: "Xcode A"))
        XCTAssertNotEqual(key, SourcePackageCache.cacheKey(resolved: data, toolchain: "Xcode B"))
        XCTAssertNotEqual(key, SourcePackageCache.cacheKey(resolved: Data("changed".utf8), toolchain: "Xcode A"))
    }

    func testCloneRebasesMetadataAndPreservesSourceAndReadOnlyModes() throws {
        let root = try temporaryDirectory()
        let source = root.appendingPathComponent("source")
        let clone = root.appendingPathComponent("clone")
        let config = "checkouts/package/.git/config"
        let alternate = "checkouts/package/.git/objects/info/alternates"
        try write("url = \(source.path)/repositories/package\n", at: source.appendingPathComponent(config))
        try write("\(source.path)/repositories/package/objects\n", at: source.appendingPathComponent(alternate))
        try write("gitdir: \(source.path)/checkouts/package/.git/modules/submodule\n", at: source.appendingPathComponent("checkouts/package/submodule/.git"))
        try write("untouched source: \(source.path)/value\n", at: source.appendingPathComponent("checkouts/package/Source.swift"))
        try write("binary", at: source.appendingPathComponent("artifacts/binary"))
        let state = ["object": ["artifacts": [["path": source.path + "/artifacts/binary"]]]]
        try JSONSerialization.data(withJSONObject: state).write(to: source.appendingPathComponent("workspace-state.json"))
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: source.appendingPathComponent(config).path)
        try FileManager.default.createSymbolicLink(atPath: source.appendingPathComponent("artifacts/link").path,
                                                   withDestinationPath: source.appendingPathComponent("artifacts/binary").path)
        try FileManager.default.createSymbolicLink(atPath: source.appendingPathComponent("artifacts/relative").path,
                                                   withDestinationPath: "binary")
        try SourcePackageCache.stageClone(from: source, to: clone)
        XCTAssertEqual(try String(contentsOf: clone.appendingPathComponent(config), encoding: .utf8), "url = \(clone.path)/repositories/package\n")
        XCTAssertEqual(try String(contentsOf: source.appendingPathComponent(config), encoding: .utf8), "url = \(source.path)/repositories/package\n")
        XCTAssertEqual(try String(contentsOf: clone.appendingPathComponent(alternate), encoding: .utf8), "\(clone.path)/repositories/package/objects\n")
        XCTAssertTrue(try String(contentsOf: clone.appendingPathComponent("checkouts/package/submodule/.git"), encoding: .utf8).contains(clone.path))
        XCTAssertTrue(try String(contentsOf: clone.appendingPathComponent("checkouts/package/Source.swift"), encoding: .utf8).contains(source.path))
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: clone.appendingPathComponent(config).path)[.posixPermissions] as? Int, 0o444)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: clone.appendingPathComponent("artifacts/link").path), clone.path + "/artifacts/binary")
        try write("changed", at: clone.appendingPathComponent("artifacts/binary"))
        XCTAssertEqual(try String(contentsOf: source.appendingPathComponent("artifacts/binary"), encoding: .utf8), "binary")
        let lhs = try FileManager.default.attributesOfItem(atPath: source.appendingPathComponent("artifacts/binary").path)
        let rhs = try FileManager.default.attributesOfItem(atPath: clone.appendingPathComponent("artifacts/binary").path)
        XCTAssertNotEqual(lhs[.systemFileNumber] as? UInt64, rhs[.systemFileNumber] as? UInt64)
    }

    func testExistingDestinationAndFailedCloneAreNotOverwritten() throws {
        let root = try temporaryDirectory()
        let source = root.appendingPathComponent("source")
        let destination = root.appendingPathComponent("destination")
        try write("new", at: source.appendingPathComponent("file"))
        try write("user edit", at: destination.appendingPathComponent("file"))
        XCTAssertThrowsError(try SourcePackageCache.stageClone(from: source, to: destination))
        XCTAssertEqual(try String(contentsOf: destination.appendingPathComponent("file"), encoding: .utf8), "user edit")
        try write("invalid JSON", at: source.appendingPathComponent("workspace-state.json"))
        let missing = root.appendingPathComponent("missing")
        XCTAssertThrowsError(try SourcePackageCache.stageClone(from: source, to: missing))
        XCTAssertFalse(FileManager.default.fileExists(atPath: missing.path))
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: root.path).contains { $0.hasPrefix(".staging-") })
    }

    func testExternalSymlinkIsNotPublished() throws {
        let root = try temporaryDirectory()
        let source = root.appendingPathComponent("source")
        try write("private", at: root.appendingPathComponent("external"))
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: source.appendingPathComponent("link").path, withDestinationPath: "../external")
        XCTAssertThrowsError(try SourcePackageCache.stageClone(from: source, to: root.appendingPathComponent("clone")))
    }

    func testSuccessfulOperationPublishesAndSeedsNextWorktree() async throws {
        let root = try temporaryDirectory()
        let fixture = try await fixture(at: root)
        let cache = SourcePackageCache(root: root.appendingPathComponent("cache"), derivedDataRoot: root)
        let first = try context(at: root, packages: fixture.packages, resolved: fixture.resolved)
        let result = try await cache.withCache(context: first) { arguments in
            XCTAssertEqual(arguments, ["-clonedSourcePackagesDirPath", fixture.packages.path])
            return "built"
        }
        XCTAssertEqual(result, "built")
        let template = first.template.appendingPathComponent("SourcePackages")
        try await SourcePackageCache.validate(template, resolved: fixture.resolved)
        let secondRoot = root.appendingPathComponent("another worktree")
        let second = SourcePackageCache.Context(lockfile: first.lockfile, resolved: first.resolved, packages: secondRoot,
                                                repositoryCache: first.repositoryCache, key: first.key,
                                                projectLock: root.appendingPathComponent("second.lock"))
        try await cache.withCache(context: second) { arguments in
            XCTAssertEqual(arguments.last, secondRoot.path)
            try await SourcePackageCache.validate(secondRoot, resolved: fixture.resolved)
        }
        try write("user edit", at: secondRoot.appendingPathComponent("checkouts/package/Source.swift"))
        try await cache.withCache(context: second) { _ in
            XCTAssertEqual(try String(contentsOf: secondRoot.appendingPathComponent("checkouts/package/Source.swift"), encoding: .utf8), "user edit")
        }
        XCTAssertEqual(try String(contentsOf: fixture.packages.appendingPathComponent("checkouts/package/Source.swift"), encoding: .utf8), "let value = 1\n")
    }

    func testFailedOperationIsNotRetriedOrPublished() async throws {
        let root = try temporaryDirectory()
        let fixture = try await fixture(at: root)
        let context = try context(at: root, packages: fixture.packages, resolved: fixture.resolved)
        let cache = SourcePackageCache(root: root, derivedDataRoot: root)
        do {
            try await cache.withCache(context: context) { _ -> Void in throw OrchardError.message("build failed") }
            XCTFail("failure was swallowed")
        } catch { XCTAssertEqual(error.localizedDescription, "build failed") }
        XCTAssertFalse(FileManager.default.fileExists(atPath: context.template.path))
        // Failure releases the lease; a subsequent build can complete.
        try await cache.withCache(context: context) { _ in }
        XCTAssertTrue(FileManager.default.fileExists(atPath: context.template.path))
    }

    func testDirtyPackagesAndChangedLockfileAreNotPublished() async throws {
        let root = try temporaryDirectory()
        let fixture = try await fixture(at: root)
        let context = try context(at: root, packages: fixture.packages, resolved: fixture.resolved)
        let cache = SourcePackageCache(root: root, derivedDataRoot: root)
        try write("edited", at: fixture.packages.appendingPathComponent("checkouts/package/Source.swift"))
        try await cache.withCache(context: context) { _ in }
        XCTAssertFalse(FileManager.default.fileExists(atPath: context.template.path))
        _ = try await git(["checkout", "--", "Source.swift"], at: fixture.packages.appendingPathComponent("checkouts/package"))
        try await cache.withCache(context: context) { _ in
            try Data("changed lockfile".utf8).write(to: context.lockfile)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: context.template.path))
    }

    func testExistingDerivedDataMustMatchExactProjectPath() throws {
        let root = try temporaryDirectory()
        let project = XcodeProject(rootURL: root, fileURL: root.appendingPathComponent("App.xcodeproj"), kind: .project)
        let directory = root.appendingPathComponent("DerivedData/App-test")
        try write("{}", at: directory.appendingPathComponent("SourcePackages/workspace-state.json"))
        let cache = SourcePackageCache(root: root, derivedDataRoot: root.appendingPathComponent("DerivedData"))
        let plist = directory.appendingPathComponent("info.plist")
        try PropertyListSerialization.data(fromPropertyList: ["WorkspacePath": "/elsewhere/App.xcodeproj"], format: .xml, options: 0).write(to: plist)
        XCTAssertNil(cache.existingPackages(for: project))
        try PropertyListSerialization.data(fromPropertyList: ["WorkspacePath": project.fileURL.path], format: .xml, options: 0).write(to: plist)
        XCTAssertEqual(cache.existingPackages(for: project)?.resolvingSymlinksInPath().path, directory.appendingPathComponent("SourcePackages").resolvingSymlinksInPath().path)
    }

    func testWaitingLeaseCanBeCancelledAndReacquired() async throws {
        let root = try temporaryDirectory()
        let path = root.appendingPathComponent("lock")
        let first = try await CacheLease.acquire(path)
        defer { first.unlock() }
        let waiting = Task { try await CacheLease.acquire(path) }
        try await Task.sleep(for: .milliseconds(200))
        waiting.cancel()
        do {
            let unexpected = try await waiting.value
            unexpected.unlock()
            XCTFail("lock waiter ignored cancellation")
        } catch is CancellationError {} catch { XCTFail("unexpected \(error)") }
        first.unlock()
        let next = try await CacheLease.acquire(path)
        next.unlock()
    }

    func testDisabledOrMissingLockfileKeepsDefaultXcodeBehavior() async throws {
        let root = try temporaryDirectory()
        let cacheRoot = root.appendingPathComponent("unused")
        let project = XcodeProject(rootURL: root, fileURL: root.appendingPathComponent("App.xcodeproj"), kind: .project)
        for enabled in [false, true] {
            let cache = SourcePackageCache(root: cacheRoot, derivedDataRoot: root, enabled: enabled)
            try await cache.withCache(project: project) { XCTAssertTrue($0.isEmpty) }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: cacheRoot.path))
    }

    func testExternalGitAlternatesAreRejected() throws {
        let root = try temporaryDirectory()
        let source = root.appendingPathComponent("source")
        try write("/external/cache/objects\n", at: source.appendingPathComponent("checkouts/package/.git/objects/info/alternates"))
        XCTAssertThrowsError(try SourcePackageCache.stageClone(from: source, to: root.appendingPathComponent("clone")))
    }

    func testSameProjectOperationsSerialize() async throws {
        actor Activity {
            var current = 0
            var maximum = 0
            func start() { current += 1; maximum = max(maximum, current) }
            func finish() { current -= 1 }
        }
        let root = try temporaryDirectory()
        let fixture = try await fixture(at: root)
        let context = try context(at: root, packages: fixture.packages, resolved: fixture.resolved)
        let cache = SourcePackageCache(root: root, derivedDataRoot: root)
        let activity = Activity()
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<2 {
                group.addTask {
                    try await cache.withCache(context: context) { _ in
                        await activity.start()
                        try await Task.sleep(for: .milliseconds(200))
                        await activity.finish()
                    }
                }
            }
            try await group.waitForAll()
        }
        let maximum = await activity.maximum
        XCTAssertEqual(maximum, 1)
    }

    func testGeneratedPackageWorkspacesStayOutOfTemplates() async throws {
        for trackedWorkspace in [false, true] {
            let root = try temporaryDirectory()
            let fixture = try await fixture(at: root, trackedWorkspace: trackedWorkspace)
            let checkout = fixture.packages.appendingPathComponent("checkouts/package")
            try write(".swiftpm/\n.build/\n", at: checkout.appendingPathComponent(".git/info/exclude"))
            try write("generated IDE state", at: checkout.appendingPathComponent(".swiftpm/xcode/generated"))
            let context = try context(at: root, packages: fixture.packages, resolved: fixture.resolved)
            let cache = SourcePackageCache(root: root, derivedDataRoot: root)
            try await cache.withCache(context: context) { _ in }
            XCTAssertTrue(FileManager.default.fileExists(atPath: context.template.path))
            let snapshot = context.template.appendingPathComponent("SourcePackages/checkouts/package/.swiftpm/xcode")
            XCTAssertFalse(FileManager.default.fileExists(atPath: snapshot.appendingPathComponent("generated").path))
            XCTAssertEqual(FileManager.default.fileExists(atPath: snapshot.appendingPathComponent("shared").path), trackedWorkspace)
            XCTAssertTrue(FileManager.default.fileExists(atPath: checkout.appendingPathComponent(".swiftpm/xcode/generated").path))
        }
    }

    func testEmptyIgnoredPackageWorkspaceIsNotTreatedAsSourceModification() async throws {
        let root = try temporaryDirectory()
        let fixture = try await fixture(at: root)
        let checkout = fixture.packages.appendingPathComponent("checkouts/package")
        try write(".swiftpm/\n", at: checkout.appendingPathComponent(".git/info/exclude"))
        try FileManager.default.createDirectory(at: checkout.appendingPathComponent(".swiftpm/xcode"), withIntermediateDirectories: true)
        let context = try context(at: root, packages: fixture.packages, resolved: fixture.resolved)
        try await SourcePackageCache(root: root, derivedDataRoot: root).withCache(context: context) { _ in }
        XCTAssertTrue(FileManager.default.fileExists(atPath: context.template.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: checkout.appendingPathComponent(".swiftpm/xcode").path))
    }

    func testTemplateCountIsBounded() async throws {
        let root = try temporaryDirectory()
        let fixture = try await fixture(at: root)
        let cache = SourcePackageCache(root: root, derivedDataRoot: root)
        for index in 0..<4 {
            let context = try context(at: root, packages: fixture.packages, resolved: fixture.resolved,
                                      key: String(repeating: String(index), count: 64))
            try await cache.withCache(context: context) { _ in }
        }
        let templates = try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("cache/templates").path)
        XCTAssertEqual(templates.count, 3)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.packages.path))
    }
}
