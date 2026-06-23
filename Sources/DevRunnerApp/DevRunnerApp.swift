import DevRunnerCore
import SwiftUI

struct DevRunnerApp: App {
    @StateObject private var model = RunnerViewModel()

    var body: some Scene {
        MenuBarExtra("DevRunner", systemImage: "hammer.fill") {
            RunnerMenuView(model: model)
                .frame(width: 460, height: 620)
        }
        .menuBarExtraStyle(.window)
    }
}
