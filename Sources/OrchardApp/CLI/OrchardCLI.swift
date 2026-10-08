import ArgumentParser
import OrchardCore

/// Root of the headless CLI. Mirrors what the menu bar UI does — pick a branch
/// (worktree), a scheme, and a destination, then build/install/launch — so an
/// agent can drive a run from the terminal.
@available(macOS 10.15, *)
struct OrchardCLI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "orchard",
        abstract: "Build and run iOS apps from a worktree/scheme/destination, the same flow as the Orchard menu bar app.",
        subcommands: [RunCommand.self, ListCommand.self, RunsCommand.self, SimulatorCommand.self, CleanupCommand.self, CleanupWorker.self]
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
}

/// Maps the mutually-exclusive `--device`/`--simulator` flags to a kind filter.
func destinationKindFilter(device: Bool, simulator: Bool) -> XcodeDestination.Kind? {
    if device { return .device }
    if simulator { return .simulator }
    return nil
}

/// Parses and runs the CLI. We dispatch `run()` on the *concrete* subcommand
/// types: calling `run()` on an `any AsyncParsableCommand` existential outside
/// ArgumentParser's own module resolves to the synchronous default (which just
/// prints help), whereas the concrete types resolve to their async `run()`.
/// Built-in commands (help/version) fall through to the synchronous default.
func runOrchardCLI(_ arguments: [String]) async {
    do {
        let parsed = try OrchardCLI.parseAsRoot(arguments)
        switch parsed {
        case var command as RunCommand:
            try await command.run()
        case var command as ListBranches:
            try await command.run()
        case var command as ListSchemes:
            try await command.run()
        case var command as ListDestinations:
            try await command.run()
        case var command as RunsCommand:
            try await command.run()
        case var command as SimulatorEnsure:
            try await command.run()
        case var command as SimulatorBase:
            try await command.run()
        case var command as CleanupCommand:
            try await command.run()
        case var command as CleanupWorker:
            try await command.run()
        default:
            var command = parsed
            try command.run()
        }
    } catch {
        OrchardCLI.exit(withError: error)
    }
}
