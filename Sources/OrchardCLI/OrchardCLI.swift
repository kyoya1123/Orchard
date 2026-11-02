import ArgumentParser
import Foundation
import OrchardCore

// Not a top-level `await OrchardCLI.main()` in main.swift: that resolves to the
// synchronous ParsableCommand.main(), which runs no subcommand and only prints help.
@main
struct OrchardCLI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "orchard",
        abstract: "Build and run iOS apps from a worktree/scheme/destination.",
        subcommands: [RunCommand.self, ListCommand.self, RunsCommand.self, StopCommand.self, SimulatorCommand.self,
                      CleanupCommand.self, CleanupWorker.self]
    )
}

/// Options shared by subcommands that discover worktrees.
struct DirectoryOptions: ParsableArguments {
    @Option(
        name: .long,
        parsing: .upToNextOption,
        help: "Directories to scan for worktrees. Overrides ORCHARD_DIRS, the current directory, and registered projects."
    )
    var dir: [String] = []

    @Flag(name: .long, help: "Emit machine-readable output (NDJSON for run, JSON array for list).")
    var json = false

    var directoryURLs: [URL] { Self.directoryURLs(explicit: dir) }

    /// Directory precedence: explicit `--dir` overrides everything, then the
    /// `ORCHARD_DIRS` env var (colon-separated). With neither, discovery prefers
    /// the current project, then shared manual/automatic registration.
    static func directoryURLs(explicit paths: [String]) -> [URL] {
        var paths = paths
        if paths.isEmpty, let envValue = ProcessInfo.processInfo.environment["ORCHARD_DIRS"], !envValue.isEmpty {
            paths = envValue.split(separator: ":").map(String.init)
        }
        return paths.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath, isDirectory: true) }
    }
}

/// Maps the mutually-exclusive `--device`/`--simulator` flags to a kind filter.
func destinationKindFilter(device: Bool, simulator: Bool) -> XcodeDestination.Kind? {
    if device { return .device }
    if simulator { return .simulator }
    return nil
}

private let prettyEncoder: JSONEncoder = {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes, .sortedKeys]
    return encoder
}()

func printJSON<T: Encodable>(_ value: T) {
    if let data = try? prettyEncoder.encode(value), let string = String(data: data, encoding: .utf8) {
        print(string)
    }
}
