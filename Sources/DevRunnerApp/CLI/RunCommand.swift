import ArgumentParser
import DevRunnerCore

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

    @Option(name: .long, help: "Stop the run after this many seconds (only with --follow).")
    var timeout: Int?

    @Flag(name: .long, help: "Run attached in this terminal: stream the app's console here and block until it exits. Default delegates to the DevRunner app and returns immediately.")
    var follow = false

    @OptionGroup var directories: DirectoryOptions

    func validate() throws {
        if device && simulator {
            throw ValidationError("Pass only one of --device or --simulator.")
        }
    }

    mutating func run() async throws {
        let env = CLIEnvironment(extraDirectoryPaths: directories.dir, json: directories.json)
        let kindFilter = destinationKindFilter(device: device, simulator: simulator)

        do {
            if follow {
                // Attached: build/run here, streaming console; logs are also
                // recorded so the GUI shows them.
                try await env.performRun(
                    branch: branch,
                    scheme: scheme,
                    destination: destination,
                    kindFilter: kindFilter,
                    timeout: timeout,
                    detached: false
                )
            } else {
                // Default: hand the run to the GUI app and return immediately.
                // The GUI runs it, keeps the app alive, and shows the logs.
                let run = try await env.delegateRun(
                    branch: branch,
                    scheme: scheme,
                    destination: destination,
                    kindFilter: kindFilter
                )
                env.emitProgress("Delegated to DevRunner: \(run.worktree.branchName) · \(run.scheme) · \(run.destination.displayName)")
                env.emitResult(status: "delegated", exitCode: 0)
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
