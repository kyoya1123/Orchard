import ArgumentParser
import OrchardCore

struct RunCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "run",
        abstract: "Build and run a branch with a scheme on a destination."
    )

    @Option(name: [.short, .long], help: "Branch / worktree name (fuzzy matched).")
    var branch: String

    @Option(name: [.short, .long], help: "Scheme name, e.g. ProdDebug (fuzzy matched).")
    var scheme: String

    @Option(name: [.short, .long], help: "Destination name or UDID, e.g. \"iPhone 15\" (fuzzy matched).")
    var destination: String

    @Flag(name: .long, help: "Only match physical devices.")
    var device = false

    @Flag(name: .long, help: "Only match simulators.")
    var simulator = false

    @Option(name: .long, help: "Stop the run after this many seconds.")
    var timeout: Int?

    @Flag(name: .long, help: "Hand the run to the Orchard app instead of running it here (returns immediately; the GUI builds/launches and shows the logs).")
    var delegate = false

    @Flag(name: .long, help: "Suppress app console output on stdout (still recorded to the run store).")
    var quiet = false

    @OptionGroup var directories: DirectoryOptions

    func validate() throws {
        if device && simulator {
            throw ValidationError("Pass only one of --device or --simulator.")
        }
    }

    mutating func run() async throws {
        RunStore.shared.pruneOrphaned()
        let env = CLIEnvironment(extraDirectoryPaths: directories.dir, json: directories.json, quiet: quiet)
        let kindFilter = destinationKindFilter(device: device, simulator: simulator)

        do {
            if delegate {
                // Opt-in: hand the run to the GUI app and return immediately.
                let run = try await env.delegateRun(
                    branch: branch,
                    scheme: scheme,
                    destination: destination,
                    kindFilter: kindFilter
                )
                env.emitProgress("Delegated to Orchard: \(run.worktree.branchName) · \(run.scheme) · \(run.destination.displayName) · run \(run.id)")
                env.emitResult(status: "delegated", exitCode: 0)
            } else {
                // Default: build/run attached here, streaming console. Logs are
                // recorded to the shared store, so the Orchard app shows this run
                // and can view its logs, rerun, or stop it. Meant to be launched
                // as a background task.
                try await env.performRun(
                    branch: branch,
                    scheme: scheme,
                    destination: destination,
                    kindFilter: kindFilter,
                    timeout: timeout,
                    detached: false
                )
            }
        } catch let error as SelectionError {
            env.emitError("\(error)")
            switch error {
            case .notFound:
                throw ExitCode(2)
            case .ambiguous:
                throw ExitCode(3)
            }
        } catch is InterruptedError {
            env.emitResult(status: "stopped", exitCode: 130)
            throw ExitCode(130)
        } catch let error as BuildFailure {
            env.emitError(error.message)
            env.emitResult(status: "failed", exitCode: 4)
            throw ExitCode(4)
        }
    }
}
