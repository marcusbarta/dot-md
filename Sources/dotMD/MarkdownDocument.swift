import Foundation
import AppKit
import UniformTypeIdentifiers
import Darwin

@MainActor
final class MarkdownDocument: ObservableObject {
    @Published var text: String = ""
    @Published var fileURL: URL?
    @Published var isDirty: Bool = false

    private var fileWatcher: DispatchSourceFileSystemObject?
    /// Debounces bursts of filesystem events (an atomic external save shows
    /// up as a delete + a create, sometimes several of each in quick
    /// succession) into a single reload instead of one per event.
    private var pendingReloadTask: Task<Void, Never>?

    var displayName: String {
        fileURL?.lastPathComponent ?? "Untitled.md"
    }

    /// (Re)starts watching `url` for external changes. The previous watcher,
    /// if any, is torn down first.
    private func startWatching(url: URL) {
        stopWatching()
        let fd = Darwin.open(url.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .delete, .rename, .extend, .revoke],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            guard let self else { return }
            // A rename/move leaves this descriptor still valid (same vnode)
            // but pointing at a new path — F_GETPATH reads that current path
            // back off the open fd, which is how we notice the file moved
            // out from under us and keep tracking it at its new location.
            if source.data.contains(.rename) {
                self.updateURLAfterRename(fd: source.handle)
            }
            self.handleExternalChange()
        }
        source.setCancelHandler {
            Darwin.close(fd)
        }
        source.resume()
        fileWatcher = source
    }

    private func stopWatching() {
        fileWatcher?.cancel()
        fileWatcher = nil
    }

    /// Reads the watched descriptor's current path back off the kernel and,
    /// if it differs from what we had, adopts it as the document's new
    /// location — this is what lets an external rename or move (on the same
    /// volume) keep the document pointed at the right file instead of
    /// silently losing track of it.
    private func updateURLAfterRename(fd: Int32) {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard fcntl(fd, F_GETPATH, &buffer) != -1 else { return }
        let newPath = String(cString: buffer)
        guard let oldURL = fileURL, newPath != oldURL.path else { return }
        fileURL = URL(fileURLWithPath: newPath)
    }

    private func handleExternalChange() {
        guard let url = fileURL else { return }
        pendingReloadTask?.cancel()
        pendingReloadTask = Task { @MainActor [weak self] in
            // Many editors save via write-to-temp-then-rename, which unlinks
            // the inode this event fired for — wait a beat so the new file
            // is actually in place before re-reading and re-arming the watch
            // (the old descriptor is now watching a deleted, orphaned inode).
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard !Task.isCancelled, let self else { return }
            self.reloadFromDisk(url: url)
            if FileManager.default.fileExists(atPath: url.path) {
                self.startWatching(url: url)
            }
        }
    }

    private func reloadFromDisk(url: URL) {
        guard let contents = try? String(contentsOf: url, encoding: .utf8), contents != text else { return }
        if isDirty {
            let alert = NSAlert()
            alert.messageText = "\(displayName) changed on disk"
            alert.informativeText = "This file was modified by another application. Reload it and discard your unsaved changes, or keep editing your version?"
            alert.addButton(withTitle: "Reload")
            alert.addButton(withTitle: "Keep Mine")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        setText(contents, markClean: true)
    }

    /// Update the text without marking the document dirty (used for loads/reverts).
    func setText(_ newText: String, markClean: Bool) {
        text = newText
        if markClean { isDirty = false }
    }

    func textDidChange() {
        isDirty = true
    }

    func confirmDiscardIfNeeded(then proceed: @escaping (Bool) -> Void) {
        guard isDirty else { proceed(true); return }
        let alert = NSAlert()
        alert.messageText = "You have unsaved changes"
        alert.informativeText = "Do you want to save the changes to \(displayName) before continuing?"
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Don't Save")
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            save { success in proceed(success) }
        case .alertSecondButtonReturn:
            proceed(true)
        default:
            proceed(false)
        }
    }

    func newDocument() {
        confirmDiscardIfNeeded { [weak self] proceed in
            guard proceed, let self else { return }
            self.stopWatching()
            self.fileURL = nil
            self.setText("", markClean: true)
        }
    }

    func openDocument() {
        confirmDiscardIfNeeded { [weak self] proceed in
            guard proceed, let self else { return }
            let panel = NSOpenPanel()
            panel.allowedContentTypes = [.text, .plainText, UTType(filenameExtension: "md") ?? .plainText]
            panel.allowsOtherFileTypes = true
            panel.canChooseDirectories = false
            panel.allowsMultipleSelection = false
            if panel.runModal() == .OK, let url = panel.url {
                self.open(url: url)
            }
        }
    }

    func open(url: URL) {
        guard let contents = try? String(contentsOf: url, encoding: .utf8) else {
            let alert = NSAlert()
            alert.messageText = "Couldn't open file"
            alert.informativeText = url.lastPathComponent
            alert.runModal()
            return
        }
        fileURL = url
        setText(contents, markClean: true)
        startWatching(url: url)
    }

    @discardableResult
    func save(completion: ((Bool) -> Void)? = nil) -> Bool {
        if let url = fileURL {
            return write(to: url, completion: completion)
        } else {
            return saveAs(completion: completion)
        }
    }

    @discardableResult
    func saveAs(completion: ((Bool) -> Void)? = nil) -> Bool {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.allowsOtherFileTypes = true
        panel.nameFieldStringValue = displayName
        guard panel.runModal() == .OK, let url = panel.url else {
            completion?(false)
            return false
        }
        return write(to: url, completion: completion)
    }

    /// Relocates the file on disk to a new path/name the user picks, leaving
    /// its contents untouched — the in-memory `text` doesn't change, only
    /// where it's stored. No-ops if there's no file yet to move.
    func moveDocument() {
        guard let currentURL = fileURL else { return }
        let panel = NSSavePanel()
        panel.title = "Move To"
        panel.prompt = "Move"
        panel.nameFieldStringValue = currentURL.lastPathComponent
        panel.directoryURL = currentURL.deletingLastPathComponent()
        guard panel.runModal() == .OK, let destination = panel.url, destination != currentURL else { return }
        stopWatching()
        do {
            // NSSavePanel already confirmed overwriting with the user if
            // `destination` pointed at an existing file.
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.moveItem(at: currentURL, to: destination)
            fileURL = destination
            startWatching(url: destination)
        } catch {
            let alert = NSAlert(error: error)
            alert.runModal()
            startWatching(url: currentURL)
        }
    }

    @discardableResult
    private func write(to url: URL, completion: ((Bool) -> Void)? = nil) -> Bool {
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            fileURL = url
            isDirty = false
            startWatching(url: url)
            completion?(true)
            return true
        } catch {
            let alert = NSAlert(error: error)
            alert.runModal()
            completion?(false)
            return false
        }
    }
}
