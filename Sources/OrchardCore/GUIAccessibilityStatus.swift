import Foundation

/// A diagnostic from the GUI process itself, never a CLI/worker's inherited
/// permission. Kept outside Cleanup-v1 so it cannot trigger its report watcher.
struct GUIAccessibilityStatus: Codable, Sendable {
    let checkedAt: Date
    let pid: Int32
    let bundle: String?
    let executable: String?
    let commit: String?
    let trusted: Bool
    let showsRequirement: Bool

    @MainActor static func record(trusted: Bool, showsRequirement: Bool) {
        let status = Self(checkedAt: Date(), pid: ProcessInfo.processInfo.processIdentifier,
            bundle: Bundle.main.bundleURL.path, executable: Bundle.main.executableURL?.path,
            commit: Bundle.main.object(forInfoDictionaryKey: "OrchardBuildCommit") as? String,
            trusted: trusted, showsRequirement: showsRequirement)
        Task { await GUIAccessibilityStatusWriter.shared.write(status) }
    }
}

private actor GUIAccessibilityStatusWriter {
    static let shared = GUIAccessibilityStatusWriter()
    private var lastWritten = Date.distantPast
    func write(_ status: GUIAccessibilityStatus) {
        guard status.checkedAt > lastWritten else { return }
        let directory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Orchard/Diagnostics-v1")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(status).write(to: directory.appendingPathComponent("gui-accessibility.json"), options: .atomic)
            lastWritten = status.checkedAt
        } catch { /* Diagnostics must never prevent permission checks or cleanup. */ }
    }
}
