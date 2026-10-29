import Foundation
@testable import OrchardCore
import XCTest

final class OrphanedDeviceCleanupTests: XCTestCase, @unchecked Sendable {
    struct Fixture {
        let root: URL
        let store: ArtifactStore
        let worker: OrphanedDeviceCleanup
        let commands: CleanupCommands
        let id: String
        let owner: ArtifactOwner
    }
    func fixture(existing: Bool = false, shared: Bool = false, unknown: Bool = false) async throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("OrphanDevices-\(UUID())").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let store = ArtifactStore(root: root.appendingPathComponent("state"))
        let worktree = root.appendingPathComponent("worktree")
        if existing { try FileManager.default.createDirectory(at: worktree, withIntermediateDirectories: true) }
        let owner = ArtifactOwner(projectPath: worktree.appendingPathComponent("App.xcodeproj").path,
            worktreePath: worktree.path, repositoryPath: root.path)
        var owners: Set<ArtifactOwner> = unknown ? [] : [owner]
        if shared {
            owners.insert(ArtifactOwner(projectPath: root.appendingPathComponent("Other.xcodeproj").path,
                worktreePath: root.path, repositoryPath: root.path))
        }
        let id = UUID().uuidString
        try store.write(ArtifactSimulator(udid: id, name: "feature-example", owners: owners, lastUsedAt: 200), to: store.simulatorURL(id))
        let commands = CleanupCommands()
        await commands.add(id, name: "feature-example", state: "Booted", date: Date(timeIntervalSince1970: 200))
        let worker = OrphanedDeviceCleanup(store: store, devices: root.appendingPathComponent("Devices"),
            home: root, environment: [:]) { tool, args in
                guard tool == "/usr/bin/xcrun" else { throw OrchardError.message("Unexpected process/session inspection") }
                return try await commands.run(tool, args)
            }
        return Fixture(root: root, store: store, worker: worker, commands: commands, id: id, owner: owner)
    }
    func testMissingWorktreeStopsAndRemovesOnlyItsDeviceWithoutSessionMetadata() async throws {
        let f = try await fixture()
        let other = UUID().uuidString
        await f.commands.add(other, name: "unrelated", state: "Booted", date: Date())
        let preview = await f.worker.run(apply: false)
        XCTAssertEqual(preview.actions.first?.outcome, "would-remove")
        let before = await f.commands.verbs
        XCTAssertFalse(before.contains("shutdown"))
        let applied = await f.worker.run(apply: true)
        XCTAssertNil(applied.error)
        XCTAssertEqual(applied.actions.first?.outcome, "removed")
        let verbs = await f.commands.verbs
        XCTAssertEqual(verbs.filter { ["shutdown", "delete"].contains($0) }, ["shutdown", "delete"])
        let remains = await f.commands.devices
        XCTAssertEqual(remains[other]?["state"], "Booted")
    }
    func testExistingSharedAndUnknownWorktreesArePreserved() async throws {
        for mode in ["existing", "shared", "unknown"] {
            let f = try await fixture(existing: mode == "existing", shared: mode == "shared", unknown: mode == "unknown")
            let result = await f.worker.run(apply: true)
            XCTAssertEqual(result.actions.first?.outcome, "preserved", mode)
            let verbs = await f.commands.verbs
            XCTAssertFalse(verbs.contains("shutdown"), mode)
            XCTAssertFalse(verbs.contains("delete"), mode)
        }
    }
    func testInaccessibleWorktreeDoesNotProveAbsence() async throws {
        let f = try await fixture()
        let worker = OrphanedDeviceCleanup(store: f.store, devices: f.worker.devices, home: f.root, environment: [:],
            isMissing: { _ in throw POSIXError(.EACCES) }) { try await f.commands.run($0, $1) }
        let result = await worker.run(apply: true)
        XCTAssertNotNil(result.error)
        XCTAssertEqual(result.actions.first?.outcome, "preserved")
        let verbs = await f.commands.verbs
        XCTAssertFalse(verbs.contains("shutdown"))
    }
    func testRecreatedWorktreeAfterShutdownPreventsDeletion() async throws {
        let f = try await fixture()
        let worker = OrphanedDeviceCleanup(store: f.store, devices: f.worker.devices, home: f.root, environment: [:]) { tool, args in
            let result = try await f.commands.run(tool, args)
            if args.contains("shutdown") { try FileManager.default.createDirectory(atPath: f.owner.worktreePath, withIntermediateDirectories: true) }
            return result
        }
        let result = await worker.run(apply: true)
        XCTAssertEqual(result.actions.first?.outcome, "stopped-preserved")
        let verbs = await f.commands.verbs
        XCTAssertFalse(verbs.contains("delete"))
    }
    func testMissingCheckPreservesSymlinksAndNonDirectories() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Presence-\(UUID())").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertFalse(try MissingWorktree.check(root.path))
        XCTAssertTrue(try MissingWorktree.check(root.appendingPathComponent("gone/child").path))
        let link = root.appendingPathComponent("dangling")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: root.appendingPathComponent("gone").path)
        XCTAssertThrowsError(try MissingWorktree.check(link.path))
        let file = root.appendingPathComponent("file")
        try Data().write(to: file)
        XCTAssertThrowsError(try MissingWorktree.check(file.appendingPathComponent("child").path))
    }
}
