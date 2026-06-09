import DevRunnerCore
import SwiftUI

@main
struct DevRunnerApp: App {
    @StateObject private var model = RunnerViewModel()

    var body: some Scene {
        MenuBarExtra("DevRunner", systemImage: model.isRunning ? "stop.circle.fill" : "play.circle") {
            RunnerMenuView(model: model)
                .frame(width: 460, height: 620)
        }
        .menuBarExtraStyle(.window)
    }
}
