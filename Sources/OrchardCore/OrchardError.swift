import Foundation

public enum OrchardError: LocalizedError, Sendable {
    case message(String)

    public var errorDescription: String? {
        switch self {
        case .message(let message):
            message
        }
    }
}
