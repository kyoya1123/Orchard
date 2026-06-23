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

    @Option(name: .long, help: "Stop the run after this many seconds.")
    var timeout: Int?

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
            try await env.performRun(
                branch: branch,
                scheme: scheme,
                destination: destination,
                kindFilter: kindFilter,
                timeout: timeout
            )
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
