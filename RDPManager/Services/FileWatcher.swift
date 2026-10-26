import Foundation

/// Watches one file for writes and replacements (atomic saves rename a new file into place,
/// so the watcher re-arms itself after a rename or delete).
final class FileWatcher {
    private let url: URL
    private let handler: () -> Void
    private var source: DispatchSourceFileSystemObject?
    private let queue = DispatchQueue(label: "rdpmanager.filewatcher")

    init(url: URL, handler: @escaping () -> Void) {
        self.url = url
        self.handler = handler
        arm()
    }

    deinit {
        source?.cancel()
    }

    private func arm() {
        let fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else {
            // File does not exist yet; try again shortly.
            queue.asyncAfter(deadline: .now() + 2) { [weak self] in self?.arm() }
            return
        }
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .extend, .rename, .delete], queue: queue)
        src.setEventHandler { [weak self] in
            guard let self else { return }
            let flags = src.data
            self.handler()
            if flags.contains(.rename) || flags.contains(.delete) {
                src.cancel()
                self.queue.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.arm() }
            }
        }
        src.setCancelHandler { close(fd) }
        source = src
        src.resume()
    }
}
