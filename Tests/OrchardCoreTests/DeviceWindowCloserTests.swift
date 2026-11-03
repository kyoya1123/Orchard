import Foundation
@testable import OrchardCore
import XCTest

final class DeviceWindowCloserTests: XCTestCase {
    let runtime = "com.apple.CoreSimulator.SimRuntime.iOS-27-0"
    func testExactCompactWindowMatchPreservesOtherNamesAndRuntimes() throws {
        let target = DeviceWindowCloser.Window(identifier: "deviceWindow-AppWindow-1", title: "branch – iOS 27.0")
        let other = DeviceWindowCloser.Window(identifier: "deviceWindow-AppWindow-2", title: "branch-two – iOS 27.0")
        XCTAssertEqual(try DeviceWindowCloser.match([target, other], name: "branch", runtime: runtime), target)
        XCTAssertNil(try DeviceWindowCloser.match([other], name: "branch", runtime: runtime))
        XCTAssertThrowsError(try DeviceWindowCloser.match([target], name: "branch", runtime: "com.apple.CoreSimulator.SimRuntime.iOS-27-1"))
    }
    func testAmbiguousAndFullWindowsCannotBeClosed() throws {
        let title = "branch – iOS 27.0"
        XCTAssertThrowsError(try DeviceWindowCloser.match([
            .init(identifier: "deviceWindow-AppWindow-1", title: title),
            .init(identifier: "deviceWindow-AppWindow-2", title: title)], name: "branch", runtime: runtime))
        XCTAssertThrowsError(try DeviceWindowCloser.match([.init(identifier: "mainWindow-AppWindow-1", title: title)], name: "branch", runtime: runtime))
        XCTAssertThrowsError(try DeviceWindowCloser.match([.init(identifier: "deviceWindow-AppWindow-1", title: "")], name: "branch", runtime: runtime))
        XCTAssertThrowsError(try DeviceWindowCloser.match([.init(identifier: "unknown-scene", title: "Device Hub")], name: "branch", runtime: runtime))
    }
}
