import Foundation
@testable import OrchardCore
import XCTest

final class DeviceWindowCloserTests: XCTestCase {
    let runtime = "com.apple.CoreSimulator.SimRuntime.iOS-27-0"
    let iPhone = "com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro"
    let iPad = "com.apple.CoreSimulator.SimDeviceType.iPad-Pro-11-inch-M5-12GB"

    func testTitleUsesDevicePlatformAndOSVersion() throws {
        XCTAssertEqual(try DeviceWindowCloser.title(name: "branch", runtime: runtime, deviceType: iPhone), "branch – iOS 27.0")
        XCTAssertEqual(try DeviceWindowCloser.title(name: "branch", runtime: runtime, deviceType: iPad), "branch – iPadOS 27.0")
        XCTAssertEqual(try DeviceWindowCloser.title(name: "branch", runtime: "com.apple.CoreSimulator.SimRuntime.iOS-27-2-iPhone19-4",
                                                    deviceType: "com.apple.CoreSimulator.SimDeviceType.iPhone-Duo"), "branch – iOS 27.2")
        XCTAssertThrowsError(try DeviceWindowCloser.title(name: "branch", runtime: runtime, deviceType: nil))
        XCTAssertThrowsError(try DeviceWindowCloser.title(name: "branch", runtime: "com.apple.CoreSimulator.SimRuntime.watchOS-12-0", deviceType: iPhone))
    }

    func testExactCompactWindowMatchPreservesOtherNamesAndPlatforms() throws {
        let title = try DeviceWindowCloser.title(name: "branch", runtime: runtime, deviceType: iPhone)
        let target = DeviceWindowCloser.Window(identifier: "deviceWindow-AppWindow-1", title: "branch – iOS 27.0")
        let other = DeviceWindowCloser.Window(identifier: "deviceWindow-AppWindow-2", title: "branch-two – iOS 27.0")
        let iPadWindow = DeviceWindowCloser.Window(identifier: "deviceWindow-AppWindow-3", title: "branch – iPadOS 27.0")
        XCTAssertEqual(try DeviceWindowCloser.match([target, other, iPadWindow], name: "branch", title: title, uniqueDevice: true), [target])
        XCTAssertEqual(try DeviceWindowCloser.match([other], name: "branch", title: title, uniqueDevice: true), [])
        XCTAssertThrowsError(try DeviceWindowCloser.match([target], name: "branch", title: "branch – iOS 27.1", uniqueDevice: true))
    }

    func testSameTitledWindowsCloseOnlyWhenNoOtherDeviceHasTheTitle() throws {
        let title = "branch – iOS 27.0"
        let windows: [DeviceWindowCloser.Window] = [
            .init(identifier: "deviceWindow-AppWindow-1", title: title),
            .init(identifier: "deviceWindow-AppWindow-2", title: title)]
        XCTAssertEqual(try DeviceWindowCloser.match(windows, name: "branch", title: title, uniqueDevice: true), windows)
        XCTAssertThrowsError(try DeviceWindowCloser.match(windows, name: "branch", title: title, uniqueDevice: false))
        XCTAssertThrowsError(try DeviceWindowCloser.match([windows[0]], name: "branch", title: title, uniqueDevice: false))
    }

    func testFullAndUnreadableWindowsCannotBeClosed() throws {
        let title = "branch – iOS 27.0"
        XCTAssertThrowsError(try DeviceWindowCloser.match([.init(identifier: "mainWindow-AppWindow-1", title: title)], name: "branch", title: title, uniqueDevice: true))
        XCTAssertThrowsError(try DeviceWindowCloser.match([.init(identifier: "deviceWindow-AppWindow-1", title: "")], name: "branch", title: title, uniqueDevice: true))
        XCTAssertThrowsError(try DeviceWindowCloser.match([.init(identifier: "unknown-scene", title: "Device Hub")], name: "branch", title: title, uniqueDevice: true))
    }

    func testDeletedDeviceMatchesEveryPlatformOfItsNameOnly() throws {
        let iOS = DeviceWindowCloser.Window(identifier: "deviceWindow-AppWindow-1", title: "branch – iOS 27.2")
        let iPadOS = DeviceWindowCloser.Window(identifier: "deviceWindow-AppWindow-2", title: "branch – iPadOS 27.2")
        let other = DeviceWindowCloser.Window(identifier: "deviceWindow-AppWindow-3", title: "branch-two – iOS 27.2")
        XCTAssertEqual(try DeviceWindowCloser.matchDeleted([iOS, iPadOS, other], name: "branch"), [iOS, iPadOS])
        XCTAssertEqual(try DeviceWindowCloser.matchDeleted([other], name: "branch"), [])
        XCTAssertThrowsError(try DeviceWindowCloser.matchDeleted([.init(identifier: "deviceWindow-AppWindow-4", title: "branch")], name: "branch"))
        XCTAssertThrowsError(try DeviceWindowCloser.matchDeleted([iOS, .init(identifier: "mainWindow-AppWindow-1", title: "Devices")], name: "branch"))
    }
}
