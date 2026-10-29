import AppKit
// The SDK exposes its immutable prompt key as a legacy C global variable.
@preconcurrency import ApplicationServices
import Foundation
import Observation

/// GUI-owned guidance. Reading state never requests permission; only an explicit
/// button action may ask macOS to show its Accessibility permission explanation.
@MainActor @Observable
public final class CleanupPermissionGuidance {
    public private(set) var isTrusted = false
    public private(set) var hasChecked = false
    public private(set) var needsAccess = false
    public private(set) var isDismissed: Bool
    public private(set) var requestedPrompt = false
    public private(set) var settingsOpenFailed = false
    public private(set) var retriedCleanup = false
    @ObservationIgnored private let check: () -> Bool
    @ObservationIgnored private let prompt: () -> Void
    @ObservationIgnored private let openSettings: () -> Bool
    @ObservationIgnored private let retryCleanup: () -> Void
    @ObservationIgnored private let saveDismissal: (Bool) -> Void
    @ObservationIgnored private let didCheck: (Bool, Bool) -> Void

    public convenience init(dismissed: Bool = false, saveDismissal: @escaping (Bool) -> Void = { _ in }) {
        self.init(dismissed: dismissed, check: { AXIsProcessTrusted() }, prompt: {
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
        }, openSettings: {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
        }, retryCleanup: { BackgroundCleanup.schedule() }, saveDismissal: saveDismissal,
           didCheck: { GUIAccessibilityStatus.record(trusted: $0, showsRequirement: $1) })
    }

    init(dismissed: Bool = false, check: @escaping () -> Bool, prompt: @escaping () -> Void,
         openSettings: @escaping () -> Bool, retryCleanup: @escaping () -> Void,
         saveDismissal: @escaping (Bool) -> Void = { _ in },
         didCheck: @escaping (Bool, Bool) -> Void = { _, _ in }) {
        self.isDismissed = dismissed
        self.check = check; self.prompt = prompt; self.openSettings = openSettings
        self.retryCleanup = retryCleanup; self.saveDismissal = saveDismissal
        self.didCheck = didCheck
    }

    public var showsBanner: Bool {
        hasChecked && !isTrusted && needsAccess && !isDismissed
    }

    /// Called on activation, menu opening and cleanup-report changes. No prompt.
    public func refresh(needsAccess: Bool) {
        let previouslyTrusted = isTrusted
        let previouslyNeeded = self.needsAccess
        let checkedBefore = hasChecked
        isTrusted = check()
        hasChecked = true
        self.needsAccess = needsAccess
        if checkedBefore && previouslyTrusted && !isTrusted {
            setDismissed(false)
            requestedPrompt = false
            retriedCleanup = false
        }
        if checkedBefore && !previouslyTrusted && isTrusted && (needsAccess || previouslyNeeded || requestedPrompt) {
            settingsOpenFailed = false
            retriedCleanup = true
            setDismissed(false)
            retryCleanup()
        }
        didCheck(isTrusted, showsBanner)
    }

    public func checkAgain() { refresh(needsAccess: needsAccess) }

    public func requestAccess() {
        checkAgain()
        guard !isTrusted else { return }
        setDismissed(false)
        // Explicit retries still open Settings, but do not stack system alerts.
        if !requestedPrompt {
            requestedPrompt = true
            prompt()
        }
        checkAgain() // The system prompt is asynchronous; normally still false.
        if !isTrusted { settingsOpenFailed = !openSettings() }
    }

    public func dismiss() {
        setDismissed(true)
        didCheck(isTrusted, showsBanner)
    }
    private func setDismissed(_ value: Bool) { isDismissed = value; saveDismissal(value) }

    public nonisolated static var reportDirectory: URL { ArtifactStore().root }

    public nonisolated static func reportNeedsAccess() async -> Bool {
        await Task.detached(priority: .utility) {
            let store = ArtifactStore()
            let report = try? store.read(CleanupReport.self, at: store.root.appendingPathComponent("last-report.json"))
            // A CLI may be trusted while this GUI isn't. Check this process's
            // permission rather than copying the CLI's 'available' outcome.
            return report?.actions.contains { $0.target == "Device Hub windows" } ?? false
        }.value
    }
}
