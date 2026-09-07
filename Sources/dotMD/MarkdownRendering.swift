import Foundation
import AppKit

/// Renders markdown source into a styled, editable NSAttributedString, and
/// serializes an edited NSAttributedString back into markdown source.
///
/// Both directions work entirely through Swift's `AttributedString` and its
/// typed `presentationIntent` / `inlinePresentationIntent` / `link`
/// attributes (from Foundation's markdown parser), which survive bridging to
/// and from `NSAttributedString` intact. That means we never need to touch
/// the underlying Objective-C `NSPresentationIntent` class directly.
///
/// Foundation's markdown parser encodes block structure (headers, list
/// items, quotes, paragraphs) purely as `presentationIntent` metadata on
/// runs — it does not insert line breaks into the text itself. Both
/// directions below have to group runs into blocks using that metadata:
/// `render` inserts the line breaks/bullets a plain NSTextView needs to show
/// separate blocks, and `serialize` uses the same grouping to emit one
/// markdown line per block.
///
/// Tables are a separate concern: Foundation's markdown parser has no
/// concept of GFM tables at all (same gap as task-list checkboxes, just
/// bigger) — a table in the source would otherwise come through as garbled
/// plain paragraphs. `render`/`serialize` both split the document into
/// alternating prose/table segments first; prose segments go through the
/// pipeline above unchanged, table segments are handled separately via
/// AppKit's native `NSTextTable`.
enum MarkdownRendering {

    /// Marks list-bullet text that `render` synthesizes (it has no
    /// corresponding markdown source characters) so `serialize` can strip it
    /// back out before reconstructing markdown from block structure.
    static let syntheticPrefixKey = NSAttributedString.Key("DotMDSyntheticPrefix")

    /// Marks a task-list item's "[ ] "/"[x] " marker (its checked state, as
    /// a Bool) so the rendered pane can detect a click on it and toggle it.
    /// Unlike `syntheticPrefixKey`, this text is NOT synthetic — it's the
    /// original source characters, just restyled — so it round-trips through
    /// `serialize` for free with no special-casing there.
    static let checkboxStateKey = NSAttributedString.Key("DotMDCheckboxState")

    enum BlockKind: Equatable {
        case plain
        case header(Int)
        case blockQuote
        case listItem(ordered: Bool, ordinal: Int)
        case codeBlock(language: String?)
    }

    /// The block kinds a user can switch a paragraph to from the Format menu
    /// / keyboard shortcuts. Distinct from `BlockKind` since a target has no
    /// existing ordinal/language to preserve — those get defaults.
    enum BlockFormatTarget {
        case paragraph
        case header(Int)
        case blockQuote
        case bulletList
        case numberedList
    }

    enum TableStructuralEdit {
        case insertRowAbove, insertRowBelow, deleteRow
        case insertColumnLeft, insertColumnRight, deleteColumn
    }

    private static func blockInfo(for run: AttributedString.Runs.Run) -> (identity: Int?, kind: BlockKind) {
        guard let intent = run.presentationIntent else { return (nil, .plain) }

        var identity: Int?
        for component in intent.components {
            switch component.kind {
            case .paragraph, .header, .codeBlock:
                identity = component.identity
            default:
                break
            }
        }
        if identity == nil {
            identity = intent.components.first?.identity
        }

        var kind: BlockKind = .plain
        for component in intent.components {
            switch component.kind {
            case .header(let level):
                kind = .header(level)
            case .blockQuote:
                kind = .blockQuote
            case .listItem(let ordinal):
                let ordered = intent.components.contains { if case .orderedList = $0.kind { return true }; return false }
                kind = .listItem(ordered: ordered, ordinal: ordinal)
            case .codeBlock(let languageHint):
                kind = .codeBlock(language: languageHint)
            default:
                break
            }
        }
        return (identity, kind)
    }

    /// Detects a GFM task-list marker ("[ ] "/"[x] "/"[X] ") at the start of
    /// an unordered list item's text, returning its checked state.
    private static func checkboxState(forBlockPlainText text: String) -> Bool? {
        if text.hasPrefix("[ ] ") { return false }
        if text.hasPrefix("[x] ") || text.hasPrefix("[X] ") { return true }
        return nil
    }

    // MARK: - Tables

    struct MarkdownTable {
        enum ColumnAlignment { case natural, left, center, right }
        var headerCells: [String]
        var alignments: [ColumnAlignment]
        var rows: [[String]]
    }

    private enum DocumentSegment {
        case prose(String)
        case table(MarkdownTable)
    }

    /// Splits raw markdown into alternating prose/table segments by scanning
    /// for a GFM table (a header row + a valid "---" alignment row) at the
    /// start of each still-unconsumed line.
    private static func splitIntoSegments(_ markdown: String) -> [DocumentSegment] {
        let lines = markdown.components(separatedBy: "\n")
        var segments: [DocumentSegment] = []
        var proseLines: [String] = []
        var i = 0

        func flushProse() {
            let text = proseLines.joined(separator: "\n").trimmingCharacters(in: .newlines)
            if !text.isEmpty {
                segments.append(.prose(text))
            }
            proseLines = []
        }

        while i < lines.count {
            if let (table, nextIndex) = tryParseTable(lines: lines, startingAt: i) {
                flushProse()
                segments.append(.table(table))
                i = nextIndex
            } else {
                proseLines.append(lines[i])
                i += 1
            }
        }
        flushProse()
        return segments
    }

    private static func tryParseTable(lines: [String], startingAt index: Int) -> (MarkdownTable, Int)? {
        guard index + 1 < lines.count,
              let headerCells = splitTableRow(lines[index]), !headerCells.isEmpty,
              let separatorCells = splitTableRow(lines[index + 1]),
              separatorCells.count == headerCells.count
        else { return nil }

        var alignments: [MarkdownTable.ColumnAlignment] = []
        for cell in separatorCells {
            let trimmed = cell.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, trimmed.allSatisfy({ $0 == "-" || $0 == ":" }), trimmed.contains("-") else {
                return nil
            }
            let leftColon = trimmed.hasPrefix(":")
            let rightColon = trimmed.hasSuffix(":")
            if leftColon && rightColon {
                alignments.append(.center)
            } else if rightColon {
                alignments.append(.right)
            } else if leftColon {
                alignments.append(.left)
            } else {
                alignments.append(.natural)
            }
        }

        var rows: [[String]] = []
        var next = index + 2
        while next < lines.count, let rowCells = splitTableRow(lines[next]) {
            var cells = rowCells
            if cells.count < headerCells.count {
                cells += Array(repeating: "", count: headerCells.count - cells.count)
            } else if cells.count > headerCells.count {
                cells = Array(cells.prefix(headerCells.count))
            }
            rows.append(cells)
            next += 1
        }

        return (MarkdownTable(headerCells: headerCells, alignments: alignments, rows: rows), next)
    }

    /// Splits a single "| a | b |" line into unescaped, trimmed cell strings.
    /// Returns nil if the line doesn't look like a table row at all.
    private static func splitTableRow(_ line: String) -> [String]? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.contains("|") else { return nil }
        var inner = Substring(trimmed)
        if inner.hasPrefix("|") { inner.removeFirst() }
        if inner.hasSuffix("|") { inner.removeLast() }

        var cells: [String] = []
        var current = ""
        var escaping = false
        for char in inner {
            if escaping {
                current.append(char)
                escaping = false
            } else if char == "\\" {
                escaping = true
            } else if char == "|" {
                cells.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            } else {
                current.append(char)
            }
        }
        cells.append(current.trimmingCharacters(in: .whitespaces))
        return cells
    }

    private static func escapeCellText(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "|", with: "\\|")
    }

    // MARK: - Markdown -> styled NSAttributedString

    static func render(_ markdown: String) -> NSAttributedString {
        let segments = splitIntoSegments(markdown)
        guard !segments.isEmpty else { return NSAttributedString() }

        let result = NSMutableAttributedString()
        for (index, segment) in segments.enumerated() {
            switch segment {
            case .prose(let text):
                result.append(renderProse(text))
            case .table(let table):
                result.append(renderTable(table))
            }
            if index < segments.count - 1 {
                result.append(NSAttributedString(string: "\n\n", attributes: [syntheticPrefixKey: true]))
            }
        }
        return result
    }

    private static func renderTable(_ table: MarkdownTable) -> NSAttributedString {
        let nsTable = NSTextTable()
        let columnCount = table.headerCells.count
        nsTable.numberOfColumns = columnCount
        nsTable.layoutAlgorithm = .automaticLayoutAlgorithm

        let result = NSMutableAttributedString()
        let allRows = [table.headerCells] + table.rows

        for (rowIndex, row) in allRows.enumerated() {
            for colIndex in 0..<columnCount {
                let cellText = colIndex < row.count ? row[colIndex] : ""

                let block = NSTextTableBlock(
                    table: nsTable,
                    startingRow: rowIndex,
                    rowSpan: 1,
                    startingColumn: colIndex,
                    columnSpan: 1
                )
                block.setBorderColor(NSColor.separatorColor)
                block.setWidth(1, type: .absoluteValueType, for: .border)
                block.setWidth(6, type: .absoluteValueType, for: .padding)
                if rowIndex == 0 {
                    // Blended toward .labelColor (not a fixed .black) so it
                    // stays visible in both appearances — labelColor is
                    // black in light mode and white in dark mode, so this
                    // darkens the header row in light mode and lightens it
                    // in dark mode instead of nearly vanishing against an
                    // already-dark background.
                    block.backgroundColor = NSColor.textBackgroundColor.blended(withFraction: 0.08, of: .labelColor) ?? .clear
                }

                let paragraphStyle = NSMutableParagraphStyle()
                paragraphStyle.textBlocks = [block]
                let alignment = colIndex < table.alignments.count ? table.alignments[colIndex] : .natural
                switch alignment {
                case .center: paragraphStyle.alignment = .center
                case .right: paragraphStyle.alignment = .right
                case .left: paragraphStyle.alignment = .left
                case .natural: paragraphStyle.alignment = .natural
                }

                var cellAttrString: AttributedString
                let inlineOptions = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
                if let parsed = try? AttributedString(markdown: cellText, options: inlineOptions) {
                    cellAttrString = parsed
                } else {
                    cellAttrString = AttributedString(cellText)
                }
                styleInline(&cellAttrString)

                let bridgedCell: NSAttributedString = NSAttributedString(cellAttrString)
                let cellNSAttr = NSMutableAttributedString(attributedString: bridgedCell)
                if rowIndex == 0 {
                    let range = NSRange(location: 0, length: cellNSAttr.length)
                    cellNSAttr.addAttribute(.font, value: NSFont.boldSystemFont(ofSize: bodyFont.pointSize), range: range)
                }
                let fullRange = NSRange(location: 0, length: cellNSAttr.length)
                cellNSAttr.addAttribute(.paragraphStyle, value: paragraphStyle, range: fullRange)
                cellNSAttr.append(NSAttributedString(string: "\n", attributes: [.paragraphStyle: paragraphStyle]))
                result.append(cellNSAttr)
            }
        }
        return result
    }

    private static func renderProse(_ markdown: String) -> NSAttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .full)
        guard !markdown.isEmpty, var parsed = try? AttributedString(markdown: markdown, options: options) else {
            var fallback = AttributedString(markdown)
            fallback.font = bodyFont
            return NSAttributedString(fallback)
        }
        styleInline(&parsed)

        // Group runs into contiguous blocks (they appear in document order),
        // then reassemble with line breaks and list bullets between blocks.
        struct Block {
            var kind: BlockKind
            var range: Range<AttributedString.Index>
        }
        var blocks: [Block] = []
        var currentID: Int?
        var currentKind: BlockKind = .plain
        var blockStart: AttributedString.Index?

        for run in parsed.runs {
            let (identity, kind) = blockInfo(for: run)
            if identity != currentID {
                if let start = blockStart {
                    blocks.append(Block(kind: currentKind, range: start..<run.range.lowerBound))
                }
                currentID = identity
                currentKind = kind
                blockStart = run.range.lowerBound
            }
        }
        if let start = blockStart {
            blocks.append(Block(kind: currentKind, range: start..<parsed.endIndex))
        }

        let result = NSMutableAttributedString()
        for (index, block) in blocks.enumerated() {
            if case .listItem(let ordered, let ordinal) = block.kind {
                let prefixText = ordered ? "\(ordinal).\u{2002}" : "\u{2022}\u{2002}"
                let indentStyle = NSMutableParagraphStyle()
                indentStyle.headIndent = 18
                let prefix = NSMutableAttributedString(string: prefixText, attributes: [
                    .font: bodyFont,
                    .foregroundColor: NSColor.labelColor,
                    .paragraphStyle: indentStyle,
                    syntheticPrefixKey: true
                ])
                result.append(prefix)
            }

            let contentStart = result.length
            result.append(NSAttributedString(AttributedString(parsed[block.range])))

            // Task-list item ("- [ ] " / "- [x] "): restyle the original
            // marker characters in place (not synthesized text) so the
            // checkbox is clickable and still round-trips through serialize
            // untouched.
            if case .listItem(let ordered, _) = block.kind, !ordered,
               let checked = checkboxState(forBlockPlainText: String(parsed[block.range].characters)) {
                let markerRange = NSRange(location: contentStart, length: 4)
                result.addAttribute(checkboxStateKey, value: checked, range: markerRange)
                result.addAttribute(.foregroundColor, value: NSColor.controlAccentColor, range: markerRange)
                result.addAttribute(
                    .font,
                    value: NSFont.monospacedSystemFont(ofSize: bodyFont.pointSize, weight: checked ? .bold : .regular),
                    range: markerRange
                )
            }

            if index < blocks.count - 1 {
                let nextIsSameList: Bool = {
                    if case .listItem(let a, _) = block.kind, case .listItem(let b, _) = blocks[index + 1].kind { return a == b }
                    return false
                }()
                let separator = NSAttributedString(
                    string: nextIsSameList ? "\n" : "\n\n",
                    attributes: [syntheticPrefixKey: true]
                )
                result.append(separator)
            }
        }
        restoreTrailingWhitespace(from: markdown, into: result)
        return result
    }

    /// CommonMark strips trailing whitespace at the end of a paragraph (there's
    /// nothing after it to soft/hard-break to), but this re-render also fires
    /// mid-edit, 150ms after every keystroke, to reconcile structural changes
    /// (see `Coordinator.textDidChange`). Without this, a space typed at the
    /// very end of the document — i.e. every space, until you type the next
    /// word right after it — would silently vanish the moment typing pauses,
    /// making the space bar look broken. Re-append whatever trailing spaces
    /// the source actually had that the parse ate.
    private static func restoreTrailingWhitespace(from markdown: String, into result: NSMutableAttributedString) {
        let sourceTrailingSpaces = markdown.reversed().prefix { $0 == " " }.count
        guard sourceTrailingSpaces > 0 else { return }
        let renderedTrailingSpaces = result.string.reversed().prefix { $0 == " " }.count
        guard sourceTrailingSpaces > renderedTrailingSpaces else { return }
        let attributes: [NSAttributedString.Key: Any] = result.length > 0
            ? result.attributes(at: result.length - 1, effectiveRange: nil)
            : [.font: bodyFont, .foregroundColor: NSColor.labelColor]
        let padding = String(repeating: " ", count: sourceTrailingSpaces - renderedTrailingSpaces)
        result.append(NSAttributedString(string: padding, attributes: attributes))
    }

    private static let bodyFont = NSFont.systemFont(ofSize: 15)
    private static let codeFont = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)

    private static func headerFont(level: Int) -> NSFont {
        let size: CGFloat = switch level {
        case 1: 28
        case 2: 23
        case 3: 20
        case 4: 17
        default: 16
        }
        return NSFont.boldSystemFont(ofSize: size)
    }

    /// Applies fonts/colors per run in place. Block-level line breaks and
    /// list bullets are handled separately by `render`, since they require
    /// restructuring the string rather than just tagging attributes.
    private static func styleInline(_ attr: inout AttributedString) {
        attr.font = bodyFont
        attr.foregroundColor = NSColor.labelColor

        for run in attr.runs {
            let range = run.range
            let (_, kind) = blockInfo(for: run)
            var isHeader = false

            switch kind {
            case .header(let level):
                isHeader = true
                attr[range].font = headerFont(level: level)
            case .blockQuote:
                attr[range].foregroundColor = NSColor.secondaryLabelColor
                let style = NSMutableParagraphStyle()
                style.headIndent = 18
                style.firstLineHeadIndent = 18
                attr[range].paragraphStyle = style
            case .listItem:
                let style = NSMutableParagraphStyle()
                style.headIndent = 18
                attr[range].paragraphStyle = style
            case .codeBlock:
                attr[range].font = codeFont
                // See the table header comment above on why this blends
                // toward .labelColor rather than a fixed .black.
                attr[range].backgroundColor = NSColor.textBackgroundColor.blended(withFraction: 0.06, of: .labelColor)
            case .plain:
                break
            }

            if let inline = run.inlinePresentationIntent {
                if inline.contains(.code) {
                    attr[range].font = codeFont
                    attr[range].backgroundColor = NSColor.textBackgroundColor.blended(withFraction: 0.06, of: .labelColor)
                } else if !isHeader {
                    let currentFont = attr[range].font ?? bodyFont
                    var traits: NSFontDescriptor.SymbolicTraits = currentFont.fontDescriptor.symbolicTraits
                    if inline.contains(.stronglyEmphasized) { traits.insert(.bold) }
                    if inline.contains(.emphasized) { traits.insert(.italic) }
                    if !traits.isEmpty {
                        let descriptor = currentFont.fontDescriptor.withSymbolicTraits(traits)
                        attr[range].font = NSFont(descriptor: descriptor, size: currentFont.pointSize) ?? currentFont
                    }
                    if inline.contains(.strikethrough) {
                        attr[range].strikethroughStyle = .single
                    }
                }
            }

            if run.link != nil {
                attr[range].foregroundColor = NSColor.linkColor
                attr[range].underlineStyle = .single
            }
        }
    }

    // MARK: - Edited NSAttributedString -> markdown

    static func serialize(_ ns: NSAttributedString) -> String {
        // Segment splitting must happen on the RAW (unstripped) string —
        // the synthetic separator between a table and adjacent prose is
        // real newline characters, and stripping them first would collapse
        // the line boundary between the last prose line and the table's
        // first cell, corrupting it. Stripping happens per-segment instead,
        // inside serializeProse, where it's safe.
        let segments = splitIntoNSSegments(ns)

        let lines = segments.map { segment -> String in
            switch segment {
            case .prose(let sub):
                return serializeProse(sub)
            case .table(let sub, let table):
                return serializeTable(sub, table: table)
            }
        }.filter { !$0.isEmpty }

        return lines.joined(separator: "\n\n")
    }

    private enum NSSegment {
        case prose(NSAttributedString)
        case table(NSAttributedString, NSTextTable)
    }

    /// Splits an edited attributed string into contiguous prose vs. table
    /// stretches, by walking paragraph-by-paragraph and checking each one's
    /// paragraph style for an `NSTextTableBlock` — this is exactly the
    /// marker `renderTable` leaves on every cell, and it survives ordinary
    /// text edits (typing within a cell doesn't touch paragraphStyle).
    private static func splitIntoNSSegments(_ ns: NSAttributedString) -> [NSSegment] {
        let fullString = ns.string as NSString
        var segments: [NSSegment] = []
        var currentTable: NSTextTable?
        var currentStart = 0
        var searchLocation = 0

        func tableBlock(at location: Int) -> NSTextTableBlock? {
            guard location < ns.length else { return nil }
            let style = ns.attribute(.paragraphStyle, at: location, effectiveRange: nil) as? NSParagraphStyle
            return style?.textBlocks.first as? NSTextTableBlock
        }

        func flush(upTo end: Int) {
            guard end > currentStart else { return }
            let range = NSRange(location: currentStart, length: end - currentStart)
            let sub = ns.attributedSubstring(from: range)
            if let table = currentTable {
                segments.append(.table(sub, table))
            } else {
                segments.append(.prose(sub))
            }
        }

        while searchLocation < fullString.length {
            let lineRange = fullString.lineRange(for: NSRange(location: searchLocation, length: 0))
            let paragraphTable = tableBlock(at: lineRange.location)?.table

            if ObjectIdentifier(paragraphTable ?? placeholderTable) != ObjectIdentifier(currentTable ?? placeholderTable) {
                flush(upTo: lineRange.location)
                currentStart = lineRange.location
                currentTable = paragraphTable
            }
            searchLocation = lineRange.location + lineRange.length
        }
        flush(upTo: fullString.length)
        return segments
    }

    /// Never actually used as a table — just a distinct sentinel identity so
    /// "no table" can be compared with `ObjectIdentifier` the same way a
    /// real table would be.
    private static let placeholderTable = NSTextTable()

    private static func serializeTable(_ ns: NSAttributedString, table: NSTextTable) -> String {
        let fullString = ns.string as NSString
        var cellsByPosition: [Int: [Int: String]] = [:]
        var alignmentsByColumn: [Int: NSTextAlignment] = [:]
        var maxRow = 0

        var location = 0
        while location < fullString.length {
            let lineRange = fullString.lineRange(for: NSRange(location: location, length: 0))
            guard let style = ns.attribute(.paragraphStyle, at: lineRange.location, effectiveRange: nil) as? NSParagraphStyle,
                  let block = style.textBlocks.first as? NSTextTableBlock,
                  block.table === table
            else {
                location = lineRange.location + lineRange.length
                continue
            }

            var cellRange = lineRange
            if cellRange.length > 0, fullString.character(at: cellRange.location + cellRange.length - 1) == 10 {
                cellRange.length -= 1
            }
            let cellText = serializeInlineOnly(ns.attributedSubstring(from: cellRange))

            cellsByPosition[block.startingRow, default: [:]][block.startingColumn] = cellText
            alignmentsByColumn[block.startingColumn] = style.alignment
            maxRow = max(maxRow, block.startingRow)

            location = lineRange.location + lineRange.length
        }

        guard let headerRow = cellsByPosition[0] else { return "" }
        let columnCount = table.numberOfColumns

        func rowLine(_ cells: [Int: String]) -> String {
            let ordered = (0..<columnCount).map { escapeCellText(cells[$0] ?? "") }
            return "| " + ordered.joined(separator: " | ") + " |"
        }

        var lines: [String] = []
        lines.append(rowLine(headerRow))

        let separatorCells = (0..<columnCount).map { col -> String in
            switch alignmentsByColumn[col] {
            case .center: return ":---:"
            case .right: return "---:"
            case .left: return ":---"
            default: return "---"
            }
        }
        lines.append("| " + separatorCells.joined(separator: " | ") + " |")

        if maxRow > 0 {
            for row in 1...maxRow {
                guard let rowCells = cellsByPosition[row] else { continue }
                lines.append(rowLine(rowCells))
            }
        }

        return lines.joined(separator: "\n")
    }

    // MARK: - Format menu: changing a block's kind in place

    /// Rewrites the block kind (header level / blockquote / list / plain
    /// paragraph) of the single line containing `location` in an edited,
    /// rendered attributed string, returning the affected range (the whole
    /// line, including any synthetic list-bullet prefix `render` added) and
    /// its freshly rendered replacement. Returns nil if `location` falls
    /// inside a table cell (structural table edits go through
    /// `applyTableEdit` instead) or the line is empty.
    static func reformattedBlock(in ns: NSAttributedString, at location: Int, to target: BlockFormatTarget) -> (NSRange, NSAttributedString)? {
        let fullString = ns.string as NSString
        guard fullString.length > 0 else { return nil }
        let clampedLocation = min(location, fullString.length - 1)
        let lineRange = fullString.lineRange(for: NSRange(location: clampedLocation, length: 0))
        guard lineRange.length > 0 else { return nil }

        if let style = ns.attribute(.paragraphStyle, at: lineRange.location, effectiveRange: nil) as? NSParagraphStyle,
           style.textBlocks.first is NSTextTableBlock {
            return nil
        }

        var cellRange = lineRange
        var trailingNewline: NSAttributedString?
        if cellRange.length > 0, fullString.character(at: cellRange.location + cellRange.length - 1) == 10 {
            cellRange.length -= 1
            // Keep the original newline character (and its attributes,
            // notably `syntheticPrefixKey` when it's a block separator
            // rather than real source text) instead of manufacturing a
            // plain one — a fresh untagged "\n" here would survive
            // `strippingSyntheticPrefixes` and corrupt the next serialize.
            trailingNewline = ns.attributedSubstring(from: NSRange(location: cellRange.location + cellRange.length, length: 1))
        }

        let lineAttrString = ns.attributedSubstring(from: cellRange)
        let stripped = strippingSyntheticPrefixes(lineAttrString)
        guard let attr = try? AttributedString(stripped, including: \.foundation) else { return nil }

        var text = ""
        for run in attr.runs {
            text += inlineMarkdown(for: run, plain: String(attr[run.range].characters))
        }
        text = text.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }

        let newSourceLine: String
        switch target {
        case .paragraph:
            newSourceLine = text
        case .header(let level):
            newSourceLine = String(repeating: "#", count: max(1, min(level, 6))) + " " + text
        case .blockQuote:
            newSourceLine = "> " + text
        case .bulletList:
            newSourceLine = "- " + text
        case .numberedList:
            newSourceLine = "1. " + text
        }

        let rebuilt = NSMutableAttributedString(attributedString: renderProse(newSourceLine))
        if let trailingNewline {
            rebuilt.append(trailingNewline)
        }
        return (lineRange, rebuilt)
    }

    // MARK: - Structural table editing (add/remove rows and columns)

    /// True if the paragraph style at `location` carries an `NSTextTableBlock`
    /// — i.e. `location` is inside a rendered table cell. Used to decide
    /// whether to offer table row/column commands at all.
    static func isInsideTable(_ ns: NSAttributedString, at location: Int) -> Bool {
        guard location < ns.length,
              let style = ns.attribute(.paragraphStyle, at: location, effectiveRange: nil) as? NSParagraphStyle
        else { return false }
        return style.textBlocks.first is NSTextTableBlock
    }

    /// Expands from the line at `location` to the full contiguous run of
    /// lines belonging to the same `NSTextTable` (by identity), so an edited
    /// table segment can be swapped out wholesale.
    private static func tableSegmentRange(in ns: NSAttributedString, at location: Int, table: NSTextTable) -> NSRange {
        let fullString = ns.string as NSString

        func lineBelongsToTable(_ loc: Int) -> Bool {
            guard loc < fullString.length,
                  let style = ns.attribute(.paragraphStyle, at: loc, effectiveRange: nil) as? NSParagraphStyle,
                  let block = style.textBlocks.first as? NSTextTableBlock
            else { return false }
            return block.table === table
        }

        var start = fullString.lineRange(for: NSRange(location: location, length: 0)).location
        while start > 0 {
            let prevLineRange = fullString.lineRange(for: NSRange(location: start - 1, length: 0))
            guard lineBelongsToTable(prevLineRange.location) else { break }
            start = prevLineRange.location
        }

        let currentLineRange = fullString.lineRange(for: NSRange(location: location, length: 0))
        var endLoc = currentLineRange.location + currentLineRange.length
        while endLoc < fullString.length {
            let nextLineRange = fullString.lineRange(for: NSRange(location: endLoc, length: 0))
            guard lineBelongsToTable(nextLineRange.location) else { break }
            endLoc = nextLineRange.location + nextLineRange.length
        }

        return NSRange(location: start, length: endLoc - start)
    }

    /// Applies a row/column insert-or-delete to the table at `location`,
    /// going through the same markdown model as ordinary table
    /// serialization: extract the table's current markdown, edit its
    /// structure, then re-render it wholesale. Returns the affected range in
    /// `ns` (the table's full segment) and its replacement, or nil if
    /// `location` isn't inside a table or the edit isn't applicable (e.g.
    /// deleting the last remaining column).
    static func applyTableEdit(_ edit: TableStructuralEdit, in ns: NSAttributedString, at location: Int) -> (NSRange, NSAttributedString)? {
        guard location < ns.length,
              let style = ns.attribute(.paragraphStyle, at: location, effectiveRange: nil) as? NSParagraphStyle,
              let block = style.textBlocks.first as? NSTextTableBlock
        else { return nil }

        let table = block.table
        let row = block.startingRow
        let col = block.startingColumn

        let range = tableSegmentRange(in: ns, at: location, table: table)
        let sub = ns.attributedSubstring(from: range)
        let markdown = serializeTable(sub, table: table)
        guard let (parsedTable, _) = tryParseTable(lines: markdown.components(separatedBy: "\n"), startingAt: 0) else { return nil }

        var updated = parsedTable
        switch edit {
        case .insertRowAbove, .insertRowBelow:
            let blankRow = Array(repeating: "", count: updated.headerCells.count)
            if row == 0 {
                updated.rows.insert(blankRow, at: 0)
            } else {
                let dataIndex = row - 1
                let insertAt = edit == .insertRowAbove ? dataIndex : dataIndex + 1
                updated.rows.insert(blankRow, at: min(max(insertAt, 0), updated.rows.count))
            }
        case .deleteRow:
            guard row > 0 else { return nil } // deleting the header row isn't supported
            let dataIndex = row - 1
            guard updated.rows.indices.contains(dataIndex) else { return nil }
            updated.rows.remove(at: dataIndex)
        case .insertColumnLeft, .insertColumnRight:
            let insertAt = edit == .insertColumnLeft ? col : col + 1
            let clampedAt = min(max(insertAt, 0), updated.headerCells.count)
            updated.headerCells.insert("", at: clampedAt)
            updated.alignments.insert(.natural, at: clampedAt)
            for i in updated.rows.indices {
                let rowInsertAt = min(clampedAt, updated.rows[i].count)
                updated.rows[i].insert("", at: rowInsertAt)
            }
        case .deleteColumn:
            guard updated.headerCells.count > 1, updated.headerCells.indices.contains(col) else { return nil }
            updated.headerCells.remove(at: col)
            if updated.alignments.indices.contains(col) { updated.alignments.remove(at: col) }
            for i in updated.rows.indices where updated.rows[i].indices.contains(col) {
                updated.rows[i].remove(at: col)
            }
        }

        let rebuilt = renderTable(updated)
        return (range, rebuilt)
    }

    /// Emits inline markdown (bold/italic/code/links) for a single table
    /// cell's content, ignoring block-level kind entirely (a cell is never
    /// more than one line/paragraph).
    private static func serializeInlineOnly(_ ns: NSAttributedString) -> String {
        guard let attr = try? AttributedString(ns, including: \.foundation) else {
            return ns.string
        }
        var text = ""
        for run in attr.runs {
            let substring = String(attr[run.range].characters)
            text += inlineMarkdown(for: run, plain: substring)
        }
        return text
    }

    private static func serializeProse(_ ns: NSAttributedString) -> String {
        let stripped = strippingSyntheticPrefixes(ns)
        guard let attr = try? AttributedString(stripped, including: \.foundation) else {
            return stripped.string
        }

        struct Paragraph {
            var kind: BlockKind
            var text: String
        }

        var paragraphs: [Paragraph] = []
        var currentID: Int?
        var currentKind: BlockKind = .plain
        var currentText = ""
        var hasStarted = false

        // `currentID` can legitimately be nil for a block (e.g. freshly
        // typed text that hasn't inherited any block metadata), so we can't
        // use it to distinguish "nothing accumulated yet" from "the current
        // block just happens to have no identity" — track that separately.
        func flush() {
            guard hasStarted else { return }
            paragraphs.append(Paragraph(kind: currentKind, text: currentText))
            currentText = ""
        }

        for run in attr.runs {
            let substring = String(attr[run.range].characters)
            let (identity, kind) = blockInfo(for: run)

            if !hasStarted {
                currentID = identity
                currentKind = kind
                hasStarted = true
            } else if identity != currentID {
                flush()
                currentID = identity
                currentKind = kind
            }

            currentText += inlineMarkdown(for: run, plain: substring)
        }
        flush()

        let lines: [(kind: BlockKind, text: String)] = paragraphs.map { paragraph in
            let text: String
            switch paragraph.kind {
            case .plain:
                text = paragraph.text
            case .header(let level):
                text = String(repeating: "#", count: max(1, min(level, 6))) + " " + paragraph.text
            case .blockQuote:
                text = "> " + paragraph.text
            case .listItem(let ordered, let ordinal):
                text = (ordered ? "\(ordinal). " : "- ") + paragraph.text
            case .codeBlock(let language):
                let content = paragraph.text.hasSuffix("\n") ? String(paragraph.text.dropLast()) : paragraph.text
                text = "```\(language ?? "")\n\(content)\n```"
            }
            return (paragraph.kind, text)
        }

        var result = ""
        for (index, line) in lines.enumerated() {
            result += line.text
            if index < lines.count - 1 {
                let nextIsSameList: Bool = {
                    if case .listItem(let a, _) = line.kind, case .listItem(let b, _) = lines[index + 1].kind { return a == b }
                    return false
                }()
                result += nextIsSameList ? "\n" : "\n\n"
            }
        }
        return result
    }

    private static func strippingSyntheticPrefixes(_ ns: NSAttributedString) -> NSAttributedString {
        let mutable = NSMutableAttributedString(attributedString: ns)
        var rangesToRemove: [NSRange] = []
        mutable.enumerateAttribute(syntheticPrefixKey, in: NSRange(location: 0, length: mutable.length)) { value, range, _ in
            if value != nil { rangesToRemove.append(range) }
        }
        for range in rangesToRemove.reversed() {
            mutable.deleteCharacters(in: range)
        }
        return mutable
    }

    private static func inlineMarkdown(for run: AttributedString.Runs.Run, plain: String) -> String {
        if let url = run.link {
            return "[\(plain)](\(url.absoluteString))"
        }
        guard let inline = run.inlinePresentationIntent else { return plain }

        var text = plain
        if inline.contains(.code) {
            return "`\(text)`"
        }
        if inline.contains(.stronglyEmphasized) && inline.contains(.emphasized) {
            text = "***\(text)***"
        } else if inline.contains(.stronglyEmphasized) {
            text = "**\(text)**"
        } else if inline.contains(.emphasized) {
            text = "*\(text)*"
        }
        if inline.contains(.strikethrough) {
            text = "~~\(text)~~"
        }
        return text
    }
}
