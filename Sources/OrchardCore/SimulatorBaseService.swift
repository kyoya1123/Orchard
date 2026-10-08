import Foundation

public struct PreparedSimulator: Encodable, Sendable {
    public let udid: String
    public let name: String
    public let deviceType: String
    public let runtime: String
    public let reused: Bool
    public let baseUDID: String
}

/// Only templates live in the private device set. Branch devices live in the
/// default set and are never erased, stopped, or deleted by this service.
public struct SimulatorBaseService: Sendable {
    typealias Command = @Sendable (String, [String], TimeInterval) async throws -> String
    private let root: URL
    private let destinationSet: URL
    private let command: Command

    public init() {
        self.init(root: FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Orchard/SimulatorBases-v1"),
                  destinationSet: FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Developer/CoreSimulator/Devices"))
    }

    init(root: URL, destinationSet: URL,
         command: @escaping Command = { tool, arguments, timeout in
             try await SimulatorProcess.run(tool: tool, arguments: arguments, timeout: timeout)
         }) {
        self.root = root
        self.destinationSet = destinationSet
        self.command = command
    }

    public func prepare(name: String? = nil, selection: SimulatorSelection = .init(),
                        progress: @Sendable (String) -> Void = { _ in }) async throws -> PreparedSimulator {
        if let name, name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw OrchardError.message("The branch Simulator name must not be empty.")
        }
        let lease = try await CacheLease.acquire(root.appendingPathComponent("lock"))
        defer { lease.unlock() }
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
        let branchMatches = name.map { name in
            (catalog.devices[runtime.identifier] ?? []).filter {
                $0.isAvailable && $0.name == name && $0.deviceTypeIdentifier == type.identifier
            }
        } ?? []
        guard branchMatches.count <= 1 else {
            throw OrchardError.message("Multiple Simulators match \(name ?? "") / \(type.name) / \(runtime.name). Select an explicit UDID.")
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
            result = PreparedSimulator(udid: id, name: name, deviceType: type.name,
                                       runtime: runtime.name, reused: false, baseUDID: base.udid)
        } else {
            result = PreparedSimulator(udid: base.udid, name: base.name, deviceType: type.name,
                                       runtime: runtime.name, reused: privateDevices.devices.values.joined().contains { $0.udid == base.udid }, baseUDID: base.udid)
        }

        // Clone first: a clone failure must not discard the previous template.
        try await prune(registry: &registry, keeping: base.udid, progress: progress)
        return result
    }

    private func prune(registry: inout Registry, keeping id: String,
                       progress: @Sendable (String) -> Void) async throws {
        for entry in registry.entries where entry.udid != id {
            do {
                let devices = try await baseDevices()
                guard let device = devices.devices[entry.configuration.runtime]?.first(where: { $0.udid == entry.udid }) else {
                    registry.entries.removeAll { $0.udid == entry.udid }
                    try save(registry)
                    continue
                }
                guard matches(device, entry), device.state == "Shutdown" else {
                    progress("Preserving busy or changed base \(entry.udid).")
                    continue
                }
                // A user may have opened our private set explicitly. Refuse to
                // discard their app data even though the registry says we own it.
                guard try hasNoAppBundles(entry.udid) else {
                    progress("Preserving base with user-installed apps: \(entry.udid).")
                    continue
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
    }
    struct Entry: Codable, Sendable {
        let udid: String
        let name: String
        let configuration: Configuration
        var ready: Bool
    }
    struct Registry: Codable { var entries: [Entry] = [] }

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
        let control = SimulatorProcessControl()
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
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
                        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
                        process.arguments = [tool] + arguments
                        process.standardOutput = out
                        process.standardError = err
                        try control.start(process)
                        let timer = DispatchSource.makeTimerSource(queue: .global())
                        timer.schedule(deadline: .now() + timeout)
                        timer.setEventHandler { control.stop(timedOut: true) }
                        timer.resume()
                        defer { timer.cancel() }
                        // Foundation's Process must run and wait on the same
                        // thread; awaiting between these calls can strand its runloop.
                        process.waitUntilExit()
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
        self.timedOut = self.timedOut || timedOut
        cancelled = true
        if let process, process.isRunning { process.terminate() }
    }

    func check() throws {
        lock.lock()
        defer { lock.unlock() }
        if timedOut { throw OrchardError.message("Simulator command timed out.") }
        if cancelled { throw CancellationError() }
    }
}
