import Darwin
import Foundation

enum MissingWorktree {
    /// Only ENOENT below searchable directory ancestors proves absence.
    /// Dangling links, permission errors, I/O failures and non-directories preserve devices.
    static func check(_ path: String) throws -> Bool {
        guard path.hasPrefix("/"), path != "/",
              URL(fileURLWithPath: path).standardizedFileURL.path == path else {
            throw OrchardError.message("Invalid worktree association: \(path)")
        }
        var current = ""
        for component in path.split(separator: "/") {
            current += "/" + component
            var value = stat()
            guard lstat(current, &value) == 0 else {
                let code = errno
                if code == ENOENT { return true }
                throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
            }
            if value.st_mode & mode_t(S_IFMT) == mode_t(S_IFLNK) {
                // macOS uses existing directory aliases such as /var -> /private/var.
                // A broken or inaccessible link is uncertainty, never absence.
                guard stat(current, &value) == 0 else {
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
            }
            guard value.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) else {
                throw OrchardError.message("Worktree path is linked or not a directory: \(current)")
            }
        }
        return false
    }
}
