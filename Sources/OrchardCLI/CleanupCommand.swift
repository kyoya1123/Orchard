import ArgumentParser
import Darwin
import Foundation
import OrchardCore

struct CleanupCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "cleanup",
        abstract: "Inspect unused worktree devices and DerivedData. Pass --apply to remove them.")
    @Flag(name: .long, help: "Apply the inspected cleanup policy. Device deletion permanently removes its apps and data.")
    var apply = false
    @Option(name: .long, help: "all, devices (Simulators and marked AVDs), simulators, emulators, derived-data, or source-packages. Defaults to all.")
    var scope = "all"
    @Flag(name: .long, help: "Use existing ownership records without discovering additional projects.")
    var noDiscover = false
    @OptionGroup var directories: DirectoryOptions

    mutating func run() async throws {
        let paths = directories.directoryURLs
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
    @Flag(name: .long) var devicesOnly = false

    mutating func run() async throws {
        signal(SIGHUP, SIG_IGN)
        _ = setsid()
        _ = setpriority(PRIO_PROCESS, 0, 20)
        // Task QoS keeps our filesystem work in the background. A process-wide
        // I/O throttle would also trap utility-QoS simctl/ADB/avdmanager children
        // and make their bounded IPC/deletion commands time out.
        let paths = DirectoryOptions.directoryURLs(explicit: [])
        let devicesOnly = devicesOnly
        _ = await Task.detached(priority: .background) {
            if devicesOnly {
                await CleanupInvocation().drain(directories: paths)
            } else {
                _ = await ArtifactCleanup().run(apply: true, directories: paths)
            }
        }.value
    }
}
