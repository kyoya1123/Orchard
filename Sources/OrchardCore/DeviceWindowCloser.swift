import AppKit
import ApplicationServices
import Foundation

/// A window is a separate Device Hub document; simctl shutdown/delete does not
/// close it. Use the public Accessibility close button, never quit the app.
enum DeviceWindowCloser {
    struct Window: Equatable { let identifier: String; let title: String }

    static func title(name: String, runtime: String, deviceType: String?) throws -> String {
        let prefix = "com.apple.CoreSimulator.SimRuntime.iOS-"
        guard runtime.hasPrefix(prefix) else { throw OrchardError.message("Unknown window runtime; close the target window manually") }
        // Device-specific runtimes (iOS-27-2-iPhone19-4) are titled with the OS version only.
        let version = runtime.dropFirst(prefix.count).split(separator: "-")
            .prefix { !$0.isEmpty && $0.allSatisfy(\.isNumber) }.joined(separator: ".")
        guard !version.isEmpty else { throw OrchardError.message("Unknown window runtime; close the target window manually") }
        let typePrefix = "com.apple.CoreSimulator.SimDeviceType."
        let platform: String
        if deviceType?.hasPrefix(typePrefix + "iPad") == true {
            platform = "iPadOS"
        } else if deviceType?.hasPrefix(typePrefix + "iPhone") == true {
            platform = "iOS"
        } else {
            throw OrchardError.message("Unknown window device type; close the target window manually")
        }
        return "\(name) – \(platform) \(version)"
    }

    /// Several windows may share the title: Device Hub keeps the window of a
    /// deleted device open. When no other existing device has the title
    /// (`uniqueDevice`), each of them belongs to this device or a deleted one.
    static func match(_ windows: [Window], name: String, title expected: String, uniqueDevice: Bool) throws -> [Window] {
        guard !windows.contains(where: { $0.identifier.hasPrefix("mainWindow") }) else {
            throw OrchardError.message("Device Hub full window may contain multiple device tabs; close the target tab manually")
        }
        guard windows.allSatisfy({ $0.identifier.hasPrefix("deviceWindow-AppWindow-") && !$0.title.isEmpty }) else {
            throw OrchardError.message("Unreadable Device Hub window identity")
        }
        let targets = windows.filter { $0.title == expected }
        guard !targets.isEmpty else {
            // A same-name window with an unrecognized title must not be mistaken
            // for no window. Main inventory windows are never closed.
            guard !windows.contains(where: { $0.title == name || $0.title.hasPrefix(name + " – ") }) else {
                throw OrchardError.message("Device Hub window identity changed; close it manually")
            }
            return []
        }
        guard uniqueDevice else { throw OrchardError.message("Multiple devices share the target window title") }
        return targets
    }

    static func accessReport() -> CleanupReport.Action? {
        guard !NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dt.Devices").isEmpty else { return nil }
        let trusted = AXIsProcessTrusted()
        return .init(target: "Device Hub windows", reason: trusted
            ? "targeted-window-close-available"
            : "Allow Accessibility for the app that runs orchard to close Device Hub windows of removed devices",
            outcome: trusted ? "available" : "permission-required")
    }

    /// Device Hub ignores a minimized window when handling `devices://device/open`
    /// and opens a second one, which the closer then refuses as ambiguous.
    /// Best effort: without Accessibility permission the open URL still shows the device.
    @MainActor static func restoreMinimized(udid: String) async {
        let apps = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dt.Devices")
        guard apps.count == 1, AXIsProcessTrusted() else { return }
        struct Device: Decodable { let udid: String; let name: String; let deviceTypeIdentifier: String? }
        struct DeviceList: Decodable { let devices: [String: [Device]] }
        // Destinations carry runtime labels that differ by source, so the
        // window title is built from simctl's runtime identifier instead.
        guard let output = try? await ProcessRunner.run(executableURL: URL(fileURLWithPath: "/usr/bin/xcrun"),
                                                        arguments: ["simctl", "list", "devices", "-j"], currentDirectoryURL: nil),
              let list = try? JSONDecoder().decode(DeviceList.self, from: Data(output.utf8)),
              let (runtime, device) = list.devices.lazy.compactMap({ runtime, devices in
                  devices.first { $0.udid == udid }.map { (runtime, $0) }
              }).first,
              let title = try? title(name: device.name, runtime: runtime, deviceType: device.deviceTypeIdentifier) else { return }
        let app = AXUIElementCreateApplication(apps[0].processIdentifier)
        AXUIElementSetMessagingTimeout(app, 0.2)
        func read(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
            AXUIElementSetMessagingTimeout(element, 0.2)
            var value: CFTypeRef?
            return AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success ? value : nil
        }
        guard let windows = read(app, kAXWindowsAttribute) as? [AXUIElement] else { return }
        let minimized = windows.filter {
            (read($0, kAXIdentifierAttribute) as? String)?.hasPrefix("deviceWindow-AppWindow-") == true
                && read($0, kAXTitleAttribute) as? String == title
                && read($0, kAXMinimizedAttribute) as? Bool == true
        }
        for window in minimized {
            AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while ContinuousClock.now < deadline,
              minimized.contains(where: { read($0, kAXMinimizedAttribute) as? Bool == true }) {
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    /// While the app is hidden (Cmd-H, Hide Others), Device Hub also opens a
    /// second window instead of showing the existing one, minimized or not.
    @MainActor static func unhide() async {
        let apps = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dt.Devices")
        guard apps.count == 1, apps[0].isHidden else { return }
        apps[0].unhide()
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while ContinuousClock.now < deadline,
              NSRunningApplication(processIdentifier: apps[0].processIdentifier)?.isHidden == true {
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    @MainActor static func close(name: String, runtime: String, deviceType: String?, uniqueDevice: Bool) async throws {
        let expected = try title(name: name, runtime: runtime, deviceType: deviceType)
        let apps = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dt.Devices")
        let legacy = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.iphonesimulator")
        guard legacy.isEmpty else { throw OrchardError.message("Legacy Simulator window mapping is unsupported; close the target window manually") }
        guard !apps.isEmpty else { return }
        guard AXIsProcessTrusted() else { throw OrchardError.message("Window close requires Accessibility permission") }
        guard apps.count == 1 else { throw OrchardError.message("Multiple Device Hub instances") }
        let app = AXUIElementCreateApplication(apps[0].processIdentifier)
        AXUIElementSetMessagingTimeout(app, 0.2)
        let deadline = ContinuousClock.now.advanced(by: .seconds(4))
        func read(_ element: AXUIElement, _ attribute: String) throws -> CFTypeRef? {
            guard ContinuousClock.now < deadline else { throw OrchardError.message("Device Hub window operation timed out") }
            AXUIElementSetMessagingTimeout(element, 0.2)
            var value: CFTypeRef?
            let status = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
            if status == .attributeUnsupported || status == .noValue { return nil }
            guard status == .success else { throw OrchardError.message("Device Hub accessibility failed (\(status.rawValue))") }
            return value
        }
        func snapshot() throws -> [(Window, AXUIElement)] {
            guard let windows = try read(app, kAXWindowsAttribute) as? [AXUIElement], windows.count <= 32 else {
                throw OrchardError.message("Device Hub window inventory is unavailable or too large")
            }
            return try windows.map {
                let title = try read($0, kAXTitleAttribute) as? String ?? ""
                let identifier = try read($0, kAXIdentifierAttribute) as? String ?? ""
                return (Window(identifier: identifier, title: title), $0)
            }
        }
        let before = try snapshot()
        let targets = try match(before.map(\.0), name: name, title: expected, uniqueDevice: uniqueDevice)
        // Every target is checked before the first UI mutation.
        let closable = try targets.map { target in
            guard let element = before.first(where: { $0.0 == target })?.1 else {
                throw OrchardError.message("Device Hub window changed before close")
            }
            if let tabs = try read(element, "AXTabs") as? [AXUIElement], tabs.count > 1 {
                throw OrchardError.message("Device Hub window has multiple tabs; close the target tab manually")
            }
            guard let value = try read(element, kAXCloseButtonAttribute), CFGetTypeID(value) == AXUIElementGetTypeID() else {
                throw OrchardError.message("Target window has no accessible close button")
            }
            return (target, element, unsafeDowncast(value, to: AXUIElement.self))
        }
        guard !closable.isEmpty else { return }
        for (target, element, button) in closable {
            guard try read(element, kAXTitleAttribute) as? String == target.title,
                  try read(element, kAXIdentifierAttribute) as? String == target.identifier else {
                throw OrchardError.message("Device Hub window changed before close")
            }
            AXUIElementSetMessagingTimeout(button, 0.2)
            guard AXUIElementPerformAction(button, kAXPressAction as CFString) == .success else {
                throw OrchardError.message("Target window close was not confirmed")
            }
        }
        while true {
            let current = try snapshot().map(\.0)
            if !current.contains(where: targets.contains) {
                guard try match(current, name: name, title: expected, uniqueDevice: uniqueDevice).isEmpty else {
                    throw OrchardError.message("Device window reopened")
                }
                return
            }
            try await Task.sleep(for: .milliseconds(50))
        }
    }
}
