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

struct RunJob: Identifiable {
    let id: UUID
    let worktreeDisplayName: String
    let project: XcodeProject
    let scheme: String
    let destination: XcodeDestination
    let startedAt: Date
    var status: RunJobStatus
    var logText: String

    var title: String {
        "\(worktreeDisplayName) · \(scheme)"
    }

    var displayName: String {
        "\(status.label) · \(destination.name) · \(scheme)"
    }

    var isRunning: Bool {
        status == .running
    }
}

struct DestinationConflictAlert: Identifiable {
    let id = UUID()
    let existingJobID: UUID
    let destinationName: String
    let existingJobTitle: String
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
    @Published var status = "Idle"
    @Published var jobs: [RunJob] = []
    @Published var selectedJobID: UUID?
    @Published var destinationConflictAlert: DestinationConflictAlert?

    private struct RunRequest {
        let worktreeDisplayName: String
        let project: XcodeProject
        let scheme: String
        let destination: XcodeDestination
    }

    private let configuredDirectoryPathsKey = "configuredDirectoryPaths"
    private let worktreeContextResolver = WorktreeContextResolver()
    private let xcodeService = XcodeService()
    private var runServices: [UUID: BuildRunService] = [:]
    private var pendingRunRequest: RunRequest?

    init() {
        configuredDirectoryPaths = UserDefaults.standard.stringArray(forKey: configuredDirectoryPathsKey) ?? []
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

    var selectedJob: RunJob? {
        guard let selectedJobID else { return jobs.last }
        return jobs.first { $0.id == selectedJobID }
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

    func removeConfiguredDirectory(at offsets: IndexSet) {
        configuredDirectoryPaths.remove(atOffsets: offsets)
        saveConfiguredDirectoryPaths()
    }

    func refresh() async {
        status = "Refreshing"

        do {
            let configuredDirectoryURLs = configuredDirectoryURLs
            async let resolvedWorktrees = worktreeContextResolver.resolve(
                fromConfiguredDirectoryURLs: configuredDirectoryURLs
            )
            async let loadedDestinations = xcodeService.destinations()

            worktrees = await resolvedWorktrees
            destinations = try await loadedDestinations
            selectedWorktreeID = selectedWorktreeID.flatMap { id in
                worktrees.contains { $0.id == id } ? id : nil
            } ?? worktrees.first?.id
            selectedDestinationID = selectedDestinationID.flatMap { id in
                destinations.contains { $0.id == id } ? id : nil
            } ?? destinations.first?.id

            try await reloadSchemesForSelectedWorktree()
            if configuredDirectoryPaths.isEmpty {
                status = "Add a directory to scan"
            } else {
                status = worktrees.isEmpty ? "No Xcode worktrees found" : "Ready"
            }
        } catch {
            status = error.localizedDescription
            appendLogToSelectedJob("Refresh failed: \(error.localizedDescription)\n")
        }
    }

    func worktreeSelectionChanged() async {
        do {
            status = "Loading schemes"
            try await reloadSchemesForSelectedWorktree()
            status = "Ready"
        } catch {
            status = error.localizedDescription
            appendLogToSelectedJob("Scheme load failed: \(error.localizedDescription)\n")
        }
    }

    func buildAndRun() {
        guard let selectedWorktree, let selectedScheme, let selectedDestination else { return }

        let request = RunRequest(
            worktreeDisplayName: selectedWorktree.displayName,
            project: selectedWorktree.project,
            scheme: selectedScheme,
            destination: selectedDestination
        )

        if let existingJob = jobs.first(where: { $0.isRunning && $0.destination.id == selectedDestination.id }) {
            pendingRunRequest = request
            destinationConflictAlert = DestinationConflictAlert(
                existingJobID: existingJob.id,
                destinationName: existingJob.destination.displayName,
                existingJobTitle: existingJob.title
            )
            return
        }

        startRun(request)
    }

    func confirmReplaceDestinationRun() {
        guard let pendingRunRequest,
              let alert = destinationConflictAlert else {
            return
        }

        self.pendingRunRequest = nil
        destinationConflictAlert = nil

        Task {
            await stop(jobID: alert.existingJobID)
            startRun(pendingRunRequest)
        }
    }

    func cancelReplaceDestinationRun() {
        pendingRunRequest = nil
        destinationConflictAlert = nil
    }

    func stopSelectedJob() {
        guard let selectedJob else { return }
        Task { await stop(jobID: selectedJob.id) }
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

        let loadedSchemes = try await xcodeService.schemes(project: selectedWorktree.project)
        schemes = loadedSchemes
        selectedScheme = selectedScheme.flatMap { loadedSchemes.contains($0) ? $0 : nil } ?? loadedSchemes.first
    }

    private func startRun(_ request: RunRequest) {
        let jobID = UUID()
        let job = RunJob(
            id: jobID,
            worktreeDisplayName: request.worktreeDisplayName,
            project: request.project,
            scheme: request.scheme,
            destination: request.destination,
            startedAt: Date(),
            status: .running,
            logText: "\n=== Build & Run: \(request.worktreeDisplayName), \(request.scheme) on \(request.destination.displayName) ===\n"
        )

        let service = BuildRunService()
        jobs.append(job)
        selectedJobID = jobID
        runServices[jobID] = service
        status = "Running"

        Task {
            do {
                try await service.buildAndRun(
                    project: request.project,
                    scheme: request.scheme,
                    destination: request.destination
                ) { [weak self] text in
                    Task { @MainActor in
                        self?.appendLog(text, to: jobID)
                    }
                }

                appendLog("\nLaunched. Use Stop to terminate the app.\n", to: jobID)
            } catch {
                let currentStatus = jobs.first { $0.id == jobID }?.status
                if currentStatus != .stopped {
                    finish(jobID: jobID, status: .failed, message: "\nFailed: \(error.localizedDescription)\n")
                }
            }
        }
    }

    private func stop(jobID: UUID) async {
        guard let service = runServices[jobID],
              let job = jobs.first(where: { $0.id == jobID }) else {
            return
        }

        await service.stopCompletely(destination: job.destination) { [weak self] text in
            Task { @MainActor in
                self?.appendLog(text, to: jobID)
            }
        }
        finish(jobID: jobID, status: .stopped, message: "\nStopped.\n")
    }

    private func finish(jobID: UUID, status: RunJobStatus, message: String) {
        guard let index = jobs.firstIndex(where: { $0.id == jobID }) else { return }

        jobs[index].status = status
        appendLog(message, to: jobID)
        runServices[jobID] = nil
        self.status = jobs.contains { $0.isRunning } ? "Running" : status.label
    }

    private func appendLogToSelectedJob(_ text: String) {
        guard let jobID = selectedJob?.id else { return }
        appendLog(text, to: jobID)
    }

    private func appendLog(_ text: String, to jobID: UUID) {
        guard let index = jobs.firstIndex(where: { $0.id == jobID }) else { return }

        jobs[index].logText += text
        let maxLength = 80_000
        if jobs[index].logText.count > maxLength {
            jobs[index].logText = String(jobs[index].logText.suffix(maxLength))
        }
    }

    private func saveConfiguredDirectoryPaths() {
        UserDefaults.standard.set(configuredDirectoryPaths, forKey: configuredDirectoryPathsKey)
    }
}
