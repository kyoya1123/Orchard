import ArgumentParser
import Darwin
import Foundation
import OrchardCore

struct CleanupCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "cleanup",
        abstract: "Inspect unused worktree Simulators and DerivedData. Pass --apply to remove them.")
    @Flag(name: .long, help: "Apply the inspected cleanup policy. Simulator deletion permanently removes its apps and data.")
    var apply = false
    @Option(name: .long, help: "all, archived-devices (iOS and Android), simulators, derived-data, or source-packages. Defaults to all.")
    var scope = "all"
    @Flag(name: .long, help: "Use existing ownership records without discovering additional projects.")
    var noDiscover = false
    @OptionGroup var directories: DirectoryOptions

    mutating func run() async throws {
        let paths = CLIEnvironment(extraDirectoryPaths: directories.dir, json: directories.json).directoryURLs
        guard let selectedScope = ArtifactCleanup.Scope(rawValue: scope) else {
            throw ValidationError("Unknown cleanup scope: \(scope)")
        }
        let shouldApply = apply
        let shouldDiscover = !noDiscover
        let report = await Task.detached(priority: .background) {
            await ArtifactCleanup().run(apply: shouldApply, directories: paths, discover: shouldDiscover, scope: selectedScope)
        }.value
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        print(String(decoding: try encoder.encode(report), as: UTF8.self))
        if report.error != nil { throw ExitCode.failure }
    }
}

struct CleanupWorker: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "cleanup-worker", shouldDisplay: false)

    mutating func run() async throws {
        signal(SIGHUP, SIG_IGN)
        _ = setsid()
        _ = setpriority(PRIO_PROCESS, 0, 20)
        _ = setiopolicy_np(IOPOL_TYPE_DISK, IOPOL_SCOPE_PROCESS, IOPOL_THROTTLE)
        let paths = CLIEnvironment(extraDirectoryPaths: [], json: false).directoryURLs
        _ = await Task.detached(priority: .background) {
            await CleanupInvocation().drain(directories: paths)
        }.value
    }
}
