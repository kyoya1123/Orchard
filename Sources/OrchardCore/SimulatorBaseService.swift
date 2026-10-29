import Foundation
import Darwin

public struct PreparedSimulator: Encodable, Sendable {
    public let udid: String
    public let name: String
    public let deviceType: String
    public let runtime: String
    public let reused: Bool
    public let baseUDID: String
}

/// Templates have a private set. Registered clones in the default set are
/// replaced within the same device type/runtime after a new generation is ready.
public struct SimulatorBaseService: Sendable {
    typealias Command = @Sendable (String, [String], TimeInterval) async throws -> String
    private let root: URL
    private let destinationSet: URL
    private let command: Command
    private let store: ArtifactStore
    private let closeWindow: @Sendable (String, String, Bool) async throws -> Void

    public init() {
        self.init(root: FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Orchard/SimulatorBases-v1"),
                  destinationSet: FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Developer/CoreSimulator/Devices"), store: ArtifactStore(), closeWindow: { try await DeviceWindowCloser.close(name: $0, runtime: $1, uniqueDevice: $2) })
    }

    init(root: URL, destinationSet: URL, store: ArtifactStore? = nil,
         closeWindow: @escaping @Sendable (String, String, Bool) async throws -> Void = { _, _, _ in },
         command: @escaping Command = { tool, arguments, timeout in
             try await SimulatorProcess.run(tool: tool, arguments: arguments, timeout: timeout)
         }) {
        self.closeWindow = closeWindow
        self.store = store ?? ArtifactStore(root: root.appendingPathComponent("ownership"))
        self.root = root
        self.destinationSet = destinationSet
        self.command = command
    }

    public func prepare(name: String? = nil, selection: SimulatorSelection = .init(),
                        project: XcodeProject? = nil,
                        progress: @Sendable (String) -> Void = { _ in }) async throws -> PreparedSimulator {
        if let name, name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw OrchardError.message("The branch Simulator name must not be empty.")
        }
        let activity: ArtifactActivity?
        if let project { activity = try await ArtifactActivity.begin(project: project) } else { activity = nil }
        defer { activity?.finish() }
        let lease = try await ArtifactLease.acquire(root.appendingPathComponent("lock"), shared: false, timeout: .seconds(10))
        defer { lease.close() }
        try Task.checkCancellation()
        try FileManager.default.createDirectory(at: root.appendingPathComponent("devices"), withIntermediateDirectories: true)
        let catalog = try JSONDecoder().decode(SimulatorCatalog.self, from: Data(try await simctl(["list", "-j"]).utf8))
        let (type, runtime) = try catalog.resolve(selection)
        let xcode = try await command("xcodebuild", ["-version"], 30)
        let simctlPath = try await command("--find", ["simctl"], 30)
        let configuration = Configuration(deviceType: type.identifier, runtime: runtime.identifier,
                                          runtimeBuild: runtime.buildversion, xcode: xcode,
                                          simctlPath: simctlPath, revision: 1)
        var registry = try loadRegistry()
        let owned = try store.all(ArtifactSimulator.self, in: "simulators")
        // Adopt only exact, previously recorded UDID/name associations. Names alone
        // never authorize migration of someone else's default-set device.
        for record in owned where !record.owners.isEmpty && !ArtifactStore.isStandardSimulator(record.name) {
            if !(registry.clones ?? []).contains(where: { $0.udid == record.udid }),
               let pair = catalog.devices.first(where: { $0.value.contains { $0.udid == record.udid && $0.name == record.name } }) {
                registry.clones = (registry.clones ?? []) + [Clone(udid: record.udid, name: record.name, runtime: pair.key, configuration: nil)]
            }
        }
        var branchMatches = name.map { name in
            (catalog.devices[runtime.identifier] ?? []).filter {
                $0.isAvailable && $0.name == name && $0.deviceTypeIdentifier == type.identifier
                    && Self.canReuse($0.udid, clones: registry.clones ?? [], configuration: configuration)
            }
        } ?? []
        guard branchMatches.count <= 1 else {
            throw OrchardError.message("Multiple Simulators match \(name ?? "") / \(type.name) / \(runtime.name). Select an explicit UDID.")
        }

        if let existing = branchMatches.first {
            try await activity?.useSimulator(udid: existing.udid, name: existing.name)
            // A collector may have completed while this invocation waited for
            // the device lease. Never return the stale catalog's deleted UDID.
            let fresh = try JSONDecoder().decode(DeviceList.self,
                from: Data(try await simctl(["list", "devices", "-j"]).utf8))
            branchMatches = (fresh.devices[runtime.identifier] ?? []).filter {
                $0.isAvailable && $0.name == name && $0.deviceTypeIdentifier == type.identifier
                    && Self.canReuse($0.udid, clones: registry.clones ?? [], configuration: configuration)
            }
            guard branchMatches.isEmpty || (branchMatches.count == 1 && branchMatches[0].udid == existing.udid) else {
                throw OrchardError.message("Simulator changed while preparing it; retry the command.")
            }
        }
        let privateDevices = try await baseDevices()
        var base: Entry?
        for entry in registry.entries where entry.configuration == configuration && entry.ready {
            guard let device = privateDevices.devices[entry.configuration.runtime]?.first(where: { $0.udid == entry.udid }),
                  matches(device, entry), device.state == "Shutdown", device.isAvailable else { continue }
            if try hasNoAppBundles(entry.udid) {
                base = entry
                break
            }
            progress("Preserving modified base \(entry.udid); preparing a clean replacement.")
        }

        if base == nil {
            let baseName = "Orchard Base \(UUID().uuidString)"
            progress("Preparing empty base: \(type.name) / \(runtime.name)")
            let id = try await simctl(["create", baseName, type.identifier, runtime.identifier], privateSet: true)
            guard UUID(uuidString: id) != nil else { throw OrchardError.message("simctl create returned an invalid UDID.") }
            var entry = Entry(udid: id, name: baseName, configuration: configuration, ready: false)
            registry.entries.append(entry)
            try save(registry)
            do {
                _ = try await simctl(["boot", id], privateSet: true)
                _ = try await simctl(["bootstatus", id, "-b"], privateSet: true, timeout: 300)
                guard try await hasOnlySystemApps(id) else {
                    throw OrchardError.message("New base contains user-installed apps; it will not be cloned.")
                }
                _ = try await simctl(["shutdown", id], privateSet: true)
                let devices = try await baseDevices()
                guard devices.devices[runtime.identifier]?.contains(where: {
                    $0.udid == id && matches($0, entry) && $0.state == "Shutdown" && $0.isAvailable
                }) == true else { throw OrchardError.message("Base did not reach Shutdown after initialization.") }
                entry.ready = true
                registry.entries[registry.entries.count - 1] = entry
                try save(registry)
                base = entry
            } catch {
                // Only this call's freshly created base can be stopped here.
                // Keep its record for a later cleanup; never destroy the old base
                // unless a replacement has completed initialization.
                _ = try? await simctl(["shutdown", id], privateSet: true)
                throw error
            }
        }
        guard let base else { throw OrchardError.message("No prepared Simulator base.") }

        let result: PreparedSimulator
        if let existing = branchMatches.first {
            progress("Reusing Simulator \(existing.name) (\(existing.udid))")
            result = PreparedSimulator(udid: existing.udid, name: existing.name, deviceType: type.name,
                                       runtime: runtime.name, reused: true, baseUDID: base.udid)
        } else if let name {
            progress("Cloning base for \(name)")
            let id = try await simctl(["clone", base.udid, name, destinationSet.path], privateSet: true)
            guard UUID(uuidString: id) != nil else { throw OrchardError.message("simctl clone returned an invalid UDID.") }
            registry.clones = (registry.clones ?? []) + [Clone(udid: id, name: name, runtime: runtime.identifier, configuration: configuration)]
            try save(registry)
            result = PreparedSimulator(udid: id, name: name, deviceType: type.name,
                                       runtime: runtime.name, reused: false, baseUDID: base.udid)
        } else {
            result = PreparedSimulator(udid: base.udid, name: base.name, deviceType: type.name,
                                       runtime: runtime.name, reused: privateDevices.devices.values.joined().contains { $0.udid == base.udid }, baseUDID: base.udid)
        }

        if name != nil, !result.reused {
            try await activity?.useSimulator(udid: result.udid, name: result.name)
        }
        // Clone first: a clone failure must not discard the previous template.
        try await pruneClones(registry: &registry, configuration: configuration, progress: progress)
        try await prune(registry: &registry, keeping: base.udid, configuration: configuration, progress: progress)
        return result
    }

    private func prune(registry: inout Registry, keeping id: String, configuration: Configuration,
                       progress: @Sendable (String) -> Void) async throws {
        for entry in registry.entries where entry.udid != id && entry.configuration.hasSameTarget(as: configuration) {
            do {
                let devices = try await baseDevices()
                guard let device = devices.devices[entry.configuration.runtime]?.first(where: { $0.udid == entry.udid }) else {
                    registry.entries.removeAll { $0.udid == entry.udid }
                    try save(registry)
                    continue
                }
                guard matches(device, entry), ["Shutdown", "Booted"].contains(device.state) else {
                    progress("Preserving busy or changed base \(entry.udid).")
                    continue
                }
                // A user may have opened our private set explicitly. Refuse to
                // discard their app data even though the registry says we own it.
                guard try hasNoAppBundles(entry.udid) else {
                    progress("Preserving base with user-installed apps: \(entry.udid).")
                    continue
                }
                try await closeWindow(entry.name, entry.configuration.runtime, true)
                if device.state == "Booted" {
                    _ = try await simctl(["shutdown", entry.udid], privateSet: true)
                    guard try await baseDevices().devices[entry.configuration.runtime]?.contains(where: {
                        $0.udid == entry.udid && $0.state == "Shutdown" && matches($0, entry)
                    }) == true else { throw OrchardError.message("Base shutdown unconfirmed") }
                }
                _ = try await simctl(["delete", entry.udid], privateSet: true)
                registry.entries.removeAll { $0.udid == entry.udid }
                try save(registry)
                progress("Removed obsolete empty base \(entry.udid).")
            } catch {
                // Unavailable runtimes or externally booted bases can be retried
                // later; they must not break a successfully prepared destination.
                progress("Could not remove base \(entry.udid): \(error)")
            }
        }
    }

    private func matches(_ device: SimulatorCatalog.Device, _ entry: Entry) -> Bool {
        device.name == entry.name && device.deviceTypeIdentifier == entry.configuration.deviceType
    }

    private func hasOnlySystemApps(_ id: String) async throws -> Bool {
        let output = try await simctl(["listapps", id], privateSet: true)
        let plist = try PropertyListSerialization.propertyList(from: Data(output.utf8), format: nil)
        guard let apps = plist as? [String: [String: Any]], !apps.isEmpty else {
            throw OrchardError.message("Unable to verify installed apps on base \(id).")
        }
        return apps.values.allSatisfy { ($0["ApplicationType"] as? String) == "System" }
    }

    private func hasNoAppBundles(_ id: String) throws -> Bool {
        try Self.hasNoAppBundles(in: root.appendingPathComponent("devices").appendingPathComponent(id))
    }

    // `simctl listapps` requires a booted device. The initial boot validates the
    // system-only baseline; while shut down, conservatively reject any installed
    // bundle or unexpected contents in the user-app installation directory.
    static func hasNoAppBundles(in device: URL) throws -> Bool {
        let containers = device.appendingPathComponent("data/Containers")
        let children = try FileManager.default.contentsOfDirectory(at: containers,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard let bundle = children.first(where: { $0.lastPathComponent == "Bundle" }) else { return true }
        let metadata = try bundle.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard metadata.isDirectory == true, metadata.isSymbolicLink != true else { return false }
        let entries = try FileManager.default.contentsOfDirectory(at: bundle,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        for entry in entries {
            let values = try entry.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard entry.lastPathComponent == "Application", values.isDirectory == true,
                  values.isSymbolicLink != true,
                  try FileManager.default.contentsOfDirectory(atPath: entry.path).isEmpty else { return false }
        }
        return true
    }

    private func simctl(_ arguments: [String], privateSet: Bool = false, timeout: TimeInterval = 60) async throws -> String {
        let prefix = privateSet ? ["--set", root.appendingPathComponent("devices").path] : ["--set", destinationSet.path]
        return try await command("simctl", prefix + arguments, timeout)
    }

    private struct DeviceList: Decodable { let devices: [String: [SimulatorCatalog.Device]] }
    private func baseDevices() async throws -> DeviceList {
        let output = try await simctl(["list", "devices", "-j"], privateSet: true)
        return try JSONDecoder().decode(DeviceList.self, from: Data(output.utf8))
    }

    struct Configuration: Codable, Equatable, Sendable {
        let deviceType: String
        let runtime: String
        let runtimeBuild: String
        let xcode: String
        let simctlPath: String
        let revision: Int

        func hasSameTarget(as other: Configuration) -> Bool {
            deviceType == other.deviceType && runtime == other.runtime
        }
    }
    struct Entry: Codable, Sendable {
        let udid: String
        let name: String
        let configuration: Configuration
        var ready: Bool
    }
    struct Clone: Codable, Sendable { let udid: String; let name: String; let runtime: String; let configuration: Configuration? }
    struct Registry: Codable { var entries: [Entry] = []; var clones: [Clone]? }

    static func canReuse(_ id: String, clones: [Clone], configuration: Configuration) -> Bool {
        guard let clone = clones.first(where: { $0.udid == id }) else { return true }
        // Legacy ownership did not record a generation. The caller still checks
        // the live model/runtime; lack of a generation alone is not obsolescence.
        return clone.configuration == nil || clone.configuration == configuration
    }

    private func pruneClones(registry: inout Registry, configuration: Configuration,
                             progress: @Sendable (String) -> Void) async throws {
        var actions: [CleanupReport.Action] = []
        for clone in registry.clones ?? [] where clone.configuration?.hasSameTarget(as: configuration) == true
            && clone.configuration != configuration {
            do {
                guard let lease = try ArtifactLease.tryAcquire(store.simulatorLock(clone.udid)) else {
                    actions.append(.init(target: clone.udid, reason: "active-build-or-test", outcome: "preserved", name: clone.name)); continue
                }
                defer { lease.close() }
                if let owner = try store.read(ArtifactSimulator.self, at: store.simulatorURL(clone.udid)) {
                    guard owner.name == clone.name, !owner.owners.isEmpty else { continue }
                    for path in Set(owner.owners.map(\.worktreePath)) { _ = try MissingWorktree.check(path) }
                }
                func current() async throws -> SimulatorCatalog.Device? {
                    let list = try JSONDecoder().decode(DeviceList.self, from: Data(try await simctl(["list", "devices", "-j"]).utf8))
                    return list.devices[clone.runtime]?.first(where: { $0.udid == clone.udid })
                }
                guard let device = try await current() else {
                    registry.clones?.removeAll { $0.udid == clone.udid }; try save(registry); continue
                }
                guard device.name == clone.name, ["Booted", "Shutdown"].contains(device.state) else { continue }
                let windowList = try JSONDecoder().decode(DeviceList.self, from: Data(try await simctl(["list", "devices", "-j"]).utf8))
                let uniqueWindowDevice = (windowList.devices[clone.runtime] ?? []).filter { $0.name == clone.name }.count == 1
                try await closeWindow(clone.name, clone.runtime, uniqueWindowDevice)
                if device.state == "Booted" { _ = try await simctl(["shutdown", clone.udid]) }
                guard let stopped = try await current(), stopped.name == clone.name, stopped.state == "Shutdown" else {
                    throw OrchardError.message("Old managed device shutdown unconfirmed")
                }
                _ = try await simctl(["delete", clone.udid])
                guard try await current() == nil else { throw OrchardError.message("Old managed device deletion unconfirmed") }
                registry.clones?.removeAll { $0.udid == clone.udid }
                try save(registry)
                // Keep the lightweight ownership receipt so a saved rerun can resolve
                // its branch name to the replacement instead of launching a stale UDID.
                actions.append(.init(target: clone.udid, reason: "obsolete-runtime-generation", outcome: "removed", name: clone.name))
                progress("Removed obsolete managed Simulator \(clone.name) (\(clone.udid)).")
            } catch {
                actions.append(.init(target: clone.udid, reason: String(describing: error), outcome: "preserved", name: clone.name))
                progress("Preserved old Simulator \(clone.udid): \(error)")
            }
        }
        try store.write(actions, to: root.appendingPathComponent("last-migration.json"))
    }

    public func prepareManagedDestination(_ destination: XcodeDestination, project: XcodeProject) async throws -> XcodeDestination {
        guard destination.kind == .simulator,
              let record = try store.read(ArtifactSimulator.self, at: store.simulatorURL(destination.id)),
              record.name == destination.name, !record.owners.isEmpty else { return destination }
        let catalog = try JSONDecoder().decode(SimulatorCatalog.self, from: Data(try await simctl(["list", "-j"]).utf8))
        let selection = try Self.managedSelection(id: destination.id, name: record.name, catalog: catalog,
                                                  clones: loadRegistry().clones ?? [])
        let prepared = try await prepare(name: record.name, selection: selection, project: project)
        return XcodeDestination(id: prepared.udid, name: prepared.name, runtime: prepared.runtime, isAvailable: true, kind: .simulator)
    }

    static func managedSelection(id: String, name: String, catalog: SimulatorCatalog, clones: [Clone]) throws -> SimulatorSelection {
        if let pair = catalog.devices.first(where: { $0.value.contains { $0.udid == id } }),
           let device = pair.value.first(where: { $0.udid == id }) {
            guard device.name == name, let type = device.deviceTypeIdentifier else {
                throw OrchardError.message("Managed Simulator identity changed; select the intended destination again.")
            }
            return SimulatorSelection(deviceType: type, runtime: pair.key)
        }
        if let clone = clones.first(where: { $0.udid == id && $0.name == name }), let configuration = clone.configuration {
            return SimulatorSelection(deviceType: configuration.deviceType, runtime: configuration.runtime)
        }
        throw OrchardError.message("The saved Simulator is missing and its device type is unknown. Select a device type and runtime again.")
    }

    func maintain() async -> CleanupReport.Action? {
        guard FileManager.default.fileExists(atPath: root.appendingPathComponent("manifest.json").path) else { return nil }
        do {
            let ready = try await prepare()
            return .init(target: ready.baseUDID, reason: "runtime-ready: \(ready.runtime)", outcome: "ready", name: ready.name)
        } catch {
            return .init(target: root.path, reason: String(describing: error), outcome: "pending")
        }
    }

    private func loadRegistry() throws -> Registry {
        let path = root.appendingPathComponent("manifest.json")
        guard FileManager.default.fileExists(atPath: path.path) else { return Registry() }
        return try JSONDecoder().decode(Registry.self, from: Data(contentsOf: path))
    }
    private func save(_ registry: Registry) throws {
        try JSONEncoder().encode(registry).write(to: root.appendingPathComponent("manifest.json"), options: .atomic)
    }
}

/// simctl bootstatus can otherwise wait indefinitely. File-backed output avoids
/// pipe deadlocks during boot, and the timeout bounds tool failures.
enum SimulatorProcess {
    static func run(tool: String, arguments: [String], timeout: TimeInterval) async throws -> String {
        try await execute(executable: "/usr/bin/xcrun", arguments: [tool] + arguments, timeout: timeout)
    }

    static func execute(executable: String, arguments: [String], timeout: TimeInterval,
                        background: Bool = false, processQualityOfService: QualityOfService? = nil,
                        terminationGrace: Duration = .seconds(2)) async throws -> String {
        let control = SimulatorProcessControl()
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: background ? .background : .userInitiated).async {
                    do {
                        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("OrchardSimctl-\(UUID().uuidString)")
                        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                        defer { try? FileManager.default.removeItem(at: directory) }
                        let output = directory.appendingPathComponent("stdout")
                        let errorOutput = directory.appendingPathComponent("stderr")
                        FileManager.default.createFile(atPath: output.path, contents: nil)
                        FileManager.default.createFile(atPath: errorOutput.path, contents: nil)
                        let out = try FileHandle(forWritingTo: output)
                        let err = try FileHandle(forWritingTo: errorOutput)
                        defer { try? out.close(); try? err.close() }
                        let process = Process()
                        process.executableURL = URL(fileURLWithPath: executable)
                        process.arguments = arguments
                        process.qualityOfService = processQualityOfService ?? (background ? .background : .userInitiated)
                        process.standardOutput = out
                        process.standardError = err
                        process.standardInput = FileHandle.nullDevice
                        try control.start(process)
                        let deadline = ContinuousClock.now.advanced(by: .seconds(timeout))
                        // Keep Foundation's launch runloop serviced, but never
                        // enter waitUntilExit: a child can ignore SIGTERM.
                        while process.isRunning {
                            if ContinuousClock.now >= deadline { control.stop(timedOut: true) }
                            if control.forceStopAfterGrace(terminationGrace) { try control.check() }
                            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.02))
                        }
                        try control.check()
                        let stdout = try String(contentsOf: output, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
                        let stderr = try String(contentsOf: errorOutput, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
                        guard process.terminationStatus == 0 else {
                            throw OrchardError.message(stderr.isEmpty ? stdout : stderr)
                        }
                        continuation.resume(returning: stdout)
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        }, onCancel: { control.stop(timedOut: false) })
    }
}

private final class SimulatorProcessControl: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false
    private var timedOut = false
    private var stoppedAt: ContinuousClock.Instant?

    func start(_ value: Process) throws {
        lock.lock()
        defer { lock.unlock() }
        guard !cancelled else { throw CancellationError() }
        try value.run()
        process = value
    }

    func stop(timedOut: Bool) {
        lock.lock()
        defer { lock.unlock() }
        guard !cancelled else { return }
        self.timedOut = timedOut
        cancelled = true
        stoppedAt = .now
        if let process, process.isRunning { process.terminate() }
    }

    func forceStopAfterGrace(_ grace: Duration) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let stoppedAt, ContinuousClock.now >= stoppedAt.advanced(by: grace) else { return false }
        // Only the Process instance we spawned is signalled. Do not enumerate
        // processes or wait indefinitely for kernel/process teardown.
        if let process, process.isRunning { _ = Darwin.kill(process.processIdentifier, SIGKILL) }
        return true
    }

    func check() throws {
        lock.lock()
        defer { lock.unlock() }
        if timedOut { throw OrchardError.message("Simulator command timed out.") }
        if cancelled { throw CancellationError() }
    }
}
