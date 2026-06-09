import Foundation

public struct GhosttyContextProvider: TerminalContextProvider {
    public let id = "ghostty"
    public let displayName = "Ghostty"

    private let appleScriptRunner: AppleScriptRunner

    public init(appleScriptRunner: AppleScriptRunner = AppleScriptRunner()) {
        self.appleScriptRunner = appleScriptRunner
    }

    public func resolveContexts() async throws -> [TerminalContext] {
        let script = """
        tell application "System Events"
            if not (exists process "Ghostty") then error "Ghostty is not running."
        end tell

        tell application "Ghostty"
            if (count of windows) is 0 then error "Ghostty has no windows."
            set focusedID to id of focused terminal of selected tab of front window as text
            set separator to ASCII character 9
            set rows to {}

            repeat with term in terminals
                set cwd to working directory of term
                if cwd is not "" then
                    set terminalID to id of term as text
                    set focusedFlag to "0"
                    if terminalID is focusedID then set focusedFlag to "1"
                    set end of rows to terminalID & separator & cwd & separator & (name of term) & separator & focusedFlag
                end if
            end repeat

            set previousDelimiters to AppleScript's text item delimiters
            set AppleScript's text item delimiters to linefeed
            set output to rows as text
            set AppleScript's text item delimiters to previousDelimiters
            return output
        end tell
        """

        let output = try await appleScriptRunner.run(script)
        let contexts = output
            .split(separator: "\n", omittingEmptySubsequences: true)
            .compactMap(parseContextLine)

        guard !contexts.isEmpty else {
            throw DevRunnerError.message("Ghostty の terminal 一覧から作業ディレクトリを取得できませんでした。")
        }

        return contexts.sorted { lhs, rhs in
            if lhs.isFocused != rhs.isFocused {
                return lhs.isFocused
            }

            return lhs.workingDirectoryURL.path < rhs.workingDirectoryURL.path
        }
    }

    private func parseContextLine(_ line: Substring) -> TerminalContext? {
        let columns = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
        guard columns.count >= 4 else { return nil }

        let rawPath = columns[1].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawPath.isEmpty else { return nil }

        let path = (rawPath as NSString).expandingTildeInPath
        return TerminalContext(
            terminalID: columns[0],
            providerID: id,
            providerName: displayName,
            workingDirectoryURL: URL(fileURLWithPath: path, isDirectory: true),
            title: columns[2].isEmpty ? nil : columns[2],
            isFocused: columns[3] == "1"
        )
    }
}
