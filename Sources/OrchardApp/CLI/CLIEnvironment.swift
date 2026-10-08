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

/// Shared machinery for the `run` and `list` subcommands: resolves which
/// directories to scan, fetches worktrees/schemes/destinations via the same
/// `OrchardCore` services the GUI uses, wires build logs to stdout/stderr,
/// and manages clean Ctrl-C teardown.
final class CLIEnvironment: @unchecked Sendable {
    let directoryURLs: [URL]
    let json: Bool
    let quiet: Bool

    private let resolver = WorktreeContextResolver()
    private let xcodeService = XcodeService()
    private let outputLock = NSLock()

    // Guards `service`, `interrupted`, `externallyStopped`, `timedOut`, and
    // `launchedEmitted`, which are touched from the signal/timeout queues and
    // the console callback (arbitrary thread) as well as the main run task.
    private let stateLock = NSLock()
    private var service: BuildRunService?
    private var interrupted = false
    // Set when the GUI (or a superseding run) asks this run to stop via SIGTERM.
    // Unlike a Ctrl-C interrupt, this is an intentional user action, so the run
    // ends cleanly (exit 0) instead of looking like a crash to a background task.
    private var externallyStopped = false
    private var timedOut = false
    // Set once the first console chunk arrives, so `emitConsole` can announce
    // "Launched" exactly once for callers polling progress instead of stdout.
    private var launchedEmitted = false
    private var activeDestination: XcodeDestination?
    private var signalSource: DispatchSourceSignal?
    private var termSignalSource: DispatchSourceSignal?

    // Shared run record written for GUI visibility. Guarded by recordLock since
    // it is mutated from build callbacks running on arbitrary threads.
    private let recordLock = NSLock()
    private var record: RunRecord?
    private var lastPersist: Date?

    /// Directory precedence: explicit `--dir` overrides everything, then the
    /// `ORCHARD_DIRS` env var (colon-separated), then the directories the GUI
    /// persisted. This lets the CLI work standalone in CI while still sharing
    /// the GUI's configuration on a developer machine.
    init(extraDirectoryPaths: [String], json: Bool, quiet: Bool = false) {
        var paths = extraDirectoryPaths

        if paths.isEmpty, let envValue = ProcessInfo.processInfo.environment["ORCHARD_DIRS"], !envValue.isEmpty {
            paths = envValue.split(separator: ":").map(String.init)
        }

        if paths.isEmpty {
            paths = AppConfiguration.configuredDirectoryPaths()
        }

        directoryURLs = paths.map {
            URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath, isDirectory: true)
        }
        self.json = json
        self.quiet = quiet
    }

    // MARK: - Fetching

    func worktrees() async -> [WorktreeContext] {
        await resolver.resolve(fromConfiguredDirectoryURLs: directoryURLs)
    }

    func schemes(for project: XcodeProject) async throws -> [String] {
        try await xcodeService.schemes(project: project)
    }

    func destinations() async throws -> [XcodeDestination] {
        try await xcodeService.destinations()
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
                name: worktree.branchName.replacingOccurrences(of: "/", with: "-"),
                selection: simulatorSelection, project: worktree.project, progress: { self.emitProgress($0) })
            return (worktree, resolvedScheme, XcodeDestination(id: prepared.udid, name: prepared.name,
                runtime: prepared.runtime, isAvailable: true, kind: .simulator))
        }

        let destinationList: [XcodeDestination]
        do {
            destinationList = try await destinations()
        } catch {
            throw BuildFailure(message: "Failed to list destinations: \(error)")
        }
        let resolvedDestination = try SelectionResolver.resolveDestination(
            name: destination,
            kind: kindFilter,
            in: destinationList
        ).get()

        return (worktree, resolvedScheme, resolvedDestination)
    }

    /// Default run path: hand a resolved request to the GUI app, which runs it
    /// (console attached, logs recorded and shown) while this command returns
    /// immediately. Ensures the GUI is running. Returns the request id.
    func delegateRun(
        branch: String,
        scheme: String,
        destination: String,
        kindFilter: XcodeDestination.Kind?,
        simulatorSelection: SimulatorSelection? = nil
    ) async throws -> (id: String, worktree: WorktreeContext, scheme: String, destination: XcodeDestination) {
        let resolved = try await resolveRun(branch: branch, scheme: scheme, destination: destination, kindFilter: kindFilter,
                                          simulatorSelection: simulatorSelection)

        let id = UUID().uuidString
        let payload = RunRequestPayload(
            id: id,
            branchName: resolved.worktree.branchName,
            worktreeDisplayName: resolved.worktree.displayName,
            project: resolved.worktree.project,
            scheme: resolved.scheme,
            destination: resolved.destination
        )
        do {
            try RunStore.shared.writeRequest(payload)
        } catch {
            throw BuildFailure(message: "Failed to write run request: \(error)")
        }
        ensureGUIRunning()
        return (id, resolved.worktree, resolved.scheme, resolved.destination)
    }

    /// Launches the Orchard GUI (no-op if already running) so it can pick up
    /// the delegated request. Derives the .app bundle from this binary's path.
    private func ensureGUIRunning() {
        let exe = URL(fileURLWithPath: ProcessInfo.processInfo.arguments.first ?? "")
            .resolvingSymlinksInPath()
        // .../Orchard.app/Contents/MacOS/orchard → .../Orchard.app
        let appURL = exe.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        guard appURL.pathExtension == "app" else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-g", appURL.path]
        try? process.run()
        process.waitUntilExit()
    }

    // MARK: - Run (attached; the default, recorded to the shared store)

    func performRun(
        branch: String,
        scheme: String,
        destination: String,
        kindFilter: XcodeDestination.Kind?,
        timeout: Int?,
        detached: Bool,
        simulatorSelection: SimulatorSelection? = nil
    ) async throws {
        let resolved = try await resolveRun(branch: branch, scheme: scheme, destination: destination, kindFilter: kindFilter,
                                          simulatorSelection: simulatorSelection)
        let worktree = resolved.worktree
        let resolvedScheme = resolved.scheme
        let resolvedDestination = resolved.destination

        // One run per destination: cancel and drop any existing run on this same
        // destination so re-running the same branch/scheme/destination replaces
        // the previous one instead of stacking (mirrors the GUI's behavior).
        await supersedeRuns(onDestination: resolvedDestination.id)

        startRecord(
            worktree: worktree,
            scheme: resolvedScheme,
            destination: resolvedDestination
        )
        emitProgress("Selected \(worktree.branchName) · \(resolvedScheme) · \(resolvedDestination.displayName)")

        let service = BuildRunService()
        setService(service)
        activeDestination = resolvedDestination
        installSignalHandler()
        defer { teardownSignalHandler() }

        let buildTask = Task {
            try await service.buildAndRun(
                project: worktree.project,
                scheme: resolvedScheme,
                destination: resolvedDestination,
                attachConsole: !detached,
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
                self.markTimedOut()
                self.emitProgress("Timeout reached after \(timeout)s — stopping")
                self.currentService()?.stop()
            }
        }

        do {
            try await buildTask.value
            timeoutTask?.cancel()
        } catch {
            timeoutTask?.cancel()

            // A GUI-initiated stop (or being superseded) is an intentional user
            // action, not a failure. Tear the launched app down the same way, but
            // finish as a clean `stopped` with exit 0 so a background task running
            // this run doesn't treat it as a crash.
            if isExternallyStopped() {
                await service.stopCompletely(destination: resolvedDestination) { [weak self] in self?.emitProgress($0) }
                emitResult(status: "stopped", exitCode: 0)
                return
            }
            // SIGINT (Ctrl-C) and timeout both need the launched app torn down,
            // not just the local xcrun/xcodebuild process that `stop()` killed.
            if isInterrupted() {
                await service.stopCompletely(destination: resolvedDestination) { [weak self] in self?.emitProgress($0) }
                throw InterruptedError()
            }
            if isTimedOut() {
                await service.stopCompletely(destination: resolvedDestination) { [weak self] in self?.emitProgress($0) }
                throw BuildFailure(message: "Timed out after \(timeout ?? 0)s")
            }
            throw BuildFailure(message: "\(error)")
        }

        emitResult(status: "completed", exitCode: 0)
    }

    // MARK: - Signal handling

    private func installSignalHandler() {
        signal(SIGINT, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
        source.setEventHandler { [weak self] in
            guard let self else { return }
            self.markInterrupted()
            self.emitProgress("Interrupted — stopping run")
            self.currentService()?.stop()
        }
        source.resume()
        signalSource = source

        // SIGTERM = intentional stop from the GUI (stop/replace/rerun) or from a
        // superseding run. Treated as a clean stop, not an interrupt/crash.
        signal(SIGTERM, SIG_IGN)
        let termSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .global())
        termSource.setEventHandler { [weak self] in
            guard let self else { return }
            self.markExternallyStopped()
            self.emitProgress("Stopped from Orchard")
            self.currentService()?.stop()
        }
        termSource.resume()
        termSignalSource = termSource
    }

    // MARK: - Synchronized run state

    private func setService(_ newService: BuildRunService?) {
        stateLock.lock()
        service = newService
        stateLock.unlock()
    }

    private func currentService() -> BuildRunService? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return service
    }

    private func markInterrupted() {
        stateLock.lock()
        interrupted = true
        stateLock.unlock()
    }

    private func isInterrupted() -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return interrupted
    }

    private func markExternallyStopped() {
        stateLock.lock()
        externallyStopped = true
        stateLock.unlock()
    }

    private func isExternallyStopped() -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return externallyStopped
    }

    private func markTimedOut() {
        stateLock.lock()
        timedOut = true
        stateLock.unlock()
    }

    private func isTimedOut() -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return timedOut
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

    private func teardownSignalHandler() {
        signalSource?.cancel()
        signalSource = nil
        signal(SIGINT, SIG_DFL)

        termSignalSource?.cancel()
        termSignalSource = nil
        signal(SIGTERM, SIG_DFL)
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
            // Signal launch success to the skill on stderr, but keep the record
            // in the steady "running" state (empty activity) so the GUI shows the
            // pulsing dot instead of a perpetual spinner.
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
                await waitForExit(pid: pid, timeout: 5)
            }
            store.remove(id: record.id)
        }
    }

    private func waitForExit(pid: Int32, timeout: Double) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            // kill(pid, 0) fails once the process is gone.
            if kill(pid, 0) != 0 { return }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    // MARK: - Run record (GUI sync)

    private func startRecord(worktree: WorktreeContext, scheme: String, destination: XcodeDestination) {
        let now = Date().timeIntervalSince1970
        let newRecord = RunRecord(
            id: UUID().uuidString,
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
        return combined.count > maxLength ? String(combined.suffix(maxLength)) : combined
    }

    func emitError(_ message: String) {
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
