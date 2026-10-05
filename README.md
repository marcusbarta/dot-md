# dotMD

A native macOS markdown editor with a live split view: plain markdown source
on the left, a fully rendered/editable rich-text pane on the right — editing
either pane keeps the other in sync.

- Split editor (`SplitEditorView.swift`) — a real `NSSplitView` (double-click
  the divider to recenter), plain source on the left, rendered prose on the
  right.
- The rendered pane supports direct editing: type into a heading, list,
  blockquote, table, or code block and it re-serializes back to markdown —
  no need to hand-type `#`/`>`/`` ``` `` syntax.
- A **Format** menu and keyboard shortcuts (⌘0–⌘6 for paragraph/headings,
  ⌘⇧7–9 for lists/blockquote) change the current block's kind directly from
  the rendered pane.
- Structural table editing (add/remove rows and columns) directly in the
  rendered pane, not just editing existing cells' text.
- Watches the open file for external changes (another editor, `git checkout`,
  a sync tool) and prompts to reload or keep your in-progress edits.

## Run it

```sh
./build.sh
```

Builds a release binary, code-signs it (ad-hoc/development identity — see
[MONETIZATION.md](MONETIZATION.md) for what's needed for real distribution),
and installs/launches `/Applications/dotMD.app`.

For iteration without reinstalling:

```sh
swift build
.build/debug/dotMD
```

There is no test suite.

## How it works

- **Two source-of-truth panes, one document.** `MarkdownDocument`
  (`MarkdownDocument.swift`) owns the plain-text `String`; both panes bind to
  it through `SplitEditorView`. Typing in the plain pane re-renders the rich
  pane; typing in the rich pane re-serializes back into markdown and pushes
  that into the shared text — `RichTextView.swift`'s `Coordinator` tracks
  which pane originated an edit (`isPushingEdit`) so the update doesn't loop.
- **Rendering** (`MarkdownRendering.swift`, the largest file): parses via
  Foundation's `AttributedString(markdown:options:)` with
  `.full` CommonMark interpretation, then walks the result to build an
  `NSAttributedString` per block (`BlockKind`: paragraph, heading levels,
  list, blockquote, code block, table via `NSTextTable`). Re-serialization
  (rich pane → markdown) walks the same attributed string back into text,
  handling `BlockFormatTarget` (Format-menu block changes) and
  `TableStructuralEdit` (row/column add-remove) explicitly, since neither
  round-trips through plain `AttributedString` parsing alone.
- **Debounced re-render**: `Coordinator.scheduleExternalRender(of:)`
  coalesces rapid typing into a single re-parse ~150ms after typing pauses,
  used both to sync the plain pane's edits into the rich pane and to
  reconcile structural changes (e.g. a heading-level bump) typed directly
  into the rich pane. `restoreTrailingWhitespace` re-appends any trailing
  spaces CommonMark's parse strips from a paragraph's end, so a debounced
  re-render mid-sentence doesn't silently eat a space the user just typed.
- **File watching** (`MarkdownDocument.swift`): a `DispatchSourceFileSystemObject`
  on the open file's descriptor, debounced ~150ms (many editors save via
  write-temp-then-rename, which fires a burst of delete/create events), with
  `F_GETPATH` used to follow the file across an external rename/move on the
  same volume.
- **Window/document lifecycle** (`DotMDApp.swift`): `AppDelegate` tracks one
  `MarkdownDocument` per `NSWindow`, places new windows at a fixed top-left
  position, and prompts to save on window-close/quit. Because `Info.plist`
  declares dotMD as an `Editor` for markdown/plain-text (`CFBundleDocumentTypes`),
  launching by opening a file races SwiftUI `WindowGroup`'s own
  "show a blank window at launch" behavior — `closeSpareBlankLaunchWindows()`
  closes the spare blank window left behind, but only within a 5s launch
  grace period, so a window you open later with ⌘N is never touched.

## Not built yet

See [TODO.md](TODO.md) for in-progress work and [MONETIZATION.md](MONETIZATION.md)
for what's needed before this can be distributed/sold (code signing beyond
ad-hoc, notarization, auto-update, crash reporting, license/privacy policy).
