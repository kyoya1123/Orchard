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
    var destination: String?

    @Flag(name: .long, help: "Reuse or clone this branch's Simulator from Orchard's empty base.")
    var branchSimulator = false

    @Option(name: .long, help: "Device type for --branch-simulator (default: latest supported iPhone, preferring Pro).")
    var deviceType: String = "latest"

    @Option(name: .long, help: "Runtime for --branch-simulator (default: latest installed compatible iOS).")
    var runtime: String = "latest"

    @Flag(name: .long, help: "Only match physical devices.")
    var device = false

    @Flag(name: .long, help: "Only match simulators.")
    var simulator = false

    @Option(name: .long, help: "Stop the run after this many seconds.")
    var timeout: Int?

    @Flag(name: .long, help: "Run in a detached background process and return immediately with the run id (follow it with `orchard runs`).")
    var delegate = false

    @Option(name: .long, help: .hidden)
    var runID: String?

    @Flag(name: .long, help: "Suppress app console output on stdout (still recorded to the run store).")
    var quiet = false

    @OptionGroup var directories: DirectoryOptions

    func validate() throws {
        if device && simulator {
            throw ValidationError("Pass only one of --device or --simulator.")
        }
        if branchSimulator && (destination != nil || device) {
            throw ValidationError("--branch-simulator cannot be combined with --destination or --device.")
        }
        if !branchSimulator && destination == nil {
            throw ValidationError("Pass --destination or --branch-simulator.")
        }
        if !branchSimulator && (deviceType != "latest" || runtime != "latest") {
            throw ValidationError("--device-type and --runtime require --branch-simulator.")
        }
    }

    mutating func run() async throws {
        RunStore.shared.pruneOrphaned()
        let env = CLIEnvironment(directoryURLs: directories.directoryURLs, json: directories.json, quiet: quiet)
        let kindFilter = destinationKindFilter(device: device, simulator: simulator)
        let selection = branchSimulator ? SimulatorSelection(deviceType: deviceType, runtime: runtime) : nil

        do {
            if delegate {
                let run = try await env.delegateRun(
                    branch: branch,
                    scheme: scheme,
                    destination: destination ?? "",
                    kindFilter: kindFilter,
                    simulatorSelection: selection,
                    arguments: Array(CommandLine.arguments.dropFirst())
                )
                env.emitProgress("Delegated to Orchard: \(run.worktree.branchName) · \(run.scheme) · \(run.destination.displayName) · run \(run.id)")
                env.emitResult(status: "delegated", exitCode: 0)
            } else {
                try await env.performRun(
                    branch: branch,
                    scheme: scheme,
                    destination: destination ?? "",
                    kindFilter: kindFilter,
                    timeout: timeout,
                    simulatorSelection: selection,
                    runID: runID
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
