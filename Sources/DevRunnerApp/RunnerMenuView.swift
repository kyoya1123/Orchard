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
                    context
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
        .alert(item: $model.destinationConflictAlert) { alert in
            Alert(
                title: Text("Destination is already running"),
                message: Text("\(alert.destinationName) is currently used by \(alert.existingJobTitle). Stop it and start the new run?"),
                primaryButton: .destructive(Text("Stop Previous & Run")) {
                    model.confirmReplaceDestinationRun()
                },
                secondaryButton: .cancel {
                    model.cancelReplaceDestinationRun()
                }
            )
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

    private var context: some View {
        VStack(alignment: .leading, spacing: 8) {
            LabeledContent("Directory", value: model.selectedWorktree?.worktreeURL.path ?? "Not resolved")
            LabeledContent("Branch", value: model.selectedWorktree?.branchName ?? "Not resolved")
            LabeledContent("Project", value: model.project?.displayName ?? "Not found")
            LabeledContent("Status", value: model.status)
        }
        .font(.caption)
        .textSelection(.enabled)
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Project", selection: $model.selectedWorktreeID) {
                Text("Select").tag(String?.none)
                ForEach(model.worktrees) { worktree in
                    Text("\(worktree.displayName) — \(worktree.detail)")
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

                Button {
                    model.stopSelectedJob()
                } label: {
                    Label("Stop", systemImage: "stop.fill")
                }
                .disabled(!model.canStopSelectedJob)
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
                Picker("Run", selection: $model.selectedJobID) {
                    ForEach(model.jobs) { job in
                        Text(job.displayName).tag(Optional(job.id))
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
