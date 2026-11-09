import CoreServices
import Foundation

/// Watches the notes folder with FSEvents and reports coalesced changes.
///
/// Events are funnelled to the main queue; the handler is expected to
/// reconcile the whole folder rather than interpret individual paths.
final class NotesFolderMonitor {

    private let folder: URL
    private let onChange: () -> Void
    private let queue = DispatchQueue(label: "com.mdstickynotes.notes-folder-monitor")
    private var stream: FSEventStreamRef?

    init(folder: URL, onChange: @escaping () -> Void) {
        self.folder = folder
        self.onChange = onChange
    }

    deinit {
        stop()
    }

    func start() {
        stop()

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        let flags = UInt32(
            kFSEventStreamCreateFlagFileEvents
                | kFSEventStreamCreateFlagUseCFTypes
                | kFSEventStreamCreateFlagWatchRoot
        )

        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            let monitor = Unmanaged<NotesFolderMonitor>.fromOpaque(info).takeUnretainedValue()
            monitor.notifyChange()
        }

        guard let stream = FSEventStreamCreate(
            nil,
            callback,
            &context,
            [folder.path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.3,
            flags
        ) else {
            print("[NotesFolderMonitor] Could not watch \(folder.path)")
            return
        }

        FSEventStreamSetDispatchQueue(stream, queue)
        guard FSEventStreamStart(stream) else {
            print("[NotesFolderMonitor] Could not start watching \(folder.path)")
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            return
        }

        self.stream = stream
        print("[NotesFolderMonitor] Watching \(folder.path)")
    }

    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    private func notifyChange() {
        DispatchQueue.main.async { [weak self] in
            self?.onChange()
        }
    }
}
