import Foundation
@testable import OrchardCore
import XCTest

final class OrphanedAndroidCleanupTests: XCTestCase, @unchecked Sendable {
    struct Fixture {
        let root: URL
        let worker: OrphanedDeviceCleanup
        let commands: AndroidCleanupCommands
        let avd: URL
        let ini: URL
        let worktree: URL
    }

    func fixture(existing: Bool = false) throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("AndroidCleanup-\(UUID())").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let sdk = root.appendingPathComponent("Library/Android/sdk")
        for relative in ["platform-tools/adb", "cmdline-tools/latest/bin/avdmanager"] {
            let path = sdk.appendingPathComponent(relative)
            try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("mock; never execute".utf8).write(to: path)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: path.path)
        }
        let avdHome = root.appendingPathComponent(".android/avd")
        let avd = avdHome.appendingPathComponent("feature-example.avd")
        try FileManager.default.createDirectory(at: avd, withIntermediateDirectories: true)
        let ini = avdHome.appendingPathComponent("feature-example.ini")
        try Data("path=\(avd.path)\n".utf8).write(to: ini)
        let worktree = root.appendingPathComponent("worktree")
        if existing { try FileManager.default.createDirectory(at: worktree, withIntermediateDirectories: true) }
        let emulator = sdk.appendingPathComponent("emulator/emulator").path
        try Data("\(worktree.path)\n\(emulator)\n3\n\(emulator)\n-avd\nfeature-example\n".utf8)
            .write(to: avd.appendingPathComponent("emu-launch-params.txt"))
        try Data("device data".utf8).write(to: avd.appendingPathComponent("userdata.img"))
        let commands = AndroidCleanupCommands(avd: avd, ini: ini, worktree: worktree)
        let worker = OrphanedDeviceCleanup(store: ArtifactStore(root: root.appendingPathComponent("state")),
            devices: root.appendingPathComponent("Devices"), home: root, environment: [:],
            shutdownTimeout: .milliseconds(100), shutdownPollInterval: .milliseconds(10)) { tool, args in
                try await commands.run(tool, args)
            }
        return Fixture(root: root, worker: worker, commands: commands, avd: avd, ini: ini, worktree: worktree)
    }

    func testPreviewThenTargetedStopDeletePreservesOtherEmulator() async throws {
        let f = try fixture()
        let other = f.avd.deletingLastPathComponent().appendingPathComponent("unrelated.avd")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        let preview = await f.worker.run(apply: false)
        XCTAssertNil(preview.error)
        XCTAssertEqual(preview.actions.first?.outcome, "would-remove")
        XCTAssertEqual(preview.actions.first?.requiresShutdown, true)
        let before = await f.commands.mutations
        XCTAssertTrue(before.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.avd.path))
        let applied = await f.worker.run(apply: true)
        XCTAssertNil(applied.error)
        XCTAssertEqual(applied.actions.first?.outcome, "removed")
        let mutations = await f.commands.mutations
        XCTAssertEqual(mutations, ["kill:emulator-5554", "delete:feature-example"])
        let remains = await f.commands.running
        XCTAssertEqual(remains, ["emulator-5556": "unrelated"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: other.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.avd.path))
    }

    func testExistingAndExcludedWorktreesAreNeverStopped() async throws {
        for mode in ["existing", "excluded"] {
            let f = try fixture(existing: mode == "existing")
            _ = await f.worker.run(apply: true, excludedPaths: mode == "excluded" ? [f.worktree.path] : [])
            let mutations = await f.commands.mutations
            XCTAssertTrue(mutations.isEmpty, mode)
            XCTAssertTrue(FileManager.default.fileExists(atPath: f.avd.path))
        }
    }

    func testShutdownFailureOrRecreatedWorktreePreventsDeletion() async throws {
        for mode in ["fail-kill", "recreate"] {
            let f = try fixture()
            await f.commands.setMode(mode)
            let result = await f.worker.run(apply: true)
            XCTAssertNotNil(result.error)
            XCTAssertEqual(result.actions.first?.outcome, mode == "fail-kill" ? "shutdown-unconfirmed" : "stopped-preserved")
            let mutations = await f.commands.mutations
            XCTAssertFalse(mutations.contains("delete:feature-example"))
            XCTAssertTrue(FileManager.default.fileExists(atPath: f.avd.path))
        }
    }

    func testShutdownDeadlineIncludesSlowADBInspection() async throws {
        let f = try fixture()
        await f.commands.setMode("slow-after-kill")
        let start = ContinuousClock.now
        let result = await f.worker.run(apply: true)
        XCTAssertLessThan(start.duration(to: .now), .seconds(2))
        XCTAssertEqual(result.actions.first?.outcome, "shutdown-unconfirmed")
        XCTAssertNotNil(result.error)
        let mutations = await f.commands.mutations
        XCTAssertEqual(mutations, ["kill:emulator-5554"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.avd.path))
    }

    func testUnknownLaunchReceiptDoesNotAuthorizeDeletion() async throws {
        let f = try fixture()
        try Data("unknown".utf8).write(to: f.avd.appendingPathComponent("emu-launch-params.txt"))
        _ = await f.worker.run(apply: true)
        let mutations = await f.commands.mutations
        XCTAssertTrue(mutations.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.avd.path))
    }

    func testMissingLaunchSubdirectoryDoesNotRemoveExistingRecordedWorktreeDevice() async throws {
        let f = try fixture()
        let owner = ArtifactOwner(projectPath: f.root.appendingPathComponent("App.xcodeproj").path,
            worktreePath: f.root.path, repositoryPath: f.root.path)
        try f.worker.store.write(ArtifactProject(owner: owner, lastUsedAt: 0), to: f.worker.store.projectURL(owner.projectPath))
        let result = await f.worker.run(apply: true)
        XCTAssertEqual(result.actions.first?.outcome, "preserved")
        let mutations = await f.commands.mutations
        XCTAssertTrue(mutations.isEmpty)
    }
}

actor AndroidCleanupCommands {
    let avd: URL
    let ini: URL
    let worktree: URL
    var running = ["emulator-5554": "feature-example", "emulator-5556": "unrelated"]
    var mutations: [String] = []
    var mode = ""
    var killed = false
    init(avd: URL, ini: URL, worktree: URL) { self.avd = avd; self.ini = ini; self.worktree = worktree }
    func setMode(_ value: String) { mode = value }

    func run(_ tool: String, _ args: [String]) async throws -> String {
        if tool.hasSuffix("/platform-tools/adb") {
            if args == ["devices"] {
                if killed && mode == "slow-after-kill" { try await Task.sleep(for: .seconds(30)) }
                return "List of devices attached\n" + running.keys.sorted().map { "\($0)\tdevice\n" }.joined()
            }
            if args.count == 5, args[0] == "-s", Array(args.suffix(3)) == ["emu", "avd", "name"], let name = running[args[1]] {
                return name + "\nOK\n"
            }
            if args == ["-s", "emulator-5554", "emu", "kill"] {
                mutations.append("kill:emulator-5554")
                if mode == "fail-kill" { throw OrchardError.message("Synthetic kill failure") }
                killed = true
                running.removeValue(forKey: "emulator-5554")
                if mode == "recreate" {
                    try FileManager.default.createDirectory(at: worktree, withIntermediateDirectories: true)
                }
                return "OK"
            }
        }
        if tool == "/usr/bin/env", Array(args.suffix(4)) == ["delete", "avd", "-n", "feature-example"] {
            mutations.append("delete:feature-example")
            try FileManager.default.removeItem(at: ini)
            try FileManager.default.removeItem(at: avd)
            return "Deleted"
        }
        throw OrchardError.message("Unexpected mock command: \(tool) \(args)")
    }
}
