import AppKit
import ApplicationServices
import Foundation

/// A window is a separate Device Hub document; simctl shutdown/delete does not
/// close it. Use the public Accessibility close button, never quit the app.
enum DeviceWindowCloser {
    struct Window: Equatable { let identifier: String; let title: String }

    static func title(name: String, runtime: String) throws -> String {
        let prefix = "com.apple.CoreSimulator.SimRuntime.iOS-"
        guard runtime.hasPrefix(prefix) else { throw OrchardError.message("Unknown window runtime; close the target window manually") }
        let version = runtime.dropFirst(prefix.count).replacingOccurrences(of: "-", with: ".")
        return "\(name) – iOS \(version)"
    }

    static func match(_ windows: [Window], name: String, runtime: String) throws -> Window? {
        guard !windows.contains(where: { $0.identifier.hasPrefix("mainWindow") }) else {
            throw OrchardError.message("Device Hub full window may contain multiple device tabs; close the target tab manually")
        }
        guard windows.allSatisfy({ $0.identifier.hasPrefix("deviceWindow-AppWindow-") && !$0.title.isEmpty }) else {
            throw OrchardError.message("Unreadable Device Hub window identity; device preserved")
        }
        let expected = try title(name: name, runtime: runtime)
        let targets = windows.filter { $0.title == expected }
        guard targets.count <= 1 else { throw OrchardError.message("Ambiguous Device Hub windows; no window was closed") }
        guard let target = targets.first else {
            // A same-name window with an unrecognized title must not be mistaken
            // for no window. Main inventory windows are never closed.
            guard !windows.contains(where: { $0.title == name || $0.title.hasPrefix(name + " – ") }) else {
                throw OrchardError.message("Device Hub window identity changed; close it manually")
            }
            return nil
        }
        guard target.identifier.hasPrefix("deviceWindow-AppWindow-") else {
            throw OrchardError.message("Device Hub target is not a standalone compact window; close its tab manually")
        }
        return target
    }

    @MainActor static func accessReport() -> CleanupReport.Action? {
        guard !NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dt.Devices").isEmpty else { return nil }
        return .init(target: "Device Hub windows", reason: AXIsProcessTrusted()
            ? "targeted-window-close-available"
            : "Enable Accessibility for Orchard in System Settings to close target windows before device deletion",
            outcome: AXIsProcessTrusted() ? "available" : "permission-required")
    }

    @MainActor static func close(name: String, runtime: String, uniqueDevice: Bool) async throws {
        let apps = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dt.Devices")
        let legacy = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.iphonesimulator")
        guard legacy.isEmpty else { throw OrchardError.message("Legacy Simulator window mapping is unsupported; close the target window manually") }
        guard !apps.isEmpty else { return }
        guard AXIsProcessTrusted() else { throw OrchardError.message("Window close requires Accessibility permission for Orchard; device preserved") }
        guard apps.count == 1 else { throw OrchardError.message("Multiple Device Hub instances; device preserved") }
        let app = AXUIElementCreateApplication(apps[0].processIdentifier)
        AXUIElementSetMessagingTimeout(app, 0.2)
        let deadline = ContinuousClock.now.advanced(by: .seconds(4))
        func read(_ element: AXUIElement, _ attribute: String) throws -> CFTypeRef? {
            guard ContinuousClock.now < deadline else { throw OrchardError.message("Device Hub window operation timed out") }
            AXUIElementSetMessagingTimeout(element, 0.2)
            var value: CFTypeRef?
            let status = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
            if status == .attributeUnsupported || status == .noValue { return nil }
            guard status == .success else { throw OrchardError.message("Device Hub accessibility failed (\(status.rawValue)); device preserved") }
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
        guard let target = try match(before.map(\.0), name: name, runtime: runtime),
              let element = before.first(where: { $0.0 == target })?.1 else { return }
        guard uniqueDevice else { throw OrchardError.message("Multiple devices share the target window title; device preserved") }
        if let tabs = try read(element, "AXTabs") as? [AXUIElement], tabs.count > 1 {
            throw OrchardError.message("Device Hub window has multiple tabs; close the target tab manually")
        }
        guard let value = try read(element, kAXCloseButtonAttribute), CFGetTypeID(value) == AXUIElementGetTypeID() else {
            throw OrchardError.message("Target window has no accessible close button; device preserved")
        }
        // Recheck immediately before the only UI mutation.
        guard try read(element, kAXTitleAttribute) as? String == target.title,
              try read(element, kAXIdentifierAttribute) as? String == target.identifier else {
            throw OrchardError.message("Device Hub window changed before close")
        }
        let button = unsafeBitCast(value, to: AXUIElement.self)
        AXUIElementSetMessagingTimeout(button, 0.2)
        guard AXUIElementPerformAction(button, kAXPressAction as CFString) == .success else {
            throw OrchardError.message("Target window close was not confirmed; device preserved")
        }
        while true {
            let current = try snapshot().map(\.0)
            if !current.contains(target) {
                guard try match(current, name: name, runtime: runtime) == nil else {
                    throw OrchardError.message("Device window reopened; device preserved")
                }
                return
            }
            try await Task.sleep(for: .milliseconds(50))
        }
    }
}
