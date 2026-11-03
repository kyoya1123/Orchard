import Foundation

/// Actual work owns a shared device lease. Console attachment and inventory do not.
/// Each activity has an atomic receipt, so concurrent users cannot overwrite a newer date.
public final class DeviceActivity: @unchecked Sendable {
    struct Receipt: Codable { let device: String; let lastUsedAt: Double }
    let store: ArtifactStore
    let device: String
    let receipt: URL
    private let lease: ArtifactLease
    private let now: @Sendable () -> Date
    private let mutex = NSLock()
    private var finished = false

    init(store: ArtifactStore, device: String, lease: ArtifactLease,
         now: @escaping @Sendable () -> Date = { Date() }) throws {
        self.store = store; self.device = device; self.lease = lease; self.now = now
        receipt = Self.directory(store, device).appendingPathComponent("\(UUID()).json")
        try touch()
    }

    static func directory(_ store: ArtifactStore, _ device: String) -> URL {
        store.root.appendingPathComponent("device-use/\(ArtifactStore.key(device))")
    }

    static func latest(store: ArtifactStore, device: String) throws -> Double? {
        let records = try store.all(Receipt.self, in: "device-use/\(ArtifactStore.key(device))")
        guard records.allSatisfy({ $0.device == device && $0.lastUsedAt.isFinite && $0.lastUsedAt > 0 }) else {
            throw OrchardError.message("Uncertain device activity receipt")
        }
        return records.map(\.lastUsedAt).max()
    }

    private func touch() throws {
        try store.write(Receipt(device: device, lastUsedAt: now().timeIntervalSince1970), to: receipt)
    }

    public func finish(scheduleCleanup: Bool = true) {
        mutex.lock(); defer { mutex.unlock() }
        guard !finished else { return }
        try? touch()
        finished = true
        lease.close()
        if scheduleCleanup { BackgroundCleanup.schedule() }
    }
    deinit { finish() }

    /// Wraps an external iOS test command in the same bounded tracking used by
    /// Orchard's own builds. This never creates ownership.
    public static func run(simulator: String, command: [String], timeout: Double) async throws -> String {
        guard !command.isEmpty, timeout.isFinite, timeout > 0, timeout <= 86400 else {
            throw OrchardError.message("Pass a command and a timeout of 1...86400 seconds")
        }
        let store = ArtifactStore()
        guard UUID(uuidString: simulator) != nil,
              let record = try store.read(ArtifactSimulator.self, at: store.simulatorURL(simulator)),
              !record.owners.isEmpty else { throw OrchardError.message("Unknown Orchard simulator") }
        let lease = try await ArtifactLease.acquire(store.simulatorLock(simulator), timeout: .seconds(5))
        let activity = try DeviceActivity(store: store, device: simulator, lease: lease)
        defer { activity.finish() }
        return try await SimulatorProcess.execute(executable: "/usr/bin/env", arguments: command, timeout: timeout)
    }
}
