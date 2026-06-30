import DevRunnerCore
import AppKit
import SwiftUI

struct RunnerMenuView: View {
    @ObservedObject var model: RunnerViewModel
    @State private var isSettingsPresented = false
    @State private var isConsolePresented = false
    // Worktree sections are expanded by default; this tracks the ones the user
    // collapsed.
    @State private var collapsedProjectIDs: Set<String> = []
    @State private var logSearchText = ""
    @State private var consoleSearchText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if isSettingsPresented {
                settingsHeader
                Divider()
                settingsView
            } else if isConsolePresented {
                consoleHeader
                Divider()
                consoleView
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
        .onAppear {
            // Only mirror CLI runs while the menu is open; no idle polling.
            model.startCLISync()
        }
        .onDisappear {
            model.stopCLISync()
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
                isConsolePresented = true
            } label: {
                Image(systemName: "terminal")
            }
            .buttonStyle(.borderless)
            .help("Console (DevRunner and build command output)")

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

    private var consoleHeader: some View {
        HStack {
            Label("Console", systemImage: "terminal")
                .font(.headline)
            Spacer()
            Button {
                isConsolePresented = false
            } label: {
                Image(systemName: "checkmark")
            }
            .buttonStyle(.borderless)
            .help("Done")
        }
    }

    private var consoleView: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("DevRunner events and build/install command output")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Spacer()

                Button {
                    copyToPasteboard(model.appLogText)
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }
                .disabled(model.appLogText.isEmpty)

                Button {
                    model.clearAppLog()
                } label: {
                    Label("Clear", systemImage: "trash")
                }
                .disabled(model.appLogText.isEmpty)
            }

            searchField(text: $consoleSearchText, matchCount: consoleMatchingLines.count)

            ScrollView {
                Text(displayedText(for: model.appLogText, query: consoleSearchText))
                    .font(.system(.caption, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .frame(maxHeight: .infinity)
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }

    private var consoleMatchingLines: [Substring] {
        matchingLines(of: model.appLogText, query: consoleSearchText)
    }

    // MARK: - Controls

    private var controls: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(spacing: 0) {
                projectRow
                configRowDivider
                schemeRow
                configRowDivider
                destinationRow
            }
            .background(
                RoundedRectangle(cornerRadius: 9)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 9)
                    .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
            )

            Button {
                model.buildAndRun()
            } label: {
                Label("Build & Run", systemImage: "play.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!model.canBuildAndRun)
        }
    }

    private var configRowDivider: some View {
        Divider()
            .padding(.leading, 40)
    }

    private var projectRow: some View {
        configRow(
            icon: "arrow.triangle.branch",
            title: "Project",
            value: model.selectedWorktree?.branchName ?? "Select",
            isPlaceholder: model.selectedWorktree == nil,
            isLoading: model.isRefreshing
        ) {
            ForEach(model.worktrees) { worktree in
                Button {
                    model.selectedWorktreeID = worktree.id
                } label: {
                    Label(
                        worktree.branchName,
                        systemImage: model.selectedWorktreeID == worktree.id
                            ? "checkmark"
                            : "arrow.triangle.branch"
                    )
                }
            }
        }
    }

    private var schemeRow: some View {
        configRow(
            icon: "target",
            title: "Scheme",
            value: model.selectedScheme ?? "Select",
            isPlaceholder: model.selectedScheme == nil,
            isLoading: model.isRefreshing || model.isLoadingSchemes
        ) {
            ForEach(model.schemes, id: \.self) { scheme in
                Button {
                    model.selectedScheme = scheme
                } label: {
                    Label(
                        scheme,
                        systemImage: model.selectedScheme == scheme ? "checkmark" : "target"
                    )
                }
            }
        }
    }

    private var destinationRow: some View {
        configRow(
            icon: model.selectedDestination?.symbolName ?? "iphone",
            title: "Destination",
            value: model.selectedDestination?.displayName ?? "Select",
            isPlaceholder: model.selectedDestination == nil,
            isLoading: model.isRefreshing
        ) {
            if !model.deviceDestinations.isEmpty {
                Section("Devices") {
                    ForEach(model.deviceDestinations) { destination in
                        destinationButton(destination, systemImage: destination.symbolName)
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

            if !model.otherSimulatorDestinations.isEmpty {
                Section("More Simulators") {
                    ForEach(model.otherSimulatorDestinations) { destination in
                        destinationButton(destination, systemImage: "macwindow")
                    }
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
        }
    }

    private func configRow<Items: View>(
        icon: String,
        title: String,
        value: String,
        isPlaceholder: Bool,
        isLoading: Bool = false,
        @ViewBuilder items: () -> Items
    ) -> some View {
        Menu {
            items()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(width: 20)

                Text(title)
                    .foregroundStyle(.secondary)
                    .frame(width: 82, alignment: .leading)

                Spacer(minLength: 8)

                if isLoading {
                    ProgressView()
                        .controlSize(.small)

                    Text("Loading…")
                        .foregroundStyle(.secondary)
                } else {
                    Text(value)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(isPlaceholder ? Color.secondary : Color.primary)
                }

                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .disabled(isLoading)
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

            Text("Add a repository or parent directory in Settings to discover projects and worktrees.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Button {
                isSettingsPresented = true
            } label: {
                Label("Open Settings", systemImage: "gearshape")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }

    // MARK: - Settings

    private var settingsView: some View {
        VStack(alignment: .leading, spacing: 12) {
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
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(model.configuredDirectoryPaths, id: \.self) { path in
                            HStack(spacing: 8) {
                                Image(systemName: "folder")
                                    .foregroundStyle(.secondary)

                                Text(path)
                                    .font(.caption)
                                    .lineLimit(1)
                                    .truncationMode(.middle)

                                Spacer(minLength: 8)

                                Button {
                                    model.removeConfiguredDirectory(path)
                                    Task { await model.refresh() }
                                } label: {
                                    Image(systemName: "trash")
                                        .foregroundStyle(.red)
                                }
                                .buttonStyle(.borderless)
                                .help("Remove this directory")
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 7)

                            if path != model.configuredDirectoryPaths.last {
                                Divider()
                                    .padding(.leading, 10)
                            }
                        }
                    }
                }
                .frame(maxHeight: 180)
                .background(
                    RoundedRectangle(cornerRadius: 9)
                        .fill(Color(nsColor: .controlBackgroundColor))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 9)
                        .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
                )
            }

            Divider()

            Text("Global Shortcut")
                .font(.headline)

            HStack(spacing: 8) {
                ShortcutRecorderField(hotKey: model.globalHotKey) { hotKey in
                    model.setGlobalHotKey(hotKey)
                }

                if model.globalHotKey != nil {
                    Button("Clear") {
                        model.setGlobalHotKey(nil)
                    }
                }
            }

            Text("Opens the DevRunner window from any app.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Jobs

    private var jobsView: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !model.jobs.isEmpty {
                HStack {
                    Text("Runs")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Spacer()
                }

                ScrollView(.vertical, showsIndicators: true) {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(model.jobGroups) { group in
                            worktreeSection(group)
                        }
                    }
                    .padding(.vertical, 2)
                    .animation(.easeOut(duration: 0.15), value: collapsedProjectIDs)
                }
                .frame(maxHeight: 260)
            }
        }
    }

    private func worktreeSection(_ group: RunJobGroup) -> some View {
        let collapsed = collapsedProjectIDs.contains(group.id)
        let accent = accentColor(for: group)

        return VStack(alignment: .leading, spacing: 0) {
            sectionHeader(group, collapsed: collapsed, accent: accent)

            if !collapsed {
                ForEach(group.jobs) { job in
                    jobRow(job, accent: accent)
                }
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.primary.opacity(0.04))
        )
        .overlay(alignment: .leading) {
            // Per-worktree accent stripe so groups are visually distinct.
            RoundedRectangle(cornerRadius: 1.5)
                .fill(accent)
                .frame(width: 3)
                .padding(.vertical, 5)
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func sectionHeader(_ group: RunJobGroup, collapsed: Bool, accent: Color) -> some View {
        let rep = group.jobs[0]

        return HStack(spacing: 6) {
            Button {
                toggleCollapse(group.id)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: collapsed ? "chevron.right" : "chevron.down")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .frame(width: 10)

                    VStack(alignment: .leading, spacing: 1) {
                        Text(rep.branchName)
                            .font(.caption.weight(.semibold))
                            .lineLimit(1)

                        Text(rep.project.rootURL.lastPathComponent)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if collapsed {
                aggregateBadge(group)
            }

            runOnDestinationMenu(for: rep)
        }
        .padding(.leading, 10)
        .padding(.trailing, 8)
        .padding(.vertical, 6)
    }

    /// Per-worktree action: pick a destination and run the same worktree/scheme
    /// on it. Replaces any run already on the chosen destination.
    private func runOnDestinationMenu(for job: RunJob) -> some View {
        Menu {
            if model.destinations.isEmpty {
                Text("No destinations")
            } else {
                ForEach(model.destinations) { destination in
                    Button {
                        model.runOnDestination(like: job, destination: destination)
                    } label: {
                        Label(destination.displayName, systemImage: destination.symbolName)
                    }
                }
            }
        } label: {
            Image(systemName: "plus.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("同じ worktree を別の destination で実行")
    }

    private func aggregateBadge(_ group: RunJobGroup) -> some View {
        let status = aggregateStatus(group)
        return HStack(spacing: 4) {
            Image(systemName: statusIcon(for: status))
                .foregroundStyle(statusColor(for: status))
            Text("\(group.jobs.count)")
                .foregroundStyle(.secondary)
        }
        .font(.caption2)
    }

    private func jobRow(_ job: RunJob, accent: Color) -> some View {
        let selected = model.selectedJob?.id == job.id

        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Image(systemName: statusIcon(for: job.status))
                    .foregroundStyle(statusColor(for: job.status))
                    .font(.caption)

                Text("\(job.scheme)  ·  \(job.destination.name)")
                    .font(.caption)
                    .lineLimit(1)

                if job.source == .cli {
                    Image(systemName: "terminal")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .help("CLI から実行")
                }

                Spacer()

                jobActions(for: job)
            }

            HStack(spacing: 5) {
                if job.isRunning {
                    ProgressView().controlSize(.small)
                }
                Text(rowSubtitle(job))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.leading, 12)
        .padding(.trailing, 8)
        .padding(.vertical, 5)
        .background(selected ? accent.opacity(0.16) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture { model.selectedJobID = job.id }
        .help(job.displayName)
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

    private func toggleCollapse(_ id: String) {
        if collapsedProjectIDs.contains(id) {
            collapsedProjectIDs.remove(id)
        } else {
            collapsedProjectIDs.insert(id)
        }
    }

    private func rowSubtitle(_ job: RunJob) -> String {
        if job.isRunning {
            return job.activityText.isEmpty ? "Running" : job.activityText
        }
        return job.status.label
    }

    /// Stable color per worktree, derived from its project path (a deterministic
    /// hash, since Swift's `hashValue` is randomized per launch).
    private func accentColor(for group: RunJobGroup) -> Color {
        let key = group.jobs[0].project.fileURL.path
        var hash: UInt64 = 5381
        for byte in key.utf8 {
            hash = (hash &* 33) &+ UInt64(byte)
        }
        return Color(hue: Double(hash % 360) / 360.0, saturation: 0.6, brightness: 0.85)
    }

    private func aggregateStatus(_ group: RunJobGroup) -> RunJobStatus {
        if group.jobs.contains(where: { $0.status == .running }) { return .running }
        if group.jobs.contains(where: { $0.status == .failed }) { return .failed }
        if group.jobs.contains(where: { $0.status == .stopped }) { return .stopped }
        return .completed
    }

    private func statusIcon(for status: RunJobStatus) -> String {
        switch status {
        case .running: "circle.fill"
        case .completed: "checkmark.circle.fill"
        case .failed: "exclamationmark.circle.fill"
        case .stopped: "stop.circle.fill"
        }
    }

    private func statusColor(for status: RunJobStatus) -> Color {
        switch status {
        case .running: .blue
        case .completed: .green
        case .failed: .red
        case .stopped: .secondary
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
                    copyToPasteboard(model.logText)
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

            searchField(text: $logSearchText, matchCount: logMatchingLines.count)

            ScrollView {
                Text(displayedText(for: model.logText, query: logSearchText))
                    .font(.system(.caption, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .frame(maxHeight: .infinity)
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }

    private var logMatchingLines: [Substring] {
        matchingLines(of: model.logText, query: logSearchText)
    }

    private func searchField(text: Binding<String>, matchCount: Int) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.caption)
                .foregroundStyle(.secondary)

            TextField("Search log", text: text)
                .textFieldStyle(.plain)
                .font(.caption)

            if !text.wrappedValue.isEmpty {
                Text("\(matchCount) lines")
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                Button {
                    text.wrappedValue = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help("Clear search")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
        )
    }

    private func matchingLines(of text: String, query: String) -> [Substring] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return [] }

        return text
            .split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
            .filter { $0.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
    }

    private func displayedText(for text: String, query: String) -> String {
        if text.isEmpty {
            return "No logs yet."
        }

        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return text
        }

        let lines = matchingLines(of: text, query: query)
        return lines.isEmpty ? "No matches." : lines.joined(separator: "\n")
    }

    private func copyToPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
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
