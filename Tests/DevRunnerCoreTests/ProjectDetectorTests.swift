import DevRunnerCore
import XCTest

final class ProjectDetectorTests: XCTestCase {
    func testDetectsWorkspaceWalkingUpFromNestedDirectory() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let nested = root.appendingPathComponent("Sources/App", isDirectory: true)
        let workspace = root.appendingPathComponent("App.xcworkspace", isDirectory: true)

        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let project = try ProjectDetector().detect(from: nested)

        XCTAssertEqual(project.fileURL.lastPathComponent, "App.xcworkspace")
        XCTAssertEqual(project.kind, .workspace)
    }

    func testWorkspaceWinsOverProject() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let workspace = root.appendingPathComponent("App.xcworkspace", isDirectory: true)
        let xcodeproj = root.appendingPathComponent("App.xcodeproj", isDirectory: true)

        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: xcodeproj, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let project = try ProjectDetector().detect(from: root)

        XCTAssertEqual(project.kind, .workspace)
    }
}
