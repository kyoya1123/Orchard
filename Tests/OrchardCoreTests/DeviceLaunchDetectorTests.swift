import XCTest
@testable import OrchardCore

final class DeviceLaunchDetectorTests: XCTestCase {
    private let main = "file:///private/var/containers/Bundle/Application/7D1E/cir-ios.app/cir-ios"
    private let appex = "file:///private/var/containers/Bundle/Application/7D1E/cir-ios.app/PlugIns/Ext.appex/Ext"
    private let other = "file:///private/var/containers/Bundle/Application/F600/Other.app/Other"

    private func ids(appPath: String) -> [Int] {
        DeviceLaunchDetector.mainProcessIDs(
            appPath: appPath,
            processes: [(main, 1), (appex, 2), (other, 3)]
        )
    }

    func testExtractsOnlyMainExecutable() {
        XCTAssertEqual(ids(appPath: "/private/var/containers/Bundle/Application/7D1E/cir-ios.app"), [1])
    }

    func testTrailingSlashIsEquivalent() {
        XCTAssertEqual(ids(appPath: "/private/var/containers/Bundle/Application/7D1E/cir-ios.app/"), [1])
    }

    func testNoBaselineNeverLaunched() {
        XCTAssertFalse(DeviceLaunchDetector.hasNewLaunch(baseline: nil, current: [1]))
    }

    func testExistingPIDsAreNotNewLaunch() {
        XCTAssertFalse(DeviceLaunchDetector.hasNewLaunch(baseline: [1], current: [1]))
        XCTAssertFalse(DeviceLaunchDetector.hasNewLaunch(baseline: [1], current: []))
    }

    func testNewPIDIsLaunch() {
        XCTAssertTrue(DeviceLaunchDetector.hasNewLaunch(baseline: [1], current: [1, 5]))
        XCTAssertTrue(DeviceLaunchDetector.hasNewLaunch(baseline: [], current: [5]))
    }
}
