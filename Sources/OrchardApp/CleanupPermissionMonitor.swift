import AppKit
import OrchardCore

/// Lives with the GUI model, even while the menu is closed. No timers or prompts.
@MainActor
final class CleanupPermissionMonitor {
    let guidance: CleanupPermissionGuidance
    private var watcher: RunStoreWatcher?
    private var refreshTask: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []
    private var workspaceObservers: [NSObjectProtocol] = []

    init() {
        let key = "cleanupAccessibilityGuidanceDismissed"
        guidance = CleanupPermissionGuidance(dismissed: UserDefaults.standard.bool(forKey: key),
            saveDismissal: { UserDefaults.standard.set($0, forKey: key) })
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification,
            object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.refresh() }
            })
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            workspaceObservers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: name,
                object: nil, queue: .main) { [weak self] notification in
                    guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                          app.bundleIdentifier == "com.apple.dt.Devices" else { return }
                    Task { @MainActor in self?.refresh() }
                })
        }
        watcher = RunStoreWatcher(directory: CleanupPermissionGuidance.reportDirectory) { [weak self] in
            Task { @MainActor in self?.refresh() }
        }
        watcher?.start()
        refresh()
    }

    func refresh() {
        // Read AX synchronously on activation so a late file read cannot miss a
        // permission transition; the report itself is loaded off the main actor.
        let running = !NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dt.Devices").isEmpty
        guidance.refresh(needsAccess: running || guidance.needsAccess)
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            let reported = await CleanupPermissionGuidance.reportNeedsAccess()
            guard !Task.isCancelled, let self else { return }
            guidance.refresh(needsAccess: running || reported)
        }
    }

    isolated deinit {
        refreshTask?.cancel()
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        for observer in workspaceObservers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
    }
}
