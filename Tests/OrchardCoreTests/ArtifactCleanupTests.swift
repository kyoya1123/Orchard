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

    func fixture(existing: Bool = true, realGit: Bool = false) throws -> Fixture {
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
            devices: root.appendingPathComponent("Devices"), deviceHome: root, deviceEnvironment: [:], now: { date }, command: { tool, args in
                if realGit && tool == "/usr/bin/git" {
                    return try await ProcessRunner.run(executableURL: URL(fileURLWithPath: tool),
                        arguments: args, currentDirectoryURL: nil)
                }
                return try await commands.run(tool, args)
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

    func testOrphanedScopeDoesNotCollectUnrelatedDerivedDataOrPackages() async throws {
        let f = try fixture(existing: false)
        let dd = try cache(f)
        let packages = f.root.appendingPathComponent("packages")
        let marker = packages.appendingPathComponent("repo/worktrees/unknown/owner.json")
        try FileManager.default.createDirectory(at: marker.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("invalid ownership; must not be inspected in archive-only scope".utf8).write(to: marker)
        let worker = ArtifactCleanup(store: f.store, derivedData: f.worker.derivedData, devices: f.worker.devices,
            sourcePackages: packages, deviceHome: f.root, deviceEnvironment: [:],
            command: { _, _ in XCTFail("No device records should require commands"); return "" })
        let report = await worker.run(apply: true, discover: false, scope: .orphanedDevices)
        XCTAssertNil(report.error)
        XCTAssertTrue(report.actions.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dd.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))
    }

    func testBootedOrphanIsPreviewedThenStoppedAndDeleted() async throws {
        let f = try fixture(existing: false)
        let id = try await simulator(f, state: "Booted")
        let dd = try cache(f)
        let preview = await f.worker.run(apply: false, discover: false, scope: .simulators)
        XCTAssertEqual(preview.actions.first?.target, id)
        XCTAssertEqual(preview.actions.first?.reason, "missing-worktree")
        XCTAssertEqual(preview.actions.first?.outcome, "would-remove")
        XCTAssertEqual(preview.actions.first?.state, "Booted")
        XCTAssertEqual(preview.actions.first?.requiresShutdown, true)
        let previewCalls = await f.commands.verbs
        XCTAssertFalse(previewCalls.contains("shutdown"))
        XCTAssertFalse(previewCalls.contains("delete"))
        let report = await f.worker.run(apply: true, discover: false)
        XCTAssertNil(report.error)
        let calls = await f.commands.verbs
        XCTAssertEqual(calls.filter { ["shutdown", "delete"].contains($0) }, ["shutdown", "delete"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: dd.path))
        XCTAssertTrue(report.actions.contains { $0.target == id && $0.reason == "missing-worktree" && $0.outcome == "removed" })
    }

    func testCacheBoundaryAndSourcePreservedWhileUnusedDeviceExpires() async throws {
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

    func testRecentMeaningfulActivityOverridesOldRecordAndLatestBuildLogWins() async throws {
        let f = try fixture()
        let id = try await simulator(f, age: 8 * 86400)
        await f.commands.add(id, name: "feature-example", state: "Booted", date: clock)
        let date = clock
        let lease = try XCTUnwrap(ArtifactLease.tryAcquire(f.store.simulatorLock(id), shared: true))
        let activity = try DeviceActivity(store: f.store, device: id, lease: lease, now: { date })
        activity.finish()
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
        let unlocked = await f.worker.run(apply: true, discover: false)
        XCTAssertTrue(unlocked.actions.contains { $0.outcome == "removed" })
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

    private func packageCheckout(in cache: URL) async throws -> URL {
        let checkout = cache.appendingPathComponent("SourcePackages/checkouts/package")
        try FileManager.default.createDirectory(at: checkout.appendingPathComponent(".swiftpm/xcode"),
                                                withIntermediateDirectories: true)
        try Data(".swiftpm/\n".utf8).write(to: checkout.appendingPathComponent(".gitignore"))
        try Data("original source".utf8).write(to: checkout.appendingPathComponent("Source.swift"))
        for arguments in [["init", "-q"], ["add", "."],
                          ["-c", "user.name=Test", "-c", "user.email=test@example.invalid",
                           "-c", "commit.gpgSign=false", "-c", "core.hooksPath=/dev/null", "commit", "-qm", "initial"]] {
            _ = try await ProcessRunner.run(executableURL: URL(fileURLWithPath: "/usr/bin/git"),
                arguments: arguments, currentDirectoryURL: checkout)
        }
        return checkout
    }

    func testEmptyIgnoredPackageDirectoriesDoNotPreventCleanup() async throws {
        let f = try fixture(existing: false, realGit: true)
        let dd = try cache(f)
        _ = try await packageCheckout(in: dd)

        let preview = await f.worker.run(apply: false, discover: false)
        XCTAssertNil(preview.error)
        XCTAssertEqual(preview.actions.count, 1)
        XCTAssertEqual(preview.actions.first?.outcome, "would-remove")
        XCTAssertTrue(FileManager.default.fileExists(atPath: dd.path))

        let applied = await f.worker.run(apply: true, discover: false)
        XCTAssertNil(applied.error)
        XCTAssertEqual(applied.actions.count, 1)
        XCTAssertEqual(applied.actions.first?.outcome, "removed")
        XCTAssertFalse(FileManager.default.fileExists(atPath: dd.path))
    }

    func testPackageFilesAndIgnoredSymlinksRemainProtected() async throws {
        for path in ["Source.swift", "untracked file.txt", ".swiftpm/xcode/notes.txt", ".swiftpm/xcode/link"] {
            let f = try fixture(existing: false, realGit: true)
            let dd = try cache(f)
            let checkout = try await packageCheckout(in: dd)
            let modified = checkout.appendingPathComponent(path)
            if path.hasSuffix("/link") {
                try FileManager.default.createSymbolicLink(atPath: modified.path, withDestinationPath: "missing-target")
            } else {
                try Data("local change".utf8).write(to: modified)
            }

            let report = await f.worker.run(apply: true, discover: false)
            XCTAssertNil(report.error, path)
            XCTAssertEqual(report.actions.count, 1, path)
            XCTAssertEqual(report.actions.first?.reason, "modified-packages", path)
            XCTAssertEqual(report.actions.first?.outcome, "preserved", path)
            XCTAssertTrue(FileManager.default.fileExists(atPath: dd.path), path)
            if path.hasSuffix("/link") {
                XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: modified.path), "missing-target")
            } else {
                XCTAssertEqual(try String(contentsOf: modified, encoding: .utf8), "local change", path)
            }
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
        let old = try await simulator(f, age: 86400 + 1)
        let boundary = try await simulator(f, age: 86400)
        let recent = try await simulator(f, age: 86400 - 1)
        let dd = try cache(f, age: 9 * 86400)
        let preview = await f.worker.run(apply: false, discover: false, scope: .simulators)
        XCTAssertTrue(preview.actions.contains { $0.target == old && $0.outcome == "would-remove" })
        let report = await f.worker.run(apply: true, discover: false, scope: .simulators)
        XCTAssertTrue(report.actions.contains { $0.target == old && $0.outcome == "removed" })
        XCTAssertTrue(report.actions.contains { $0.target == boundary && $0.outcome == "preserved" })
        XCTAssertTrue(report.actions.contains { $0.target == recent && $0.outcome == "preserved" })
        XCTAssertTrue(FileManager.default.fileExists(atPath: dd.path))
    }

    func testUnknownUsageIsPreservedAndBootDoesNotRefreshMeaningfulUse() async throws {
        let f = try fixture()
        let unknown = try await simulator(f)
        try f.store.write(ArtifactSimulator(udid: unknown, name: "feature-example", owners: [f.owner], lastUsedAt: 0),
                          to: f.store.simulatorURL(unknown))
        await f.commands.setDates(unknown, used: "invalid", booted: nil)
        let recent = try await simulator(f, age: 9 * 86400)
        await f.commands.setDates(recent, used: nil, booted: ISO8601DateFormatter().string(from: clock))
        let report = await f.worker.run(apply: true, discover: false, scope: .simulators)
        XCTAssertTrue(report.actions.contains { $0.target == unknown && $0.outcome == "preserved" })
        XCTAssertTrue(report.actions.contains { $0.target == recent && $0.outcome == "removed" })
    }

    func testUnusedDeviceDoesNotInspectExternalProcesses() async throws {
        for externalBuild in [true, false] {
            let f = try fixture()
            _ = try await simulator(f, age: 3 * 86400)
            if externalBuild { await f.commands.setBusy(external: true) }
            else { await f.commands.setOpenPath(f.owner.worktreePath) }
            let report = await f.worker.run(apply: true, discover: false, scope: .simulators)
            XCTAssertTrue(report.actions.contains { $0.reason == "unused-over-24-hours" && $0.outcome == "removed" })
            let calls = await f.commands.verbs
            XCTAssertTrue(calls.contains("delete"))
        }
    }

    func testMergedOwnerRequiresCleanNonDefaultBranchAndCachedAncestry() async throws {
      for state in ["Shutdown", "Booted"] {
        for mode in ["merged", "dirty", "unmerged", "default", "detached", "missing-remote", "renamed-branch"] {
            let f = try fixture()
            let id = try await simulator(f, state: state)
            await f.commands.setMerge(mode, worktree: f.owner.worktreePath)
            let report = await f.worker.run(apply: true, discover: false, scope: .simulators)
            XCTAssertTrue(report.actions.contains { $0.target == id && $0.outcome == "preserved" }, mode)
        }
      }
    }

    func testBootedUnusedDeviceQualifiesButTransitionalStateDoesNot() async throws {
        for state in ["Booted", "Booting", "Shutting Down", "Unknown"] {
            let f = try fixture(existing: state == "Booted")
            _ = try await simulator(f, state: state, age: 10 * 86400)
            let result = await f.worker.run(apply: true, discover: false, scope: .simulators)
            XCTAssertEqual(result.actions.first?.outcome, state == "Booted" ? "removed" : "preserved", state)
            XCTAssertEqual(result.actions.first?.reason, state == "Booted" ? "unused-over-24-hours" : "transitioning-device")
            let calls = await f.commands.verbs
            XCTAssertEqual(calls.contains("shutdown"), state == "Booted")
            XCTAssertEqual(calls.contains("delete"), state == "Booted")
        }
    }

    func testBootedOrphanDoesNotInferActivityFromProcesses() async throws {
        for mode in ["build", "worktree", "user-app", "console", "unknown-process", "debugger", "lease"] {
            let f = try fixture(existing: false)
            let id = try await simulator(f, state: "Booted")
            let devicePath = f.worker.devices.appendingPathComponent(id).path
            var lease: ArtifactLease?
            switch mode {
            case "build": await f.commands.setBusy(external: true)
            case "worktree": await f.commands.setOpenPath(f.owner.worktreePath)
            case "user-app":
                await f.commands.setUsage(processes: "321 \(devicePath)/data/Containers/Bundle/Application/app/MyApp.app/MyApp\n",
                                          files: "p321\nn\(devicePath)/data/Library/state\n")
            case "console": await f.commands.setUsage(processes: "321 /usr/bin/simctl\n", arguments: "simctl launch --console \(id) com.example.app\n")
            case "debugger": await f.commands.setUsage(processes: "321 /usr/bin/lldb\n")
            case "lease": lease = try XCTUnwrap(ArtifactLease.tryAcquire(f.store.simulatorLock(id), shared: true))
            default: await f.commands.setUsage(files: "p321\nn\(devicePath)/data/Library/state\n")
            }
            defer { lease?.close() }
            let report = await f.worker.run(apply: true, discover: false, scope: .simulators)
            XCTAssertEqual(report.actions.first?.outcome, mode == "lease" ? "preserved" : "removed", mode)
            let calls = await f.commands.verbs
            XCTAssertEqual(calls.contains("delete"), mode != "lease", mode)
        }
    }

    func testBootedSystemServicesAloneDoNotPinAnOrphan() async throws {
        let f = try fixture(existing: false)
        let id = try await simulator(f, state: "Booted")
        let runtime = "/Library/Developer/CoreSimulator/Volumes/iOS_Test/Library/Developer/CoreSimulator/Profiles/Runtimes/iOS.simruntime/Contents/Resources/RuntimeRoot"
        await f.commands.setUsage(processes: "321 \(runtime)/System/Library/CoreServices/SpringBoard.app/SpringBoard\n",
                                  files: "p321\nn\(f.worker.devices.path)/\(id)/data/Library/state\n")
        await f.commands.clearFilesWhenStopped()
        let report = await f.worker.run(apply: true, discover: false, scope: .simulators)
        XCTAssertEqual(report.actions.first?.outcome, "removed")
        XCTAssertFalse(ArtifactCleanup.isSimulatorSystemExecutable("/tmp/SpringBoard"))
        XCTAssertFalse(ArtifactCleanup.isSimulatorSystemExecutable("/tmp/Library/Developer/CoreSimulator/Volumes/iOS_Test/iOS.simruntime/Contents/Resources/RuntimeRoot/usr/bin/test"))
        XCTAssertFalse(ArtifactCleanup.isSimulatorSystemExecutable("/Library/Developer/CoreSimulator/Volumes/iOS_Test/iOS.simruntime/Contents/Resources/RuntimeRoot/Applications/../../../../outside"))
    }

    func testShutdownFailureOrNewUseNeverContinuesToDelete() async throws {
        for mode in ["failure", "unconfirmed", "reboot"] {
            let f = try fixture(existing: false)
            _ = try await simulator(f, state: "Booted")
            await f.commands.setShutdownBehavior(mode)
            let report = await f.worker.run(apply: true, discover: false, scope: .simulators)
            XCTAssertEqual(report.actions.first?.outcome, "shutdown-unconfirmed", mode)
            let calls = await f.commands.verbs
            XCTAssertEqual(calls.filter { $0 == "shutdown" }.count, 1)
            XCTAssertFalse(calls.contains("delete"))
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
    var processListing = ""
    var fileListing = ""
    var sessionArguments = ""
    var clearFilesOnShutdown = false
    var shutdownBehavior = ""
    func setUsage(processes: String = "", files: String = "", arguments: String = "") {
        processListing = processes; fileListing = files; sessionArguments = arguments
    }
    func clearFilesWhenStopped() { clearFilesOnShutdown = true }
    func setShutdownBehavior(_ mode: String) { shutdownBehavior = mode }
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
        if tool == "/bin/ps" {
            if args.contains("args=") || args.contains("pid=,args=") { return sessionArguments }
            return externalBuild ? "123 /usr/bin/xcodebuild\n" : processListing
        }
        if tool == "/usr/sbin/lsof" {
            return fileListing + (openPath.isEmpty ? "" : "n" + openPath + "\n")
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
            if let id = bootOnInspection { devices[id]?["state"] = "Booted"; bootOnInspection = nil }
            return String(decoding: try JSONSerialization.data(withJSONObject: ["devices": ["runtime": Array(devices.values)]]), as: UTF8.self)
        case "shutdown":
            if shutdownFails || shutdownBehavior == "failure" { throw OrchardError.message("Shutdown failed") }
            if shutdownBehavior == "unconfirmed" { return "" }
            devices[args[4]]?["state"] = "Shutdown"
            devices[args[4]]?["lastUsedAt"] = ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: 2_000_000_000))
            if clearFilesOnShutdown { fileListing = "" }
            if shutdownBehavior == "new-build" { externalBuild = true }
            if shutdownBehavior == "reboot" { bootOnInspection = args[4] }
            return ""
        case "delete":
            devices.removeValue(forKey: args[4])
            return ""
        default: throw OrchardError.message("Unexpected simctl verb")
        }
    }
}
