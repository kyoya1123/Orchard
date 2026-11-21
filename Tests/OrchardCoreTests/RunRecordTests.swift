import OrchardCore
import XCTest

final class RunRecordTests: XCTestCase {
    private let legacyJSON = """
    {
      "id": "A1",
      "source": "cli",
      "branchName": "main",
      "worktreeDisplayName": "main",
      "projectRootPath": "/tmp/p",
      "projectFilePath": "/tmp/p/P.xcodeproj",
      "projectKind": "project",
      "scheme": "App",
      "destination": {"id": "U", "name": "iPhone", "runtime": "iOS 27", "kind": "simulator", "modelCode": "iPhone1,1"},
      "startedAt": 1,
      "updatedAt": 2,
      "status": "running",
      "activityText": "",
      "log": ""
    }
    """

    func testDecodesLegacyRecordWithoutNewFields() throws {
        let record = try JSONDecoder().decode(RunRecord.self, from: Data(legacyJSON.utf8))
        XCTAssertNil(record.pid)
        XCTAssertNil(record.launchedAt)
        XCTAssertNil(record.exitCode)
        XCTAssertNil(record.errorMessage)
        XCTAssertFalse(record.isLaunched)
    }

    func testRoundTripPreservesNewFields() throws {
        var record = try JSONDecoder().decode(RunRecord.self, from: Data(legacyJSON.utf8))
        record.pid = 42
        record.launchedAt = 100.5
        record.exitCode = 4
        record.errorMessage = "boom"

        let decoded = try JSONDecoder().decode(RunRecord.self, from: JSONEncoder().encode(record))
        XCTAssertEqual(decoded.pid, 42)
        XCTAssertEqual(decoded.launchedAt, 100.5)
        XCTAssertEqual(decoded.exitCode, 4)
        XCTAssertEqual(decoded.errorMessage, "boom")
        XCTAssertTrue(decoded.isLaunched)
    }
}
