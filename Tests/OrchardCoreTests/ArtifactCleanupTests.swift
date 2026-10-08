import Foundation
@testable import OrchardCore
import XCTest

final class ArtifactCleanupTests: XCTestCase, @unchecked Sendable {
    let clock = Date(timeIntervalSince1970: 2_000_000_000)

    struct Fixture {
        let root: URL
        let store: ArtifactStore
        let owner: ArtifactOwner
        let worker: ArtifactCleanup
        let commands: CleanupCommands
    }

    func fixture(existing: Bool = true) throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Orchard Cleanup Tests-\(UUID().uuidString)").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("external-codex/worktree")
        if existing {
            try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
            try Data("uncommitted source".utf8).write(to: path.appendingPathComponent("Source.swift"))
        }
        let owner = ArtifactOwner(projectPath: path.appendingPathComponent("App.xcodeproj").path,
                                  worktreePath: path.path, repositoryPath: root.appendingPathComponent("repo").path)
        let store = ArtifactStore(root: root.appendingPathComponent("state"))
        try store.write(ArtifactProject(owner: owner, lastUsedAt: 0), to: store.projectURL(owner.projectPath))
        let commands = CleanupCommands()
        let date = clock
        let worker = ArtifactCleanup(store: store, derivedData: root.appendingPathComponent("DerivedData"),
            devices: root.appendingPathComponent("Devices"), now: { date }, command: { tool, args in
                try await commands.run(tool, args)
            })
        return Fixture(root: root, store: store, owner: owner, worker: worker, commands: commands)
    }

    func simulator(_ f: Fixture, name: String = "feature-example", state: String = "Booted",
                   age: TimeInterval = 0, owners: Set<ArtifactOwner>? = nil) async throws -> String {
        let id = UUID().uuidString
        let record = ArtifactSimulator(udid: id, name: name, owners: owners ?? [f.owner],
                                       lastUsedAt: clock.timeIntervalSince1970 - age)
        try f.store.write(record, to: f.store.simulatorURL(id))
        await f.commands.add(id, name: name, state: state, date: Date(timeIntervalSince1970: record.lastUsedAt))
        return id
    }

    func cache(_ f: Fixture, name: String = "App-hash", age: TimeInterval = 0,
               workspace: String? = nil) throws -> URL {
        let path = f.worker.derivedData.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        let data = try PropertyListSerialization.data(fromPropertyList: ["WorkspacePath": workspace ?? f.owner.projectPath], format: .xml, options: 0)
        try data.write(to: path.appendingPathComponent("info.plist"))
        try Data("build product".utf8).write(to: path.appendingPathComponent("cached-object"))
        try FileManager.default.setAttributes([.modificationDate: clock.addingTimeInterval(-age)], ofItemAtPath: path.path)
        return path
    }

    func testBootedOrphanIsStoppedAndRemovedEvenWhenRecentlyUsed() async throws {
        let f = try fixture(existing: false)
        let id = try await simulator(f)
        let dd = try cache(f)
        let report = await f.worker.run(apply: true, discover: false)
        XCTAssertNil(report.error)
        let calls = await f.commands.verbs
        XCTAssertEqual(calls.filter { ["shutdown", "delete"].contains($0) }, ["shutdown", "delete"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: dd.path))
        XCTAssertTrue(report.actions.contains { $0.target == id && $0.reason == "missing-worktree" && $0.outcome == "removed" })
    }

    func testExistingWorktreeSevenDayBoundaryAndSourceArePreserved() async throws {
        let f = try fixture()
        let expired = try cache(f, name: "App-expired", age: ArtifactCleanup.retention)
        let recent = try cache(f, name: "App-recent", age: ArtifactCleanup.retention - 1)
        let id = try await simulator(f, age: ArtifactCleanup.retention)
        let report = await f.worker.run(apply: true, discover: false)
        XCTAssertNil(report.error)
        XCTAssertFalse(FileManager.default.fileExists(atPath: expired.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: recent.path))
        XCTAssertTrue(report.actions.contains { $0.target == id && $0.outcome == "removed" })
        XCTAssertEqual(try String(contentsOfFile: f.owner.worktreePath + "/Source.swift", encoding: .utf8), "uncommitted source")
    }

    func testRecentSimulatorActivityOverridesOldRecordAndLatestBuildLogWins() async throws {
        let f = try fixture()
        let id = try await simulator(f, age: 8 * 86400)
        await f.commands.add(id, name: "feature-example", state: "Booted", date: clock)
        let dd = try cache(f, age: 8 * 86400)
        let logs = dd.appendingPathComponent("Logs/Build")
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.modificationDate: clock], ofItemAtPath: logs.path)
        try FileManager.default.setAttributes([.modificationDate: clock.addingTimeInterval(-8 * 86400)], ofItemAtPath: dd.path)
        let report = await f.worker.run(apply: true, discover: false)
        XCTAssertTrue(report.actions.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dd.path))
    }

    func testStandardBaseRenamedAndUnregisteredDevicesRemain() async throws {
        let f = try fixture(existing: false)
        for name in ["iPhone 18 Pro", "iPad Pro", "base", "Orchard Base private"] {
            _ = try await simulator(f, name: name)
        }
        let renamed = try await simulator(f)
        await f.commands.add(renamed, name: "my custom device", state: "Booted", date: clock)
        await f.commands.add(UUID().uuidString, name: "unknown-branch", state: "Booted", date: clock)
        let report = await f.worker.run(apply: true, discover: false)
        XCTAssertTrue(report.actions.isEmpty)
        let calls = await f.commands.verbs
        XCTAssertFalse(calls.contains("shutdown"))
        XCTAssertFalse(calls.contains("delete"))
    }

    func testActiveBuildLeaseProtectsBothArtifacts() async throws {
        let f = try fixture(existing: false)
        let dd = try cache(f)
        _ = try await simulator(f)
        let lease = try XCTUnwrap(ArtifactLease.tryAcquire(f.store.projectLock(f.owner.projectPath), shared: true))
        defer { lease.close() }
        let report = await f.worker.run(apply: true, discover: false)
        XCTAssertEqual(report.actions.count, 2)
        XCTAssertTrue(report.actions.allSatisfy { $0.outcome == "preserved" })
        XCTAssertTrue(FileManager.default.fileExists(atPath: dd.path))
        let calls = await f.commands.verbs
        XCTAssertFalse(calls.contains("shutdown"))
    }

    func testSimulatorLeaseProtectsPreparationAndShutdownFailurePreventsDeletion() async throws {
        let f = try fixture(existing: false)
        let id = try await simulator(f)
        let lease = try XCTUnwrap(ArtifactLease.tryAcquire(f.store.simulatorLock(id), shared: true))
        let locked = await f.worker.run(apply: true, discover: false)
        XCTAssertTrue(locked.actions.contains { $0.outcome == "preserved" })
        lease.close()
        await f.commands.failShutdown()
        let failed = await f.worker.run(apply: true, discover: false)
        XCTAssertTrue(failed.actions.contains { $0.outcome == "preserved" })
        let calls = await f.commands.verbs
        XCTAssertFalse(calls.contains("delete"))
    }

    func testAnyExistingOwnerPreservesRecentSharedSimulator() async throws {
        let f = try fixture(existing: false)
        let path = f.root.appendingPathComponent("second-owner")
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        let alive = ArtifactOwner(projectPath: path.appendingPathComponent("App.xcodeproj").path,
                                  worktreePath: path.path, repositoryPath: f.owner.repositoryPath)
        _ = try await simulator(f, owners: [f.owner, alive])
        let report = await f.worker.run(apply: true, discover: false)
        XCTAssertTrue(report.actions.isEmpty)
    }

    func testUnknownExternalDataSymlinksAndExcludedProjectRemain() async throws {
        let f = try fixture(existing: false)
        let unknown = try cache(f, name: "App-unknown", workspace: f.owner.worktreePath + "-other/App.xcodeproj")
        let dd = try cache(f)
        try f.store.write(ArtifactCleanup.Settings(excludedPaths: [f.owner.worktreePath]), to: f.store.root.appendingPathComponent("settings.json"))
        let link = f.worker.derivedData.appendingPathComponent("App-link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: dd)
        _ = try await simulator(f)
        let report = await f.worker.run(apply: true, discover: false)
        XCTAssertTrue(report.actions.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: unknown.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dd.path))
    }

    func testModifiedPackagesAndExternalBuildsRemain() async throws {
        for external in [false, true] {
            let f = try fixture(existing: false)
            let dd = try cache(f)
            try FileManager.default.createDirectory(at: dd.appendingPathComponent("SourcePackages/checkouts/package"), withIntermediateDirectories: true)
            await f.commands.setBusy(external: external)
            let report = await f.worker.run(apply: true, discover: false)
            XCTAssertTrue(report.actions.contains { $0.reason == (external ? "external-build" : "modified-packages") })
            XCTAssertTrue(FileManager.default.fileExists(atPath: dd.path))
        }
    }

    func testDryRunNeverStopsOrRemovesAndWorkerLockCoalesces() async throws {
        let f = try fixture(existing: false)
        let dd = try cache(f)
        _ = try await simulator(f)
        let report = await f.worker.run(apply: false, discover: false)
        XCTAssertEqual(report.actions.count, 2)
        XCTAssertTrue(report.actions.allSatisfy { $0.outcome == "would-remove" })
        XCTAssertTrue(FileManager.default.fileExists(atPath: dd.path))
        let calls = await f.commands.verbs
        XCTAssertFalse(calls.contains("shutdown"))
        let lease = try XCTUnwrap(ArtifactLease.tryAcquire(f.store.root.appendingPathComponent("cleanup.lock")))
        defer { lease.close() }
        let overlapping = await f.worker.run(apply: true, discover: false)
        XCTAssertTrue(overlapping.alreadyRunning)
    }

    func testExternalBuildStartingDuringPackageInspectionPreventsRemoval() async throws {
        let f = try fixture(existing: false)
        let dd = try cache(f)
        try FileManager.default.createDirectory(at: dd.appendingPathComponent("SourcePackages/checkouts/package"), withIntermediateDirectories: true)
        await f.commands.startBuildDuringPackageCheck()
        let report = await f.worker.run(apply: true, discover: false)
        XCTAssertTrue(report.actions.contains { $0.reason == "external-build" && $0.outcome == "preserved" })
        XCTAssertTrue(FileManager.default.fileExists(atPath: dd.path))
    }

    func testOrphanOwnershipUsesPathBoundariesAndRecordedCodexAssociation() throws {
        let f = try fixture()
        let main = ArtifactOwner(projectPath: f.owner.repositoryPath + "/App.xcodeproj",
                                 worktreePath: f.owner.repositoryPath, repositoryPath: f.owner.repositoryPath)
        let known = [ArtifactProject(owner: main, lastUsedAt: 0)]
        let removed = f.owner.repositoryPath + "/.claude/worktrees/removed/App.xcodeproj"
        XCTAssertEqual(f.worker.owner(for: removed, known: known)?.worktreePath,
                       f.owner.repositoryPath + "/.claude/worktrees/removed")
        XCTAssertNil(f.worker.owner(for: f.owner.projectPath, known: known))
        XCTAssertEqual(f.worker.owner(for: f.owner.projectPath, known: known + [ArtifactProject(owner: f.owner, lastUsedAt: 0)]), f.owner)
        XCTAssertFalse(ArtifactCleanup.contains("/repo-other/App.xcodeproj", in: "/repo"))
    }
}

actor CleanupCommands {
    var devices: [String: [String: String]] = [:]
    var verbs: [String] = []
    var shutdownFails = false
    var externalBuild = false
    var dirtyPackages = false
    var buildDuringPackageCheck = false

    func add(_ id: String, name: String, state: String, date: Date) {
        devices[id] = ["udid": id, "name": name, "state": state,
                       "lastUsedAt": ISO8601DateFormatter().string(from: date)]
    }
    func failShutdown() { shutdownFails = true }
    func setBusy(external: Bool) { externalBuild = external; dirtyPackages = !external }
    func startBuildDuringPackageCheck() { buildDuringPackageCheck = true }

    func run(_ tool: String, _ args: [String]) throws -> String {
        if tool == "/bin/ps" { return externalBuild ? "123 /usr/bin/xcodebuild\n" : "" }
        if tool == "/usr/bin/git" {
            if buildDuringPackageCheck { externalBuild = true }
            return dirtyPackages ? " M Source.swift\n" : ""
        }
        guard tool == "/usr/bin/xcrun", args.first == "simctl" else { throw OrchardError.message("Unexpected command") }
        let verb = args[3]
        verbs.append(verb)
        switch verb {
        case "list":
            return String(decoding: try JSONSerialization.data(withJSONObject: ["devices": ["runtime": Array(devices.values)]]), as: UTF8.self)
        case "shutdown":
            if shutdownFails { throw OrchardError.message("Shutdown failed") }
            devices[args[4]]?["state"] = "Shutdown"
            devices[args[4]]?["lastUsedAt"] = ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: 2_000_000_000))
            return ""
        case "delete":
            devices.removeValue(forKey: args[4])
            return ""
        default: throw OrchardError.message("Unexpected simctl verb")
        }
    }
}
