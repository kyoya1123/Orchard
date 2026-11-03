import ArgumentParser
import OrchardCore
import Foundation

/// Thrown when the user interrupts a run with Ctrl-C. Surfaced as exit code 130.
struct InterruptedError: Error {}

/// Thrown when build / install / launch fails. Surfaced as exit code 4.
struct BuildFailure: Error, CustomStringConvertible {
    let message: String
    var description: String { message }
}

/// Shared machinery for the `run` and `list` subcommands: fetches
/// worktrees/schemes/destinations via the same `OrchardCore` services, wires
/// build logs to stdout/stderr, and manages clean Ctrl-C teardown.
final class CLIEnvironment: @unchecked Sendable {
    let directoryURLs: [URL]
    let json: Bool
    let quiet: Bool

    private let xcodeService = XcodeService()
    private let outputLock = NSLock()

    /// Ordered by precedence when several arrive: an intentional stop wins, so
    /// the run ends cleanly (exit 0) instead of looking like a crash to a background task.
    private enum StopReason: Int, Comparable {
        case timedOut, interrupted, externallyStopped
        static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    // Guards `stopReason` and `launchedEmitted`, which are touched from the
    // signal/timeout queues and the console callback (arbitrary thread) as well
    // as the main run task.
    private let stateLock = NSLock()
    private var stopReason: StopReason?
    // Set once the first console chunk arrives, so `emitConsole` can announce
    // "Launched" exactly once for callers polling progress instead of stdout.
    private var launchedEmitted = false
    private var signalSources: [DispatchSourceSignal] = []

    // Run record read by `orchard runs` / `orchard stop`. Guarded by recordLock since
    // it is mutated from build callbacks running on arbitrary threads.
    private let recordLock = NSLock()
    private var record: RunRecord?
    private var lastPersist: Date?

    init(directoryURLs: [URL], json: Bool, quiet: Bool = false) {
        self.directoryURLs = directoryURLs
        self.json = json
        self.quiet = quiet
    }

    // MARK: - Fetching

    func worktrees() async -> [WorktreeContext] {
        await ProjectDiscovery().resolve(explicitDirectories: directoryURLs,
            currentDirectory: URL(fileURLWithPath: FileManager.default.currentDirectoryPath),
            configuredDirectories: AppConfiguration.configuredDirectoryPaths().map { URL(fileURLWithPath: $0) })
    }

    func schemes(for project: XcodeProject) async throws -> [String] {
        // Register before any xcodebuild call, including failed scheme/build
        // attempts. Both `run` and `list schemes` use this path.
        await Self.register(project: project)
        return try await xcodeService.schemes(project: project)
    }

    static func register(project: XcodeProject) async {
        do { try await RepositoryRegistry().register(project: project) }
        catch {
            FileHandle.standardError.write(Data("Could not add project to Orchard: \(error.localizedDescription)\n".utf8))
        }
    }

    // MARK: - Resolution

    /// Resolves the typed names to concrete worktree/scheme/destination.
    /// Throws SelectionError (not found / ambiguous) or BuildFailure (lookup).
    func resolveRun(
        branch: String,
        scheme: String,
        destination: String,
        kindFilter: XcodeDestination.Kind?,
        simulatorSelection: SimulatorSelection? = nil
    ) async throws -> (worktree: WorktreeContext, scheme: String, destination: XcodeDestination) {
        let worktrees = await worktrees()
        guard !worktrees.isEmpty else {
            throw SelectionError.notFound(kind: "branch", query: branch, available: [])
        }
        let worktree = try SelectionResolver.resolveWorktree(name: branch, in: worktrees).get()

        let schemeList: [String]
        do {
            schemeList = try await schemes(for: worktree.project)
        } catch {
            throw BuildFailure(message: "Failed to list schemes: \(error)")
        }
        let resolvedScheme = try SelectionResolver.resolveScheme(name: scheme, in: schemeList).get()

        if let simulatorSelection {
            let prepared = try await SimulatorBaseService().prepare(
                name: SimulatorBaseService.simulatorName(forBranch: worktree.branchName),
                selection: simulatorSelection, project: worktree.project, progress: { self.emitProgress($0) })
            return (worktree, resolvedScheme, XcodeDestination(id: prepared.udid, name: prepared.name,
                runtime: prepared.runtime, kind: .simulator))
        }

        let destinationList: [XcodeDestination]
        do {
            destinationList = try await xcodeService.destinations()
        } catch {
            throw BuildFailure(message: "Failed to list destinations: \(error)")
        }
        let resolvedDestination = try SelectionResolver.resolveDestination(
            name: destination,
            kind: kindFilter,
            in: destinationList
        ).get()

        let current = try await SimulatorBaseService().prepareManagedDestination(resolvedDestination, project: worktree.project)
        return (worktree, resolvedScheme, current)
    }

    /// Resolves here first so selection errors and Simulator preparation are
    /// reported to the caller, then hands the same arguments to an `orchard run`
    /// in its own session so the run (and the attached console) outlives the
    /// calling shell. Returns once the run's record exists, so `orchard runs <id>`
    /// works immediately.
    func delegateRun(
        branch: String,
        scheme: String,
        destination: String,
        kindFilter: XcodeDestination.Kind?,
        simulatorSelection: SimulatorSelection? = nil,
        arguments: [String]
    ) async throws -> (id: String, worktree: WorktreeContext, scheme: String, destination: XcodeDestination) {
        let resolved = try await resolveRun(branch: branch, scheme: scheme, destination: destination, kindFilter: kindFilter,
                                          simulatorSelection: simulatorSelection)

        let id = UUID().uuidString
        let pid = try Self.spawnDetached(arguments.filter { $0 != "--delegate" } + ["--quiet", "--run-id", id])
        let deadline = Date().addingTimeInterval(120)
        while RunStore.shared.loadAll().contains(where: { $0.id == id }) == false {
            guard Date() < deadline, kill(pid, 0) == 0 else {
                throw BuildFailure(message: "The delegated run (pid \(pid)) did not start.")
            }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        return (id, resolved.worktree, resolved.scheme, resolved.destination)
    }

    private static func spawnDetached(_ arguments: [String]) throws -> pid_t {
        guard let executable = Bundle.main.executablePath else {
            throw BuildFailure(message: "Cannot locate the orchard executable.")
        }
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSID))
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addopen(&actions, 1, "/dev/null", O_WRONLY, 0)
        posix_spawn_file_actions_addopen(&actions, 2, "/dev/null", O_WRONLY, 0)

        let argv: [UnsafeMutablePointer<CChar>?] = ([executable] + arguments).map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) } }
        var pid: pid_t = 0
        let status = posix_spawn(&pid, executable, &actions, &attributes, argv, environ)
        guard status == 0 else {
            throw BuildFailure(message: "Failed to start the delegated run: \(String(cString: strerror(status)))")
        }
        return pid
    }

    // MARK: - Run (attached; the default, recorded to the shared store)

    func performRun(
        branch: String,
        scheme: String,
        destination: String,
        kindFilter: XcodeDestination.Kind?,
        timeout: Int?,
        simulatorSelection: SimulatorSelection? = nil,
        runID: String? = nil
    ) async throws {
        let resolved = try await resolveRun(branch: branch, scheme: scheme, destination: destination, kindFilter: kindFilter,
                                          simulatorSelection: simulatorSelection)
        let worktree = resolved.worktree
        let resolvedScheme = resolved.scheme
        let resolvedDestination = resolved.destination

        // One run per destination: cancel and drop any existing run on this same
        // destination so re-running the same branch/scheme/destination replaces
        // the previous one instead of stacking.
        await supersedeRuns(onDestination: resolvedDestination.id)

        startRecord(
            id: runID ?? UUID().uuidString,
            worktree: worktree,
            scheme: resolvedScheme,
            destination: resolvedDestination
        )
        emitProgress("Selected \(worktree.branchName) · \(resolvedScheme) · \(resolvedDestination.displayName)")

        let service = BuildRunService()
        installSignalHandlers(service: service)
        defer { teardownSignalHandlers() }

        let buildTask = Task {
            try await service.buildAndRun(
                project: worktree.project,
                scheme: resolvedScheme,
                destination: resolvedDestination,
                progress: { self.emitProgress($0) },
                consoleLog: { self.emitConsole($0) },
                commandLog: { self.emitCommand($0) }
            )
        }

        var timeoutTask: Task<Void, Never>?
        if let timeout, timeout > 0 {
            timeoutTask = Task {
                try? await Task.sleep(nanoseconds: UInt64(timeout) * 1_000_000_000)
                guard !Task.isCancelled else { return }
                self.requestStop(.timedOut, message: "Timeout reached after \(timeout)s — stopping", service: service)
            }
        }

        let result = await buildTask.result
        timeoutTask?.cancel()
        if case let .failure(error) = result {
            guard let reason = currentStopReason() else { throw BuildFailure(message: "\(error)") }
            // The launched app must be torn down too, not just the local
            // xcrun/xcodebuild process that `stop()` killed.
            await service.stopCompletely(destination: resolvedDestination) { [weak self] in self?.emitProgress($0) }
            switch reason {
            case .externallyStopped:
                emitResult(status: "stopped", exitCode: 0)
                return
            case .interrupted:
                throw InterruptedError()
            case .timedOut:
                throw BuildFailure(message: "Timed out after \(timeout ?? 0)s")
            }
        }

        emitResult(status: "completed", exitCode: 0)
    }

    // MARK: - Signal handling

    private func installSignalHandlers(service: BuildRunService) {
        signalSources = [
            makeStopSource(SIGINT, .interrupted, message: "Interrupted — stopping run", service: service),
            // SIGTERM comes from `orchard stop` or a superseding run.
            makeStopSource(SIGTERM, .externallyStopped, message: "Stopped from Orchard", service: service)
        ]
    }

    private func makeStopSource(_ signalNumber: Int32, _ reason: StopReason, message: String,
                                service: BuildRunService) -> DispatchSourceSignal {
        signal(signalNumber, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .global())
        source.setEventHandler { [weak self] in
            self?.requestStop(reason, message: message, service: service)
        }
        source.resume()
        return source
    }

    private func teardownSignalHandlers() {
        for source in signalSources {
            source.cancel()
            signal(Int32(source.handle), SIG_DFL)
        }
        signalSources = []
    }

    // MARK: - Synchronized run state

    private func requestStop(_ reason: StopReason, message: String, service: BuildRunService) {
        stateLock.lock()
        stopReason = max(stopReason ?? reason, reason)
        stateLock.unlock()
        emitProgress(message)
        service.stop()
    }

    private func currentStopReason() -> StopReason? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return stopReason
    }

    /// Returns true only on the first call, so callers can fire a one-time
    /// "Launched" signal from `emitConsole`, which runs on arbitrary threads.
    private func markLaunchedOnce() -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard !launchedEmitted else { return false }
        launchedEmitted = true
        return true
    }

    // MARK: - Output

    /// Diagnostic/progress lines go to stderr so stdout stays clean for the
    /// app's own console output (or NDJSON events in `--json` mode).
    func emitProgress(_ message: String) {
        updateRecord(persistNow: true) { $0.activityText = message }
        if json {
            emitEvent(CLIEvent(type: "progress", stage: message))
        } else {
            writeLine(message, to: .standardError)
        }
    }

    func emitCommand(_ chunk: String) {
        if json {
            emitEvent(CLIEvent(type: "command", text: chunk))
        } else {
            write(chunk, to: .standardError)
        }
    }

    func emitConsole(_ chunk: String) {
        if markLaunchedOnce() {
            // Pollers of `orchard runs` treat `running` with an empty activity as
            // "launched and attached", so clear it rather than writing "Launched".
            updateRecord(persistNow: true) { $0.activityText = "" }
            if json {
                emitEvent(CLIEvent(type: "progress", stage: "Launched"))
            } else {
                writeLine("Launched", to: .standardError)
            }
        }
        // Console output can be voluminous; persist throttled.
        updateRecord(persistNow: false) { $0.log = Self.boundedAppend($0.log, chunk) }
        guard !quiet else { return }
        if json {
            emitEvent(CLIEvent(type: "console", text: chunk))
        } else {
            write(chunk, to: .standardOutput)
        }
    }

    func emitResult(status: String, exitCode: Int) {
        updateRecord(persistNow: true) {
            if let mapped = RunRecord.Status(rawValue: status) {
                $0.status = mapped
            }
            $0.activityText = status.capitalized
        }
        if json {
            emitEvent(CLIEvent(type: "result", status: status, exitCode: exitCode))
        }
    }

    // MARK: - Supersede prior runs

    /// Cancels and removes any existing run on the given destination so a new
    /// run replaces it rather than stacking. A still-running predecessor is sent
    /// SIGTERM (an intentional replace: its own handler tears down the launched
    /// app and exits cleanly); we wait for it to exit before deleting its record
    /// so it can't rewrite the file on the way out.
    private func supersedeRuns(onDestination destinationID: String) async {
        let store = RunStore.shared
        for record in store.loadAll() where record.destination.id == destinationID {
            if record.status == .running, let pid = record.pid, pid != ProcessInfo.processInfo.processIdentifier {
                kill(pid, SIGTERM)
                await Self.waitForExit(pid: pid, timeout: 5)
            }
            store.remove(id: record.id)
        }
    }

    /// Returns whether the process exited within `timeout`.
    @discardableResult
    static func waitForExit(pid: Int32, timeout: TimeInterval, interval: Duration = .milliseconds(100)) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while kill(pid, 0) == 0 {
            guard Date() < deadline else { return false }
            try? await Task.sleep(for: interval)
        }
        return true
    }

    // MARK: - Run record

    private func startRecord(id: String, worktree: WorktreeContext, scheme: String, destination: XcodeDestination) {
        let now = Date().timeIntervalSince1970
        let newRecord = RunRecord(
            id: id,
            branchName: worktree.branchName,
            worktreeDisplayName: worktree.displayName,
            project: worktree.project,
            scheme: scheme,
            destination: destination,
            startedAt: now,
            updatedAt: now,
            status: .running,
            activityText: "Starting",
            log: "",
            pid: ProcessInfo.processInfo.processIdentifier
        )
        recordLock.lock()
        record = newRecord
        lastPersist = Date()
        recordLock.unlock()
        try? RunStore.shared.write(newRecord)
    }

    private func updateRecord(persistNow: Bool, _ mutate: (inout RunRecord) -> Void) {
        recordLock.lock()
        guard var current = record else {
            recordLock.unlock()
            return
        }
        mutate(&current)
        current.updatedAt = Date().timeIntervalSince1970
        record = current

        let shouldWrite: Bool
        if persistNow {
            shouldWrite = true
        } else if let last = lastPersist {
            shouldWrite = Date().timeIntervalSince(last) >= 0.5
        } else {
            shouldWrite = true
        }

        if shouldWrite {
            lastPersist = Date()
            let snapshot = current
            recordLock.unlock()
            try? RunStore.shared.write(snapshot)
        } else {
            recordLock.unlock()
        }
    }

    private static func boundedAppend(_ existing: String, _ chunk: String) -> String {
        let combined = existing + chunk
        let maxLength = 80_000
        // `count` walks every grapheme; the UTF-8 length is O(1) and never smaller.
        guard combined.utf8.count > maxLength, combined.count > maxLength else { return combined }
        return String(combined.suffix(maxLength))
    }

    func emitError(_ message: String) {
        // A delegated run's stderr goes to /dev/null; the record is the only place the failure survives.
        updateRecord(persistNow: true) { $0.log = Self.boundedAppend($0.log, message + "\n") }
        if json {
            emitEvent(CLIEvent(type: "error", text: message))
        } else {
            writeLine(message, to: .standardError)
        }
    }

    private func emitEvent(_ event: CLIEvent) {
        guard let data = try? CLIEvent.encoder.encode(event),
              let line = String(data: data, encoding: .utf8) else {
            return
        }
        writeLine(line, to: .standardOutput)
    }

    private func writeLine(_ text: String, to handle: FileHandle) {
        write(text + "\n", to: handle)
    }

    private func write(_ text: String, to handle: FileHandle) {
        guard let data = text.data(using: .utf8) else { return }
        outputLock.lock()
        defer { outputLock.unlock() }
        handle.write(data)
    }
}

/// One NDJSON event emitted on stdout in `--json` mode.
struct CLIEvent: Encodable {
    let type: String
    var stage: String?
    var text: String?
    var status: String?
    var exitCode: Int?

    init(type: String, stage: String? = nil, text: String? = nil, status: String? = nil, exitCode: Int? = nil) {
        self.type = type
        self.stage = stage
        self.text = text
        self.status = status
        self.exitCode = exitCode
    }

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        return encoder
    }()
}
