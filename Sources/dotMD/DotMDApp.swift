import SwiftUI
import AppKit
import UniformTypeIdentifiers

private struct MarkdownDocumentFocusedKey: FocusedValueKey {
    typealias Value = MarkdownDocument
}

extension FocusedValues {
    var markdownDocument: MarkdownDocument? {
        get { self[MarkdownDocumentFocusedKey.self] }
        set { self[MarkdownDocumentFocusedKey.self] = newValue }
    }
}

private struct SidebarVisibleFocusedKey: FocusedValueKey {
    typealias Value = Binding<Bool>
}

extension FocusedValues {
    var sidebarVisible: Binding<Bool>? {
        get { self[SidebarVisibleFocusedKey.self] }
        set { self[SidebarVisibleFocusedKey.self] = newValue }
    }
}

/// Bridges a SwiftUI view to its hosting NSWindow, since plain WindowGroup
/// gives no direct way to observe which NSWindow a given scene resolved to.
struct WindowAccessor: NSViewRepresentable {
    let onResolve: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            if let window = view.window {
                onResolve(window)
            }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

/// Tracks each open window's document (one per window, not shared) so it can
/// prompt to save on window-close or app-quit, and places every window
/// (including ones opened later via Cmd+N) at the same top-left spot on the
/// primary display, rather than only the first one.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var documentsByWindow: [ObjectIdentifier: MarkdownDocument] = [:]
    /// Set by "Open…" when it had to create a fresh window first (no
    /// existing window/document to target — e.g. all windows were closed
    /// but the app is still running); consumed by the next `register` call.
    var pendingURL: URL?

    private let launchDate = Date()
    /// How long after launch a still-blank window is considered a launch
    /// artifact rather than something the user deliberately opened (e.g.
    /// via Cmd+N) — see `closeSpareBlankLaunchWindows`.
    private static let launchGracePeriod: TimeInterval = 5

    func register(_ document: MarkdownDocument, window: NSWindow) {
        documentsByWindow[ObjectIdentifier(window)] = document
        window.delegate = self
        if let screen = NSScreen.screens.first {
            let topLeft = NSPoint(x: screen.visibleFrame.minX, y: screen.visibleFrame.maxY)
            window.setFrameTopLeftPoint(topLeft)
        }
        if let url = pendingURL {
            pendingURL = nil
            document.open(url: url)
        }
        closeSpareBlankLaunchWindows()
    }

    /// Opening a file (Finder double-click, or `open -a`/`open file.md`)
    /// races against WindowGroup's own "show a blank window on launch"
    /// behavior — both fire independently, so launching by opening a file
    /// leaves an extra untitled window sitting behind the one that actually
    /// loaded the file. Called both whenever a window registers and right
    /// after a document finishes opening a URL, since either one might be
    /// the last piece of information needed to tell the two apart; it's a
    /// no-op once nothing blank is left, or once the launch grace period
    /// has passed, so it never touches a window the user deliberately left
    /// blank later on.
    func closeSpareBlankLaunchWindows() {
        guard Date().timeIntervalSince(launchDate) < Self.launchGracePeriod else { return }
        let entries: [(window: NSWindow, document: MarkdownDocument)] = NSApp.windows.compactMap { window in
            guard let document = documentsByWindow[ObjectIdentifier(window)] else { return nil }
            return (window, document)
        }
        guard entries.contains(where: { $0.document.fileURL != nil }) else { return }
        for entry in entries where entry.document.fileURL == nil && entry.document.text.isEmpty && !entry.document.isDirty {
            entry.window.close()
        }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard let document = documentsByWindow[ObjectIdentifier(sender)] else { return true }
        var shouldClose = true
        document.confirmDiscardIfNeeded { proceed in shouldClose = proceed }
        return shouldClose
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        documentsByWindow.removeValue(forKey: ObjectIdentifier(window))
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        for document in documentsByWindow.values where document.isDirty {
            var proceed = true
            document.confirmDiscardIfNeeded { result in proceed = result }
            if !proceed { return .terminateCancel }
        }
        return .terminateNow
    }
}

struct DotMDCommands: Commands {
    @FocusedValue(\.markdownDocument) private var document
    @FocusedBinding(\.sidebarVisible) private var sidebarVisible: Bool?
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New") { openWindow(id: "editor") }
                .keyboardShortcut("n", modifiers: .command)
            Button("Open…") {
                if let document {
                    document.openDocument()
                } else {
                    // No focused window (e.g. all windows were closed but
                    // the app is still running) — show the panel directly
                    // and open the result into a fresh window.
                    openFileInNewWindow()
                }
            }
            .keyboardShortcut("o", modifiers: .command)
        }
        CommandGroup(after: .saveItem) {
            Button("Save") { document?.save() }
                .keyboardShortcut("s", modifiers: .command)
                .disabled(document == nil)
            Button("Save As…") { document?.saveAs() }
                .keyboardShortcut("s", modifiers: [.command, .shift])
                .disabled(document == nil)
            Button("Move To…") { document?.moveDocument() }
                .keyboardShortcut("m", modifiers: [.command, .shift])
                .disabled(document?.fileURL == nil)
        }
        CommandGroup(after: .printItem) {
            Button("Print…") {
                NSApp.sendAction(Selector(("print:")), to: nil, from: nil)
            }
            .keyboardShortcut("p", modifiers: .command)
        }
        CommandGroup(after: .sidebar) {
            Button(sidebarVisible == true ? "Hide File Sidebar" : "Show File Sidebar") {
                sidebarVisible?.toggle()
            }
            .keyboardShortcut("e", modifiers: [.command, .shift])
            .disabled(sidebarVisible == nil)
        }
        CommandGroup(after: .textEditing) {
            Divider()
            Button("Find…") { performTextFinderAction(.showFindInterface) }
                .keyboardShortcut("f", modifiers: .command)
            Button("Find Next") { performTextFinderAction(.nextMatch) }
                .keyboardShortcut("g", modifiers: .command)
            Button("Find Previous") { performTextFinderAction(.previousMatch) }
                .keyboardShortcut("g", modifiers: [.command, .shift])
        }
        CommandMenu("Format") {
            Button("Paragraph") { applyBlockFormat(tag: 0) }
                .keyboardShortcut("0", modifiers: .command)
            Button("Heading 1") { applyBlockFormat(tag: 1) }
                .keyboardShortcut("1", modifiers: .command)
            Button("Heading 2") { applyBlockFormat(tag: 2) }
                .keyboardShortcut("2", modifiers: .command)
            Button("Heading 3") { applyBlockFormat(tag: 3) }
                .keyboardShortcut("3", modifiers: .command)
            Button("Heading 4") { applyBlockFormat(tag: 4) }
                .keyboardShortcut("4", modifiers: .command)
            Button("Heading 5") { applyBlockFormat(tag: 5) }
                .keyboardShortcut("5", modifiers: .command)
            Button("Heading 6") { applyBlockFormat(tag: 6) }
                .keyboardShortcut("6", modifiers: .command)
            Divider()
            Button("Numbered List") { applyBlockFormat(tag: 7) }
                .keyboardShortcut("7", modifiers: [.command, .shift])
            Button("Bullet List") { applyBlockFormat(tag: 8) }
                .keyboardShortcut("8", modifiers: [.command, .shift])
            Button("Blockquote") { applyBlockFormat(tag: 9) }
                .keyboardShortcut("9", modifiers: [.command, .shift])
        }
    }

    /// Routes to whichever rendered-pane text view is first responder (see
    /// `CheckboxTextView.dotMDApplyBlockFormat` in RichTextView.swift) — the
    /// same responder-chain pattern `performTextFinderAction` below uses.
    /// No-ops silently if the rendered pane isn't focused.
    private func applyBlockFormat(tag: Int) {
        let sender = NSMenuItem()
        sender.tag = tag
        NSApp.sendAction(Selector(("dotMDApplyBlockFormat:")), to: nil, from: sender)
    }

    private func openFileInNewWindow() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.text, .plainText, UTType(filenameExtension: "md") ?? .plainText]
        panel.allowsOtherFileTypes = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        (NSApp.delegate as? AppDelegate)?.pendingURL = url
        openWindow(id: "editor")
    }
}

@main
struct DotMDApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup(id: "editor") {
            ContentView(
                registerWindow: { document, window in
                    appDelegate.register(document, window: window)
                },
                onDocumentOpened: {
                    appDelegate.closeSpareBlankLaunchWindows()
                }
            )
        }
        .defaultSize(width: 916, height: 881)
        .commands {
            DotMDCommands()
        }
    }
}

/// Routes a Find-menu command to whichever text view is first responder, the
/// same way AppKit's own Find menu does (via the sender's tag).
private func performTextFinderAction(_ action: NSTextFinder.Action) {
    let sender = NSMenuItem()
    sender.tag = action.rawValue
    NSApp.sendAction(#selector(NSResponder.performTextFinderAction(_:)), to: nil, from: sender)
}
