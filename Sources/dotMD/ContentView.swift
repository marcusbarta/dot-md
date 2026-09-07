import SwiftUI
import AppKit

private struct FileTreeScanKey: Equatable {
    let root: URL?
    let file: URL?
}

struct ContentView: View {
    @StateObject private var document = MarkdownDocument()
    @State private var showSidebar = true
    // Owned here (not inside FileTreeSidebar) so it survives the sidebar
    // being toggled closed — FileTreeSidebar is removed from the hierarchy
    // entirely when hidden, which would otherwise throw this away and force
    // a full re-scan of the directory on every single toggle-open.
    @State private var fileTreeNodes: [FileNode] = []
    let registerWindow: (MarkdownDocument, NSWindow) -> Void
    /// Notifies the app delegate right after a document finishes opening a
    /// URL, so it can clean up the spare blank window WindowGroup's launch
    /// behavior leaves behind when the app is launched by opening a file.
    let onDocumentOpened: () -> Void

    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 0) {
                if showSidebar {
                    FileTreeSidebar(
                        rootDirectory: fileTreeRoot,
                        currentFileDirectory: document.fileURL?.deletingLastPathComponent(),
                        nodes: fileTreeNodes,
                        maxWidth: geometry.size.width / 3
                    ) { url in
                        document.confirmDiscardIfNeeded { proceed in
                            if proceed { document.open(url: url) }
                        }
                    }
                    Divider()
                }
                SplitEditorView(text: Binding(
                    get: { document.text },
                    set: { newValue in
                        document.text = newValue
                        document.textDidChange()
                    }
                ))
            }
        }
        .frame(minWidth: 595, minHeight: 343)
        .navigationTitle(document.displayName + (document.isDirty ? " — Edited" : ""))
        .focusedSceneValue(\.markdownDocument, document)
        .focusedSceneValue(\.sidebarVisible, $showSidebar)
        .onOpenURL { url in
            document.confirmDiscardIfNeeded { proceed in
                if proceed {
                    document.open(url: url)
                    onDocumentOpened()
                }
            }
        }
        .background(WindowAccessor { window in registerWindow(document, window) })
        // Scans the directory as soon as a file opens (regardless of
        // whether the sidebar is currently shown), off the main thread, so
        // it's already ready by the time the user toggles the sidebar open.
        // Re-runs automatically (and cancels any in-flight scan) whenever
        // the open file's identity changes — not just when the root
        // directory itself changes, but also on a same-directory rename or
        // move (detected live by MarkdownDocument), so a renamed-away entry
        // doesn't linger stale in the list.
        .task(id: FileTreeScanKey(root: fileTreeRoot, file: document.fileURL)) {
            await refreshFileTree()
        }
    }

    /// One level up from the open document's own directory, so the sidebar
    /// shows that directory alongside its siblings rather than just its own
    /// contents.
    private var fileTreeRoot: URL? {
        document.fileURL?.deletingLastPathComponent().deletingLastPathComponent()
    }

    private func refreshFileTree() async {
        guard let directory = fileTreeRoot else {
            fileTreeNodes = []
            return
        }
        let nodes = await Task.detached(priority: .utility) {
            FileTree.build(rootDirectory: directory)
        }.value
        guard !Task.isCancelled else { return }
        fileTreeNodes = nodes
    }
}
