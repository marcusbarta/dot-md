import SwiftUI
import AppKit

struct ContentView: View {
    @StateObject private var document = MarkdownDocument()
    let registerWindow: (MarkdownDocument, NSWindow) -> Void
    /// Notifies the app delegate right after a document finishes opening a
    /// URL, so it can clean up the spare blank window WindowGroup's launch
    /// behavior leaves behind when the app is launched by opening a file.
    let onDocumentOpened: () -> Void

    var body: some View {
        SplitEditorView(text: Binding(
            get: { document.text },
            set: { newValue in
                document.text = newValue
                document.textDidChange()
            }
        ))
        .frame(minWidth: 595, minHeight: 343)
        .navigationTitle(document.displayName + (document.isDirty ? " — Edited" : ""))
        .focusedSceneValue(\.markdownDocument, document)
        .onOpenURL { url in
            document.confirmDiscardIfNeeded { proceed in
                if proceed {
                    document.open(url: url)
                    onDocumentOpened()
                }
            }
        }
        .background(WindowAccessor { window in registerWindow(document, window) })
}
}
