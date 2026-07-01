import OrchardCore
import SwiftUI

struct OrchardApp: App {
    @StateObject private var model = RunnerViewModel()

    var body: some Scene {
        MenuBarExtra("Orchard", systemImage: "hammer.fill") {
            RunnerMenuView(model: model)
                .frame(width: 460, height: 620)
        }
        .menuBarExtraStyle(.window)
    }
}
