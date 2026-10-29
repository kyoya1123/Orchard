import Darwin
import Foundation

public struct CleanupReport: Codable, Sendable {
    public struct Action: Codable, Sendable {
        public let target: String
        public let reason: String
        public let outcome: String
        public var name: String? = nil
        public var lastUsedAt: String? = nil
        public var estimatedBytes: Int64? = nil
        public var state: String? = nil
        public var requiresShutdown: Bool? = nil
    }
    public var actions: [Action] = []
    public var alreadyRunning = false
    public var error: String?
}

public struct ArtifactCleanup: Sendable {
    public enum Scope: String, Sendable { case all, simulators, orphanedDevices = "orphaned-devices", archivedDevices = "archived-devices", derivedData = "derived-data", sourcePackages = "source-packages" }
    typealias Command = @Sendable (String, [String]) async throws -> String
    let store: ArtifactStore
    let derivedData: URL
    let devices: URL
    let sourcePackages: URL?
    let deviceHome: URL
    let deviceEnvironment: [String: String]
    let command: Command
    let now: @Sendable () -> Date
    static let retention: TimeInterval = 7 * 86400

    public init() {
        self.init(store: ArtifactStore(),
                  derivedData: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Developer/Xcode/DerivedData"),
                  devices: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Developer/CoreSimulator/Devices"),
                  sourcePackages: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches/Orchard/SourcePackages-v1"))
    }

    init(store: ArtifactStore, derivedData: URL, devices: URL, sourcePackages: URL? = nil,
         deviceHome: URL = FileManager.default.homeDirectoryForCurrentUser,
         deviceEnvironment: [String: String] = ProcessInfo.processInfo.environment,
         now: @escaping @Sendable () -> Date = { Date() },
         command: @escaping Command = { executable, arguments in
             // CoreSimulator IPC can stall even for `list` at background QoS.
             // Keep the worker/queue at low priority; only its short simctl
             // client uses utility QoS. Filesystem collection remains throttled.
             try await SimulatorProcess.execute(executable: executable, arguments: arguments, timeout: 60,
                 background: true, processQualityOfService: executable == "/usr/bin/xcrun" ? .utility : nil)
         }) {
        self.store = store
        self.derivedData = derivedData
        self.devices = devices
        self.sourcePackages = sourcePackages
        self.deviceHome = deviceHome
        self.deviceEnvironment = deviceEnvironment
        self.now = now
        self.command = command
    }

    struct Settings: Codable { var excludedPaths: [String] = [] }
    struct Device: Decodable, Sendable {
        let udid: String
        let name: String
        let state: String
        let lastBootedAt: String?
        let lastUsedAt: String?
        let dataPathSize: Int64?
    }
    struct DeviceList: Decodable { let devices: [String: [Device]] }
    struct Trash: Codable { let path: String }

    public func run(apply: Bool, directories: [URL] = [], discover: Bool = true, scope: Scope = .all) async -> CleanupReport {
        var report = CleanupReport()
        do {
            guard let lease = try ArtifactLease.tryAcquire(store.root.appendingPathComponent("cleanup.lock")) else {
                report.alreadyRunning = true
                return report
            }
            defer { lease.close() }
            let settings = try store.read(Settings.self, at: store.root.appendingPathComponent("settings.json")) ?? Settings()
            if discover { try await discoverOwners(directories: directories) }
            let owners = try store.all(ArtifactProject.self, in: "projects")
            if scope == .all || scope == .derivedData {
                if apply { try drainTrash(report: &report) }
                try await cleanDerivedData(owners: owners, settings: settings, apply: apply, report: &report)
            }
            if [.all, .simulators, .orphanedDevices, .archivedDevices].contains(scope) {
                let devicesReport = await OrphanedDeviceCleanup(store: store, devices: devices, home: deviceHome,
                    environment: deviceEnvironment, command: command).run(apply: apply,
                        excludedPaths: settings.excludedPaths, includeAndroid: scope != .simulators)
                report.actions += devicesReport.actions
                if let error = devicesReport.error { report.error = error }
            }
            if scope == .all || scope == .sourcePackages {
                try await cleanSourcePackages(owners: owners, settings: settings, apply: apply, report: &report)
            }
        } catch {
            report.error = String(describing: error)
        }
        if !report.alreadyRunning {
            try? store.write(report, to: store.root.appendingPathComponent("last-report.json"))
        }
        return report
    }

    private func discoverOwners(directories: [URL]) async throws {
        let existing = try store.all(ArtifactProject.self, in: "projects")
        let roots = Set(directories + existing.map { URL(fileURLWithPath: $0.owner.repositoryPath) })
        let contexts = await WorktreeContextResolver().resolve(fromConfiguredDirectoryURLs: Array(roots))
        for context in contexts {
            guard let owner = try? await ArtifactOwner.resolve(context.project),
                  let lease = try ArtifactLease.tryAcquire(store.projectLock(owner.projectPath)) else { continue }
            defer { lease.close() }
            if try store.read(ArtifactProject.self, at: store.projectURL(owner.projectPath)) == nil {
                // Discovery is not usage. Otherwise opening Orchard would keep
                // every stale worktree's artifacts alive forever.
                try store.write(ArtifactProject(owner: owner, lastUsedAt: 0), to: store.projectURL(owner.projectPath))
            }
        }
        // Existing run records provide a UDID-to-project association; a branch
        // shaped name alone never establishes ownership of another app's data.
        let known = try store.all(ArtifactProject.self, in: "projects")
        for run in RunStore.shared.loadAll() where run.destination.kind == "simulator" {
            guard !ArtifactStore.isStandardSimulator(run.destination.name),
                  UUID(uuidString: run.destination.id) != nil,
                  let owner = known.first(where: { $0.owner.projectPath == run.projectFilePath })?.owner,
                  let lease = try ArtifactLease.tryAcquire(store.simulatorLock(run.destination.id)) else { continue }
            defer { lease.close() }
            let url = store.simulatorURL(run.destination.id)
            var record = try store.read(ArtifactSimulator.self, at: url)
                ?? ArtifactSimulator(udid: run.destination.id, name: run.destination.name, owners: [], lastUsedAt: 0)
            guard record.name == run.destination.name else { continue }
            record.owners.insert(owner)
            record.lastUsedAt = max(record.lastUsedAt, run.updatedAt)
            try store.write(record, to: url)
        }
    }

    static func contains(_ path: String, in parent: String) -> Bool {
        path == parent || path.hasPrefix(parent.hasSuffix("/") ? parent : parent + "/")
    }

    private func excluded(_ owner: ArtifactOwner, settings: Settings) -> Bool {
        settings.excludedPaths.contains {
            let path = URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath).resolvingSymlinksInPath().path
            return Self.contains(owner.projectPath, in: path) || Self.contains(owner.worktreePath, in: path)
        }
    }

    func owner(for workspace: String, known: [ArtifactProject]) -> ArtifactOwner? {
        if let exact = known.first(where: { $0.owner.projectPath == workspace }) { return exact.owner }
        if let parent = known.map(\.owner).filter({ Self.contains(workspace, in: $0.worktreePath) })
            .max(by: { $0.worktreePath.count < $1.worktreePath.count }) {
            // The main checkout contains .claude worktrees, so inspect those
            // boundaries before treating a missing child as the main project.
            for component in [".claude/worktrees", ".worktrees"] {
                let prefix = URL(fileURLWithPath: parent.repositoryPath).appendingPathComponent(component).path + "/"
                if workspace.hasPrefix(prefix), let name = workspace.dropFirst(prefix.count).split(separator: "/").first {
                    return ArtifactOwner(projectPath: workspace, worktreePath: prefix + name,
                                         repositoryPath: parent.repositoryPath)
                }
            }
            return ArtifactOwner(projectPath: workspace, worktreePath: parent.worktreePath, repositoryPath: parent.repositoryPath)
        }
        // Missing Codex/external worktrees need a recorded association. Their
        // directory basename is insufficient evidence of repository ownership.
        return nil
    }

    private func worktreeExists(_ owner: ArtifactOwner) throws -> Bool {
        // ENOENT is different from a permission or I/O failure.
        do {
            let values = try URL(fileURLWithPath: owner.worktreePath).resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else {
                throw OrchardError.message("Worktree is no longer an ordinary directory: \(owner.worktreePath)")
            }
            return true
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile { return false }
    }

    private func workspace(in directory: URL) throws -> String? {
        let info = directory.appendingPathComponent("info.plist")
        guard FileManager.default.fileExists(atPath: info.path),
              let value = try PropertyListSerialization.propertyList(from: Data(contentsOf: info), format: nil) as? [String: Any],
              let path = value["WorkspacePath"] as? String, path.hasPrefix("/") else { return nil }
        return URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    }

    private func lastBuild(in directory: URL, owner: ArtifactOwner) throws -> Double? {
        var dates: [Double] = []
        if let record = try store.read(ArtifactProject.self, at: store.projectURL(owner.projectPath)), record.lastUsedAt > 0 {
            dates.append(record.lastUsedAt)
        }
        for relative in ["", "Logs/Build", "Build/Intermediates.noindex/XCBuildData/build.db"] {
            let url = relative.isEmpty ? directory : directory.appendingPathComponent(relative)
            if FileManager.default.fileExists(atPath: url.path),
               let date = try url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate {
                dates.append(date.timeIntervalSince1970)
            }
        }
        return dates.max()
    }

    private func packagesAreUnmodified(in directory: URL) async throws -> Bool {
        let root = directory.appendingPathComponent("SourcePackages/checkouts")
        guard FileManager.default.fileExists(atPath: root.path) else { return true }
        for checkout in try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isSymbolicLinkKey]) {
            guard try checkout.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else { return false }
            // Matching mode reports even empty ignored directories such as Xcode's .swiftpm/xcode.
            let status = try await command("/usr/bin/git", ["--no-optional-locks", "-C", checkout.path,
                "-c", "core.fsmonitor=false", "status", "--porcelain", "--untracked-files=all",
                "--ignored=traditional", "--ignore-submodules=none"])
            if !status.isEmpty { return false }
        }
        return true
    }

    private func externallyUsed(_ directory: URL) async throws -> Bool {
        let processes = try await command("/bin/ps", ["-axo", "pid=,comm="])
        var buildServices: [String] = []
        for line in processes.split(separator: "\n") {
            let pieces = line.split(maxSplits: 1, whereSeparator: { $0.isWhitespace })
            guard pieces.count == 2 else { continue }
            let name = URL(fileURLWithPath: String(pieces[1])).lastPathComponent
            if name == "xcodebuild" { return true }
            if ["XCBBuildService", "XCBuildService", "SWBBuildService"].contains(name) { buildServices.append(String(pieces[0])) }
        }
        guard !buildServices.isEmpty else { return false }
        let files = try await command("/usr/sbin/lsof", ["-nP", "-a", "-p", buildServices.joined(separator: ","), "-F", "n"])
        return files.split(separator: "\n").contains { $0.hasPrefix("n") && Self.contains(String($0.dropFirst()), in: directory.path) }
    }

    private func cleanDerivedData(owners: [ArtifactProject], settings: Settings, apply: Bool,
                                  report: inout CleanupReport) async throws {
        guard FileManager.default.fileExists(atPath: derivedData.path),
              try derivedData.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else { return }
        for directory in try FileManager.default.contentsOfDirectory(at: derivedData,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles]) {
            do {
                let values = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                guard values.isDirectory == true, values.isSymbolicLink != true,
                      let path = try workspace(in: directory), let owner = owner(for: path, known: owners),
                      !excluded(owner, settings: settings) else { continue }
                guard let lease = try ArtifactLease.tryAcquire(store.projectLock(owner.projectPath)) else {
                    report.actions.append(.init(target: directory.path, reason: "active-build", outcome: "preserved")); continue
                }
                defer { lease.close() }
                guard try workspace(in: directory) == path else { continue }
                let exists = try worktreeExists(owner)
                guard try !exists || (lastBuild(in: directory, owner: owner)).map({ $0 <= now().timeIntervalSince1970 - Self.retention }) == true else { continue }
                let reason = exists ? "unused-7-days" : "missing-worktree"
                guard try await !externallyUsed(directory) else {
                    report.actions.append(.init(target: directory.path, reason: "external-build", outcome: "preserved")); continue
                }
                guard try await packagesAreUnmodified(in: directory) else {
                    report.actions.append(.init(target: directory.path, reason: "modified-packages", outcome: "preserved")); continue
                }
                if apply {
                    guard try await !externallyUsed(directory) else {
                        report.actions.append(.init(target: directory.path, reason: "external-build", outcome: "preserved")); continue
                    }
                    // Recheck after subprocesses. Moving aside under the lease
                    // is fast; slow recursive removal runs after releasing it.
                    guard try workspace(in: directory) == path,
                          try !worktreeExists(owner) || (lastBuild(in: directory, owner: owner)).map({ $0 <= now().timeIntervalSince1970 - Self.retention }) == true else { continue }
                    let trash = derivedData.appendingPathComponent(".orchard-cleanup-\(UUID().uuidString)")
                    let receipt = store.root.appendingPathComponent("trash/\(trash.lastPathComponent).json")
                    try store.write(Trash(path: trash.path), to: receipt)
                    try FileManager.default.moveItem(at: directory, to: trash)
                    lease.close()
                    try FileManager.default.removeItem(at: trash)
                    try FileManager.default.removeItem(at: receipt)
                }
                report.actions.append(.init(target: directory.path, reason: reason, outcome: apply ? "removed" : "would-remove"))
            } catch {
                report.actions.append(.init(target: directory.path, reason: String(describing: error), outcome: "preserved"))
            }
        }
    }

    private func drainTrash(report: inout CleanupReport) throws {
        for item in try store.all(Trash.self, in: "trash") {
            let path = URL(fileURLWithPath: item.path)
            guard path.deletingLastPathComponent().standardizedFileURL == derivedData.standardizedFileURL,
                  path.lastPathComponent.hasPrefix(".orchard-cleanup-"),
                  UUID(uuidString: String(path.lastPathComponent.dropFirst(".orchard-cleanup-".count))) != nil else { continue }
            if FileManager.default.fileExists(atPath: path.path) {
                guard try path.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else { continue }
                try FileManager.default.removeItem(at: path)
                report.actions.append(.init(target: path.path, reason: "interrupted-cleanup", outcome: "removed"))
            }
            try FileManager.default.removeItem(at: store.root.appendingPathComponent("trash/\(path.lastPathComponent).json"))
        }
    }

    private func simctl(_ arguments: [String]) async throws -> String {
        try await command("/usr/bin/xcrun", ["simctl", "--set", devices.path] + arguments)
    }

    func deviceList() async throws -> [Device] {
        let output = try await simctl(["list", "devices", "-j"])
        return Array(try JSONDecoder().decode(DeviceList.self, from: Data(output.utf8)).devices.values.joined())
    }

    static func epoch(_ text: String?) -> Double? {
        guard let text else { return nil }
        let format = ISO8601DateFormatter()
        format.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = format.date(from: text) { return date.timeIntervalSince1970 }
        format.formatOptions = [.withInternetDateTime]
        return format.date(from: text)?.timeIntervalSince1970
    }

    // CoreSimulator/Orchard usage metadata only; directory mtimes are not usage.
    struct ExternalUsage {
        struct OpenFile { let pid: Int?; let path: String }
        let buildRunning: Bool
        let processes: [Int: String]
        let files: [OpenFile]
        let simulatorSessions: [String]
        var consoleTargets: [Int: String] = [:]
        func contains(_ paths: [String]) -> Bool {
            buildRunning || files.contains { file in paths.contains { ArtifactCleanup.contains(file.path, in: $0) } }
        }

        func usesSimulator(_ device: Device, root: URL, owners: Set<ArtifactOwner>) -> Bool {
            if contains(owners.map(\.worktreePath)) { return true }
            if simulatorSessions.contains(where: { $0.isEmpty || $0 == device.udid.lowercased() }) { return true }
            let path = root.appendingPathComponent(device.udid).path
            return files.contains { file in
                guard ArtifactCleanup.contains(file.path, in: path) else { return false }
                // Shutdown devices keep the conservative open-file check.
                // Booted devices necessarily have OS processes opening files;
                // ignore only known system executables, never installed apps,
                // consoles, debuggers, unknown processes or worktree users.
                guard device.state == "Booted", let pid = file.pid, let executable = processes[pid] else { return true }
                return !ArtifactCleanup.isSimulatorSystemExecutable(executable)
            }
        }
    }

    static func isSimulatorSystemExecutable(_ executable: String) -> Bool {
        let path = URL(fileURLWithPath: executable).standardizedFileURL.path
        if path.hasPrefix("/Library/Developer/CoreSimulator/Volumes/"),
           let range = path.range(of: ".simruntime/Contents/Resources/RuntimeRoot/") {
            let relative = path[range.upperBound...]
            return ["System/", "usr/", "bin/", "sbin/", "Applications/"].contains { relative.hasPrefix($0) }
        }
        // Known macOS helpers that also open Simulator data.
        // Unknown helpers remain a reason to defer, rather than widening this
        // to every Apple executable or every process named like a system daemon.
        return [
            "/usr/libexec/pkd",
            "/System/Library/Frameworks/StoreKit.framework/Support/storekitd",
            "/Library/Developer/PrivateFrameworks/CoreDevice.framework/Versions/A/PrivateApplications/CoreDeviceExtensions.app/Contents/Extensions/DeviceFS.appex/Contents/MacOS/DeviceFS",
            "/Library/Developer/PrivateFrameworks/CoreSimulator.framework/Versions/A/Resources/bin/launchd_sim",
            "/Library/Developer/PrivateFrameworks/CoreSimulator.framework/Versions/A/XPCServices/com.apple.CoreSimulator.CoreSimulatorService.xpc/Contents/MacOS/com.apple.CoreSimulator.CoreSimulatorService"
        ].contains(path)
    }

    func externalUsage(globalBuildGuard: Bool = true) async throws -> ExternalUsage {
        let listing = try await command("/bin/ps", ["-axo", "pid=,comm="])
        var processes: [Int: String] = [:]
        for line in listing.split(separator: "\n") {
            let fields = line.split(maxSplits: 1, whereSeparator: { $0.isWhitespace })
            guard fields.count == 2, let pid = Int(fields[0]) else { continue }
            processes[pid] = String(fields[1])
        }
        let buildRunning = processes.values.contains {
            ["xcodebuild", "XCBBuildService", "XCBuildService", "SWBBuildService"]
                .contains(URL(fileURLWithPath: $0).lastPathComponent)
        }
        if buildRunning && globalBuildGuard { return ExternalUsage(buildRunning: true, processes: processes, files: [], simulatorSessions: []) }
        var consoleTargets: [Int: String] = [:]
        var sessions: [String] = processes.values.contains {
            ["lldb", "debugserver", "lldb-rpc-server"].contains(URL(fileURLWithPath: $0).lastPathComponent)
        } ? [""] : []
        let simctlPIDs = processes.filter { URL(fileURLWithPath: $0.value).lastPathComponent == "simctl" }.keys.sorted()
        if !simctlPIDs.isEmpty {
            let arguments = try await command("/bin/ps", ["-ww", "-p", simctlPIDs.map(String.init).joined(separator: ","), "-o", "pid=,args="])
            for line in arguments.split(separator: "\n") {
                let ids = line.split(whereSeparator: { $0.isWhitespace }).filter { UUID(uuidString: String($0)) != nil }
                let parts = line.split(whereSeparator: { $0.isWhitespace })
                if ids.count == 1, parts.contains("launch"), parts.contains("--console"), let first = parts.first, let pid = Int(first) {
                    consoleTargets[pid] = String(ids[0]).lowercased()
                }
                // Commands addressing "booted" or whose target is unknown are
                // conservatively busy; never interrupt a console/log session.
                sessions.append(contentsOf: ids.isEmpty ? [""] : ids.map { $0.lowercased() })
            }
            if sessions.isEmpty { sessions = [""] }
        }
        let listingFiles = try await command("/usr/sbin/lsof", ["-nP", "-F", "pn"])
        var pid: Int?
        var files: [ExternalUsage.OpenFile] = []
        for line in listingFiles.split(separator: "\n") {
            if line.hasPrefix("p") { pid = Int(line.dropFirst()) }
            else if line.hasPrefix("n") { files.append(.init(pid: pid, path: String(line.dropFirst()))) }
        }
        return ExternalUsage(buildRunning: false, processes: processes, files: files, simulatorSessions: sessions, consoleTargets: consoleTargets)
    }

    private func cleanSourcePackages(owners: [ArtifactProject], settings: Settings, apply: Bool,
                                     report: inout CleanupReport) async throws {
        guard let sourcePackages, FileManager.default.fileExists(atPath: sourcePackages.path) else { return }
        func ordinary(_ url: URL) throws -> Bool {
            let value = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            return value.isDirectory == true && value.isSymbolicLink != true
        }
        guard try ordinary(sourcePackages) else { return }
        for repository in try FileManager.default.contentsOfDirectory(at: sourcePackages, includingPropertiesForKeys: nil) {
            guard try ordinary(repository) else { continue }
            let worktrees = repository.appendingPathComponent("worktrees")
            guard FileManager.default.fileExists(atPath: worktrees.path), try ordinary(worktrees) else { continue }
            for directory in try FileManager.default.contentsOfDirectory(at: worktrees, includingPropertiesForKeys: nil) {
                do {
                    guard try ordinary(directory) else { continue }
                    guard let receipt = try store.read(SourcePackageOwnership.self, at: directory.appendingPathComponent("owner.json")),
                          receipt.repositoryCacheID == repository.lastPathComponent,
                          ArtifactStore.key(receipt.owner.projectPath) == directory.lastPathComponent,
                          owners.contains(where: { $0.owner == receipt.owner }) else {
                        report.actions.append(.init(target: directory.path, reason: "package-ownership-unverified", outcome: "preserved")); continue
                    }
                    let owner = receipt.owner
                    guard !excluded(owner, settings: settings), try !worktreeExists(owner) else {
                        report.actions.append(.init(target: directory.path, reason: "live-or-excluded-worktree", outcome: "preserved")); continue
                    }
                    guard let projectLease = try ArtifactLease.tryAcquire(store.projectLock(owner.projectPath)) else {
                        report.actions.append(.init(target: directory.path, reason: "active-build", outcome: "preserved")); continue
                    }
                    defer { projectLease.close() }
                    guard let cacheLease = try ArtifactLease.tryAcquire(repository.appendingPathComponent("locks/\(directory.lastPathComponent).lock")) else {
                        report.actions.append(.init(target: directory.path, reason: "active-package-cache", outcome: "preserved")); continue
                    }
                    defer { cacheLease.close() }
                    let children = try FileManager.default.contentsOfDirectory(atPath: directory.path)
                    let packages = directory.appendingPathComponent("SourcePackages")
                    guard Set(children) == ["SourcePackages", "owner.json"], try ordinary(packages),
                          try await !externalUsage().contains([directory.path]), try await packagesAreUnmodified(in: directory) else {
                        report.actions.append(.init(target: directory.path, reason: "modified-or-in-use-packages", outcome: "preserved")); continue
                    }
                    // Also rejects local commits, edited/local dependencies and
                    // checkout revisions differing from the recorded lockfile.
                    try receipt.validateLayout(packages)
                    try await SourcePackageCache.validate(packages, resolved: receipt.resolved)
                    if apply {
                        guard try !worktreeExists(owner), try await !externalUsage().contains([directory.path]),
                              try await packagesAreUnmodified(in: directory) else { continue }
                        try receipt.validateLayout(packages)
                        try await SourcePackageCache.validate(packages, resolved: receipt.resolved)
                        try FileManager.default.removeItem(at: directory)
                    }
                    report.actions.append(.init(target: directory.path, reason: "missing-worktree-clean-packages", outcome: apply ? "removed" : "would-remove"))
                } catch {
                    report.actions.append(.init(target: directory.path, reason: "package-inspection-failed: \(error)", outcome: "preserved"))
                }
            }
        }
    }
}
