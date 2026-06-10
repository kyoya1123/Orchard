import DevRunnerCore
import AppKit
import SwiftUI

struct RunnerMenuView: View {
    @ObservedObject var model: RunnerViewModel
    @State private var isSettingsPresented = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if isSettingsPresented {
                settingsHeader
                Divider()
                settingsView
            } else {
                header
                Divider()
                if model.configuredDirectoryPaths.isEmpty {
                    emptyDirectoriesView
                } else {
                    controls
                    Divider()
                    jobsView
                    logView
                }
            }
        }
        .padding(16)
        .task {
            await model.refresh()
        }
        .onChange(of: model.selectedWorktreeID) { _, _ in
            Task { await model.worktreeSelectionChanged() }
        }
    }

    private var header: some View {
        HStack {
            Label("DevRunner", systemImage: "play.circle")
                .font(.headline)
            Spacer()
            Button {
                isSettingsPresented = true
            } label: {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.borderless)
            .help("Settings")

            Button {
                Task { await model.refresh() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help("Refresh")
        }
    }

    private var settingsHeader: some View {
        HStack {
            Label("Settings", systemImage: "gearshape")
                .font(.headline)
            Spacer()
            Button {
                isSettingsPresented = false
            } label: {
                Image(systemName: "checkmark")
            }
            .buttonStyle(.borderless)
            .help("Done")
        }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Project", selection: $model.selectedWorktreeID) {
                Text("Select").tag(String?.none)
                ForEach(model.worktrees) { worktree in
                    Text(worktree.branchName)
                        .tag(Optional(worktree.id))
                }
            }

            Picker("Scheme", selection: $model.selectedScheme) {
                Text("Select").tag(String?.none)
                ForEach(model.schemes, id: \.self) { scheme in
                    Text(scheme).tag(Optional(scheme))
                }
            }

            destinationMenu

            HStack {
                Button {
                    model.buildAndRun()
                } label: {
                    Label("Build & Run", systemImage: "play.fill")
                }
                .disabled(!model.canBuildAndRun)
            }
        }
    }

    private var destinationMenu: some View {
        HStack {
            Text("Destination")
                .frame(width: 76, alignment: .leading)

            Menu {
                if !model.deviceDestinations.isEmpty {
                    Section("Devices") {
                        ForEach(model.deviceDestinations) { destination in
                            destinationButton(destination, systemImage: "iphone")
                        }
                    }
                }

                if !model.favoriteSimulatorDestinations.isEmpty {
                    Section("Favorite Simulators") {
                        ForEach(model.favoriteSimulatorDestinations) { destination in
                            destinationButton(destination, systemImage: "star.fill")
                        }
                    }
                }

                if model.showsAllSimulators && !model.otherSimulatorDestinations.isEmpty {
                    Section("More Simulators") {
                        ForEach(model.otherSimulatorDestinations) { destination in
                            destinationButton(destination, systemImage: "macwindow")
                        }
                    }
                }

                if model.hiddenSimulatorCount > 0 || model.showsAllSimulators {
                    Divider()

                    Button {
                        model.toggleShowsAllSimulators()
                    } label: {
                        Label(
                            model.showsAllSimulators ? "Show Less Simulators" : "Show More Simulators",
                            systemImage: model.showsAllSimulators ? "chevron.up" : "chevron.down"
                        )
                    }
                }

                if model.canToggleSelectedSimulatorFavorite {
                    Divider()

                    Button {
                        model.toggleSelectedSimulatorFavorite()
                    } label: {
                        Label(
                            model.selectedSimulatorIsFavorite ? "Unfavorite Selected Simulator" : "Favorite Selected Simulator",
                            systemImage: model.selectedSimulatorIsFavorite ? "star.slash" : "star"
                        )
                    }
                }
            } label: {
                HStack {
                    Text(model.selectedDestinationTitle)
                        .lineLimit(1)
                    Spacer()
                    Image(systemName: "chevron.down")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
            }
        }
    }

    private func destinationButton(_ destination: XcodeDestination, systemImage: String) -> some View {
        Button {
            model.selectDestination(destination.id)
        } label: {
            Label(
                destination.displayName,
                systemImage: model.selectedDestinationID == destination.id ? "checkmark" : systemImage
            )
        }
    }

    private var emptyDirectoriesView: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("No Scan Directories", systemImage: "folder.badge.questionmark")
                .font(.headline)

            Text("Add a repository or parent directory to discover projects and worktrees.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Button {
                selectDirectory()
            } label: {
                Label("Add Directory", systemImage: "folder.badge.plus")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }

    private var settingsView: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Scan Directories")
                    .font(.headline)

                Spacer()

                Button {
                    selectDirectory()
                } label: {
                    Label("Add", systemImage: "folder.badge.plus")
                }
            }

            if model.configuredDirectoryPaths.isEmpty {
                Text("No directories configured.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                List {
                    ForEach(model.configuredDirectoryPaths, id: \.self) { path in
                        Text(path)
                            .font(.caption)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .onDelete { offsets in
                        model.removeConfiguredDirectory(at: offsets)
                        Task { await model.refresh() }
                    }
                }
            }
        }
    }

    private var jobsView: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !model.jobs.isEmpty {
                HStack {
                    Text("Runs")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Spacer()
                }

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(model.jobs) { job in
                            VStack(alignment: .leading, spacing: 5) {
                                HStack(spacing: 6) {
                                    Text(job.tabTitle)
                                        .font(.caption)
                                        .lineLimit(1)

                                    Spacer()

                                    jobActions(for: job)
                                }

                                Text(job.branchName)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)

                                jobStatusRow(for: job)
                            }
                            .frame(width: 206, alignment: .leading)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 6)
                            .background(tabBackground(for: job))
                            .overlay {
                                RoundedRectangle(cornerRadius: 7)
                                    .stroke(tabBorderColor(for: job), lineWidth: 1)
                            }
                            .clipShape(RoundedRectangle(cornerRadius: 7))
                            .contentShape(RoundedRectangle(cornerRadius: 7))
                            .onTapGesture {
                                model.selectedJobID = job.id
                            }
                            .help(job.displayName)
                        }
                    }
                }
            }
        }
    }

    private func jobActions(for job: RunJob) -> some View {
        HStack(spacing: 4) {
            Button {
                model.stopJob(job.id)
            } label: {
                Image(systemName: "stop.fill")
            }
            .buttonStyle(.borderless)
            .disabled(!job.isRunning)
            .help("Stop")

            Button {
                model.rerunJob(job.id)
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help("Rerun")

            Button {
                model.closeJob(job.id)
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .help("Close")
        }
    }

    @ViewBuilder
    private func jobStatusRow(for job: RunJob) -> some View {
        HStack(spacing: 5) {
            if job.isRunning && !job.activityText.isEmpty {
                ProgressView()
                    .controlSize(.small)

                Text(job.activityText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else {
                Image(systemName: jobStatusSystemImage(for: job))
                    .foregroundStyle(jobStatusColor(for: job))

                Text(jobStatusText(for: job))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(height: 14, alignment: .leading)
    }

    private func jobStatusText(for job: RunJob) -> String {
        switch job.status {
        case .running:
            "Succeeded"
        case .completed:
            "Completed"
        case .failed:
            "Failed"
        case .stopped:
            "Stopped"
        }
    }

    private func jobStatusSystemImage(for job: RunJob) -> String {
        switch job.status {
        case .running, .completed:
            "checkmark.circle"
        case .failed:
            "xmark.circle"
        case .stopped:
            "stop.circle"
        }
    }

    private func jobStatusColor(for job: RunJob) -> Color {
        switch job.status {
        case .running, .completed:
            .green
        case .failed:
            .red
        case .stopped:
            .secondary
        }
    }

    private var logView: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Log")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Spacer()

                Button {
                    copyLogToPasteboard()
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }
                .disabled(model.logText.isEmpty)

                Button {
                    model.clearLog()
                } label: {
                    Label("Clear", systemImage: "trash")
                }
                .disabled(model.logText.isEmpty)
            }

            ScrollView {
                Text(model.logText.isEmpty ? "No logs yet." : model.logText)
                    .font(.system(.caption, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .frame(maxHeight: .infinity)
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }

    private func copyLogToPasteboard() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(model.logText, forType: .string)
    }

    private func tabBackground(for job: RunJob) -> Color {
        if model.selectedJob?.id == job.id {
            return Color.accentColor.opacity(0.18)
        }

        return Color(nsColor: .controlBackgroundColor)
    }

    private func tabBorderColor(for job: RunJob) -> Color {
        if model.selectedJob?.id == job.id {
            return Color.accentColor.opacity(0.75)
        }

        return Color(nsColor: .separatorColor)
    }

    private func selectDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true

        if panel.runModal() == .OK {
            panel.urls.forEach(model.addConfiguredDirectory)
            Task { await model.refresh() }
        }
    }
}
