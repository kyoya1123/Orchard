import OrchardCore
import XCTest

final class XcodeBuildSettingsTests: XCTestCase {
    func testFindsFirstRunnableApp() {
        let settings = XcodeBuildSettings(entries: [
            [
                "WRAPPER_NAME": "Widget.appex",
                "TARGET_BUILD_DIR": "/tmp/Products",
                "PRODUCT_BUNDLE_IDENTIFIER": "example.widget"
            ],
            [
                "WRAPPER_NAME": "App.app",
                "TARGET_BUILD_DIR": "/tmp/Products",
                "PRODUCT_BUNDLE_IDENTIFIER": "example.app"
            ]
        ])

        let app = settings.firstRunnableApp

        XCTAssertEqual(app?.appURL.path, "/tmp/Products/App.app")
        XCTAssertEqual(app?.bundleIdentifier, "example.app")
    }
}
