import SwiftUI
import AppKit

/// An NSSplitView-backed container for the plain/rendered editor panes.
///
/// SwiftUI's `HSplitView` has no hook for divider interactions, so a
/// double-click-to-recenter gesture needs a real `NSSplitView` underneath.
struct SplitEditorView: NSViewRepresentable {
    @Binding var text: String

    func makeNSView(context: Context) -> NSSplitView {
        let splitView = CenteringSplitView()
        splitView.isVertical = true
        splitView.dividerStyle = .thin
        splitView.delegate = context.coordinator

        let leftHost = NSHostingView(rootView: PlainMarkdownEditor(text: $text))
        let rightHost = NSHostingView(rootView: RichTextView(text: $text))
        splitView.addArrangedSubview(leftHost)
        splitView.addArrangedSubview(rightHost)

        context.coordinator.leftHost = leftHost
        context.coordinator.rightHost = rightHost
        context.coordinator.lastText = text

        return splitView
    }

    func updateNSView(_ nsView: NSSplitView, context: Context) {
        // NSHostingView doesn't automatically re-render when state outside
        // it changes — its rootView has to be reassigned explicitly, or
        // edits made in one pane never show up in the other. Skipping this
        // when the text hasn't actually changed (e.g. an
        // unrelated re-render) avoids needless rebuild work without
        // relying on "which pane caused it" — which broke the initial file
        // load (both panes start empty and both genuinely need the update).
        guard context.coordinator.lastText != text else { return }
        context.coordinator.lastText = text
        context.coordinator.leftHost?.rootView = PlainMarkdownEditor(text: $text)
        context.coordinator.rightHost?.rootView = RichTextView(text: $text)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, NSSplitViewDelegate {
        var leftHost: NSHostingView<PlainMarkdownEditor>?
        var rightHost: NSHostingView<RichTextView>?
        var lastText: String?
        private let minPaneWidth: CGFloat = 280

        func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
            proposedMinimumPosition + minPaneWidth
        }

        func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
            proposedMaximumPosition - minPaneWidth
        }
    }
}

/// Recognizes a double-click on the divider and recenters the split.
private final class CenteringSplitView: NSSplitView {
    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            let point = convert(event.locationInWindow, from: nil)
            // NSSplitView has no public accessor for a divider's rect, so
            // derive it from the neighboring subview's frame instead.
            for index in 0..<max(0, subviews.count - 1) {
                let dividerX = subviews[index].frame.maxX
                let dividerRect = NSRect(x: dividerX, y: 0, width: dividerThickness, height: bounds.height)
                    .insetBy(dx: -3, dy: 0)
                if dividerRect.contains(point) {
                    setPosition(bounds.width / 2, ofDividerAt: index)
                    return
                }
            }
        }
        super.mouseDown(with: event)
    }
}

struct PlainMarkdownEditor: View {
    @Binding var text: String

    var body: some View {
        TextEditor(text: $text)
            .font(.system(.body, design: .monospaced))
            .scrollContentBackground(.hidden)
            .padding(8)
    }
}
