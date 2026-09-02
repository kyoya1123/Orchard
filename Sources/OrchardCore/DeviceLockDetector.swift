import Foundation

public enum DeviceLockDetector {
    /// A bare "locked" is deliberately not a marker: `devicectl` output also
    /// contains words like "unlocked", so only these compound phrases and the
    /// MobileDevice error code identify a passcode-locked device.
    private static let markers = [
        "passcode protected",
        "device is locked",
        "device was locked",
        "please unlock",
        // FrontBoard (FBSOpenApplicationServiceErrorDomain) phrasing:
        // "... because the device was not, or could not be, unlocked."
        "could not be, unlocked",
        // kAMDPasswordProtectedError (0xE800001A) as a signed 32-bit value.
        "-402653158"
    ]

    public static func isDeviceLockedFailure(_ outputTail: String) -> Bool {
        guard !outputTail.isEmpty else { return false }
        let lowercased = outputTail.lowercased()
        return markers.contains { lowercased.contains($0) }
    }
}
