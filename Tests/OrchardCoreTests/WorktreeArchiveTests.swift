import Foundation
import SQLite3
@testable import OrchardCore
import XCTest

final class WorktreeArchiveTests: XCTestCase, @unchecked Sendable {
    func session(_ id: String = "one", path: String = "/work", branch: String = "feature/example", archived: Bool = true, created: Double = 100) -> WorktreeArchiveState.Session {
        .init(id: id, cwd: path, branches: [branch], archived: archived, createdAt: created)
    }
    func proof(_ sessions: [WorktreeArchiveState.Session], paths: Set<String> = ["/work"]) -> WorktreeArchiveState.Evidence? {
        WorktreeArchiveState.evidence(sessions: sessions, paths: paths, name: "feature-example", boundAt: 200)
    }
    func testArchiveRequiresMatchingBranchAndEveryOwner() {
        XCTAssertNotNil(proof([session()]))
        XCTAssertNil(proof([session(archived: false)]))
        XCTAssertNil(proof([session(branch: "other")]))
        XCTAssertNil(proof([session()], paths: ["/work", "/unknown"]))
        XCTAssertNil(proof([session(), session("codex", archived: false)]))
    }
    func testPathReusedByNewTaskIsDifferentFromActiveSameBranch() {
        XCTAssertNotNil(proof([session(), session("new", branch: "other", archived: false, created: 201)]))
        XCTAssertNil(proof([session(), session("old", branch: "other", archived: false, created: 150)]))
        XCTAssertNil(proof([session(), session("new", archived: false, created: 201)]))
        XCTAssertNil(proof([session(), .init(id: "unknown", cwd: "/work", branches: [], archived: false, createdAt: 201)]))
    }
    func testNormalizedBranchCollisionIsNotProof() {
        XCTAssertNil(proof([session(), session("collision", branch: "feature-example")]))
    }
    func root() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }
    func writeSession(_ root: URL, archived: Bool) throws {
        let path = root.appendingPathComponent("Library/Application Support/Claude/claude-code-sessions/account/org/local_one.json")
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: ["sessionId": "local_one", "cwd": "/work", "branch": "old",
            "writtenBranches": ["/work\0feature/example", "/another\0wrong"], "isArchived": archived, "createdAt": 100000,
            "prompt": "must never be needed by the reader"]).write(to: path)
    }
    func testClaudeWrittenBranchAndUnarchiveRecheck() throws {
        let root = try root()
        try writeSession(root, archived: true)
        let source = WorktreeArchiveState(home: root)
        XCTAssertNotNil(proof(try source.sessions()))
        try writeSession(root, archived: false)
        XCTAssertNil(proof(try source.sessions()))
    }
    func testCodexReadOnlyArchiveAndUnsupportedSchemaFailsClosed() throws {
        let root = try root()
        let directory = root.appendingPathComponent(".codex")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appendingPathComponent("state_5.sqlite")
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(path.path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        XCTAssertEqual(sqlite3_exec(db, "CREATE TABLE threads(id TEXT,cwd TEXT,git_branch TEXT,archived INT,created_at INT); INSERT INTO threads VALUES('one','/work','feature/example',1,100);", nil, nil, nil), SQLITE_OK)
        let source = WorktreeArchiveState(home: root)
        XCTAssertNotNil(proof(try source.sessions()))
        XCTAssertEqual(sqlite3_exec(db, "UPDATE threads SET archived=0;", nil, nil, nil), SQLITE_OK)
        XCTAssertNil(proof(try source.sessions()))
        XCTAssertEqual(sqlite3_exec(db, "DROP TABLE threads;", nil, nil, nil), SQLITE_OK)
        XCTAssertThrowsError(try source.sessions())
    }
    func testMalformedMetadataDoesNotBecomeAnArchive() throws {
        let root = try root()
        try writeSession(root, archived: true)
        let path = root.appendingPathComponent("Library/Application Support/Claude/claude-code-sessions/account/org/local_one.json")
        try Data("{}".utf8).write(to: path)
        XCTAssertThrowsError(try WorktreeArchiveState(home: root).sessions())
    }
}
