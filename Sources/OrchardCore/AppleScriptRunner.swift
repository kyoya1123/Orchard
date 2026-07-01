import Foundation

public struct AppleScriptRunner: Sendable {
    public init() {}

    public func run(_ source: String) async throws -> String {
        try await ProcessRunner.run(
            executableURL: URL(fileURLWithPath: "/usr/bin/osascript"),
            arguments: ["-e", source],
            currentDirectoryURL: nil
        )
    }
}
