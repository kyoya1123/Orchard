import Foundation
@testable import OrchardCore
import XCTest

final class SimulatorProcessTests: XCTestCase, @unchecked Sendable {
    func testTimeoutCompletesEvenWhenOwnChildIgnoresTermination() async throws {
        let start = ContinuousClock.now
        do {
            _ = try await SimulatorProcess.execute(executable: "/bin/sh",
                arguments: ["-c", "trap '' TERM; while :; do :; done"], timeout: 0.2,
                terminationGrace: .milliseconds(100))
            XCTFail("Expected timeout")
        } catch { XCTAssertTrue(String(describing: error).contains("timed out")) }
        XCTAssertLessThan(start.duration(to: .now), .seconds(3))
    }

    func testCancellationCompletesEvenWhenOwnChildIgnoresTermination() async throws {
        let task = Task {
            try await SimulatorProcess.execute(executable: "/bin/sh",
                arguments: ["-c", "trap '' TERM; while :; do :; done"], timeout: 30,
                terminationGrace: .milliseconds(100))
        }
        try await Task.sleep(for: .milliseconds(200))
        let start = ContinuousClock.now
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertLessThan(start.duration(to: .now), .seconds(3))
    }

    func testNormalOutputAndFailedExitAreReported() async throws {
        let output = try await SimulatorProcess.execute(executable: "/bin/echo", arguments: ["ready"], timeout: 2)
        XCTAssertEqual(output, "ready")
        do {
            _ = try await SimulatorProcess.execute(executable: "/bin/sh", arguments: ["-c", "echo failed >&2; exit 3"], timeout: 2)
            XCTFail("Expected failure")
        } catch { XCTAssertTrue(String(describing: error).contains("failed")) }
    }
}
