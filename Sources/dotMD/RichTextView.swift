import SwiftUI
import AppKit

/// An NSTextView that intercepts clicks on task-list checkbox markers
/// (tagged with `MarkdownRendering.checkboxStateKey`) and toggles them
/// in place instead of placing the cursor/starting a text selection there.
private final class CheckboxTextView: NSTextView {
    var onCheckboxToggle: ((NSRange) -> Void)?

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let charIndex = checkboxCharacterIndex(at: point) {
            var effectiveRange = NSRange()
            if textStorage?.attribute(MarkdownRendering.checkboxStateKey, at: charIndex, effectiveRange: &effectiveRange) != nil {
                onCheckboxToggle?(effectiveRange)
                return
            }
        }
        super.mouseDown(with: event)
    }

    /// Routed here via the responder chain by the Format menu / ⌘1-⌘6 etc.
    /// (see DotMDCommands.applyBlockFormat), so it only fires when this
    /// pane is the one with focus. `sender.tag` encodes the target: 0 =
    /// plain paragraph, 1-6 = header level, 7 = numbered list, 8 = bullet
    /// list, 9 = blockquote.
    @objc func dotMDApplyBlockFormat(_ sender: Any?) {
        guard let tag = (sender as? NSMenuItem)?.tag, let storage = textStorage else { return }
        let target: MarkdownRendering.BlockFormatTarget
        switch tag {
        case 1...6: target = .header(tag)
        case 7: target = .numberedList
        case 8: target = .bulletList
        case 9: target = .blockQuote
        default: target = .paragraph
        }
        guard let (range, replacement) = MarkdownRendering.reformattedBlock(in: storage, at: selectedRange().location, to: target) else { return }
        guard shouldChangeText(in: range, replacementString: replacement.string) else { return }
        storage.replaceCharacters(in: range, with: replacement)
        didChangeText()
    }

    /// Returns the character index under `point` only if `point` actually
    /// falls within that character's own glyph rect (not just "nearest"),
    /// so a click just past the checkbox still places the cursor normally.
    private func checkboxCharacterIndex(at point: NSPoint) -> Int? {
        guard let layoutManager, let textContainer else { return nil }
        let containerPoint = NSPoint(x: point.x - textContainerOrigin.x, y: point.y - textContainerOrigin.y)
        let glyphIndex = layoutManager.glyphIndex(for: containerPoint, in: textContainer)
        guard glyphIndex < layoutManager.numberOfGlyphs else { return nil }
        let glyphRect = layoutManager.boundingRect(forGlyphRange: NSRange(location: glyphIndex, length: 1), in: textContainer)
        let adjustedRect = glyphRect.offsetBy(dx: textContainerOrigin.x, dy: textContainerOrigin.y)
        guard adjustedRect.contains(point) else { return nil }
        return layoutManager.characterIndexForGlyph(at: glyphIndex)
    }
}

/// An editable, live-rendered markdown pane backed by NSTextView.
///
/// The view displays a styled NSAttributedString built from the markdown
/// source. When the user types directly into it, we serialize the current
/// attributed content back into markdown and push it into `text`. To avoid
/// fighting the user's cursor, we only rebuild the attributed content from
/// scratch when `text` changed for a reason OTHER than an edit made in this
/// view (e.g. the left plain-text pane changed, or a file was opened).
struct RichTextView: NSViewRepresentable {
    @Binding var text: String

    func makeNSView(context: Context) -> NSScrollView {
        let textView = CheckboxTextView()
        textView.delegate = context.coordinator
        textView.onCheckboxToggle = { [weak textView] range in
            guard let textView else { return }
            context.coordinator.toggleCheckbox(in: textView, markerRange: range)
        }
        textView.isRichText = true
        textView.isEditable = true
        textView.isSelectable = true
        textView.allowsUndo = true
        textView.usesFindBar = true
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.drawsBackground = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)

        let scrollView = NSScrollView()
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.drawsBackground = false
        scrollView.autohidesScrollers = true

        context.coordinator.textView = textView
        context.coordinator.isProgrammaticUpdate = true
        textView.textStorage?.setAttributedString(MarkdownRendering.render(text))
        context.coordinator.isProgrammaticUpdate = false
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard context.coordinator.textView != nil else { return }

        if context.coordinator.isPushingEdit {
            context.coordinator.isPushingEdit = false
            return
        }

        // External change (left pane edited, or a file was opened): rebuild.
        // MarkdownRendering.render() is a full re-parse of the whole
        // document — measured at 15-45ms for a few-thousand-word document,
        // well past a frame budget. Debouncing it means a fast typing burst
        // in the plain pane re-parses once after typing pauses, not on
        // every keystroke; the plain pane itself is never blocked by this
        // (it's a separate, un-rendered NSTextView/TextEditor).
        context.coordinator.scheduleExternalRender(of: text)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    /// Bundles a pending table structural edit's context so it can be
    /// stashed on an `NSMenuItem.representedObject` between the context
    /// menu being built and the item actually being clicked.
    private struct TableEditRequest {
        let view: NSTextView
        let charIndex: Int
        let edit: MarkdownRendering.TableStructuralEdit
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        static let externalRenderDebounce: TimeInterval = 0.15

        var text: Binding<String>
        weak var textView: NSTextView?
        var isPushingEdit = false
        var isProgrammaticUpdate = false
        private var pendingRender: DispatchWorkItem?

        init(text: Binding<String>) {
            self.text = text
        }

        /// Coalesces rapid external text changes (i.e. typing in the other
        /// pane) into a single re-parse, instead of one per keystroke.
        func scheduleExternalRender(of newText: String) {
            pendingRender?.cancel()
            let work = DispatchWorkItem { [weak self] in
                self?.applyExternalRender(newText)
            }
            pendingRender = work
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.externalRenderDebounce, execute: work)
        }

        private func applyExternalRender(_ newText: String) {
            guard let textView, let storage = textView.textStorage else { return }
            // Always reapply, even when the plain text is unchanged — a
            // block-kind change (e.g. "# heading" -> "## heading") edits
            // only the *styling* a paragraph should have, not its
            // characters, so a plain-string comparison would never catch
            // it. Cursor position is preserved explicitly below.
            let rendered = MarkdownRendering.render(newText)
            let selectedRanges = textView.selectedRanges
            isProgrammaticUpdate = true
            storage.setAttributedString(rendered)
            isProgrammaticUpdate = false
            textView.selectedRanges = selectedRanges
        }

        /// Adds row/column insert-delete commands to the right-click menu
        /// when the click lands inside a rendered table cell.
        func textView(_ view: NSTextView, menu: NSMenu, for event: NSEvent, at charIndex: Int) -> NSMenu? {
            guard let storage = view.textStorage, MarkdownRendering.isInsideTable(storage, at: charIndex) else {
                return menu
            }

            menu.addItem(.separator())
            let items: [(String, MarkdownRendering.TableStructuralEdit)] = [
                ("Insert Row Above", .insertRowAbove),
                ("Insert Row Below", .insertRowBelow),
                ("Delete Row", .deleteRow),
                ("Insert Column Left", .insertColumnLeft),
                ("Insert Column Right", .insertColumnRight),
                ("Delete Column", .deleteColumn),
            ]
            for (title, edit) in items {
                let item = NSMenuItem(title: title, action: #selector(performTableEdit(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = TableEditRequest(view: view, charIndex: charIndex, edit: edit)
                menu.addItem(item)
            }
            return menu
        }

        @objc func performTableEdit(_ sender: NSMenuItem) {
            guard let request = sender.representedObject as? TableEditRequest,
                  let storage = request.view.textStorage,
                  let (range, replacement) = MarkdownRendering.applyTableEdit(request.edit, in: storage, at: request.charIndex)
            else { return }
            guard request.view.shouldChangeText(in: range, replacementString: replacement.string) else { return }
            storage.replaceCharacters(in: range, with: replacement)
            request.view.didChangeText()
        }

        func textView(_ textView: NSTextView, shouldChangeTextIn affectedCharRange: NSRange, replacementString: String?) -> Bool {
            // Never let newly typed text inherit the synthetic list-bullet
            // marker (it would silently vanish on the next save).
            textView.typingAttributes[MarkdownRendering.syntheticPrefixKey] = nil
            return true
        }

        func textDidChange(_ notification: Notification) {
            guard !isProgrammaticUpdate else { return }
            guard let textView = notification.object as? NSTextView,
                  let storage = textView.textStorage else { return }
            let markdown = MarkdownRendering.serialize(storage)
            isPushingEdit = true
            text.wrappedValue = markdown
            // updateNSView's isPushingEdit guard skips rebuilding THIS pane
            // for its own edit (avoids fighting the cursor mid-keystroke),
            // but that means a structural change typed directly here — e.g.
            // adding a "#" to bump a heading's level — would never get
            // restyled. Reconcile it once typing settles.
            scheduleExternalRender(of: markdown)
        }

        /// Flips a task-list item's checked state in place: only the single
        /// character between the brackets changes ("x" <-> space), going
        /// through shouldChangeText/didChangeText so it's undoable and fires
        /// the normal textDidChange -> serialize -> push pipeline above.
        func toggleCheckbox(in textView: NSTextView, markerRange: NSRange) {
            guard let storage = textView.textStorage,
                  let checked = storage.attribute(MarkdownRendering.checkboxStateKey, at: markerRange.location, effectiveRange: nil) as? Bool
            else { return }

            let newChecked = !checked
            let middleCharRange = NSRange(location: markerRange.location + 1, length: 1)
            let newChar = newChecked ? "x" : " "
            guard textView.shouldChangeText(in: middleCharRange, replacementString: newChar) else { return }

            storage.replaceCharacters(in: middleCharRange, with: newChar)
            storage.addAttribute(MarkdownRendering.checkboxStateKey, value: newChecked, range: markerRange)
            storage.addAttribute(
                .font,
                value: NSFont.monospacedSystemFont(ofSize: 15, weight: newChecked ? .bold : .regular),
                range: markerRange
            )
            textView.didChangeText()
        }
    }
}
