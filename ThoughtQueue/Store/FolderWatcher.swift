import Foundation
import os

private let log = Logger(subsystem: "com.thoughtqueue.app", category: "FolderWatcher")

/// Watches the store root recursively via FSEvents, debounces bursts, suppresses
/// the app's own writes, and posts `.notesDidChange` so the UI re-reads the folder.
final class FolderWatcher {
    private var stream: FSEventStreamRef?
    private let root: URL
    private var debounceWorkItem: DispatchWorkItem?
    private let debounceInterval: TimeInterval = 0.3
    private let queue = DispatchQueue(label: "com.thoughtqueue.folderwatcher")

    init(root: URL) {
        self.root = root.standardizedFileURL
    }

    deinit {
        stop()
    }

    func start() {
        stop()

        let callback: FSEventStreamCallback = { _, info, numEvents, eventPaths, _, _ in
            guard let info = info else { return }
            let watcher = Unmanaged<FolderWatcher>.fromOpaque(info).takeUnretainedValue()
            let paths = unsafeBitCast(eventPaths, to: NSArray.self) as? [String] ?? []
            watcher.handleEvents(paths: paths, count: numEvents)
        }

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        let flags = UInt32(
            kFSEventStreamCreateFlagFileEvents |
            kFSEventStreamCreateFlagNoDefer |
            kFSEventStreamCreateFlagUseCFTypes
        )

        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            [root.path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.2,
            flags
        ) else {
            log.error("Failed to create FSEventStream for \(self.root.path)")
            return
        }

        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
        log.info("FolderWatcher started on \(self.root.path)")
    }

    func stop() {
        guard let stream = stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    /// Decide whether the event batch is meaningful (not purely self-writes), then debounce.
    private func handleEvents(paths: [String], count: Int) {
        // Consume a pending self-write for EVERY path (no short-circuit), so each app write
        // is matched to exactly one event. The batch is suppressed only if every path was
        // a self-write; any genuinely external path forces a refresh.
        var externalSeen = false
        for path in paths {
            let wasSelf = NoteStore.shared.wasSelfWrite(path)
            if !wasSelf { externalSeen = true }
        }
        if paths.isEmpty || !externalSeen {
            log.debug("Ignored self-write batch of \(paths.count) paths")
            return
        }

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.debounceWorkItem?.cancel()
            let item = DispatchWorkItem {
                NotificationCenter.default.post(name: .notesDidChange, object: nil)
            }
            self.debounceWorkItem = item
            DispatchQueue.main.asyncAfter(deadline: .now() + self.debounceInterval, execute: item)
        }
    }
}
