import Foundation

public final class BuildRunService: @unchecked Sendable {
    private let processRunner: ProcessRunner
    private var runningProcess: Process?
    private var launchedApp: RunnableApp?
    private var isStopping = false
    private var shouldStop = false

    public init(processRunner: ProcessRunner = ProcessRunner()) {
        self.processRunner = processRunner
    }

    public func stop() {
        isStopping = true
        shouldStop = true
        runningProcess?.terminate()
        runningProcess = nil
    }

    public func stopCompletely(
        destination: XcodeDestination,
        log: @Sendable @escaping (String) -> Void
    ) async {
        stop()

        guard let launchedApp else {
            log("\nNo launched app is recorded for this run.\n")
            return
        }

        do {
            switch destination.kind {
            case .device:
                try await terminateOnDevice(app: launchedApp, destination: destination, log: log)
            case .simulator:
                try await terminateOnSimulator(app: launchedApp, destination: destination, log: log)
            }
        } catch {
            log("\nStop app failed: \(error.localizedDescription)\n")
        }
    }

    /// - Parameter attachConsole: when `true` (default) the launch attaches to
    ///   the app's console and blocks until the app exits — the app's lifetime
    ///   is tied to this process. When `false`, the app is launched detached:
    ///   it keeps running independently and this method returns right after a
    ///   successful launch (no console output is captured).
    public func buildAndRun(
        project: XcodeProject,
        scheme: String,
        destination: XcodeDestination,
        attachConsole: Bool = true,
        progress: @Sendable @escaping (String) -> Void,
        consoleLog: @Sendable @escaping (String) -> Void,
        commandLog: @Sendable @escaping (String) -> Void = { _ in }
    ) async throws {
        shouldStop = false
        isStopping = false

        let slimTask = destination.kind == .simulator
            ? SimSlimService.slimTaskIfNeeded(udid: destination.id, log: commandLog)
            : nil

        let buildArguments = project.xcodebuildArguments + [
            "-scheme", scheme,
            "-destination", destination.xcodebuildDestination,
            "build"
        ]

        progress("Building")
        commandLog("$ xcodebuild \(buildArguments.joined(separator: " "))\n")
        try await runStreaming(
            executableURL: URL(fileURLWithPath: "/usr/bin/xcodebuild"),
            arguments: buildArguments,
            currentDirectoryURL: project.rootURL,
            log: commandLog
        )
        try throwIfStopped()

        progress("Resolving build product")
        let settings = try await XcodeService().buildSettings(
            project: project,
            scheme: scheme,
            destination: destination
        )
        try throwIfStopped()

        guard let app = settings.firstRunnableApp else {
            throw OrchardError.message("ビルド成果物の .app と bundle identifier を特定できませんでした。")
        }
        launchedApp = app

        switch destination.kind {
        case .device:
            try await installAndLaunchOnDevice(
                app: app,
                destination: destination,
                attachConsole: attachConsole,
                progress: progress,
                consoleLog: consoleLog,
                commandLog: commandLog
            )
        case .simulator:
            try await installAndLaunchOnSimulator(
                app: app,
                destination: destination,
                attachConsole: attachConsole,
                progress: progress,
                consoleLog: consoleLog,
                commandLog: commandLog,
                slimTask: slimTask
            )
        }
    }

    /// Xcode 27 replaced Simulator.app with Device Hub, which opens a window
    /// only for the device named in its URL. Older Xcodes still ship
    /// Simulator.app, which opens a window for every booted device.
    /// `-g` keeps the frontmost app focused. Failures are logged but not fatal,
    /// since the app still runs on the booted device.
    private func showSimulatorWindow(
        udid: String,
        commandLog: @Sendable @escaping (String) -> Void
    ) async {
        let openURL = URL(fileURLWithPath: "/usr/bin/open")
        var attempts: [[String]] = [["-g", "-a", "Simulator"]]
        if let developerDir = try? await ProcessRunner.run(
            executableURL: URL(fileURLWithPath: "/usr/bin/xcode-select"),
            arguments: ["-p"],
            currentDirectoryURL: nil
        ) {
            // Resolved from the selected Xcode rather than by bundle id, so a
            // second installed Xcode's Device Hub isn't picked by LaunchServices.
            let deviceHub = URL(fileURLWithPath: developerDir)
                .deletingLastPathComponent()
                .appendingPathComponent("Applications/DeviceHub.app")
            if FileManager.default.fileExists(atPath: deviceHub.path) {
                attempts.insert(["-g", "-a", deviceHub.path, "devices://device/open?id=\(udid)"], at: 0)
            }
        }

        for arguments in attempts {
            commandLog("$ open \(arguments.joined(separator: " "))\n")
            do {
                _ = try await ProcessRunner.run(executableURL: openURL, arguments: arguments, currentDirectoryURL: nil)
                return
            } catch {
                commandLog("\(error.localizedDescription)\n")
            }
        }
    }

    private func installAndLaunchOnSimulator(
        app: RunnableApp,
        destination: XcodeDestination,
        attachConsole: Bool,
        progress: @Sendable @escaping (String) -> Void,
        consoleLog: @Sendable @escaping (String) -> Void,
        commandLog: @Sendable @escaping (String) -> Void,
        slimTask: Task<Void, Never>?
    ) async throws {
        if let slimTask {
            progress("Slimming simulator")
            await slimTask.value
        }
        progress("Booting simulator")
        commandLog("$ xcrun simctl boot \(destination.id)\n")
        _ = try? await ProcessRunner.run(
            executableURL: URL(fileURLWithPath: "/usr/bin/xcrun"),
            arguments: ["simctl", "boot", destination.id],
            currentDirectoryURL: nil
        )
        try throwIfStopped()

        // `simctl boot` only boots the device headlessly, so the app would
        // install and launch with no window on screen.
        await showSimulatorWindow(udid: destination.id, commandLog: commandLog)
        try throwIfStopped()

        progress("Installing")
        commandLog("$ xcrun simctl install \(destination.id) \(app.appURL.path)\n")
        try await runStreaming(
            executableURL: URL(fileURLWithPath: "/usr/bin/xcrun"),
            arguments: ["simctl", "install", destination.id, app.appURL.path],
            currentDirectoryURL: nil,
            log: commandLog
        )
        try throwIfStopped()

        progress(attachConsole ? "" : "Launching")
        var launchArguments = ["simctl", "launch", "--terminate-running-process"]
        if attachConsole {
            // Streams the app's console and blocks until it exits.
            // Uses a PTY (line-buffered) instead of a plain pipe so the app's
            // stdout/print() output is captured; a plain --console pipe is
            // block-buffered and drops print output.
            launchArguments.append("--console-pty")
        }
        launchArguments += [destination.id, app.bundleIdentifier]
        try await runStreaming(
            executableURL: URL(fileURLWithPath: "/usr/bin/xcrun"),
            arguments: launchArguments,
            currentDirectoryURL: nil,
            log: consoleLog
        )
        try throwIfStopped()
    }

    private func installAndLaunchOnDevice(
        app: RunnableApp,
        destination: XcodeDestination,
        attachConsole: Bool,
        progress: @Sendable @escaping (String) -> Void,
        consoleLog: @Sendable @escaping (String) -> Void,
        commandLog: @Sendable @escaping (String) -> Void
    ) async throws {
        commandLog("$ xcrun devicectl device install app --device \(destination.id) \(app.appURL.path)\n")
        try await runStreamingWaitingForDeviceUnlock(
            arguments: [
                "devicectl",
                "device",
                "--quiet",
                "install",
                "app",
                "--device",
                destination.id,
                app.appURL.path
            ],
            phase: "Installing",
            log: commandLog,
            progress: progress,
            commandLog: commandLog
        )
        try throwIfStopped()

        var launchArguments = [
            "devicectl", "device", "--quiet", "process", "launch",
            "--device", destination.id, "--terminate-existing"
        ]
        if attachConsole {
            launchArguments.append("--console")
        }
        launchArguments.append(app.bundleIdentifier)
        try await runStreamingWaitingForDeviceUnlock(
            arguments: launchArguments,
            phase: attachConsole ? "" : "Launching",
            log: consoleLog,
            progress: progress,
            commandLog: commandLog
        )
        try throwIfStopped()
    }

    /// Retries indefinitely while the device reports being locked: the user
    /// unlocking the phone is the only thing that can clear it, and Stop, the
    /// CLI's Ctrl-C and `--timeout` already provide the ways out.
    private func runStreamingWaitingForDeviceUnlock(
        arguments: [String],
        phase: String,
        log: @Sendable @escaping (String) -> Void,
        progress: @Sendable @escaping (String) -> Void,
        commandLog: @Sendable @escaping (String) -> Void
    ) async throws {
        var announcedWait = false

        while true {
            try throwIfStopped()
            progress(phase)

            do {
                try await runStreamingCapturingFailure(
                    executableURL: URL(fileURLWithPath: "/usr/bin/xcrun"),
                    arguments: arguments,
                    currentDirectoryURL: nil,
                    log: log
                )
                return
            } catch let failure as CommandFailure {
                guard DeviceLockDetector.isDeviceLockedFailure(failure.outputTail) else {
                    throw failure.orchardError
                }
                try throwIfStopped()

                if !announcedWait {
                    commandLog("Device is locked. Waiting for unlock...\n")
                    announcedWait = true
                }
                progress("Waiting for device unlock")
                try await Task.sleep(nanoseconds: 3_000_000_000)
            }
        }
    }

    private func terminateOnSimulator(
        app: RunnableApp,
        destination: XcodeDestination,
        log: @Sendable @escaping (String) -> Void
    ) async throws {
        try await runStreaming(
            executableURL: URL(fileURLWithPath: "/usr/bin/xcrun"),
            arguments: ["simctl", "terminate", destination.id, app.bundleIdentifier],
            currentDirectoryURL: nil,
            log: { _ in }
        )
    }

    private func terminateOnDevice(
        app: RunnableApp,
        destination: XcodeDestination,
        log: @Sendable @escaping (String) -> Void
    ) async throws {
        let appURL = try await installedDeviceAppURL(
            bundleIdentifier: app.bundleIdentifier,
            destination: destination
        )
        let processIDs = try await runningDeviceProcessIDs(
            appURL: appURL,
            destination: destination
        )

        if processIDs.isEmpty {
            return
        }

        for processID in processIDs {
            try await runStreaming(
                executableURL: URL(fileURLWithPath: "/usr/bin/xcrun"),
                arguments: [
                    "devicectl",
                    "device",
                    "--quiet",
                    "process",
                    "terminate",
                    "--device",
                    destination.id,
                    "--pid",
                    String(processID)
                ],
                currentDirectoryURL: nil,
                log: { _ in }
            )
        }
    }

    private func installedDeviceAppURL(
        bundleIdentifier: String,
        destination: XcodeDestination
    ) async throws -> URL {
        let outputURL = FileManager.default
            .temporaryDirectory
            .appendingPathComponent("OrchardDeviceApps-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: outputURL) }

        _ = try await ProcessRunner.run(
            executableURL: URL(fileURLWithPath: "/usr/bin/xcrun"),
            arguments: [
                "devicectl",
                "device",
                "info",
                "apps",
                "--device",
                destination.id,
                "--json-output",
                outputURL.path,
                "--quiet"
            ],
            currentDirectoryURL: nil
        )

        let data = try Data(contentsOf: outputURL)
        let response = try JSONDecoder().decode(DeviceAppsResponse.self, from: data)

        guard let app = response.result.apps.first(where: { $0.bundleIdentifier == bundleIdentifier }),
              let url = URL(string: app.url) else {
            throw OrchardError.message("実機上のアプリ \(bundleIdentifier) を特定できませんでした。")
        }

        return url
    }

    private func runningDeviceProcessIDs(
        appURL: URL,
        destination: XcodeDestination
    ) async throws -> [Int] {
        let outputURL = FileManager.default
            .temporaryDirectory
            .appendingPathComponent("OrchardDeviceProcesses-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: outputURL) }

        _ = try await ProcessRunner.run(
            executableURL: URL(fileURLWithPath: "/usr/bin/xcrun"),
            arguments: [
                "devicectl",
                "device",
                "info",
                "processes",
                "--device",
                destination.id,
                "--json-output",
                outputURL.path,
                "--quiet"
            ],
            currentDirectoryURL: nil
        )

        let data = try Data(contentsOf: outputURL)
        let response = try JSONDecoder().decode(DeviceProcessesResponse.self, from: data)
        let appPath = appURL.path.hasSuffix("/") ? appURL.path : "\(appURL.path)/"

        return response.result.runningProcesses.compactMap { process in
            guard let executableURL = URL(string: process.executable),
                  executableURL.path.hasPrefix(appPath) else {
                return nil
            }
            return process.processIdentifier
        }
    }

    private func runStreaming(
        executableURL: URL,
        arguments: [String],
        currentDirectoryURL: URL?,
        log: @Sendable @escaping (String) -> Void
    ) async throws {
        do {
            try await runStreamingCapturingFailure(
                executableURL: executableURL,
                arguments: arguments,
                currentDirectoryURL: currentDirectoryURL,
                log: log
            )
        } catch let failure as CommandFailure {
            throw failure.orchardError
        }
    }

    private func runStreamingCapturingFailure(
        executableURL: URL,
        arguments: [String],
        currentDirectoryURL: URL?,
        log: @Sendable @escaping (String) -> Void
    ) async throws {
        let outputTail = OutputTail()

        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = executableURL
            process.arguments = arguments
            process.currentDirectoryURL = currentDirectoryURL

            let outputPipe = Pipe()
            let errorPipe = Pipe()
            process.standardOutput = outputPipe
            process.standardError = errorPipe

            outputPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
                let normalized = text.strippingCarriageReturns()
                outputTail.append(normalized)
                log(normalized)
            }
            errorPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
                let normalized = text.strippingCarriageReturns()
                outputTail.append(normalized)
                log(normalized)
            }

            process.terminationHandler = { [weak self] process in
                outputPipe.fileHandleForReading.readabilityHandler = nil
                errorPipe.fileHandleForReading.readabilityHandler = nil
                let stopped = self?.isStopping == true
                self?.runningProcess = nil
                self?.isStopping = false

                if process.terminationStatus == 0 || stopped {
                    continuation.resume()
                } else {
                    continuation.resume(
                        throwing: CommandFailure(
                            exitCode: process.terminationStatus,
                            outputTail: outputTail.text
                        )
                    )
                }
            }

            runningProcess = process

            do {
                try process.run()
            } catch {
                outputPipe.fileHandleForReading.readabilityHandler = nil
                errorPipe.fileHandleForReading.readabilityHandler = nil
                runningProcess = nil
                continuation.resume(throwing: error)
            }
        }
    }

    private func throwIfStopped() throws {
        if shouldStop {
            throw OrchardError.message("Stopped.")
        }
    }
}

private struct CommandFailure: Error {
    let exitCode: Int32
    let outputTail: String

    var orchardError: OrchardError {
        OrchardError.message("Command failed with exit code \(exitCode).")
    }
}

/// Keeps the last `limit` characters of a command's combined output so a
/// failure can be classified. Both pipe readability handlers write to it from
/// their own queues, hence the lock.
private final class OutputTail: @unchecked Sendable {
    private let limit = 4000
    private let lock = NSLock()
    private var buffer = ""

    var text: String {
        lock.lock()
        defer { lock.unlock() }
        return buffer
    }

    func append(_ chunk: String) {
        lock.lock()
        defer { lock.unlock() }
        buffer += chunk
        if buffer.count > limit {
            buffer = String(buffer.suffix(limit))
        }
    }
}

private extension String {
    /// Normalizes PTY-style line endings ("\r\n") to "\n" and drops any
    /// remaining stray "\r" (e.g. from --console-pty output).
    ///
    /// Checked via `unicodeScalars`, not `contains("\r")`: Swift's Character
    /// (grapheme cluster) view merges "\r\n" into a single Character, so a
    /// Character-based check for "\r" silently returns false even when a
    /// literal CR byte is present right before a LF.
    func strippingCarriageReturns() -> String {
        guard unicodeScalars.contains(where: { $0 == "\r" }) else { return self }
        return replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "")
    }
}

private struct DeviceAppsResponse: Decodable {
    let result: Result

    struct Result: Decodable {
        let apps: [DeviceApp]
    }
}

private struct DeviceApp: Decodable {
    let bundleIdentifier: String
    let url: String
}

private struct DeviceProcessesResponse: Decodable {
    let result: Result

    struct Result: Decodable {
        let runningProcesses: [DeviceProcess]
    }
}

private struct DeviceProcess: Decodable {
    let executable: String
    let processIdentifier: Int
}
