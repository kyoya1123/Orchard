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

    func simulator(_ f: Fixture, name: String = "feature-example", state: String = "Shutdown",
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

    func testBootedOrphanIsPreservedEvenWhenWorktreeIsMissing() async throws {
        let f = try fixture(existing: false)
        let id = try await simulator(f, state: "Booted")
        let dd = try cache(f)
        let report = await f.worker.run(apply: true, discover: false)
        XCTAssertNil(report.error)
        let calls = await f.commands.verbs
        XCTAssertTrue(calls.filter { ["shutdown", "delete"].contains($0) }.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dd.path))
        XCTAssertTrue(report.actions.contains { $0.target == id && $0.reason == "booted-or-transitioning" && $0.outcome == "preserved" })
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
        XCTAssertTrue(report.actions.allSatisfy { $0.outcome == "preserved" })
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
        XCTAssertTrue(report.actions.allSatisfy { $0.outcome == "preserved" })
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

    func testSimulatorLeaseProtectsPreparationAndBootRacePreventsDeletion() async throws {
        let f = try fixture(existing: false)
        let id = try await simulator(f)
        let lease = try XCTUnwrap(ArtifactLease.tryAcquire(f.store.simulatorLock(id), shared: true))
        let locked = await f.worker.run(apply: true, discover: false)
        XCTAssertTrue(locked.actions.contains { $0.reason == "active-build-or-install" })
        lease.close()
        await f.commands.bootDuringInspection(id)
        let raced = await f.worker.run(apply: true, discover: false)
        XCTAssertTrue(raced.actions.contains { $0.outcome == "preserved" })
        let calls = await f.commands.verbs
        XCTAssertFalse(calls.contains("shutdown"))
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
        XCTAssertTrue(report.actions.allSatisfy { $0.outcome == "preserved" })
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
        XCTAssertTrue(report.actions.allSatisfy { $0.outcome == "preserved" })
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

    func testSimulatorOneDayBoundaryUsesMetadataAndDoesNotTouchDerivedData() async throws {
        let f = try fixture()
        let old = try await simulator(f, age: ArtifactCleanup.simulatorRetention + 1)
        let boundary = try await simulator(f, age: ArtifactCleanup.simulatorRetention)
        let recent = try await simulator(f, age: ArtifactCleanup.simulatorRetention - 1)
        let dd = try cache(f, age: 9 * 86400)
        let preview = await f.worker.run(apply: false, discover: false, scope: .simulators)
        XCTAssertEqual(preview.actions.filter { $0.outcome == "would-remove" }.map(\.target), [old])
        let report = await f.worker.run(apply: true, discover: false, scope: .simulators)
        XCTAssertTrue(report.actions.contains { $0.target == old && $0.reason == "unused-over-1-day" && $0.outcome == "removed" })
        XCTAssertTrue(report.actions.contains { $0.target == boundary && $0.outcome == "preserved" })
        XCTAssertTrue(report.actions.contains { $0.target == recent && $0.outcome == "preserved" })
        XCTAssertTrue(FileManager.default.fileExists(atPath: dd.path))
    }

    func testUnknownUsageAndRecentCoreSimulatorBootArePreserved() async throws {
        let f = try fixture()
        let unknown = try await simulator(f)
        try f.store.write(ArtifactSimulator(udid: unknown, name: "feature-example", owners: [f.owner], lastUsedAt: 0),
                          to: f.store.simulatorURL(unknown))
        await f.commands.setDates(unknown, used: "invalid", booted: nil)
        let recent = try await simulator(f, age: 9 * 86400)
        await f.commands.setDates(recent, used: nil, booted: ISO8601DateFormatter().string(from: clock))
        let report = await f.worker.run(apply: true, discover: false, scope: .simulators)
        XCTAssertTrue(report.actions.contains { $0.target == unknown && $0.reason == "unknown-last-use" })
        XCTAssertTrue(report.actions.allSatisfy { $0.outcome == "preserved" })
    }

    func testExternalWorktreeProcessAndExternalBuildProtectOldSimulator() async throws {
        for externalBuild in [true, false] {
            let f = try fixture()
            _ = try await simulator(f, age: 3 * 86400)
            if externalBuild { await f.commands.setBusy(external: true) }
            else { await f.commands.setOpenPath(f.owner.worktreePath) }
            let report = await f.worker.run(apply: true, discover: false, scope: .simulators)
            XCTAssertTrue(report.actions.contains { $0.reason == "external-use" && $0.outcome == "preserved" })
            let calls = await f.commands.verbs
            XCTAssertFalse(calls.contains("delete"))
        }
    }

    func testMergedOwnerRequiresCleanNonDefaultBranchAndCachedAncestry() async throws {
        for mode in ["merged", "dirty", "unmerged", "default", "detached", "missing-remote", "renamed-branch"] {
            let f = try fixture()
            let id = try await simulator(f)
            await f.commands.setMerge(mode, worktree: f.owner.worktreePath)
            let report = await f.worker.run(apply: true, discover: false, scope: .simulators)
            if mode == "merged" {
                XCTAssertTrue(report.actions.contains { $0.target == id && $0.reason == "merged-into-cached-origin-default" && $0.outcome == "removed" })
            } else {
                XCTAssertTrue(report.actions.allSatisfy { $0.outcome == "preserved" }, mode)
            }
        }
    }

    func testLegacyPackageCacheAndLiveOwnerAreNotDeleted() async throws {
        let f = try fixture()
        let packages = f.root.appendingPathComponent("packages")
        let repository = packages.appendingPathComponent("repo-cache")
        let directory = repository.appendingPathComponent("worktrees/\(ArtifactStore.key(f.owner.projectPath))")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let worker = ArtifactCleanup(store: f.store, derivedData: f.worker.derivedData, devices: f.worker.devices,
                                     sourcePackages: packages, command: { try await f.commands.run($0, $1) })
        let legacy = await worker.run(apply: true, discover: false, scope: .sourcePackages)
        XCTAssertEqual(legacy.actions.first?.reason, "package-ownership-unverified")
        try f.store.write(SourcePackageOwnership(owner: f.owner, repositoryCacheID: "repo-cache", resolved: Data()),
                          to: directory.appendingPathComponent("owner.json"))
        let live = await worker.run(apply: true, discover: false, scope: .sourcePackages)
        XCTAssertEqual(live.actions.first?.reason, "live-or-excluded-worktree")
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.path))
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
    var openPath = ""
    var bootOnInspection: String?
    var mergeMode = ""
    var mergeWorktree = ""
    func setOpenPath(_ path: String) { openPath = path }
    func bootDuringInspection(_ id: String) { bootOnInspection = id }
    func setDates(_ id: String, used: String?, booted: String?) {
        devices[id]?["lastUsedAt"] = used
        devices[id]?["lastBootedAt"] = booted
    }
    func setMerge(_ mode: String, worktree: String) { mergeMode = mode; mergeWorktree = worktree }

    func add(_ id: String, name: String, state: String, date: Date) {
        devices[id] = ["udid": id, "name": name, "state": state,
                       "lastUsedAt": ISO8601DateFormatter().string(from: date)]
    }
    func failShutdown() { shutdownFails = true }
    func setBusy(external: Bool) { externalBuild = external; dirtyPackages = !external }
    func startBuildDuringPackageCheck() { buildDuringPackageCheck = true }

    func run(_ tool: String, _ args: [String]) throws -> String {
        if tool == "/bin/ps" { return externalBuild ? "123 /usr/bin/xcodebuild\n" : "" }
        if tool == "/usr/sbin/lsof" {
            if let id = bootOnInspection { devices[id]?["state"] = "Booted"; bootOnInspection = nil }
            return openPath.isEmpty ? "" : "n" + openPath + "\n"
        }
        if tool == "/usr/bin/git" {
            if !mergeMode.isEmpty {
                if args.contains("--show-toplevel") { return mergeWorktree }
                if args.contains("symbolic-ref") {
                    if args.contains("refs/remotes/origin/HEAD") { return mergeMode == "missing-remote" ? "" : "refs/remotes/origin/main" }
                    return mergeMode == "detached" ? "" : (mergeMode == "default" ? "refs/heads/main" : (mergeMode == "renamed-branch" ? "refs/heads/other" : "refs/heads/feature/example"))
                }
                if args.contains("rev-parse") { return "abc" }
                if args.contains("merge-base") { return mergeMode == "unmerged" ? "def" : "abc" }
                if args.contains("status") { return mergeMode == "dirty" ? " M Source.swift" : "" }
            }
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
