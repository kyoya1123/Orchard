import Darwin
import Foundation

struct AndroidToolchain: Sendable {
    let avdHome: URL
    let sdk: URL
    let java: String?

    init(home: URL = FileManager.default.homeDirectoryForCurrentUser,
         environment: [String: String] = ProcessInfo.processInfo.environment) {
        avdHome = URL(fileURLWithPath: environment["ANDROID_AVD_HOME"] ?? home.appendingPathComponent(".android/avd").path)
        sdk = URL(fileURLWithPath: environment["ANDROID_HOME"] ?? environment["ANDROID_SDK_ROOT"]
            ?? home.appendingPathComponent("Library/Android/sdk").path)
        let studioJava = "/Applications/Android Studio.app/Contents/jbr/Contents/Home"
        java = environment["JAVA_HOME"] ?? (FileManager.default.fileExists(atPath: studioJava) ? studioJava : nil)
    }

    var adb: String { sdk.appendingPathComponent("platform-tools/adb").path }
    var avdmanager: String { sdk.appendingPathComponent("cmdline-tools/latest/bin/avdmanager").path }
    func ini(_ name: String) -> URL { avdHome.appendingPathComponent(name + ".ini") }
    func directory(_ name: String) -> URL { avdHome.appendingPathComponent(name + ".avd") }

    /// avdmanager reads ANDROID_AVD_HOME/JAVA_HOME and may prompt on stdin.
    func avdmanagerArguments(_ arguments: [String]) -> [String] {
        var environment = ["ANDROID_AVD_HOME=\(avdHome.path)"]
        if let java { environment.append("JAVA_HOME=\(java)") }
        return ["-c", "printf 'no\\n' | \"$@\"", "sh", "/usr/bin/env"] + environment + [avdmanager] + arguments
    }

    static func isValidName(_ name: String) -> Bool {
        !name.isEmpty && name.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "-_.".contains($0)) }
    }
}

/// Written by the tool that uses the AVD for a worktree, inside `<name>.avd/`.
/// Orchard never creates AVDs and never infers ownership from an AVD's name or
/// from the directory it was launched from. `branch` and `lastUsedAt` (Unix
/// seconds) are optional; without them only the missing-worktree rule applies.
struct AVDOwnerMarker: Codable, Sendable {
    static let fileName = "orchard-owner.json"
    let worktreePath: String
    var branch: String? = nil
    var lastUsedAt: Double? = nil
}

/// Removes marked AVDs whose owner worktree no longer exists. When the owner
/// folder was reused for another branch, the AVD is stopped, then removed once
/// its marker has not been refreshed for a day.
struct AVDCleanup: Sendable {
    typealias Command = ArtifactCleanup.Command
    static let switchedRetention: Double = 86400
    let toolchain: AndroidToolchain
    let command: Command
    let isMissing: @Sendable (String) throws -> Bool
    let now: @Sendable () -> Date
    let shutdownTimeout: Duration
    let shutdownPollInterval: Duration

    init(toolchain: AndroidToolchain, command: @escaping Command,
         isMissing: @escaping @Sendable (String) throws -> Bool = MissingWorktree.check,
         now: @escaping @Sendable () -> Date = { Date() },
         shutdownTimeout: Duration = .seconds(10), shutdownPollInterval: Duration = .milliseconds(250)) {
        self.toolchain = toolchain
        self.command = command
        self.isMissing = isMissing
        self.now = now
        self.shutdownTimeout = shutdownTimeout
        self.shutdownPollInterval = shutdownPollInterval
    }

    /// Detached HEADs, non-root paths and Git errors never count as a switch.
    func branchSwitched(_ marker: AVDOwnerMarker) async -> Bool {
        guard let branch = marker.branch, !branch.isEmpty else { return false }
        func git(_ args: [String]) async -> String? {
            try? await command("/usr/bin/git", ["--no-optional-locks", "-C", marker.worktreePath,
                "-c", "core.fsmonitor=false"] + args).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard await git(["rev-parse", "--show-toplevel"]) == marker.worktreePath,
              let current = await git(["symbolic-ref", "-q", "HEAD"]), current.hasPrefix("refs/heads/") else { return false }
        return current != "refs/heads/" + branch
    }

    struct Candidate { let name: String; let marker: AVDOwnerMarker }

    /// Only an ordinary `<name>.avd` directory beside `<name>.ini` with an
    /// ordinary marker file qualifies; links and unreadable markers are skipped.
    func marked() throws -> [Candidate] {
        guard FileManager.default.fileExists(atPath: toolchain.avdHome.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: toolchain.avdHome, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "avd" }
            .compactMap { directory in
                let name = directory.deletingPathExtension().lastPathComponent
                let marker = directory.appendingPathComponent(AVDOwnerMarker.fileName)
                guard AndroidToolchain.isValidName(name), Self.isOrdinary(directory, directory: true),
                      Self.isOrdinary(marker, directory: false), Self.isOrdinary(toolchain.ini(name), directory: false),
                      let data = try? Data(contentsOf: marker),
                      let value = try? JSONDecoder().decode(AVDOwnerMarker.self, from: data) else { return nil }
                return Candidate(name: name, marker: value)
            }
    }

    static func isOrdinary(_ url: URL, directory: Bool) -> Bool {
        var value = stat()
        guard lstat(url.path, &value) == 0 else { return false }
        return value.st_mode & mode_t(S_IFMT) == mode_t(directory ? S_IFDIR : S_IFREG)
    }

    func adb(_ arguments: [String]) async throws -> String { try await command(toolchain.adb, arguments) }

    func runningAVDs() async throws -> [String: String] {
        let output = try await adb(["devices"])
        var result: [String: String] = [:]
        for line in output.split(whereSeparator: \.isNewline).dropFirst() {
            let columns = line.split(whereSeparator: { $0.isWhitespace })
            guard columns.count >= 2, columns[0].hasPrefix("emulator-") else { continue }
            guard columns[1] == "device" else { throw OrchardError.message("Offline emulator; its identity cannot be checked") }
            let serial = String(columns[0])
            let name = try await adb(["-s", serial, "emu", "avd", "name"]).split(whereSeparator: \.isNewline)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            guard name.count == 2, name[1] == "OK", !name[0].isEmpty else { throw OrchardError.message("Unknown emulator identity") }
            result[serial] = name[0]
        }
        return result
    }

    func connectedEmulatorSerials() async throws -> Set<String> {
        let lines = try await adb(["devices"]).split(whereSeparator: \.isNewline)
        guard lines.first?.hasPrefix("List of devices attached") == true else {
            throw OrchardError.message("Unable to confirm emulator disconnect")
        }
        // During targeted shutdown ADB can temporarily report offline or lose
        // its console identity. Wait for the already-verified serial to vanish;
        // do not query a dying emulator's name or mistake offline for absence.
        return Set(lines.dropFirst().compactMap { line in
            let columns = line.split(whereSeparator: { $0.isWhitespace })
            guard let serial = columns.first, serial.hasPrefix("emulator-") else { return nil }
            return String(serial)
        })
    }

    func waitForShutdown(_ serial: String) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                while try await self.connectedEmulatorSerials().contains(serial) {
                    try await Task.sleep(for: self.shutdownPollInterval)
                }
            }
            group.addTask {
                try await Task.sleep(for: self.shutdownTimeout)
                throw OrchardError.message("Emulator shutdown not confirmed before deadline; no retry or delete")
            }
            defer { group.cancelAll() }
            try await group.next()
        }
    }

    func run(apply: Bool, excluded: @escaping (String) -> Bool, report: inout CleanupReport) async {
        let candidates: [Candidate]
        do { candidates = try marked() } catch {
            report.error = report.error ?? String(describing: error)
            return
        }
        var running: [String: String]?
        for candidate in candidates {
            let name = candidate.name
            let worktree = candidate.marker.worktreePath
            let directory = toolchain.directory(name)
            var outcome = "preserved"
            func action(_ reason: String, _ result: String, state: String? = nil) -> CleanupReport.Action {
                .init(target: directory.path, reason: reason, outcome: result, name: name,
                      state: state, requiresShutdown: state.map { $0 == "Booted" })
            }
            do {
                guard !excluded(worktree) else { continue }
                let missing = try isMissing(worktree)
                let switched = missing ? false : await branchSwitched(candidate.marker)
                guard missing || switched else { continue }
                let reason = missing ? "missing-worktree" : "branch-switched"
                let expired = candidate.marker.lastUsedAt.map { now().timeIntervalSince1970 - $0 > Self.switchedRetention } ?? false
                let removes = missing || expired
                guard FileManager.default.isExecutableFile(atPath: toolchain.avdmanager),
                      FileManager.default.isExecutableFile(atPath: toolchain.adb) else {
                    throw OrchardError.message("Android tooling unavailable")
                }
                if running == nil { running = try await runningAVDs() }
                let serials = (running ?? [:]).filter { $0.value == name }.map(\.key)
                guard serials.count <= 1 else { throw OrchardError.message("Multiple running instances of AVD") }
                let state = serials.isEmpty ? "Shutdown" : "Booted"
                guard removes || !serials.isEmpty else { continue }
                if !apply {
                    report.actions.append(action(reason, removes ? "would-remove" : "would-stop", state: state)); continue
                }
                if let serial = serials.first {
                    outcome = "shutdown-unconfirmed"
                    _ = try await adb(["-s", serial, "emu", "kill"])
                    try await waitForShutdown(serial)
                    outcome = "stopped-preserved"
                }
                running = nil
                guard removes else {
                    report.actions.append(action(reason, "stopped", state: state)); continue
                }
                let stillEligible = missing ? try isMissing(worktree) : await branchSwitched(candidate.marker)
                guard stillEligible, try marked().contains(where: { $0.name == name && $0.marker.worktreePath == worktree
                        && $0.marker.lastUsedAt == candidate.marker.lastUsedAt }),
                      try await !runningAVDs().values.contains(name) else {
                    throw OrchardError.message("Emulator still running or AVD/worktree changed")
                }
                outcome = "deletion-unconfirmed"
                _ = try await command("/bin/sh", toolchain.avdmanagerArguments(["delete", "avd", "-n", name]))
                guard !FileManager.default.fileExists(atPath: toolchain.ini(name).path),
                      !FileManager.default.fileExists(atPath: directory.path) else {
                    throw OrchardError.message("AVD removal not confirmed; no filesystem fallback or retry")
                }
                report.actions.append(action(reason, "removed", state: state))
            } catch {
                report.error = report.error ?? String(describing: error)
                report.actions.append(action(String(describing: error), outcome))
            }
        }
    }
}
