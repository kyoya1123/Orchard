import Darwin
import Foundation

public struct CleanupReport: Codable, Sendable {
    public struct Action: Codable, Sendable {
        public let target: String
        public let reason: String
        public let outcome: String
    }
    public var actions: [Action] = []
    public var alreadyRunning = false
    public var error: String?
}

public struct ArtifactCleanup: Sendable {
    typealias Command = @Sendable (String, [String]) async throws -> String
    let store: ArtifactStore
    let derivedData: URL
    let devices: URL
    let command: Command
    let now: @Sendable () -> Date
    static let retention: TimeInterval = 7 * 86400

    public init() {
        self.init(store: ArtifactStore(),
                  derivedData: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Developer/Xcode/DerivedData"),
                  devices: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Developer/CoreSimulator/Devices"))
    }

    init(store: ArtifactStore, derivedData: URL, devices: URL,
         now: @escaping @Sendable () -> Date = { Date() },
         command: @escaping Command = { executable, arguments in
             try await SimulatorProcess.execute(executable: executable, arguments: arguments, timeout: 60, background: true)
         }) {
        self.store = store
        self.derivedData = derivedData
        self.devices = devices
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
    }
    struct DeviceList: Decodable { let devices: [String: [Device]] }
    struct Trash: Codable { let path: String }

    public func run(apply: Bool, directories: [URL] = [], discover: Bool = true) async -> CleanupReport {
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
            if apply { try drainTrash(report: &report) }
            try await cleanDerivedData(owners: owners, settings: settings, apply: apply, report: &report)
            try await cleanSimulators(settings: settings, apply: apply, report: &report)
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
            let status = try await command("/usr/bin/git", ["--no-optional-locks", "-C", checkout.path,
                "-c", "core.fsmonitor=false", "status", "--porcelain", "--untracked-files=all",
                "--ignored=matching", "--ignore-submodules=none"])
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

    private func deviceList() async throws -> [Device] {
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

    private func simulatorReason(_ record: ArtifactSimulator, device: Device) throws -> String? {
        guard !record.owners.isEmpty else { return nil }
        if try record.owners.allSatisfy({ try !worktreeExists($0) }) { return "missing-worktree" }
        let lastUse = [record.lastUsedAt > 0 ? record.lastUsedAt : nil,
                       Self.epoch(device.lastUsedAt), Self.epoch(device.lastBootedAt)].compactMap { $0 }.max()
        return lastUse.map { $0 <= now().timeIntervalSince1970 - Self.retention } == true ? "unused-7-days" : nil
    }

    private func cleanSimulators(settings: Settings, apply: Bool, report: inout CleanupReport) async throws {
        let records = try store.all(ArtifactSimulator.self, in: "simulators")
        guard !records.isEmpty else { return }
        let inventory = try await deviceList()
        for entry in records {
            do {
                guard UUID(uuidString: entry.udid) != nil, !ArtifactStore.isStandardSimulator(entry.name),
                      !entry.owners.contains(where: { excluded($0, settings: settings) }),
                      let initial = inventory.first(where: { $0.udid == entry.udid }), initial.name == entry.name,
                      try simulatorReason(entry, device: initial) != nil else { continue }
                var leases: [ArtifactLease] = []
                defer { leases.forEach { $0.close() } }
                let paths = Set(entry.owners.map { store.projectLock($0.projectPath) }).sorted { $0.path < $1.path }
                for path in paths {
                    guard let lease = try ArtifactLease.tryAcquire(path) else { break }
                    leases.append(lease)
                }
                guard leases.count == paths.count,
                      let deviceLease = try ArtifactLease.tryAcquire(store.simulatorLock(entry.udid)) else {
                    report.actions.append(.init(target: entry.udid, reason: "active-build-or-install", outcome: "preserved")); continue
                }
                defer { deviceLease.close() }
                guard let record = try store.read(ArtifactSimulator.self, at: store.simulatorURL(entry.udid)),
                      record.owners == entry.owners, record.name == entry.name,
                      let device = try await deviceList().first(where: { $0.udid == entry.udid }), device.name == record.name,
                      let reason = try simulatorReason(record, device: device) else { continue }
                if apply {
                    guard ["Booted", "Shutdown"].contains(device.state) else { continue }
                    if device.state == "Booted" { _ = try await simctl(["shutdown", device.udid]) }
                    guard let stopped = try await deviceList().first(where: { $0.udid == device.udid }),
                          stopped.state == "Shutdown", stopped.name == record.name,
                          try simulatorReason(record, device: device) != nil else { continue }
                    _ = try await simctl(["delete", device.udid])
                    try FileManager.default.removeItem(at: store.simulatorURL(record.udid))
                }
                report.actions.append(.init(target: entry.udid, reason: reason, outcome: apply ? "removed" : "would-remove"))
            } catch {
                report.actions.append(.init(target: entry.udid, reason: String(describing: error), outcome: "preserved"))
            }
        }
    }
}
