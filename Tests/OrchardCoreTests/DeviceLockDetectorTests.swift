import OrchardCore
import XCTest

final class DeviceLockDetectorTests: XCTestCase {
    func testDetectsPasscodeProtectedError() {
        let output = "ERROR: The specified device is passcode protected. (com.apple.dt.CoreDeviceError error 12345.)"
        XCTAssertTrue(DeviceLockDetector.isDeviceLockedFailure(output))
    }

    func testDetectsDeviceIsLockedError() {
        let output = """
        ERROR: Failed to install the app on the device.
        The device is locked.
        """
        XCTAssertTrue(DeviceLockDetector.isDeviceLockedFailure(output))
    }

    func testDetectsMobileDeviceErrorCode() {
        let output = "Underlying error: com.apple.mobiledevice error -402653158."
        XCTAssertTrue(DeviceLockDetector.isDeviceLockedFailure(output))
    }

    func testDetectsPleaseUnlockError() {
        let output = "Please unlock your device and reattach. (com.apple.dt.CoreDeviceError error 3002.)"
        XCTAssertTrue(DeviceLockDetector.isDeviceLockedFailure(output))
    }

    func testDetectsFrontBoardNotUnlockedError() {
        let output = """
        ERROR: Unable to launch com.example.app because the device was not, or could not be, unlocked. \
        (FBSOpenApplicationServiceErrorDomain error 7.)
        """
        XCTAssertTrue(DeviceLockDetector.isDeviceLockedFailure(output))
    }

    func testIgnoresPlainExitCodeFailure() {
        XCTAssertFalse(DeviceLockDetector.isDeviceLockedFailure("Command failed with exit code 70."))
    }

    func testIgnoresUnlockedMention() {
        XCTAssertFalse(DeviceLockDetector.isDeviceLockedFailure("The device was successfully unlocked."))
    }

    func testIgnoresEmptyOutput() {
        XCTAssertFalse(DeviceLockDetector.isDeviceLockedFailure(""))
    }
}
