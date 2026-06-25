import DevRunnerCore
import Foundation

enum RunJobStatus: Equatable {
    case running
    case completed
    case failed
    case stopped

    var label: String {
        switch self {
        case .running:
            "Running"
        case .completed:
            "Completed"
        case .failed:
            "Failed"
        case .stopped:
            "Stopped"
        }
    }
}

enum RunSource {
    case gui
    case cli
}

struct RunJob: Identifiable {
    let id: UUID
    let worktreeDisplayName: String
    let branchName: String
    let project: XcodeProject
    let scheme: String
    let destination: XcodeDestination
    let startedAt: Date
    var status: RunJobStatus
    var activityText: String
    var logText: String
    var source: RunSource = .gui
    // PID of the owning CLI process (CLI jobs only), used to stop it via SIGINT.
    var cliPID: Int32?

    var title: String {
        "\(branchName) · \(scheme)"
    }

    var displayName: String {
        "\(status.label) · \(destination.name) · \(scheme)"
    }

    var isRunning: Bool {
        status == .running
    }

    var statusIcon: String {
        switch status {
        case .running:
            "●"
        case .completed:
            "✓"
        case .failed:
            "!"
        case .stopped:
            "■"
        }
    }

    var tabTitle: String {
        "\(statusIcon) \(branchName)"
    }

    var tabSubtitle: String {
        "\(destination.name) · \(scheme)"
    }
}

struct RunJobGroup: Identifiable {
    let projectID: String
    let jobs: [RunJob]

    var id: String { projectID }
}

@MainActor
final class RunnerViewModel: ObservableObject {
    @Published var configuredDirectoryPaths: [String] = []
    @Published var worktrees: [WorktreeContext] = []
    @Published var selectedWorktreeID: String?
    @Published var schemes: [String] = []
    @Published var destinations: [XcodeDestination] = []
    @Published var selectedScheme: String?
    @Published var selectedDestinationID: String?
    @Published var favoriteSimulatorDestinationIDs: Set<String> = []
    @Published var status = "Idle"
    @Published var jobs: [RunJob] = []
    @Published var selectedJobID: UUID?
    @Published var globalHotKey: GlobalHotKey?
    @Published var isRefreshing = false
    @Published var isLoadingSchemes = false
    @Published var appLogText = ""

    private struct RunRequest {
        let replacingJobID: UUID?
        let worktreeDisplayName: String
        let branchName: String
        let project: XcodeProject
        let scheme: String
        let destination: XcodeDestination
    }

    private let configuredDirectoryPathsKey = AppConfiguration.Keys.configuredDirectoryPaths
    private let favoriteSimulatorDestinationIDsKey = AppConfiguration.Keys.favoriteSimulatorDestinationIDs
    private let globalHotKeyKey = AppConfiguration.Keys.globalHotKey
    private let schemeCacheKey = AppConfiguration.Keys.schemeCache
    private let worktreeContextResolver = WorktreeContextResolver()
    private let xcodeService = XcodeService()
    private let globalHotKeyManager = GlobalHotKeyManager()
    private var runServices: [UUID: BuildRunService] = [:]
    // Keyed by the project file path: project.id hashes are not stable
    // across launches, and this cache is persisted.
    private var schemeCache: [String: [String]] = [:]
    // Watches the shared run store so CLI-originated runs appear in the Runs
    // list. Event-driven (FSEvents) — no idle polling. Kept for the VM's whole
    // lifetime; only the underlying stream is started/stopped.
    private var runStoreWatcher: RunStoreWatcher?
    // Tombstones for CLI runs the user dismissed via Close. A running CLI run
    // keeps rewriting its record, so without this it would reappear on the next
    // sync. Entries are forgotten once their record actually leaves the store.
    private var dismissedCLIRunIDs: Set<UUID> = []

    init() {
        configuredDirectoryPaths = UserDefaults.standard.stringArray(forKey: configuredDirectoryPathsKey) ?? []
        favoriteSimulatorDestinationIDs = Set(
            UserDefaults.standard.stringArray(forKey: favoriteSimulatorDestinationIDsKey) ?? []
        )

        if let data = UserDefaults.standard.data(forKey: globalHotKeyKey),
           let hotKey = try? JSONDecoder().decode(GlobalHotKey.self, from: data) {
            globalHotKey = hotKey
        }
        globalHotKeyManager.handler = { MenuBarWindowPresenter.toggle() }
        applyGlobalHotKey()

        schemeCache = UserDefaults.standard.dictionary(forKey: schemeCacheKey) as? [String: [String]] ?? [:]
    }

    var isRunning: Bool {
        jobs.contains { $0.isRunning }
    }

    var canBuildAndRun: Bool {
        selectedWorktree != nil && selectedScheme != nil && selectedDestination != nil
    }

    var canStopSelectedJob: Bool {
        selectedJob.map(\.isRunning) ?? false
    }

    var canRerunSelectedJob: Bool {
        selectedJob != nil
    }

    var canCloseSelectedJob: Bool {
        selectedJob != nil
    }

    var selectedWorktree: WorktreeContext? {
        guard let selectedWorktreeID else { return nil }
        return worktrees.first { $0.id == selectedWorktreeID }
    }

    var project: XcodeProject? {
        selectedWorktree?.project
    }

    var selectedDestination: XcodeDestination? {
        guard let selectedDestinationID else { return nil }
        return destinations.first { $0.id == selectedDestinationID }
    }

    var displayedDestinations: [XcodeDestination] {
        destinations
    }

    var deviceDestinations: [XcodeDestination] {
        destinations.filter { $0.kind == .device }
    }

    var favoriteSimulatorDestinations: [XcodeDestination] {
        destinations.filter {
            $0.kind == .simulator && favoriteSimulatorDestinationIDs.contains($0.id)
        }
    }

    var otherSimulatorDestinations: [XcodeDestination] {
        destinations.filter {
            $0.kind == .simulator && !favoriteSimulatorDestinationIDs.contains($0.id)
        }
    }

    var selectedDestinationTitle: String {
        selectedDestination?.displayName ?? "Select"
    }

    var canToggleSelectedSimulatorFavorite: Bool {
        selectedDestination?.kind == .simulator
    }

    var selectedSimulatorIsFavorite: Bool {
        guard let selectedDestination, selectedDestination.kind == .simulator else { return false }
        return favoriteSimulatorDestinationIDs.contains(selectedDestination.id)
    }

    var selectedJob: RunJob? {
        guard let selectedJobID else { return jobs.last }
        return jobs.first { $0.id == selectedJobID }
    }

    var jobGroups: [RunJobGroup] {
        var order: [String] = []
        var grouped: [String: [RunJob]] = [:]

        for job in jobs {
            let key = job.project.id
            if grouped[key] == nil {
                order.append(key)
            }
            grouped[key, default: []].append(job)
        }

        return order.map { RunJobGroup(projectID: $0, jobs: grouped[$0] ?? []) }
    }

    var logText: String {
        selectedJob?.logText ?? ""
    }

    var configuredDirectoryURLs: [URL] {
        configuredDirectoryPaths.map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    func addConfiguredDirectory(_ url: URL) {
        let path = url.standardizedFileURL.path
        guard !configuredDirectoryPaths.contains(path) else { return }

        configuredDirectoryPaths.append(path)
        saveConfiguredDirectoryPaths()
    }

    func removeConfiguredDirectory(_ path: String) {
        configuredDirectoryPaths.removeAll { $0 == path }
        saveConfiguredDirectoryPaths()
    }

    func setGlobalHotKey(_ hotKey: GlobalHotKey?) {
        globalHotKey = hotKey

        if let hotKey, let data = try? JSONEncoder().encode(hotKey) {
            UserDefaults.standard.set(data, forKey: globalHotKeyKey)
        } else {
            UserDefaults.standard.removeObject(forKey: globalHotKeyKey)
        }

        applyGlobalHotKey()
    }

    private func applyGlobalHotKey() {
        if let globalHotKey {
            globalHotKeyManager.register(
                keyCode: globalHotKey.keyCode,
                modifiers: globalHotKey.carbonModifiers
            )
        } else {
            globalHotKeyManager.unregister()
        }
    }

    func refresh() async {
        status = "Refreshing"
        // Show the loading state only on a cold start. With cached data the
        // refresh runs silently in the background and swaps results in.
        if worktrees.isEmpty && destinations.isEmpty {
            isRefreshing = true
        }
        defer { isRefreshing = false }

        do {
            let configuredDirectoryURLs = configuredDirectoryURLs
            async let resolvedWorktrees = worktreeContextResolver.resolve(
                fromConfiguredDirectoryURLs: configuredDirectoryURLs
            )
            async let loadedDestinations = xcodeService.destinations()

            worktrees = await resolvedWorktrees
            destinations = try await loadedDestinations
            favoriteSimulatorDestinationIDs.formIntersection(Set(destinations.map(\.id)))
            selectedWorktreeID = selectedWorktreeID.flatMap { id in
                worktrees.contains { $0.id == id } ? id : nil
            } ?? worktrees.first?.id
            selectedDestinationID = preferredDestinationID(currentID: selectedDestinationID)

            removeJobsForDeletedProjects()

            try await reloadSchemesForSelectedWorktree()
            if configuredDirectoryPaths.isEmpty {
                status = "Add a directory to scan"
            } else {
                status = worktrees.isEmpty ? "No Xcode worktrees found" : "Ready"
            }
        } catch {
            status = error.localizedDescription
            appendAppLog("[\(timestamp())] Refresh failed: \(error.localizedDescription)\n")
        }
    }

    /// Starts mirroring CLI runs. Called when the menu window opens — there is
    /// no point watching the run store while nobody is looking at the Runs list,
    /// so the GUI does no work at all when the popover is closed.
    func startCLISync() {
        if runStoreWatcher == nil {
            let directory = RunStore.shared.prepareDirectory()
            runStoreWatcher = RunStoreWatcher(directory: directory) { [weak self] in
                Task { @MainActor in self?.syncCLIRuns() }
            }
        }
        runStoreWatcher?.start()

        // Sync once immediately: FSEvents only reports changes from now on, so
        // runs that happened while the menu was closed need an initial scan.
        syncCLIRuns()
    }

    /// Stops mirroring when the menu window closes.
    func stopCLISync() {
        runStoreWatcher?.stop()
    }

    /// Removes jobs whose project no longer exists on disk — i.e. the worktree
    /// (or branch) was deleted. Uses on-disk existence rather than the current
    /// `worktrees` list so a temporarily unscanned-but-present worktree keeps
    /// its jobs. CLI jobs also have their shared record deleted.
    private func removeJobsForDeletedProjects() {
        let missing = jobs.filter { !FileManager.default.fileExists(atPath: $0.project.fileURL.path) }
        guard !missing.isEmpty else { return }

        // Both CLI and GUI runs have shared records now; drop them either way.
        for job in missing {
            RunStore.shared.remove(id: job.id.uuidString)
        }

        let missingIDs = Set(missing.map(\.id))
        jobs.removeAll { missingIDs.contains($0.id) }
        if let selectedJobID, missingIDs.contains(selectedJobID) {
            self.selectedJobID = jobs.last?.id
        }
    }

    /// Mirrors CLI-originated runs from the shared `RunStore` into the Runs list.
    /// GUI-originated jobs (`source == .gui`) are never touched here.
    ///
    /// Runs synchronously on the main actor: the store holds a handful of small
    /// files and FSEvents already coalesces bursts, so reading inline keeps each
    /// sync atomic and avoids the stale-overwrite race that concurrent loads
    /// (older scan finishing after a newer one) would introduce.
    func syncCLIRuns() {
        let store = RunStore.shared
        // 24h after finishing, drop the record so the list doesn't grow forever.
        store.pruneFinished(olderThan: 24 * 60 * 60, now: Date().timeIntervalSince1970)
        let allRecords = store.loadAll().filter { $0.source == "cli" }

        let onDiskIDs = Set(allRecords.compactMap { UUID(uuidString: $0.id) })
        // Forget tombstones whose record has actually left the store.
        dismissedCLIRunIDs.formIntersection(onDiskIDs)

        let records = allRecords.filter { record in
            guard let id = UUID(uuidString: record.id) else { return false }
            if dismissedCLIRunIDs.contains(id) { return false }
            // Drop runs whose worktree/project was deleted from disk, and delete
            // the stale record so it doesn't linger.
            if !FileManager.default.fileExists(atPath: record.projectFilePath) {
                store.remove(id: record.id)
                return false
            }
            return true
        }

        let recordIDs = Set(records.compactMap { UUID(uuidString: $0.id) })

        // Drop CLI jobs whose record was removed (closed or pruned).
        jobs.removeAll { $0.source == .cli && !recordIDs.contains($0.id) }

        for record in records {
            guard let id = UUID(uuidString: record.id) else { continue }
            let status = mapRecordStatus(record.status)

            if let index = jobs.firstIndex(where: { $0.id == id }) {
                jobs[index].status = status
                jobs[index].activityText = record.activityText
                jobs[index].logText = record.log
                jobs[index].cliPID = record.pid
            } else {
                jobs.append(
                    RunJob(
                        id: id,
                        worktreeDisplayName: record.worktreeDisplayName,
                        branchName: record.branchName,
                        project: record.toXcodeProject(),
                        scheme: record.scheme,
                        destination: record.destination.toXcodeDestination(),
                        startedAt: Date(timeIntervalSince1970: record.startedAt),
                        status: status,
                        activityText: record.activityText,
                        logText: record.log,
                        source: .cli,
                        cliPID: record.pid
                    )
                )
            }
        }
    }

    // MARK: - GUI run records (agent visibility)

    private var guiRecordLastWrite: [UUID: Date] = [:]

    /// Persists a GUI-managed job to the shared run store (source "gui") so an AI
    /// agent can read its status/log the same way it reads CLI runs — including
    /// runs started or rerun from the GUI. Throttled for frequent console
    /// updates; pass `force` for lifecycle/status changes.
    private func persistGUIRecord(_ jobID: UUID, force: Bool = false) {
        guard let job = jobs.first(where: { $0.id == jobID }), job.source == .gui else { return }
        if !force, let last = guiRecordLastWrite[jobID], Date().timeIntervalSince(last) < 0.5 { return }
        guiRecordLastWrite[jobID] = Date()

        let record = RunRecord(
            id: job.id.uuidString,
            source: "gui",
            branchName: job.branchName,
            worktreeDisplayName: job.worktreeDisplayName,
            project: job.project,
            scheme: job.scheme,
            destination: job.destination,
            startedAt: job.startedAt.timeIntervalSince1970,
            updatedAt: Date().timeIntervalSince1970,
            status: recordStatus(job.status),
            activityText: job.activityText,
            log: job.logText,
            pid: nil
        )
        try? RunStore.shared.write(record)
    }

    private func recordStatus(_ status: RunJobStatus) -> RunRecord.Status {
        switch status {
        case .running: .running
        case .completed: .completed
        case .failed: .failed
        case .stopped: .stopped
        }
    }

    private func mapRecordStatus(_ status: RunRecord.Status) -> RunJobStatus {
        switch status {
        case .running: .running
        case .completed: .completed
        case .failed: .failed
        case .stopped: .stopped
        }
    }

    func toggleSelectedSimulatorFavorite() {
        guard let selectedDestination, selectedDestination.kind == .simulator else { return }
        toggleSimulatorFavorite(selectedDestination.id)
    }

    func toggleSimulatorFavorite(_ destinationID: String) {
        guard destinations.contains(where: { $0.id == destinationID && $0.kind == .simulator }) else {
            return
        }

        if favoriteSimulatorDestinationIDs.contains(destinationID) {
            favoriteSimulatorDestinationIDs.remove(destinationID)
        } else {
            favoriteSimulatorDestinationIDs.insert(destinationID)
        }

        saveFavoriteSimulatorDestinationIDs()
        selectedDestinationID = preferredDestinationID(currentID: selectedDestinationID)
    }

    func selectDestination(_ destinationID: String) {
        selectedDestinationID = destinationID
    }

    func worktreeSelectionChanged() async {
        let hasCachedSchemes = selectedWorktree.map {
            schemeCache[$0.project.fileURL.path] != nil
        } ?? true

        if !hasCachedSchemes {
            isLoadingSchemes = true
        }
        defer { isLoadingSchemes = false }

        do {
            status = "Loading schemes"
            try await reloadSchemesForSelectedWorktree()
            status = "Ready"
        } catch {
            status = error.localizedDescription
            appendAppLog("[\(timestamp())] Scheme load failed: \(error.localizedDescription)\n")
        }
    }

    func buildAndRun() {
        guard let selectedWorktree, let selectedScheme, let selectedDestination else { return }

        let request = RunRequest(
            replacingJobID: nil,
            worktreeDisplayName: selectedWorktree.displayName,
            branchName: selectedWorktree.branchName,
            project: selectedWorktree.project,
            scheme: selectedScheme,
            destination: selectedDestination
        )

        Task {
            await startRunReplacingDestination(request)
        }
    }

    func rerunSelectedJob() {
        guard let selectedJob else { return }
        rerunJob(selectedJob.id)
    }

    func rerunJob(_ jobID: UUID) {
        guard let job = jobs.first(where: { $0.id == jobID }) else { return }

        if job.source == .cli {
            rerunCLIJob(job)
            return
        }

        let request = RunRequest(
            replacingJobID: job.id,
            worktreeDisplayName: job.worktreeDisplayName,
            branchName: job.branchName,
            project: job.project,
            scheme: job.scheme,
            destination: job.destination
        )

        Task {
            if job.isRunning {
                await stop(jobID: job.id)
            }
            await startRunReplacingDestination(request)
        }
    }

    /// Reruns a CLI-originated job as a GUI-managed run: stop the CLI process if
    /// it's still running, stop mirroring its record, then start a fresh in-app
    /// run with the same branch/scheme/destination. The new run is a normal GUI
    /// job, so stop/rerun work the usual way afterwards. `startRunReplacingDestination`
    /// also clears any other job on the same destination.
    private func rerunCLIJob(_ job: RunJob) {
        if job.isRunning {
            stopCLIJob(job)
        }
        dismissedCLIRunIDs.insert(job.id)
        RunStore.shared.remove(id: job.id.uuidString)
        removeJob(jobID: job.id)

        let request = RunRequest(
            replacingJobID: nil,
            worktreeDisplayName: job.worktreeDisplayName,
            branchName: job.branchName,
            project: job.project,
            scheme: job.scheme,
            destination: job.destination
        )

        Task {
            await startRunReplacingDestination(request)
        }
    }

    func stopSelectedJob() {
        guard let selectedJob else { return }
        stopJob(selectedJob.id)
    }

    func stopJob(_ jobID: UUID) {
        if let job = jobs.first(where: { $0.id == jobID }), job.source == .cli {
            stopCLIJob(job)
            return
        }
        Task { await stop(jobID: jobID) }
    }

    /// Stops a CLI-originated run by signalling its process. The CLI's SIGINT
    /// handler tears down the launched app, writes the final `stopped` status to
    /// the shared record, and exits — so the terminal reflects the stop too, and
    /// the GUI picks up the `stopped` status via the run-store watcher.
    private func stopCLIJob(_ job: RunJob) {
        guard job.isRunning, let pid = job.cliPID else { return }

        if let index = jobs.firstIndex(where: { $0.id == job.id }) {
            jobs[index].activityText = "Stopping…"
        }
        kill(pid, SIGINT)
    }

    func closeSelectedJob() {
        guard let selectedJob else { return }
        closeJob(selectedJob.id)
    }

    func closeJob(_ jobID: UUID) {
        guard let job = jobs.first(where: { $0.id == jobID }) else { return }

        // Closing a CLI run only stops mirroring it. Tombstone the id so a still
        // running CLI (which keeps rewriting its record) doesn't reappear on the
        // next sync; delete the record only once the run has finished.
        if job.source == .cli {
            dismissedCLIRunIDs.insert(jobID)
            if !job.isRunning {
                RunStore.shared.remove(id: jobID.uuidString)
            }
            removeJob(jobID: jobID)
            return
        }

        if job.isRunning {
            Task {
                await stop(jobID: job.id)
                RunStore.shared.remove(id: job.id.uuidString)
                removeJob(jobID: job.id)
            }
        } else {
            RunStore.shared.remove(id: job.id.uuidString)
            removeJob(jobID: job.id)
        }
    }

    func clearLog() {
        guard let jobID = selectedJob?.id,
              let index = jobs.firstIndex(where: { $0.id == jobID }) else {
            return
        }

        jobs[index].logText = ""
    }

    private func reloadSchemesForSelectedWorktree() async throws {
        guard let selectedWorktree else {
            schemes = []
            selectedScheme = nil
            return
        }

        let cacheKey = selectedWorktree.project.fileURL.path

        // Serve cached schemes immediately; the fresh list replaces them below.
        if let cachedSchemes = schemeCache[cacheKey], schemes != cachedSchemes || schemes.isEmpty {
            applySchemes(cachedSchemes)
        }

        let loadedSchemes = try await xcodeService.schemes(project: selectedWorktree.project)
        schemeCache[cacheKey] = loadedSchemes
        UserDefaults.standard.set(schemeCache, forKey: schemeCacheKey)

        // The user may have switched projects while xcodebuild was running.
        guard self.selectedWorktree?.project.fileURL.path == cacheKey else { return }
        applySchemes(loadedSchemes)
    }

    private func applySchemes(_ loadedSchemes: [String]) {
        schemes = loadedSchemes
        selectedScheme = selectedScheme.flatMap { loadedSchemes.contains($0) ? $0 : nil } ?? loadedSchemes.first
    }

    private func startRun(_ request: RunRequest) {
        let jobID = request.replacingJobID ?? UUID()

        let service = BuildRunService()
        if let index = jobs.firstIndex(where: { $0.id == jobID }) {
            jobs[index].status = .running
            jobs[index].activityText = "Starting"
            jobs[index].logText = ""
        } else {
            let job = RunJob(
                id: jobID,
                worktreeDisplayName: request.worktreeDisplayName,
                branchName: request.branchName,
                project: request.project,
                scheme: request.scheme,
                destination: request.destination,
                startedAt: Date(),
                status: .running,
                activityText: "Starting",
                logText: ""
            )
            jobs.append(job)
        }
        selectedJobID = jobID
        runServices[jobID] = service
        status = "Running"
        persistGUIRecord(jobID, force: true)

        let jobLabel = "\(request.branchName) · \(request.scheme) → \(request.destination.name)"
        appendAppLog("\n[\(timestamp())] ▶ \(jobLabel)\n")

        Task {
            do {
                try await service.buildAndRun(
                    project: request.project,
                    scheme: request.scheme,
                    destination: request.destination,
                    progress: { [weak self] text in
                        Task { @MainActor in
                            self?.updateActivity(text, for: jobID)
                        }
                    },
                    consoleLog: { [weak self] text in
                        Task { @MainActor in
                            self?.appendLog(text, to: jobID)
                        }
                    },
                    commandLog: { [weak self] text in
                        Task { @MainActor in
                            self?.appendAppLog(text)
                        }
                    }
                )

                if jobs.first(where: { $0.id == jobID })?.status == .running {
                    appendAppLog("[\(timestamp())] ■ \(jobLabel): console detached\n")
                    finish(jobID: jobID, status: .completed, message: "")
                }
            } catch {
                let currentStatus = jobs.first { $0.id == jobID }?.status
                if currentStatus != .stopped {
                    appendAppLog("[\(timestamp())] ✖ \(jobLabel): \(error.localizedDescription)\n")
                    finish(jobID: jobID, status: .failed, message: "")
                }
            }
        }
    }

    private func startRunReplacingDestination(_ request: RunRequest) async {
        var request = request

        // Reuse the existing job instead of stacking a new one when the
        // branch, scheme, and destination all match.
        if request.replacingJobID == nil,
           let duplicate = jobs.first(where: {
               $0.branchName == request.branchName &&
               $0.scheme == request.scheme &&
               $0.destination.id == request.destination.id
           }) {
            request = RunRequest(
                replacingJobID: duplicate.id,
                worktreeDisplayName: request.worktreeDisplayName,
                branchName: request.branchName,
                project: request.project,
                scheme: request.scheme,
                destination: request.destination
            )
        }

        let replacingJobID = request.replacingJobID
        let conflictingJobs = jobs.filter {
            $0.destination.id == request.destination.id && $0.id != replacingJobID && $0.isRunning
        }

        for job in conflictingJobs {
            await stop(jobID: job.id)
        }

        if let replacingJobID, jobs.first(where: { $0.id == replacingJobID })?.isRunning == true {
            await stop(jobID: replacingJobID)
        }

        startRun(request)
    }

    private func stop(jobID: UUID) async {
        guard let service = runServices[jobID],
              let job = jobs.first(where: { $0.id == jobID }) else {
            return
        }

        if let index = jobs.firstIndex(where: { $0.id == jobID }) {
            jobs[index].status = .stopped
            jobs[index].activityText = "Stopped"
            status = jobs.contains { $0.isRunning } ? "Running" : RunJobStatus.stopped.label
            persistGUIRecord(jobID, force: true)
        }

        appendAppLog("[\(timestamp())] ⏹ \(job.branchName) · \(job.scheme) → \(job.destination.name): stopped\n")
        await service.stopCompletely(destination: job.destination) { [weak self] text in
            Task { @MainActor in
                self?.appendAppLog(text)
            }
        }
        runServices[jobID] = nil
    }

    private func finish(jobID: UUID, status: RunJobStatus, message: String) {
        guard let index = jobs.firstIndex(where: { $0.id == jobID }) else { return }

        jobs[index].status = status
        jobs[index].activityText = status.label
        if !message.isEmpty {
            appendLog(message, to: jobID)
        }
        runServices[jobID] = nil
        self.status = jobs.contains { $0.isRunning } ? "Running" : status.label
        persistGUIRecord(jobID, force: true)
    }

    private func removeJob(jobID: UUID) {
        jobs.removeAll { $0.id == jobID }
        runServices[jobID] = nil
        guiRecordLastWrite[jobID] = nil

        if selectedJobID == jobID {
            selectedJobID = jobs.last?.id
        }
    }

    func clearAppLog() {
        appLogText = ""
    }

    private func appendAppLog(_ text: String) {
        appLogText += text
        let maxLength = 200_000
        if appLogText.count > maxLength {
            appLogText = String(appLogText.suffix(maxLength))
        }
    }

    private static let logTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    private func timestamp() -> String {
        Self.logTimeFormatter.string(from: Date())
    }

    private func appendLog(_ text: String, to jobID: UUID) {
        guard let index = jobs.firstIndex(where: { $0.id == jobID }) else { return }

        jobs[index].logText += text
        let maxLength = 80_000
        if jobs[index].logText.count > maxLength {
            jobs[index].logText = String(jobs[index].logText.suffix(maxLength))
        }
        persistGUIRecord(jobID)
    }

    private func updateActivity(_ text: String, for jobID: UUID) {
        guard let index = jobs.firstIndex(where: { $0.id == jobID }) else { return }

        jobs[index].activityText = text
        persistGUIRecord(jobID, force: true)
    }

    private func preferredDestinationID(currentID: String?) -> String? {
        if let currentID,
           displayedDestinations.contains(where: { $0.id == currentID }) {
            return currentID
        }

        return displayedDestinations.first?.id
    }

    private func saveConfiguredDirectoryPaths() {
        UserDefaults.standard.set(configuredDirectoryPaths, forKey: configuredDirectoryPathsKey)
    }

    private func saveFavoriteSimulatorDestinationIDs() {
        UserDefaults.standard.set(
            Array(favoriteSimulatorDestinationIDs).sorted(),
            forKey: favoriteSimulatorDestinationIDsKey
        )
    }
}
