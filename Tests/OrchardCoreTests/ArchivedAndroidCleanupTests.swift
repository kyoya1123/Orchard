import Foundation
@testable import OrchardCore
import XCTest

final class ArchivedAndroidCleanupTests: XCTestCase, @unchecked Sendable {
    struct Fixture {
        let root: URL
        let worker: ArchivedDeviceCleanup
        let commands: AndroidCleanupCommands
        let avd: URL
        let ini: URL
        let session: URL
    }

    func fixture(archived: Bool = true, shared: Bool = false) throws -> Fixture {
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
        let emulator = sdk.appendingPathComponent("emulator/emulator").path
        try Data("/work\n\(emulator)\n3\n\(emulator)\n-avd\nfeature-example\n".utf8)
            .write(to: avd.appendingPathComponent("emu-launch-params.txt"))
        try Data("device data".utf8).write(to: avd.appendingPathComponent("userdata.img"))
        let sessions = root.appendingPathComponent("Library/Application Support/Claude/claude-code-sessions/account/org")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        let session = sessions.appendingPathComponent("local_one.json")
        try JSONSerialization.data(withJSONObject: ["sessionId": "one", "cwd": "/work", "branch": "feature/example",
            "isArchived": archived, "createdAt": 100000]).write(to: session)
        if shared {
            try JSONSerialization.data(withJSONObject: ["sessionId": "two", "cwd": "/work", "branch": "feature/example",
                "isArchived": false, "createdAt": 100000]).write(to: sessions.appendingPathComponent("local_two.json"))
        }
        let commands = AndroidCleanupCommands(avd: avd, ini: ini, session: session)
        let worker = ArchivedDeviceCleanup(store: ArtifactStore(root: root.appendingPathComponent("state")),
            devices: root.appendingPathComponent("Devices"), home: root, environment: [:],
            shutdownTimeout: .milliseconds(100), shutdownPollInterval: .milliseconds(10)) { tool, args in
                try await commands.run(tool, args)
            }
        return Fixture(root: root, worker: worker, commands: commands, avd: avd, ini: ini, session: session)
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

    func testNonArchivedSharedAndExcludedOwnersAreNeverStopped() async throws {
        for mode in ["active", "shared", "excluded"] {
            let f = try fixture(archived: mode != "active", shared: mode == "shared")
            _ = await f.worker.run(apply: true, excludedPaths: mode == "excluded" ? ["/work"] : [])
            let mutations = await f.commands.mutations
            XCTAssertTrue(mutations.isEmpty, mode)
            XCTAssertTrue(FileManager.default.fileExists(atPath: f.avd.path))
        }
    }

    func testShutdownFailureOrArchiveChangePreventsDeletion() async throws {
        for mode in ["fail-kill", "unarchive"] {
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

    func testLingeringQEMUAndOpenAVDFilesPreventDeletion() async throws {
        for mode in ["qemu-avd", "qemu-at", "open-avd-file"] {
            let f = try fixture()
            await f.commands.setMode(mode)
            let result = await f.worker.run(apply: true)
            XCTAssertEqual(result.actions.first?.outcome, "stopped-preserved", mode)
            let mutations = await f.commands.mutations
            XCTAssertFalse(mutations.contains("delete:feature-example"), mode)
            XCTAssertTrue(FileManager.default.fileExists(atPath: f.avd.path))
        }
    }

    func testUnknownLaunchReceiptDoesNotAuthorizeDeletion() async throws {
        let f = try fixture()
        try Data("unknown".utf8).write(to: f.avd.appendingPathComponent("emu-launch-params.txt"))
        _ = await f.worker.run(apply: true)
        let mutations = await f.commands.mutations
        XCTAssertTrue(mutations.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.avd.path))
    }
}

actor AndroidCleanupCommands {
    let avd: URL
    let ini: URL
    let session: URL
    var running = ["emulator-5554": "feature-example", "emulator-5556": "unrelated"]
    var mutations: [String] = []
    var mode = ""
    var killed = false
    init(avd: URL, ini: URL, session: URL) { self.avd = avd; self.ini = ini; self.session = session }
    func setMode(_ value: String) { mode = value }

    func run(_ tool: String, _ args: [String]) async throws -> String {
        if tool == "/bin/ps" {
            if args == ["-axo", "args="] {
                if mode == "qemu-avd" { return "qemu -avd feature-example" }
                if mode == "qemu-at" { return "emulator @feature-example" }
                return ""
            }
            return mode == "open-avd-file" ? "99 /tools/reader" : ""
        }
        if tool == "/usr/sbin/lsof" {
            return killed && mode == "open-avd-file" ? "p99\nn\(avd.path)/userdata.img\n" : ""
        }
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
                if mode == "unarchive" {
                    var value = try JSONSerialization.jsonObject(with: Data(contentsOf: session)) as! [String: Any]
                    value["isArchived"] = false
                    try JSONSerialization.data(withJSONObject: value).write(to: session)
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
