import ArgumentParser
import Foundation
import OrchardCore

struct DeviceUseCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "device-use",
        abstract: "Track and protect an Orchard Simulator during an external build, install, or test command.")
    @Option(name: .long, help: "UDID of an Orchard branch Simulator.")
    var simulator: String
    @Option(name: .long, help: "Maximum command duration in seconds (up to 86400).")
    var timeout: Double = 7200
    @Argument(parsing: .captureForPassthrough) var command: [String] = []

    mutating func run() async throws {
        let arguments = command.first == "--" ? Array(command.dropFirst()) : command
        let output = try await DeviceActivity.run(simulator: simulator, command: arguments, timeout: timeout)
        if !output.isEmpty { print(output) }
    }
}
