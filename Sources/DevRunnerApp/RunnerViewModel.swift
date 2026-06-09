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
        "\(statusIcon) \(destination.name) · \(scheme)"
    }
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

    private struct RunRequest {
        let replacingJobID: UUID?
        let worktreeDisplayName: String
        let project: XcodeProject
        let scheme: String
        let destination: XcodeDestination
    }

    private let configuredDirectoryPathsKey = "configuredDirectoryPaths"
    private let worktreeContextResolver = WorktreeContextResolver()
    private let xcodeService = XcodeService()
    private var runServices: [UUID: BuildRunService] = [:]

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
            replacingJobID: nil,
            worktreeDisplayName: selectedWorktree.displayName,
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

        let request = RunRequest(
            replacingJobID: selectedJob.id,
            worktreeDisplayName: selectedJob.worktreeDisplayName,
            project: selectedJob.project,
            scheme: selectedJob.scheme,
            destination: selectedJob.destination
        )

        Task {
            if selectedJob.isRunning {
                await stop(jobID: selectedJob.id)
            }
            await startRunReplacingDestination(request)
        }
    }

    func stopSelectedJob() {
        guard let selectedJob else { return }
        Task { await stop(jobID: selectedJob.id) }
    }

    func closeSelectedJob() {
        guard let selectedJob else { return }

        if selectedJob.isRunning {
            Task {
                await stop(jobID: selectedJob.id)
                removeJob(jobID: selectedJob.id)
            }
        } else {
            removeJob(jobID: selectedJob.id)
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

        let loadedSchemes = try await xcodeService.schemes(project: selectedWorktree.project)
        schemes = loadedSchemes
        selectedScheme = selectedScheme.flatMap { loadedSchemes.contains($0) ? $0 : nil } ?? loadedSchemes.first
    }

    private func startRun(_ request: RunRequest) {
        let jobID = request.replacingJobID ?? UUID()

        let service = BuildRunService()
        if let index = jobs.firstIndex(where: { $0.id == jobID }) {
            jobs[index].status = .running
            jobs[index].logText = ""
        } else {
            let job = RunJob(
                id: jobID,
                worktreeDisplayName: request.worktreeDisplayName,
                project: request.project,
                scheme: request.scheme,
                destination: request.destination,
                startedAt: Date(),
                status: .running,
                logText: ""
            )
            jobs.append(job)
        }
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

                if jobs.first(where: { $0.id == jobID })?.status == .running {
                    finish(jobID: jobID, status: .completed, message: "")
                }
            } catch {
                let currentStatus = jobs.first { $0.id == jobID }?.status
                if currentStatus != .stopped {
                    finish(jobID: jobID, status: .failed, message: "")
                }
            }
        }
    }

    private func startRunReplacingDestination(_ request: RunRequest) async {
        let replacingJobID = request.replacingJobID
        let replacedJobs = jobs.filter {
            $0.destination.id == request.destination.id && $0.id != replacingJobID
        }

        for job in replacedJobs {
            if job.isRunning {
                await stop(jobID: job.id)
            }
            removeJob(jobID: job.id)
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
            status = jobs.contains { $0.isRunning } ? "Running" : RunJobStatus.stopped.label
        }

        await service.stopCompletely(destination: job.destination) { _ in }
        runServices[jobID] = nil
    }

    private func finish(jobID: UUID, status: RunJobStatus, message: String) {
        guard let index = jobs.firstIndex(where: { $0.id == jobID }) else { return }

        jobs[index].status = status
        if !message.isEmpty {
            appendLog(message, to: jobID)
        }
        runServices[jobID] = nil
        self.status = jobs.contains { $0.isRunning } ? "Running" : status.label
    }

    private func removeJob(jobID: UUID) {
        jobs.removeAll { $0.id == jobID }
        runServices[jobID] = nil

        if selectedJobID == jobID {
            selectedJobID = jobs.last?.id
        }
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
