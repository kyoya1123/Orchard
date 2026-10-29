import XCTest
@testable import OrchardCore

@MainActor
final class CleanupPermissionGuidanceTests: XCTestCase {
    @MainActor private final class Environment {
        var trusted = false
        var opensSettings = true
        var prompts = 0
        var settings = 0
        var retries = 0
        var dismissed = false
        func model() -> CleanupPermissionGuidance {
            CleanupPermissionGuidance(dismissed: dismissed, check: { self.trusted },
                prompt: { self.prompts += 1 }, openSettings: { self.settings += 1; return self.opensSettings },
                retryCleanup: { self.retries += 1 }, saveDismissal: { self.dismissed = $0 })
        }
    }

    func testRepeatedRefreshAndDismissalNeverPromptButSettingsCanRetry() {
        let environment = Environment()
        let model = environment.model()
        model.refresh(needsAccess: false)
        XCTAssertFalse(model.showsBanner)
        model.refresh(needsAccess: true)
        XCTAssertTrue(model.showsBanner)
        model.dismiss()
        for _ in 0..<5 { model.refresh(needsAccess: true) }
        let relaunched = environment.model()
        relaunched.refresh(needsAccess: true)
        XCTAssertFalse(relaunched.showsBanner)
        XCTAssertEqual(environment.prompts, 0)
        XCTAssertEqual(environment.settings, 0)
        relaunched.requestAccess() // Explicit Settings button remains available.
        XCTAssertTrue(relaunched.showsBanner)
        XCTAssertTrue(relaunched.requestedPrompt)
        relaunched.requestAccess()
        XCTAssertEqual(environment.prompts, 1)
        XCTAssertEqual(environment.settings, 2)
        XCTAssertEqual(environment.retries, 0)
    }

    func testReturnFromSettingsWithoutGrantRemainsActionableAndGrantRetriesOnce() {
        let environment = Environment()
        let model = environment.model()
        model.refresh(needsAccess: true)
        model.requestAccess()
        model.refresh(needsAccess: true) // Returned after dismissing the system prompt.
        XCTAssertFalse(model.isTrusted)
        XCTAssertTrue(model.showsBanner)
        XCTAssertEqual(environment.retries, 0)
        environment.trusted = true
        model.refresh(needsAccess: true)
        model.refresh(needsAccess: true) // A stale permission-required report cannot override AX.
        model.checkAgain()
        XCTAssertTrue(model.isTrusted)
        XCTAssertTrue(model.retriedCleanup)
        XCTAssertTrue(model.showsBanner) // Success is visible until dismissed.
        XCTAssertEqual(environment.retries, 1)
        XCTAssertEqual(environment.prompts, 1)
        model.requestAccess()
        XCTAssertEqual(environment.settings, 1)
        model.dismiss()
        XCTAssertFalse(model.showsBanner)
    }

    func testSettingsFailureRemainsRetryableWithoutRepeatedSystemAlerts() {
        let environment = Environment()
        environment.opensSettings = false
        let model = environment.model()
        model.refresh(needsAccess: true)
        model.requestAccess()
        XCTAssertTrue(model.settingsOpenFailed)
        XCTAssertFalse(model.isTrusted)
        environment.opensSettings = true
        model.requestAccess()
        XCTAssertFalse(model.settingsOpenFailed)
        XCTAssertEqual(environment.prompts, 1)
        XCTAssertEqual(environment.retries, 0)
    }

    func testAlreadyTrustedStartupDoesNotRetryAndRevocationOffersGuidance() {
        let environment = Environment()
        environment.trusted = true
        let model = environment.model()
        model.refresh(needsAccess: true)
        XCTAssertFalse(model.showsBanner)
        XCTAssertEqual(environment.retries, 0)
        model.dismiss()
        environment.trusted = false
        model.refresh(needsAccess: true)
        XCTAssertTrue(model.showsBanner)
        XCTAssertFalse(environment.dismissed)
        XCTAssertEqual(environment.prompts, 0)
        XCTAssertEqual(environment.settings, 0)
    }
}
