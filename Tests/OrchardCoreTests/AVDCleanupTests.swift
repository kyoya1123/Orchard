import Foundation
@testable import OrchardCore
import XCTest

final class AVDCleanupTests: XCTestCase, @unchecked Sendable {
    struct Fixture {
        let root: URL
        let toolchain: AndroidToolchain
        let fake: AndroidFake
        let cleanup: AVDCleanup
    }

    func fixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("OrchardAVDTests-\(UUID().uuidString)").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let sdk = root.appendingPathComponent("sdk")
        for tool in ["platform-tools/adb", "cmdline-tools/latest/bin/avdmanager"] {
            let url = sdk.appendingPathComponent(tool)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: url.path, contents: Data(), attributes: [.posixPermissions: 0o755])
        }
        let toolchain = AndroidToolchain(home: root, environment: ["ANDROID_HOME": sdk.path, "JAVA_HOME": "/java"])
        let fake = AndroidFake(toolchain: toolchain)
        let cleanup = AVDCleanup(toolchain: toolchain, command: { try await fake.run($0, $1) },
                                 shutdownTimeout: .seconds(2), shutdownPollInterval: .milliseconds(10))
        return Fixture(root: root, toolchain: toolchain, fake: fake, cleanup: cleanup)
    }

    func worktree(_ f: Fixture, _ name: String) throws -> URL {
        let path = f.root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        return path
    }

    func run(_ f: Fixture, apply: Bool, excluded: @escaping (String) -> Bool = { _ in false }) async -> CleanupReport {
        var report = CleanupReport()
        await f.cleanup.run(apply: apply, excluded: excluded, report: &report)
        return report
    }

    func testRunningMarkedAVDOfMissingWorktreeIsKilledAndDeleted() async throws {
        let f = try fixture()
        let owner = try worktree(f, "repo")
        try await f.fake.createAVD("feature-x", owner: owner.path)
        await f.fake.boot("feature-x", serial: "emulator-5554")
        try FileManager.default.removeItem(at: owner)

        let preview = await run(f, apply: false)
        XCTAssertTrue(preview.actions.contains { $0.name == "feature-x" && $0.outcome == "would-remove" && $0.requiresShutdown == true })
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.toolchain.ini("feature-x").path))

        let report = await run(f, apply: true)
        XCTAssertNil(report.error)
        XCTAssertTrue(report.actions.contains { $0.name == "feature-x" && $0.outcome == "removed" })
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.toolchain.directory("feature-x").path))
        let commands = await f.fake.commands
        XCTAssertTrue(commands.contains { $0.contains("kill") })
        XCTAssertTrue(commands.contains { $0.contains("ANDROID_AVD_HOME=\(f.toolchain.avdHome.path)") && $0.suffix(4).elementsEqual(["delete", "avd", "-n", "feature-x"]) })
    }

    func testFolderReusedForAnotherBranchStopsThenRemovesAfterADay() async throws {
        let f = try fixture()
        let owner = try worktree(f, "repo")
        await f.fake.setHead(owner.path, "refs/heads/other")
        let now = Date().timeIntervalSince1970
        try await f.fake.createAVD("fresh", owner: owner.path, branch: "feature/fresh", lastUsedAt: now - 60)
        await f.fake.boot("fresh", serial: "emulator-5554")
        try await f.fake.createAVD("idle", owner: owner.path, branch: "feature/idle", lastUsedAt: now - AVDCleanup.switchedRetention - 60)
        try await f.fake.createAVD("stopped", owner: owner.path, branch: "feature/stopped", lastUsedAt: now - 60)
        try await f.fake.createAVD("current", owner: owner.path, branch: "other", lastUsedAt: now - AVDCleanup.switchedRetention - 60)

        let preview = await run(f, apply: false)
        XCTAssertTrue(preview.actions.contains { $0.name == "fresh" && $0.outcome == "would-stop" })
        XCTAssertTrue(preview.actions.contains { $0.name == "idle" && $0.outcome == "would-remove" })

        let report = await run(f, apply: true)
        XCTAssertNil(report.error)
        XCTAssertTrue(report.actions.contains { $0.name == "fresh" && $0.reason == "branch-switched" && $0.outcome == "stopped" })
        XCTAssertTrue(report.actions.contains { $0.name == "idle" && $0.reason == "branch-switched" && $0.outcome == "removed" })
        XCTAssertFalse(report.actions.contains { ["stopped", "current"].contains($0.name) })
        for name in ["fresh", "stopped", "current"] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: f.toolchain.ini(name).path), name)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.toolchain.ini("idle").path))
        let running = await f.fake.running
        XCTAssertTrue(running.isEmpty)
    }

    func testDetachedHeadOrUnknownBranchNeverCountsAsSwitch() async throws {
        let f = try fixture()
        let owner = try worktree(f, "repo")
        await f.fake.setHead(owner.path, "")
        let old = Date().timeIntervalSince1970 - AVDCleanup.switchedRetention - 60
        try await f.fake.createAVD("detached", owner: owner.path, branch: "feature/x", lastUsedAt: old)
        let other = try worktree(f, "other")
        await f.fake.setHead(other.path, "refs/heads/main")
        try await f.fake.createAVD("no-branch", owner: other.path)
        let report = await run(f, apply: true)
        XCTAssertTrue(report.actions.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.toolchain.ini("detached").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.toolchain.ini("no-branch").path))
    }

    func testUnmarkedExistingAndExcludedAVDsAreNeverTouched() async throws {
        let f = try fixture()
        try await f.fake.createAVD("Medium_Phone", owner: nil)
        let live = try worktree(f, "live")
        try await f.fake.createAVD("live-branch", owner: live.path)
        let gone = f.root.appendingPathComponent("gone").path
        try await f.fake.createAVD("excluded-branch", owner: gone)

        let report = await run(f, apply: true, excluded: { $0 == gone })
        XCTAssertNil(report.error)
        XCTAssertTrue(report.actions.isEmpty)
        for name in ["Medium_Phone", "live-branch", "excluded-branch"] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: f.toolchain.ini(name).path))
        }
        let commands = await f.fake.commands
        XCTAssertTrue(commands.isEmpty)
    }

    func testSymlinkedMarkerAndUncertainWorktreeArePreserved() async throws {
        let f = try fixture()
        try await f.fake.createAVD("linked", owner: nil)
        let real = f.root.appendingPathComponent("marker.json")
        try JSONEncoder().encode(AVDOwnerMarker(worktreePath: f.root.appendingPathComponent("gone").path)).write(to: real)
        try FileManager.default.createSymbolicLink(at: f.toolchain.directory("linked").appendingPathComponent(AVDOwnerMarker.fileName),
                                                   withDestinationURL: real)
        try await f.fake.createAVD("relative", owner: "relative/path")

        let report = await run(f, apply: true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.toolchain.ini("linked").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.toolchain.ini("relative").path))
        XCTAssertTrue(report.actions.contains { $0.name == "relative" && $0.outcome == "preserved" })
    }
}

actor AndroidFake {
    let toolchain: AndroidToolchain
    var commands: [[String]] = []
    var running: [String: String] = [:]
    var heads: [String: String] = [:]
    init(toolchain: AndroidToolchain) { self.toolchain = toolchain }

    func boot(_ name: String, serial: String) { running[serial] = name }
    func setHead(_ worktree: String, _ ref: String) { heads[worktree] = ref }

    func createAVD(_ name: String, owner: String?, branch: String? = nil, lastUsedAt: Double? = nil) throws {
        try FileManager.default.createDirectory(at: toolchain.directory(name), withIntermediateDirectories: true)
        try Data("path=\(toolchain.directory(name).path)\n".utf8).write(to: toolchain.ini(name))
        if let owner {
            try JSONEncoder().encode(AVDOwnerMarker(worktreePath: owner, branch: branch, lastUsedAt: lastUsedAt))
                .write(to: toolchain.directory(name).appendingPathComponent(AVDOwnerMarker.fileName))
        }
    }

    func run(_ tool: String, _ arguments: [String]) throws -> String {
        if tool == "/usr/bin/git", let flag = arguments.firstIndex(of: "-C") {
            let path = arguments[flag + 1]
            guard let head = heads[path] else { throw OrchardError.message("not a git repository") }
            if arguments.contains("--show-toplevel") { return path }
            if arguments.contains("symbolic-ref") {
                if head.isEmpty { throw OrchardError.message("detached") }
                return head
            }
        }
        if tool == toolchain.adb {
            if arguments == ["devices"] {
                return "List of devices attached\n" + running.keys.map { "\($0)\tdevice\n" }.joined()
            }
            if arguments.count == 5, arguments[2...] == ["emu", "avd", "name"] {
                return "\(running[arguments[1]] ?? "")\r\nOK"
            }
            if arguments.count == 4, arguments[2...] == ["emu", "kill"] {
                commands.append(arguments)
                running.removeValue(forKey: arguments[1])
                return ""
            }
        }
        guard tool == "/bin/sh", let manager = arguments.firstIndex(of: toolchain.avdmanager) else {
            throw OrchardError.message("Unexpected command \(tool) \(arguments)")
        }
        commands.append(arguments)
        let args = Array(arguments[(manager + 1)...])
        guard args.prefix(2) == ["delete", "avd"], let flag = args.firstIndex(of: "-n") else {
            throw OrchardError.message("Unexpected avdmanager \(args)")
        }
        let name = args[flag + 1]
        try FileManager.default.removeItem(at: toolchain.directory(name))
        try FileManager.default.removeItem(at: toolchain.ini(name))
        return ""
    }
}
