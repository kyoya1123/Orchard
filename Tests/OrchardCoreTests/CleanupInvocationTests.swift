import Foundation
@testable import OrchardCore
import XCTest

final class CleanupInvocationTests: XCTestCase, @unchecked Sendable {
    func fixture() throws -> CleanupInvocation {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("CleanupInvocation-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return CleanupInvocation(store: ArtifactStore(root: root), lockTimeout: .milliseconds(80),
            retryTimeout: .milliseconds(80), retryDelay: .milliseconds(10))
    }

    func testSuccessAcknowledgesTheCollectedRequest() async throws {
        let invocation = try fixture()
        try await invocation.enqueue()
        let request = try invocation.store.read(CleanupInvocation.Request.self, at: invocation.pending)
        await invocation.drain { CleanupReport() }
        XCTAssertFalse(FileManager.default.fileExists(atPath: invocation.pending.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: invocation.store.root.appendingPathComponent("invocation-error.json").path))
        let completed = try invocation.store.read(CleanupInvocation.Request.self,
            at: invocation.store.root.appendingPathComponent("invocation-completed.json"))
        XCTAssertEqual(completed, request)
    }

    func testFailureRetainsRequestAndNextInvocationCanRetry() async throws {
        let invocation = try fixture()
        try await invocation.enqueue()
        await invocation.drain {
            var report = CleanupReport(); report.error = "Inspection failed"; return report
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: invocation.pending.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: invocation.store.root.appendingPathComponent("invocation-completed.json").path))
        let error = try invocation.store.read([String: String].self,
            at: invocation.store.root.appendingPathComponent("invocation-error.json"))
        XCTAssertTrue(error?["error"]?.contains("Inspection failed") == true)
        await invocation.drain { CleanupReport() }
        XCTAssertFalse(FileManager.default.fileExists(atPath: invocation.pending.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: invocation.store.root.appendingPathComponent("invocation-error.json").path))
    }

    func testBusyCollectorHasDeadlineAndLeavesPendingRequest() async throws {
        let invocation = try fixture()
        try await invocation.enqueue()
        let passes = InvocationPasses()
        let start = ContinuousClock.now
        await invocation.drain {
            _ = await passes.next()
            var report = CleanupReport(); report.alreadyRunning = true; return report
        }
        XCTAssertLessThan(start.duration(to: .now), .seconds(2))
        let count = await passes.count
        XCTAssertGreaterThan(count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: invocation.pending.path))
        let worker = try XCTUnwrap(ArtifactLease.tryAcquire(invocation.workerLock))
        worker.close()
    }

    func testRequestLockCannotBlockEnqueueOrDrainIndefinitely() async throws {
        let invocation = try fixture()
        try await invocation.enqueue()
        let held = try XCTUnwrap(ArtifactLease.tryAcquire(invocation.requestLock))
        defer { held.close() }
        let start = ContinuousClock.now
        do {
            try await invocation.enqueue()
            XCTFail("Expected lock timeout")
        } catch { XCTAssertTrue(String(describing: error).contains("Timed out")) }
        await invocation.drain { XCTFail("Must not collect while the request lock is held"); return CleanupReport() }
        XCTAssertLessThan(start.duration(to: .now), .seconds(2))
        XCTAssertTrue(FileManager.default.fileExists(atPath: invocation.pending.path))
    }

    func testRequestArrivingDuringCollectionGetsAnotherPassWithoutConcurrentWorker() async throws {
        let invocation = try fixture()
        try await invocation.enqueue()
        let passes = InvocationPasses()
        await invocation.drain {
            if await passes.next() == 1 {
                do { try await invocation.enqueue() } catch { XCTFail("\(error)") }
                await invocation.drain { XCTFail("A second worker must not collect concurrently"); return CleanupReport() }
            }
            return CleanupReport()
        }
        let count = await passes.count
        XCTAssertEqual(count, 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: invocation.pending.path))
    }
}

private actor InvocationPasses {
    var count = 0
    func next() -> Int { count += 1; return count }
}
