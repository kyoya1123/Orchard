import Foundation

public struct TerminalContext: Equatable, Identifiable, Sendable {
    public let terminalID: String
    public let providerID: String
    public let providerName: String
    public let workingDirectoryURL: URL
    public let title: String?
    public let isFocused: Bool

    public init(
        terminalID: String,
        providerID: String,
        providerName: String,
        workingDirectoryURL: URL,
        title: String?,
        isFocused: Bool
    ) {
        self.terminalID = terminalID
        self.providerID = providerID
        self.providerName = providerName
        self.workingDirectoryURL = workingDirectoryURL
        self.title = title
        self.isFocused = isFocused
    }

    public var id: String {
        "\(providerID):\(terminalID)"
    }
}

public protocol TerminalContextProvider: Sendable {
    var id: String { get }
    var displayName: String { get }

    func resolveContexts() async throws -> [TerminalContext]
}

public extension TerminalContextProvider {
    func resolveContext() async throws -> TerminalContext {
        guard let context = try await resolveContexts().first else {
            throw DevRunnerError.message("\(displayName) から terminal context を取得できませんでした。")
        }

        return context
    }
}

public struct TerminalContextProviderRegistry: Sendable {
    public let providers: [any TerminalContextProvider]

    public init(providers: [any TerminalContextProvider] = [GhosttyContextProvider()]) {
        self.providers = providers
    }

    public var defaultProvider: (any TerminalContextProvider)? {
        providers.first
    }
}
