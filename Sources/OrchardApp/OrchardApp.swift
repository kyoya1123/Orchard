import OrchardCore
import SwiftUI

struct OrchardApp: App {
    @NSApplicationDelegateAdaptor(OrchardAppDelegate.self) private var delegate
    @StateObject private var model = RunnerViewModel()

    var body: some Scene {
        MenuBarExtra("Orchard", systemImage: "hammer.fill") {
            RunnerMenuView(model: model)
                .frame(width: 460, height: 620)
        }
        .menuBarExtraStyle(.window)
    }
}

@MainActor
final class OrchardAppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        BackgroundCleanup.schedule()
        return true
    }
}
