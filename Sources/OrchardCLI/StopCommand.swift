import ArgumentParser
import OrchardCore
import Foundation

struct StopCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "stop",
        abstract: "Stop a running run and terminate the app it launched."
    )

    @Argument(help: "Run id (or unique prefix), as printed by `run --delegate` or `runs`.")
    var id: String

    func run() async throws {
        RunStore.shared.finishAbandoned()
        let matches = RunStore.shared.loadAll().filter { $0.id == id || $0.id.hasPrefix(id) }
        guard matches.count == 1, let record = matches.first else {
            FileHandle.standardError.write(Data((matches.isEmpty ? "No run matches \"\(id)\".\n" : "\"\(id)\" matches several runs.\n").utf8))
            throw ExitCode(matches.isEmpty ? 2 : 3)
        }
        guard record.status == .running, let pid = record.pid else {
            print("\(record.id) is already \(record.status.rawValue).")
            return
        }
        // The owner handles SIGTERM by tearing down the launched app and
        // recording `stopped`, which can take a while for a device app.
        kill(pid, SIGTERM)
        guard await CLIEnvironment.waitForExit(pid: pid, timeout: 60, interval: .milliseconds(200)) else {
            FileHandle.standardError.write(Data("Run \(record.id) (pid \(pid)) did not exit within 60s.\n".utf8))
            throw ExitCode(1)
        }
        print("Stopped \(record.id).")
    }
}
