import Foundation

/// Removes positively associated devices only when every owning worktree is missing.
/// No session metadata, process inspection, age, or merge inference. Called under cleanup.lock.
struct OrphanedDeviceCleanup: Sendable {
    typealias Command = ArtifactCleanup.Command
    let store: ArtifactStore
    let devices: URL
    let isMissing: @Sendable (String) throws -> Bool
    let androidHome: URL
    let sdk: URL
    let java: String?
    let command: Command
    let shutdownTimeout: Duration
    let shutdownPollInterval: Duration

    init(store: ArtifactStore, devices: URL, home: URL = FileManager.default.homeDirectoryForCurrentUser,
         environment: [String: String] = ProcessInfo.processInfo.environment,
         shutdownTimeout: Duration = .seconds(5), shutdownPollInterval: Duration = .milliseconds(250),
         isMissing: @escaping @Sendable (String) throws -> Bool = MissingWorktree.check,
         command: @escaping Command) {
        self.store = store
        self.devices = devices
        self.isMissing = isMissing
        let env = environment
        self.androidHome = URL(fileURLWithPath: env["ANDROID_AVD_HOME"] ?? home.appendingPathComponent(".android/avd").path)
        self.sdk = URL(fileURLWithPath: env["ANDROID_HOME"] ?? env["ANDROID_SDK_ROOT"] ?? home.appendingPathComponent("Library/Android/sdk").path)
        self.java = env["JAVA_HOME"] ?? (FileManager.default.fileExists(atPath: "/Applications/Android Studio.app/Contents/jbr/Contents/Home")
            ? "/Applications/Android Studio.app/Contents/jbr/Contents/Home" : nil)
        self.command = command
        self.shutdownTimeout = shutdownTimeout
        self.shutdownPollInterval = shutdownPollInterval
    }

    func run(apply: Bool, excludedPaths: [String] = [], includeAndroid: Bool = true) async -> CleanupReport {
        var report = CleanupReport()
        do {
            try await ios(apply: apply, exclusions: excludedPaths, report: &report)
        } catch {
            report.error = String(describing: error)
            report.actions.append(.init(target: devices.path, reason: "worktree-inspection-failed: \(error)", outcome: "preserved"))
        }
        guard includeAndroid else { return report }
        // An unavailable CoreSimulator must not prevent Android inspection.
        do {
            try await android(apply: apply, exclusions: excludedPaths, report: &report)
        } catch {
            report.error = report.error ?? String(describing: error)
            report.actions.append(.init(target: androidHome.path, reason: "worktree-inspection-failed: \(error)", outcome: "preserved"))
        }
        return report
    }

    func allMissing(_ paths: Set<String>) throws -> Bool {
        guard !paths.isEmpty else { return false }
        return try paths.allSatisfy { try isMissing($0) }
    }
    func excluded(_ paths: Set<String>, _ exclusions: [String]) -> Bool {
        exclusions.contains { exclusion in
            let root = URL(fileURLWithPath: (exclusion as NSString).expandingTildeInPath).resolvingSymlinksInPath().path
            return paths.contains { ArtifactCleanup.contains($0, in: root) }
        }
    }
    func simctl(_ args: [String]) async throws -> String {
        try await command("/usr/bin/xcrun", ["simctl", "--set", devices.path] + args)
    }
    func inventory() async throws -> [ArtifactCleanup.Device] {
        Array(try JSONDecoder().decode(ArtifactCleanup.DeviceList.self,
            from: Data(try await simctl(["list", "devices", "-j"]).utf8)).devices.values.joined())
    }
    func ios(apply: Bool, exclusions: [String], report: inout CleanupReport) async throws {
        let records = try store.all(ArtifactSimulator.self, in: "simulators")
        guard !records.isEmpty else { return }
        let list = try await inventory()
        for record in records {
            var outcome = "preserved"
            var current = list.first { $0.udid == record.udid && $0.name == record.name }
            func action(_ reason: String, _ result: String) -> CleanupReport.Action {
                .init(target: record.udid, reason: reason, outcome: result, name: record.name,
                      estimatedBytes: current?.dataPathSize, state: current?.state,
                      requiresShutdown: current.map { $0.state == "Booted" })
            }
            do {
                let paths = Set(record.owners.map(\.worktreePath))
                guard UUID(uuidString: record.udid) != nil, !ArtifactStore.isStandardSimulator(record.name),
                      !excluded(paths, exclusions), let device = current else { continue }
                guard try allMissing(paths) else {
                    report.actions.append(action("worktree-exists-or-ownership-unknown", "preserved")); continue
                }
                guard ["Booted", "Shutdown"].contains(device.state) else {
                    report.actions.append(action("transitioning-device", "preserved")); continue
                }
                var leases: [ArtifactLease] = []
                defer { leases.forEach { $0.close() } }
                let lockPaths = Set(record.owners.map { store.projectLock($0.projectPath) } + [store.simulatorLock(record.udid)]).sorted { $0.path < $1.path }
                for path in lockPaths {
                    guard let lease = try ArtifactLease.tryAcquire(path) else { break }
                    leases.append(lease)
                }
                guard leases.count == lockPaths.count else { report.actions.append(action("active-build-or-install", "preserved")); continue }
                func unchanged() throws -> Bool {
                    guard let fresh = try store.read(ArtifactSimulator.self, at: store.simulatorURL(record.udid)),
                          fresh.name == record.name, fresh.owners == record.owners, fresh.lastUsedAt == record.lastUsedAt else { return false }
                    return try allMissing(paths)
                }
                guard try unchanged() else {
                    report.actions.append(action("worktree-or-owner-changed", "preserved")); continue
                }
                if !apply { report.actions.append(action("missing-worktree", "would-remove")); continue }
                guard let fresh = try await inventory().first(where: { $0.udid == device.udid }),
                      fresh.name == record.name, fresh.state == device.state,
                      try unchanged() else { report.actions.append(action("device-or-worktree-changed", "preserved")); continue }
                if fresh.state == "Booted" {
                    outcome = "shutdown-unconfirmed"
                    _ = try await simctl(["shutdown", fresh.udid])
                    guard let stopped = try await inventory().first(where: { $0.udid == fresh.udid }),
                          stopped.state == "Shutdown", stopped.name == fresh.name else {
                        throw OrchardError.message("Targeted shutdown not confirmed; no retry or delete")
                    }
                    outcome = "stopped-preserved"
                    current = stopped
                }
                guard let final = try await inventory().first(where: { $0.udid == device.udid }),
                      final.state == "Shutdown", final.name == record.name,
                      try unchanged() else {
                    report.actions.append(action("device-or-worktree-changed-before-delete", outcome)); continue
                }
                outcome = "deletion-unconfirmed"
                _ = try await simctl(["delete", final.udid])
                guard try await !inventory().contains(where: { $0.udid == final.udid }) else {
                    throw OrchardError.message("Deletion not confirmed; no retry")
                }
                outcome = "removed"
                try FileManager.default.removeItem(at: store.simulatorURL(record.udid))
                report.actions.append(action("missing-worktree", outcome))
            } catch {
                report.error = report.error ?? String(describing: error)
                report.actions.append(action(String(describing: error), outcome))
            }
        }
    }

    struct AVD: Equatable {
        let name: String
        let path: URL
        let cwd: String
        let launchedAt: Double
        let fingerprint: String
    }
    func avd(_ ini: URL) throws -> AVD? {
        let fm = FileManager.default
        let name = ini.deletingPathExtension().lastPathComponent
        guard !name.isEmpty, name.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "-_.".contains($0)) }),
              ini.resolvingSymlinksInPath() == ini.standardizedFileURL else { return nil }
        let data = try Data(contentsOf: ini)
        let lines = String(decoding: data, as: UTF8.self).split(separator: "\n")
        let paths = lines.filter { $0.hasPrefix("path=") }.map { String($0.dropFirst(5)) }
        let expected = androidHome.appendingPathComponent(name + ".avd").standardizedFileURL
        guard paths == [expected.path], expected.resolvingSymlinksInPath() == expected,
              try expected.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else { return nil }
        let launch = expected.appendingPathComponent("emu-launch-params.txt")
        guard fm.fileExists(atPath: launch.path), launch.resolvingSymlinksInPath() == launch else { return nil }
        let launchData = try Data(contentsOf: launch)
        let args = String(decoding: launchData, as: UTF8.self).split(separator: "\n").map(String.init)
        guard args.count >= 6, args[0].hasPrefix("/"), args[1] == sdk.appendingPathComponent("emulator/emulator").path,
              args[3] == args[1], let count = Int(args[2]), args.count == count + 3,
              args.filter({ $0 == "-avd" }).count == 1, let flag = args.firstIndex(of: "-avd"),
              flag + 1 < args.count, args[flag + 1] == name,
              let modified = try launch.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate else { return nil }
        let attributes = try fm.attributesOfItem(atPath: expected.path)
        let identity = String(describing: attributes[.systemFileNumber])
        return AVD(name: name, path: expected, cwd: args[0], launchedAt: modified.timeIntervalSince1970,
            fingerprint: ArtifactStore.key(data.base64EncodedString() + launchData.base64EncodedString() + identity))
    }

    func adb(_ args: [String]) async throws -> String { try await command(sdk.appendingPathComponent("platform-tools/adb").path, args) }
    func runningAVDs() async throws -> [String: String] {
        let output = try await adb(["devices"])
        var result: [String: String] = [:]
        for line in output.split(separator: "\n").dropFirst() {
            let columns = line.split(whereSeparator: { $0.isWhitespace })
            guard columns.count >= 2, columns[0].hasPrefix("emulator-") else { continue }
            guard columns[1] == "device" else { throw OrchardError.message("Offline emulator; ownership cannot be checked") }
            let serial = String(columns[0])
            let name = try await adb(["-s", serial, "emu", "avd", "name"]).split(separator: "\n").map(String.init)
            guard name.count == 2, name[1] == "OK", !name[0].isEmpty else { throw OrchardError.message("Unknown emulator identity") }
            result[serial] = name[0]
        }
        return result
    }

    func waitForShutdown(_ serial: String) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                while try await self.runningAVDs().keys.contains(serial) {
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
    func android(apply: Bool, exclusions: [String], report: inout CleanupReport) async throws {
        guard FileManager.default.fileExists(atPath: androidHome.path) else { return }
        let inis = try FileManager.default.contentsOfDirectory(at: androidHome, includingPropertiesForKeys: nil).filter { $0.pathExtension == "ini" }
        let owners = try store.all(ArtifactProject.self, in: "projects")
        var running: [String: String]?
        for ini in inis {
            var outcome = "preserved"
            do {
                guard let device = try avd(ini), !excluded([device.cwd], exclusions) else { continue }
                // A launch cwd may be a subproject inside a recorded worktree.
                // A removed subdirectory must not make that existing owner eligible.
                let ownerPath = owners.map(\.owner.worktreePath)
                    .filter { ArtifactCleanup.contains(device.cwd, in: $0) }
                    .max(by: { $0.count < $1.count }) ?? device.cwd
                guard !excluded([ownerPath], exclusions), try allMissing([ownerPath]) else {
                    report.actions.append(.init(target: device.path.path, reason: "worktree-exists-or-ownership-unknown", outcome: "preserved", name: device.name)); continue
                }
                func unchanged() throws -> Bool {
                    try avd(ini) == device && allMissing([ownerPath])
                }
                guard let lease = try ArtifactLease.tryAcquire(store.root.appendingPathComponent("locks/avd-\(ArtifactStore.key(device.path.path)).lock")) else {
                    report.actions.append(.init(target: device.path.path, reason: "concurrent-avd-cleanup", outcome: outcome)); continue
                }
                defer { lease.close() }
                let manager = sdk.appendingPathComponent("cmdline-tools/latest/bin/avdmanager").path
                guard FileManager.default.isExecutableFile(atPath: manager),
                      FileManager.default.isExecutableFile(atPath: sdk.appendingPathComponent("platform-tools/adb").path) else {
                    throw OrchardError.message("Android tooling unavailable")
                }
                if running == nil { running = try await runningAVDs() }
                let serials = (running ?? [:]).filter { $0.value == device.name }.map(\.key)
                guard serials.count <= 1 else { throw OrchardError.message("Multiple running instances of AVD") }
                guard try unchanged() else { throw OrchardError.message("Worktree or device association changed") }
                if !apply {
                    report.actions.append(.init(target: device.path.path, reason: "missing-worktree", outcome: "would-remove", name: device.name,
                        state: serials.isEmpty ? "Shutdown" : "Booted", requiresShutdown: !serials.isEmpty)); continue
                }
                guard try unchanged(), try await runningAVDs() == running else { throw OrchardError.message("Emulator identity changed") }
                if let serial = serials.first {
                    outcome = "shutdown-unconfirmed"
                    _ = try await adb(["-s", serial, "emu", "kill"])
                    try await waitForShutdown(serial)
                    outcome = "stopped-preserved"
                }
                guard try unchanged(), try await !runningAVDs().values.contains(device.name) else {
                    throw OrchardError.message("Emulator still running or worktree association changed")
                }
                outcome = "deletion-unconfirmed"
                var args = ["ANDROID_AVD_HOME=\(androidHome.path)"]
                if let java { args.append("JAVA_HOME=\(java)") }
                args += [manager, "delete", "avd", "-n", device.name]
                _ = try await command("/usr/bin/env", args)
                guard !FileManager.default.fileExists(atPath: ini.path), !FileManager.default.fileExists(atPath: device.path.path) else {
                    throw OrchardError.message("AVD removal not confirmed; no filesystem fallback or retry")
                }
                outcome = "removed"
                running = nil
                report.actions.append(.init(target: device.path.path, reason: "missing-worktree", outcome: outcome, name: device.name))
            } catch {
                report.error = report.error ?? String(describing: error)
                report.actions.append(.init(target: ini.path, reason: String(describing: error), outcome: outcome))
            }
        }
    }
}
