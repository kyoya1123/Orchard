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
                    Text(worktree.displayName)
                        .tag(Optional(worktree.id))
                }
            }

            Picker("Scheme", selection: $model.selectedScheme) {
                Text("Select").tag(String?.none)
                ForEach(model.schemes, id: \.self) { scheme in
                    Text(scheme).tag(Optional(scheme))
                }
            }

            Picker("Destination", selection: $model.selectedDestinationID) {
                Text("Select").tag(String?.none)
                ForEach(model.destinations) { destination in
                    Text(destination.displayName).tag(Optional(destination.id))
                }
            }

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

                    Button {
                        model.stopSelectedJob()
                    } label: {
                        Image(systemName: "stop.fill")
                    }
                    .buttonStyle(.borderless)
                    .disabled(!model.canStopSelectedJob)
                    .help("Stop")

                    Button {
                        model.rerunSelectedJob()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                    .disabled(!model.canRerunSelectedJob)
                    .help("Rerun")

                    Button {
                        model.closeSelectedJob()
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(.borderless)
                    .disabled(!model.canCloseSelectedJob)
                    .help("Close")
                }

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(model.jobs) { job in
                            Button {
                                model.selectedJobID = job.id
                            } label: {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(job.tabTitle)
                                        .font(.caption)
                                        .lineLimit(1)

                                    Text(job.worktreeDisplayName)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                .frame(width: 172, alignment: .leading)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 6)
                                .background(tabBackground(for: job))
                                .overlay {
                                    RoundedRectangle(cornerRadius: 7)
                                        .stroke(tabBorderColor(for: job), lineWidth: 1)
                                }
                                .clipShape(RoundedRectangle(cornerRadius: 7))
                            }
                            .buttonStyle(.plain)
                            .help(job.displayName)
                        }
                    }
                }
            }
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
