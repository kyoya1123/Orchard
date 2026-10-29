import Foundation

/// Durable, coalescing requests. An invocation arriving during a collection
/// causes another pass; it is not discarded by the collector's try-lock.
public struct CleanupInvocation: Sendable {
    let store: ArtifactStore
    let lockTimeout: Duration
    let retryTimeout: Duration
    let retryDelay: Duration
    public init() { self.init(store: ArtifactStore()) }
    init(store: ArtifactStore, lockTimeout: Duration = .seconds(2),
         retryTimeout: Duration = .seconds(30), retryDelay: Duration = .milliseconds(500)) {
        self.store = store
        self.lockTimeout = lockTimeout
        self.retryTimeout = retryTimeout
        self.retryDelay = retryDelay
    }
    struct Request: Codable, Equatable { let id: UUID; let requestedAt: Date }
    var pending: URL { store.root.appendingPathComponent("invocation-pending.json") }
    var requestLock: URL { store.root.appendingPathComponent("invocation.lock") }
    var workerLock: URL { store.root.appendingPathComponent("invocation-worker.lock") }

    func enqueue() async throws {
        let lease = try await ArtifactLease.acquire(requestLock, shared: false, timeout: lockTimeout)
        defer { lease.close() }
        try store.write(Request(id: UUID(), requestedAt: Date()), to: pending)
    }

    public func drain(directories: [URL]) async {
        await drain {
            // Device ownership must already be recorded. Avoid an
            // unrelated repository scan on every CLI/GUI invocation.
            await ArtifactCleanup().run(apply: true, directories: directories, discover: false, scope: .orphanedDevices)
        }
    }

    func drain(collect: @Sendable () async -> CleanupReport) async {
        do {
            guard let worker = try ArtifactLease.tryAcquire(workerLock) else { return }
            defer { worker.close() }
            // Also supports an older GUI invoking cleanup-worker directly.
            let initial = try await ArtifactLease.acquire(requestLock, shared: false, timeout: lockTimeout)
            if try store.read(Request.self, at: pending) == nil {
                try store.write(Request(id: UUID(), requestedAt: Date()), to: pending)
            }
            initial.close()
            let retryDeadline = ContinuousClock.now.advanced(by: retryTimeout)
            while !Task.isCancelled {
                let gate = try await ArtifactLease.acquire(requestLock, shared: false, timeout: lockTimeout)
                guard let request = try store.read(Request.self, at: pending) else {
                    // Release the worker lock before the enqueue lock: no
                    // request can land in the exit handoff gap and be lost.
                    worker.close()
                    gate.close()
                    return
                }
                gate.close()
                let report = await collect()
                if report.alreadyRunning {
                    guard ContinuousClock.now < retryDeadline else {
                        throw OrchardError.message("Timed out waiting for another cleanup; request remains pending")
                    }
                    try await Task.sleep(for: max(.zero, min(retryDelay, ContinuousClock.now.duration(to: retryDeadline))))
                    continue
                }
                if let error = report.error { throw OrchardError.message(error) }
                let finish = try await ArtifactLease.acquire(requestLock, shared: false, timeout: lockTimeout)
                defer { finish.close() }
                try store.write(request, to: store.root.appendingPathComponent("invocation-completed.json"))
                let errorFile = store.root.appendingPathComponent("invocation-error.json")
                if FileManager.default.fileExists(atPath: errorFile.path) { try FileManager.default.removeItem(at: errorFile) }
                if try store.read(Request.self, at: pending) == request {
                    try FileManager.default.removeItem(at: pending)
                }
            }
        } catch {
            // Retain pending request on failure; a future invocation retries.
            try? store.write(["error": String(describing: error)], to: store.root.appendingPathComponent("invocation-error.json"))
        }
    }
}
