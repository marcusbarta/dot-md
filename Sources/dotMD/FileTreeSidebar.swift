import SwiftUI
import AppKit

struct FileNode: Identifiable {
    let id: URL
    let isDirectory: Bool
    var children: [FileNode]?

    var name: String { id.lastPathComponent }

    /// Only markdown files can actually be opened into this editor —
    /// everything else is shown but greyed out and inert.
    var isOpenable: Bool {
        isDirectory || ["md", "markdown"].contains(id.pathExtension.lowercased())
    }
}

enum FileTree {
    static func build(rootDirectory: URL) -> [FileNode] {
        children(of: rootDirectory)
    }

    private static func children(of directory: URL) -> [FileNode] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        return entries
            .map { url -> FileNode in
                let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
                return FileNode(id: url, isDirectory: isDir, children: isDir ? children(of: url) : nil)
            }
            .sorted { lhs, rhs in
                if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
    }
}

/// Reports a row's true trailing edge (in the list's own coordinate space),
/// both the widest and narrowest currently-visible row, so the sidebar can
/// snap its width to fit either exactly — this measures the real rendered
/// layout (icon, indent, disclosure triangle) instead of estimating it from
/// guessed constants.
private struct RowTrailingEdgeMaxKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct RowTrailingEdgeMinKey: PreferenceKey {
    static var defaultValue: CGFloat = .greatestFiniteMagnitude
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = min(value, nextValue())
    }
}

/// Shows the directory the current document lives in, plus its sibling
/// directories (the tree is rooted one level up, at that directory's
/// parent). Clicking a file opens it into the current window's document
/// (going through the usual unsaved-changes prompt), the same way Cmd+O
/// does. Only currently-visible (expanded) rows are measured, so the two
/// snap widths re-settle as folders expand/collapse.
struct FileTreeSidebar: View {
    let rootDirectory: URL?
    /// The directory the open document actually lives in (one level below
    /// `rootDirectory`) — expanded by default so its contents are visible
    /// without an extra click, the same way this sidebar looked before
    /// siblings were added. Sibling directories start collapsed.
    let currentFileDirectory: URL?
    /// Computed and cached by ContentView (not here) so it survives this
    /// view being torn down and recreated on every sidebar toggle.
    let nodes: [FileNode]
    /// Hard ceiling on the sidebar's width — 1/3 of the window's current
    /// total width, passed down by ContentView. Wins over both snap widths
    /// below, so a very long name can still get truncated rather than the
    /// sidebar ever exceeding this.
    let maxWidth: CGFloat
    let onOpen: (URL) -> Void

    private static let minimumWidth: CGFloat = 140
    private static let placeholderWidth: CGFloat = 220
    private static let trailingBuffer: CGFloat = 16
    private static let handleWidth: CGFloat = 6
    private static let coordinateSpaceName = "DotMDFileTree"

    private enum WidthMode { case shortest, longest }

    @State private var widthMode: WidthMode = .shortest
    @State private var shortestWidth: CGFloat = FileTreeSidebar.minimumWidth
    @State private var longestWidth: CGFloat = FileTreeSidebar.minimumWidth
    /// Captured once at the start of a drag so the live drag position can be
    /// compared against the two fixed snap targets, independent of which one
    /// is currently showing.
    @State private var dragStartWidth: CGFloat?
    /// Paths (not URLs — sidesteps any trailing-slash/equality quirks)
    /// currently expanded in the tree. Seeded with the open file's directory
    /// and grown additively as the user expands more or opens other files,
    /// so manual expansions aren't lost.
    @State private var expandedPaths: Set<String> = []

    private var displayedWidth: CGFloat {
        min(widthMode == .longest ? longestWidth : shortestWidth, maxWidth)
    }

    var body: some View {
        Group {
            if rootDirectory != nil {
                List {
                    ForEach(nodes) { node in
                        recursiveRow(for: node)
                    }
                }
                .listStyle(.sidebar)
                .coordinateSpace(name: Self.coordinateSpaceName)
                .onAppear {
                    expandedPaths.formUnion(defaultExpansion(target: currentFileDirectory))
                }
                .onChange(of: rootDirectory) { _, newRoot in
                    expandedPaths = defaultExpansion(root: newRoot, target: currentFileDirectory)
                }
                .onChange(of: currentFileDirectory) { _, newDirectory in
                    expandedPaths.formUnion(defaultExpansion(target: newDirectory))
                }
                .onPreferenceChange(RowTrailingEdgeMaxKey.self) { trailingEdge in
                    longestWidth = max(trailingEdge + Self.trailingBuffer, Self.minimumWidth)
                }
                .onPreferenceChange(RowTrailingEdgeMinKey.self) { trailingEdge in
                    guard trailingEdge.isFinite else { return }
                    shortestWidth = max(trailingEdge + Self.trailingBuffer, Self.minimumWidth)
                }
                .frame(width: displayedWidth)
                .overlay(alignment: .trailing) { dragHandle }
                .animation(.interactiveSpring(response: 0.25, dampingFraction: 0.85), value: widthMode)
            } else {
                VStack {
                    Spacer()
                    Text("Save the document to browse its folder")
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding()
                    Spacer()
                }
                .frame(width: min(Self.placeholderWidth, maxWidth))
            }
        }
    }

    /// A thin, invisible strip on the sidebar's trailing edge that can be
    /// dragged to resize — but only ever settles at the shortest- or
    /// longest-name width, never anywhere in between. Whichever snap target
    /// is nearer the live drag position wins, so it flips the moment the
    /// drag crosses the midpoint between the two.
    private var dragHandle: some View {
        Color.clear
            .frame(width: Self.handleWidth)
            .contentShape(Rectangle())
            .onHover { inside in
                if inside {
                    NSCursor.resizeLeftRight.push()
                } else {
                    NSCursor.pop()
                }
            }
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { value in
                        let startWidth = dragStartWidth ?? displayedWidth
                        if dragStartWidth == nil { dragStartWidth = startWidth }
                        let candidate = startWidth + value.translation.width
                        let midpoint = (shortestWidth + longestWidth) / 2
                        widthMode = candidate <= midpoint ? .shortest : .longest
                    }
                    .onEnded { _ in
                        dragStartWidth = nil
                    }
            )
    }

    /// Ancestor directory paths (inclusive of `target`, exclusive of `root`)
    /// that should start out expanded so `target`'s contents are visible
    /// without a click. Defaults `root` to `rootDirectory` since that never
    /// changes mid-computation except in the explicit root-change handler.
    private func defaultExpansion(root: URL? = nil, target: URL?) -> Set<String> {
        guard let target, let root = (root ?? rootDirectory) else { return [] }
        let rootPath = root.standardizedFileURL.path
        var expanded: Set<String> = []
        var current = target.standardizedFileURL
        while current.path != rootPath, current.path.count > rootPath.count {
            expanded.insert(current.path)
            current = current.deletingLastPathComponent()
        }
        return expanded
    }

    // Type-erased because this recurses into itself — a `some View` return
    // type can't be inferred for a function that calls itself.
    private func recursiveRow(for node: FileNode) -> AnyView {
        if node.isDirectory {
            return AnyView(
                DisclosureGroup(isExpanded: expansionBinding(for: node.id)) {
                    ForEach(node.children ?? []) { child in
                        recursiveRow(for: child)
                    }
                } label: {
                    row(for: node)
                }
            )
        } else {
            return AnyView(row(for: node))
        }
    }

    private func expansionBinding(for url: URL) -> Binding<Bool> {
        let path = url.standardizedFileURL.path
        return Binding(
            get: { expandedPaths.contains(path) },
            set: { isExpanded in
                if isExpanded {
                    expandedPaths.insert(path)
                } else {
                    expandedPaths.remove(path)
                }
            }
        )
    }

    @ViewBuilder
    private func row(for node: FileNode) -> some View {
        Group {
            if node.isDirectory {
                Label(node.name, systemImage: "folder")
            } else if node.isOpenable {
                Button {
                    onOpen(node.id)
                } label: {
                    Label(node.name, systemImage: "doc.text")
                }
                .buttonStyle(.plain)
            } else {
                Label(node.name, systemImage: "doc.text")
                    .foregroundStyle(.tertiary)
            }
        }
        // Forces the row to lay out at its true intrinsic width rather than
        // being truncated to whatever width the sidebar currently has — the
        // measurement below needs the untruncated size to snap correctly.
        .fixedSize(horizontal: true, vertical: false)
        .background(
            GeometryReader { geo in
                let trailingEdge = geo.frame(in: .named(Self.coordinateSpaceName)).maxX
                Color.clear
                    .preference(key: RowTrailingEdgeMaxKey.self, value: trailingEdge)
                    .preference(key: RowTrailingEdgeMinKey.self, value: trailingEdge)
            }
        )
    }
}
