import DevRunnerCore
import AppKit
import SwiftUI

struct RunnerMenuView: View {
    @ObservedObject var model: RunnerViewModel
    @State private var isSettingsPresented = false
    @State private var isConsolePresented = false
    @State private var expandedProjectIDs: Set<String> = []
    @State private var logSearchText = ""
    @State private var consoleSearchText = ""

    private let jobCardWidth: CGFloat = 206

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

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(model.jobGroups) { group in
                            jobGroupView(group)
                        }
                    }
                    .padding(.vertical, 2)
                    .animation(.easeOut(duration: 0.18), value: expandedProjectIDs)
                }
            }
        }
    }

    @ViewBuilder
    private func jobGroupView(_ group: RunJobGroup) -> some View {
        if group.jobs.count == 1 {
            jobCard(group.jobs[0], group: nil)
        } else if expandedProjectIDs.contains(group.id) {
            HStack(spacing: 6) {
                ForEach(group.jobs) { job in
                    jobCard(job, group: group)
                }

                collapseButton(for: group)
            }
            // Hug the cards' height; otherwise the infinity-height collapse
            // button stretches the group to the scroll view's full height.
            .fixedSize(horizontal: false, vertical: true)
            .padding(3)
            .background(
                RoundedRectangle(cornerRadius: 9)
                    .fill(Color.primary.opacity(0.05))
            )
        } else {
            collapsedJobStack(group)
        }
    }

    private func collapsedJobStack(_ group: RunJobGroup) -> some View {
        let front = frontJob(in: group)
        let back = backJobs(in: group).prefix(2)

        return ZStack(alignment: .leading) {
            ForEach(Array(back.enumerated().reversed()), id: \.element.id) { index, job in
                let depth = CGFloat(index + 1)

                jobCard(job, group: nil)
                    // Dim the card while keeping it opaque so the front card
                    // never shows back-card content through itself.
                    .overlay(
                        RoundedRectangle(cornerRadius: 7)
                            .fill(Color(nsColor: .windowBackgroundColor).opacity(0.6))
                    )
                    .scaleEffect(x: 1, y: 1 - depth * 0.08, anchor: .center)
                    .offset(x: depth * 9)
                    .allowsHitTesting(false)
            }

            jobCard(front, group: group) {
                expandedProjectIDs.insert(group.id)
                model.selectedJobID = front.id
            }
            .shadow(color: .black.opacity(0.3), radius: 3, x: 2, y: 0)
        }
        .padding(.trailing, CGFloat(back.count) * 9)
    }

    private func collapseButton(for group: RunJobGroup) -> some View {
        Button {
            expandedProjectIDs.remove(group.id)
        } label: {
            Image(systemName: "chevron.compact.left")
                .font(.title3)
                .foregroundStyle(.secondary)
                .frame(width: 16)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help("Collapse runs for this project")
    }

    private func frontJob(in group: RunJobGroup) -> RunJob {
        if let selected = model.selectedJob,
           group.jobs.contains(where: { $0.id == selected.id }) {
            return selected
        }

        return group.jobs.last ?? group.jobs[0]
    }

    private func backJobs(in group: RunJobGroup) -> [RunJob] {
        let frontID = frontJob(in: group).id
        return group.jobs.filter { $0.id != frontID }
    }

    private func jobCard(
        _ job: RunJob,
        group: RunJobGroup?,
        onTap: (() -> Void)? = nil
    ) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Text(job.tabTitle)
                    .font(.caption)
                    .lineLimit(1)

                if job.source == .cli {
                    Image(systemName: "terminal")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .help("CLI から実行")
                }

                Spacer()

                if let group {
                    stackBadge(for: group)
                }

                jobActions(for: job)
            }

            Text(job.tabSubtitle)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            jobStatusRow(for: job)
        }
        .frame(width: jobCardWidth, alignment: .leading)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            // Opaque base first: the tint colors are translucent and would
            // otherwise let stacked cards show through in the vibrant window.
            ZStack {
                RoundedRectangle(cornerRadius: 7)
                    .fill(Color(nsColor: .windowBackgroundColor))

                RoundedRectangle(cornerRadius: 7)
                    .fill(tabBackground(for: job))
            }
        )
        .overlay {
            RoundedRectangle(cornerRadius: 7)
                .stroke(tabBorderColor(for: job), lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .contentShape(RoundedRectangle(cornerRadius: 7))
        .onTapGesture {
            if let onTap {
                onTap()
            } else {
                model.selectedJobID = job.id
            }
        }
        .help(job.displayName)
    }

    private func stackBadge(for group: RunJobGroup) -> some View {
        let isExpanded = expandedProjectIDs.contains(group.id)

        return Button {
            if isExpanded {
                expandedProjectIDs.remove(group.id)
            } else {
                expandedProjectIDs.insert(group.id)
            }
        } label: {
            HStack(spacing: 2) {
                Image(systemName: "square.stack")
                Text("\(group.jobs.count)")
            }
            .font(.caption2)
        }
        .buttonStyle(.borderless)
        .help(isExpanded ? "Collapse runs for this project" : "Expand runs for this project")
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
            .disabled(job.source == .cli)
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
