import CoreServices
import Foundation

/// Watches the shared run-store directory with FSEvents and invokes `onChange`
/// whenever its contents change (a CLI run record is created, updated, or
/// removed). This replaces idle polling: no work happens until the filesystem
/// actually reports a change. FSEvents reports directory-subtree changes
/// including in-place file modifications, so a CLI updating `<id>.json` as a
/// run progresses triggers a callback.
///
/// The owner keeps this object alive for its whole lifetime and toggles the
/// stream with `start()` / `stop()`. The FSEvents context holds an unretained
/// pointer to `self`, which is safe because the object outlives the stream.
final class RunStoreWatcher {
    private let directory: URL
    private let onChange: () -> Void
    private let queue = DispatchQueue(label: "dev.codex.Orchard.runstore-watcher")
    private var stream: FSEventStreamRef?

    init(directory: URL, onChange: @escaping () -> Void) {
        self.directory = directory
        self.onChange = onChange
    }

    func start() {
        guard stream == nil else { return }

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            Unmanaged<RunStoreWatcher>.fromOpaque(info).takeUnretainedValue().onChange()
        }

        // ~0.3s latency coalesces the burst of writes a single run produces.
        guard let created = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            [directory.path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.3,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer)
        ) else {
            return
        }

        FSEventStreamSetDispatchQueue(created, queue)
        FSEventStreamStart(created)
        stream = created
    }

    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    deinit {
        stop()
    }
}
