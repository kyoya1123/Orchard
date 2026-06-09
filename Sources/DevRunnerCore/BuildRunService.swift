import Foundation

public final class BuildRunService: @unchecked Sendable {
    private let processRunner: ProcessRunner
    private var runningProcess: Process?
    private var launchedApp: RunnableApp?

    public init(processRunner: ProcessRunner = ProcessRunner()) {
        self.processRunner = processRunner
    }

    public func stop() {
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

    public func buildAndRun(
        project: XcodeProject,
        scheme: String,
        destination: XcodeDestination,
        log: @Sendable @escaping (String) -> Void
    ) async throws {
        let derivedDataURL = FileManager.default
            .temporaryDirectory
            .appendingPathComponent("DevRunnerDerivedData", isDirectory: true)
            .appendingPathComponent(project.id, isDirectory: true)

        try FileManager.default.createDirectory(
            at: derivedDataURL,
            withIntermediateDirectories: true
        )

        let buildArguments = project.xcodebuildArguments + [
            "-scheme", scheme,
            "-destination", destination.xcodebuildDestination,
            "-derivedDataPath", derivedDataURL.path,
            "build"
        ]

        log("$ xcodebuild \(buildArguments.joined(separator: " "))\n")
        try await runStreaming(
            executableURL: URL(fileURLWithPath: "/usr/bin/xcodebuild"),
            arguments: buildArguments,
            currentDirectoryURL: project.rootURL,
            log: log
        )

        let settings = try await XcodeService().buildSettings(
            project: project,
            scheme: scheme,
            destination: destination,
            derivedDataURL: derivedDataURL
        )

        guard let app = settings.firstRunnableApp else {
            throw DevRunnerError.message("ビルド成果物の .app と bundle identifier を特定できませんでした。")
        }
        launchedApp = app

        switch destination.kind {
        case .device:
            try await installAndLaunchOnDevice(app: app, destination: destination, log: log)
        case .simulator:
            try await installAndLaunchOnSimulator(app: app, destination: destination, log: log)
        }
    }

    private func installAndLaunchOnSimulator(
        app: RunnableApp,
        destination: XcodeDestination,
        log: @Sendable @escaping (String) -> Void
    ) async throws {
        log("\n$ xcrun simctl boot \(destination.id)\n")
        _ = try? await ProcessRunner.run(
            executableURL: URL(fileURLWithPath: "/usr/bin/xcrun"),
            arguments: ["simctl", "boot", destination.id],
            currentDirectoryURL: nil
        )

        log("$ xcrun simctl install \(destination.id) \(app.appURL.path)\n")
        try await runStreaming(
            executableURL: URL(fileURLWithPath: "/usr/bin/xcrun"),
            arguments: ["simctl", "install", destination.id, app.appURL.path],
            currentDirectoryURL: nil,
            log: log
        )

        log("$ xcrun simctl launch \(destination.id) \(app.bundleIdentifier)\n")
        try await runStreaming(
            executableURL: URL(fileURLWithPath: "/usr/bin/xcrun"),
            arguments: ["simctl", "launch", destination.id, app.bundleIdentifier],
            currentDirectoryURL: nil,
            log: log
        )
    }

    private func installAndLaunchOnDevice(
        app: RunnableApp,
        destination: XcodeDestination,
        log: @Sendable @escaping (String) -> Void
    ) async throws {
        log("\n$ xcrun devicectl device install app --device \(destination.id) \(app.appURL.path)\n")
        try await runStreaming(
            executableURL: URL(fileURLWithPath: "/usr/bin/xcrun"),
            arguments: ["devicectl", "device", "install", "app", "--device", destination.id, app.appURL.path],
            currentDirectoryURL: nil,
            log: log
        )

        log("$ xcrun devicectl device process launch --device \(destination.id) --terminate-existing \(app.bundleIdentifier)\n")
        try await runStreaming(
            executableURL: URL(fileURLWithPath: "/usr/bin/xcrun"),
            arguments: [
                "devicectl",
                "device",
                "process",
                "launch",
                "--device",
                destination.id,
                "--terminate-existing",
                app.bundleIdentifier
            ],
            currentDirectoryURL: nil,
            log: log
        )
    }

    private func terminateOnSimulator(
        app: RunnableApp,
        destination: XcodeDestination,
        log: @Sendable @escaping (String) -> Void
    ) async throws {
        log("\n$ xcrun simctl terminate \(destination.id) \(app.bundleIdentifier)\n")
        try await runStreaming(
            executableURL: URL(fileURLWithPath: "/usr/bin/xcrun"),
            arguments: ["simctl", "terminate", destination.id, app.bundleIdentifier],
            currentDirectoryURL: nil,
            log: log
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
            log("\nNo running process found for \(app.bundleIdentifier).\n")
            return
        }

        for processID in processIDs {
            log("\n$ xcrun devicectl device process terminate --device \(destination.id) --pid \(processID)\n")
            try await runStreaming(
                executableURL: URL(fileURLWithPath: "/usr/bin/xcrun"),
                arguments: [
                    "devicectl",
                    "device",
                    "process",
                    "terminate",
                    "--device",
                    destination.id,
                    "--pid",
                    String(processID)
                ],
                currentDirectoryURL: nil,
                log: log
            )
        }
    }

    private func installedDeviceAppURL(
        bundleIdentifier: String,
        destination: XcodeDestination
    ) async throws -> URL {
        let outputURL = FileManager.default
            .temporaryDirectory
            .appendingPathComponent("DevRunnerDeviceApps-\(UUID().uuidString).json")
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
            throw DevRunnerError.message("実機上のアプリ \(bundleIdentifier) を特定できませんでした。")
        }

        return url
    }

    private func runningDeviceProcessIDs(
        appURL: URL,
        destination: XcodeDestination
    ) async throws -> [Int] {
        let outputURL = FileManager.default
            .temporaryDirectory
            .appendingPathComponent("DevRunnerDeviceProcesses-\(UUID().uuidString).json")
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
                log(text)
            }
            errorPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
                log(text)
            }

            process.terminationHandler = { [weak self] process in
                outputPipe.fileHandleForReading.readabilityHandler = nil
                errorPipe.fileHandleForReading.readabilityHandler = nil
                self?.runningProcess = nil

                if process.terminationStatus == 0 {
                    continuation.resume()
                } else {
                    continuation.resume(
                        throwing: DevRunnerError.message("Command failed with exit code \(process.terminationStatus).")
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
