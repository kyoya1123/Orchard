import Foundation
@testable import OrchardCore
import XCTest

final class ArchivedDeviceCleanupTests: XCTestCase, @unchecked Sendable {
    struct Fixture {
        let root: URL
        let store: ArtifactStore
        let worker: ArchivedDeviceCleanup
        let commands: CleanupCommands
        let id: String
        let owner: ArtifactOwner
        let session: URL
    }
    func fixture(archived: Bool = true) async throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Archived Devices-\(UUID().uuidString)").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let store = ArtifactStore(root: root.appendingPathComponent("state"))
        let owner = ArtifactOwner(projectPath: "/work/App.xcodeproj", worktreePath: "/work", repositoryPath: "/repo")
        let id = UUID().uuidString
        try store.write(ArtifactSimulator(udid: id, name: "feature-example", owners: [owner], lastUsedAt: 200), to: store.simulatorURL(id))
        let session = root.appendingPathComponent("Library/Application Support/Claude/claude-code-sessions/account/org/local_one.json")
        try FileManager.default.createDirectory(at: session.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: ["sessionId": "local_one", "cwd": "/work", "branch": "feature/example", "isArchived": archived, "createdAt": 100000]).write(to: session)
        let commands = CleanupCommands()
        await commands.add(id, name: "feature-example", state: "Booted", date: Date(timeIntervalSince1970: 200))
        let worker = ArchivedDeviceCleanup(store: store, devices: root.appendingPathComponent("Devices"), home: root, environment: [:]) { tool, args in
            try await commands.run(tool, args)
        }
        return Fixture(root: root, store: store, worker: worker, commands: commands, id: id, owner: owner, session: session)
    }
    func testArchivedBootedAppAndItsConsoleAreStoppedButOtherDeviceRemains() async throws {
        let f = try await fixture()
        let other = UUID().uuidString
        await f.commands.add(other, name: "unrelated", state: "Booted", date: Date())
        let app = f.worker.devices.appendingPathComponent(f.id + "/data/Containers/Bundle/Application/id/App.app/App").path
        await f.commands.setUsage(processes: "31 \(app)\n32 /tools/simctl", files: "p31\nn\(app)\np32\nn/work\n",
            arguments: "32 /tools/simctl launch --console \(f.id) example.app")
        await f.commands.clearFilesWhenStopped()
        let preview = await f.worker.run(apply: false)
        XCTAssertEqual(preview.actions.first?.outcome, "would-remove")
        var verbs = await f.commands.verbs
        XCTAssertFalse(verbs.contains("shutdown"))
        let applied = await f.worker.run(apply: true)
        XCTAssertEqual(applied.actions.first?.outcome, "removed")
        verbs = await f.commands.verbs
        XCTAssertEqual(verbs.filter { ["shutdown", "delete"].contains($0) }, ["shutdown", "delete"])
        let remains = await f.commands.devices
        XCTAssertEqual(remains[other]?["state"], "Booted")
    }
    func testNonArchivedAndBusyLeaseRemain() async throws {
        let active = try await fixture(archived: false)
        let result = await active.worker.run(apply: true)
        XCTAssertEqual(result.actions.first?.outcome, "preserved")
        let f = try await fixture()
        let lease = try XCTUnwrap(ArtifactLease.tryAcquire(f.store.simulatorLock(f.id), shared: true))
        defer { lease.close() }
        let busy = await f.worker.run(apply: true)
        XCTAssertEqual(busy.actions.first?.reason, "active-build-or-install")
    }
    func testShutdownFailureAndUnarchiveAfterShutdownDoNotDelete() async throws {
        let f = try await fixture()
        await f.commands.failShutdown()
        let failed = await f.worker.run(apply: true)
        XCTAssertEqual(failed.actions.first?.outcome, "shutdown-unconfirmed")
        let g = try await fixture()
        let worker = ArchivedDeviceCleanup(store: g.store, devices: g.worker.devices, home: g.root, environment: [:]) { tool, args in
            let result = try await g.commands.run(tool, args)
            if args.contains("shutdown") {
                var session = try JSONSerialization.jsonObject(with: Data(contentsOf: g.session)) as! [String: Any]
                session["isArchived"] = false
                try JSONSerialization.data(withJSONObject: session).write(to: g.session)
            }
            return result
        }
        let unarchived = await worker.run(apply: true)
        XCTAssertEqual(unarchived.actions.first?.outcome, "stopped-preserved")
        let verbs = await g.commands.verbs
        XCTAssertFalse(verbs.contains("delete"))
    }
    func testIdleBuildServiceDoesNotBlockButTargetFilesDo() async throws {
        let f = try await fixture()
        await f.commands.setUsage(processes: "99 /tools/SWBBuildService")
        let idle = await f.worker.run(apply: false)
        XCTAssertEqual(idle.actions.first?.outcome, "would-remove")
        await f.commands.setUsage(processes: "99 /tools/SWBBuildService", files: "p99\nn/work/Source.swift")
        let busy = await f.worker.run(apply: false)
        XCTAssertEqual(busy.actions.first?.outcome, "preserved")
    }
}
