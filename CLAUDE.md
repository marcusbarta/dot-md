# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

dotMD is a native macOS SwiftUI app (SwiftPM package) — a markdown editor
with a live split view: plain source on the left, a fully rendered and
directly-editable rich-text pane on the right. Editing either pane keeps the
other in sync via a shared `MarkdownDocument`.

## Build & run

```sh
./build.sh
```

The only build path in normal use: builds a release binary via
`swift build -c release`, copies it into the local `dotMD.app` staging
bundle, strips `com.apple.FinderInfo` (`xattr -cr`) before signing (required
or codesign fails on a copied bundle), signs with an explicit
identifier-only designated requirement, and installs/relaunches
`/Applications/dotMD.app`.

For iteration without reinstalling:

```sh
swift build
.build/debug/dotMD
```

Notes:
- Installing to `/Applications/dotMD.app` needs `xattr -cr` run on the
  installed copy too (not just the staging bundle), then
  `codesign --verify --deep --strict` to confirm.
- Always `killall dotMD 2>/dev/null; sleep 1` before reinstalling/reopening
  in any verification cycle — the running instance holds the bundle.
- **Do not test UI changes by scripting clicks/keystrokes** (`osascript`/
  System Events). It has repeatedly proven unreliable in this environment
  (focus silently reverting to Terminal mid-script, synthetic keystrokes
  landing in the wrong app). Build and install as usual, then hand back a
  concrete manual test procedure instead.
- There is no test suite.

## Architecture

Package layout: a single executable target (`dotMD`) under
`Sources/dotMD/`, one concern per file (~2100 lines total).

**Data flow — two panes, one document**: `MarkdownDocument`
(`MarkdownDocument.swift`, `@MainActor ObservableObject`) owns the plain-text
`String`, `fileURL`, and `isDirty`. `SplitEditorView.swift` hosts both panes
(`PlainMarkdownEditor` — a bare SwiftUI `TextEditor` — and `RichTextView`)
inside a real `NSSplitView` (SwiftUI's `HSplitView` has no hook for
double-click-to-recenter, hence the `NSViewRepresentable` wrapper). Both
panes bind to the same `text`; `updateNSView` skips reassigning either
`NSHostingView`'s `rootView` when the text hasn't actually changed, to avoid
needless rebuild work.

**Rendering & re-serialization** (`MarkdownRendering.swift`, the largest
file at ~930 lines): parses via Foundation's
`AttributedString(markdown:options:)` with `.full` CommonMark interpretation,
then builds an `NSAttributedString` per block via `BlockKind` (paragraph,
heading levels 1–6, list, blockquote, code block, table). Tables render via
real `NSTextTable`/`NSTextTableBlock`. Re-serialization walks the rendered
`NSAttributedString` back into markdown text, handling `BlockFormatTarget`
(a Format-menu/keyboard-shortcut block-kind change) and
`TableStructuralEdit` (a row/column add or remove) as explicit cases, since
neither round-trips through attribute-string parsing alone.

**Trailing-whitespace restoration**: CommonMark's `.full` parse strips
trailing whitespace at a paragraph's end (nothing to soft/hard-break to).
Since the rich pane re-renders ~150ms after every keystroke pause to
reconcile structural edits, a space typed at the very end of the document
would otherwise vanish the moment typing paused. `restoreTrailingWhitespace`
(called at the end of `renderProse`) re-appends whatever trailing spaces the
source markdown had that the parse ate, using the last character's own
attributes.

**Rich pane bridging** (`RichTextView.swift`): an `NSViewRepresentable`
wrapping a custom `NSTextView` subclass (`CheckboxTextView`, which also
handles the `dotMDApplyBlockFormat:` action routed from the Format menu). Its
`Coordinator.textDidChange` schedules a debounced re-render
(`scheduleExternalRender`, ~150ms) rather than re-rendering on every
keystroke, and tracks `isPushingEdit` so a push from one pane into the
shared `text` doesn't loop back and re-render the pane that originated it —
except when the edit changed the block's *kind* (e.g. `#` → `##`), which
still needs to flow back through, since only re-rendering picks up a
structural change within the same pane.

**File-tree sidebar** (`FileTreeSidebar.swift`): `FileTree.build` walks the
directory one level above the open file's own directory (so siblings are
visible), synchronously off the main thread. `ContentView` owns and caches
the resulting `[FileNode]` outside the sidebar view itself, so toggling the
sidebar closed doesn't throw away the scan; `.task(id: FileTreeScanKey(...))`
re-scans (and cancels any in-flight scan) on file open/rename/move, not just
on root-directory change. The sidebar's width snaps to one of two measured
extremes (shortest/longest visible row) via a drag handle, using real
rendered-row widths (`PreferenceKey`) rather than estimated constants.

**File watching** (`MarkdownDocument.swift`): a
`DispatchSourceFileSystemObject` on the open file's descriptor
(`O_EVTONLY`), debounced ~150ms — an atomic external save shows up as a
delete + create (sometimes several), so this coalesces the burst into one
reload. `F_GETPATH` reads the descriptor's current path back off the kernel
on a rename event, which is how the document keeps tracking a file that was
renamed/moved externally (same volume) instead of losing it.

**Window/document lifecycle** (`DotMDApp.swift`): `AppDelegate` tracks one
`MarkdownDocument` per `NSWindow` (`documentsByWindow`), places every new
window at the same top-left spot on the primary display, and prompts to save
on window-close (`windowShouldClose`) and app-quit
(`applicationShouldTerminate`). `Info.plist` declares dotMD as an `Editor`
for markdown/plain-text (`CFBundleDocumentTypes`), which activates AppKit
document-launch machinery that races SwiftUI `WindowGroup`'s own
"show a blank window at launch" behavior — opening a file at launch can leave
an orphaned blank window behind the one that actually loaded the file.
`closeSpareBlankLaunchWindows()` closes a still-blank sibling window, called
both when a window registers and right after a document finishes opening a
URL (either might be the last piece of information needed to tell the two
apart), gated to a 5s launch grace period so a window deliberately opened
later via ⌘N is never touched.

**Tooling**: `.sourcekit-lsp/config.json` enables background indexing —
`build.sh` only ever produces a release build, so without this,
sourcekit-lsp (which indexes against the debug configuration by default) had
no persistent index and lagged behind edits, surfacing transient
"Cannot find X in scope" false positives that a real `swift build` never
reproduced.

## Working conventions in this file

- Comments in this codebase record *why* a non-obvious approach was chosen,
  often naming the simpler approach that was tried first and silently
  failed (e.g. why re-serialization can't just reuse attribute-string
  parsing, why the file watcher debounces). Match that style rather than
  commenting on what code obviously does.
- Never verify a UI/editor behavior change by scripting synthetic
  clicks/keystrokes against the running app — see the note under Build & run.
  Build, install, and hand back manual test steps instead.
- Both panes must stay driven from the single `MarkdownDocument.text` — don't
  add per-pane state that could drift from it.
