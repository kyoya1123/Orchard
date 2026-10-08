import ArgumentParser
import Foundation
import OrchardCore

struct SimulatorCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "simulator",
        abstract: "Prepare an empty, booted-once base and clone branch Simulators.",
        subcommands: [SimulatorEnsure.self, SimulatorBase.self])
}

struct SimulatorOptions: ParsableArguments {
    @Option(name: .long, help: "Exact device type name/identifier, or latest (newest supported iPhone; prefers Pro).")
    var deviceType: String = "latest"

    @Option(name: .long, help: "Exact runtime name/identifier, or latest installed compatible iOS runtime.")
    var runtime: String = "latest"

    @Flag(name: .long, help: "Emit JSON instead of the UDID.")
    var json = false

    func prepare(name: String?) async throws {
        let project = name == nil ? nil : try? ProjectDetector().detect(from: URL(fileURLWithPath: FileManager.default.currentDirectoryPath))
        if let project { await CLIEnvironment.register(project: project) }
        let result = try await SimulatorBaseService().prepare(
            name: name, selection: .init(deviceType: deviceType, runtime: runtime), project: project,
            progress: { FileHandle.standardError.write(Data(($0 + "\n").utf8)) })
        await BackgroundCleanup.launch()
        if json {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            print(String(decoding: try encoder.encode(result), as: UTF8.self))
        } else {
            print(result.udid)
        }
    }
}

struct SimulatorEnsure: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "ensure", abstract: "Reuse or clone a named branch Simulator from a clean base.")
    @Option(name: .long, help: "Exact Simulator name (typically the branch name with slashes replaced by hyphens).")
    var name: String
    @OptionGroup var options: SimulatorOptions
    mutating func run() async throws { try await options.prepare(name: name) }
}

struct SimulatorBase: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "base", abstract: "Prepare the current empty base and remove obsolete, unused Orchard bases.")
    @OptionGroup var options: SimulatorOptions
    mutating func run() async throws { try await options.prepare(name: nil) }
}
