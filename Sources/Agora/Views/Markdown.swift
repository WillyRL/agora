import AppKit
import SwiftUI

/// Renders a message's Markdown: paragraphs with inline styling, headings, lists, quotes, tables,
/// and fenced code blocks with syntax colouring and a copy button.
struct MarkdownView: View {
    let text: String
    var textColor: Color = .primary

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(Self.pieces(MarkdownBlock.parse(text)).enumerated()), id: \.offset) { _, piece in
                switch piece {
                case .prose(let blocks):
                    Text(prose(blocks)).foregroundStyle(textColor).fixedSize(horizontal: false, vertical: true)
                case .block(let block):
                    view(for: block)
                }
            }
        }
        .textSelection(.enabled)
    }

    /// Text you can select across in one go, or a block that has to stand on its own.
    enum Piece {
        case prose([MarkdownBlock])
        case block(MarkdownBlock)
    }

    /// SwiftUI selects within one `Text` only, so paragraphs, headings and lists that follow each other
    /// become one `Text`. Quotes, code, tables and rules draw things text can't, and stand alone.
    static func pieces(_ blocks: [MarkdownBlock]) -> [Piece] {
        var out: [Piece] = []
        for block in blocks {
            switch block {
            case .paragraph, .heading, .list:
                if case .prose(let run) = out.last {
                    out[out.count - 1] = .prose(run + [block])
                } else {
                    out.append(.prose([block]))
                }
            default:
                out.append(.block(block))
            }
        }
        return out
    }

    /// Paragraphs, headings and lists as one string, spaced as they were as separate views.
    func prose(_ blocks: [MarkdownBlock]) -> AttributedString {
        func gap(_ points: CGFloat) -> AttributedString {
            var g = AttributedString("\n")
            g.font = .system(size: points)
            return g
        }
        var out = AttributedString()
        for (i, block) in blocks.enumerated() {
            if i > 0 {
                out += AttributedString("\n")
                out += gap(5)
            }
            switch block {
            case .paragraph(let s):
                out += inline(s)
            case .heading(let level, let s):
                var h = inline(s)
                let size: CGFloat = level == 1 ? 18 : level == 2 ? 16 : 14
                for run in h.runs where run.font == nil { h[run.range].font = .system(size: size, weight: .semibold) }
                out += h
            case .list(let items, let ordered):
                for (n, item) in items.enumerated() {
                    if n > 0 {
                        out += AttributedString("\n")
                        out += gap(2)
                    }
                    let depth = item.prefix(while: { $0 == " " }).count / 2
                    var marker = AttributedString(String(repeating: "    ", count: depth) + (ordered ? "\(n + 1)." : "•") + "  ")
                    marker.foregroundColor = .secondary
                    out += marker
                    out += inline(String(item.drop(while: { $0 == " " })))
                }
            default:
                break
            }
        }
        return out
    }

    @ViewBuilder
    func view(for block: MarkdownBlock) -> some View {
        switch block {
        case .paragraph(let s):
            Text(inline(s)).foregroundStyle(textColor).fixedSize(horizontal: false, vertical: true)
        case .heading(let level, let s):
            Text(inline(s))
                .font(.system(size: level == 1 ? 18 : level == 2 ? 16 : 14, weight: .semibold))
                .foregroundStyle(textColor)
                .padding(.top, 2)
        case .list(let items, let ordered):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { i, item in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(ordered ? "\(i + 1)." : "•").foregroundStyle(.secondary).monospacedDigit()
                        Text(inline(item)).foregroundStyle(textColor).fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.leading, CGFloat(item.prefix(while: { $0 == " " }).count / 2) * 12)
                }
            }
        case .quote(let s):
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 1).fill(Theme.accent.opacity(0.5)).frame(width: 3)
                Text(inline(s)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        case .code(let language, let code):
            CodeBlockView(language: language, code: code)
        case .rule:
            Divider()
        case .table(let header, let alignments, let rows):
            table(header: header, alignments: alignments, rows: rows)
        }
    }

    func table(header: [String], alignments: [HorizontalAlignment], rows: [[String]]) -> some View {
        Grid(alignment: .topLeading, horizontalSpacing: 0, verticalSpacing: 0) {
            GridRow {
                ForEach(header.indices, id: \.self) { i in
                    cell(header[i], alignment: alignments[i]).font(.system(size: 13, weight: .semibold))
                }
            }
            .background(Color.primary.opacity(0.05))
            ForEach(rows.indices, id: \.self) { r in
                Divider().gridCellUnsizedAxes(.horizontal)
                GridRow {
                    ForEach(header.indices, id: \.self) { i in
                        cell(i < rows[r].count ? rows[r][i] : "", alignment: alignments[i])
                    }
                }
            }
        }
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.hairline))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .fixedSize(horizontal: false, vertical: true)
    }

    func cell(_ s: String, alignment: HorizontalAlignment) -> some View {
        Text(inline(s))
            .foregroundStyle(textColor)
            .multilineTextAlignment(alignment == .trailing ? .trailing : alignment == .center ? .center : .leading)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: Alignment(horizontal: alignment, vertical: .top))
            .gridColumnAlignment(alignment)
    }

    func inline(_ s: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace, failurePolicy: .returnPartiallyParsedIfPossible)
        var a = (try? AttributedString(markdown: s, options: options)) ?? AttributedString(s)
        for run in a.runs where run.inlinePresentationIntent?.contains(.code) == true {
            a[run.range].font = .system(size: 12.5, design: .monospaced)
            a[run.range].backgroundColor = Color.primary.opacity(0.07)
        }
        return a
    }
}

enum MarkdownBlock: Equatable {
    case paragraph(String)
    case heading(Int, String)
    case list([String], ordered: Bool)
    case quote(String)
    case code(String, String)
    case rule
    /// Header cells, column alignments, body rows.
    case table([String], [HorizontalAlignment], [[String]])

    static func == (a: MarkdownBlock, b: MarkdownBlock) -> Bool {
        switch (a, b) {
        case (.paragraph(let x), .paragraph(let y)), (.quote(let x), .quote(let y)): return x == y
        case (.heading(let l, let x), .heading(let m, let y)): return l == m && x == y
        case (.list(let x, let o), .list(let y, let p)): return x == y && o == p
        case (.code(let l, let x), .code(let m, let y)): return l == m && x == y
        case (.rule, .rule): return true
        case (.table(let h, _, let r), .table(let i, _, let q)): return h == i && r == q
        default: return false
        }
    }

    /// `| a | b |` → ["a", "b"]. Pipes inside `code` or escaped as `\|` stay in the cell.
    static func cells(_ line: String) -> [String] {
        var t = line.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("|") { t.removeFirst() }
        if t.hasSuffix("|") && !t.hasSuffix("\\|") { t.removeLast() }
        var cells: [String] = []
        var current = ""
        var inCode = false
        var escaped = false
        for ch in t {
            if escaped {
                current.append(ch == "|" ? "|" : "\\\(ch)")
                escaped = false
            } else if ch == "\\" {
                escaped = true
            } else if ch == "`" {
                inCode.toggle()
                current.append(ch)
            } else if ch == "|" && !inCode {
                cells.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            } else {
                current.append(ch)
            }
        }
        cells.append(current.trimmingCharacters(in: .whitespaces))
        return cells
    }

    /// A `|---|:--:|` line: one alignment per column, or nil if it isn't one.
    static func separator(_ line: String) -> [HorizontalAlignment]? {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard t.contains("-"), t.contains("|") || t.hasPrefix(":") || t.hasPrefix("-") else { return nil }
        let parts = cells(t)
        guard !parts.isEmpty else { return nil }
        var result: [HorizontalAlignment] = []
        for p in parts {
            guard !p.isEmpty, p.allSatisfy({ $0 == "-" || $0 == ":" }), p.contains("-") else { return nil }
            result.append(p.hasPrefix(":") && p.hasSuffix(":") ? .center : p.hasSuffix(":") ? .trailing : .leading)
        }
        return result
    }

    static func parse(_ text: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var paragraph: [String] = []
        var list: [String] = []
        var ordered = false
        var quote: [String] = []
        var code: [String]? = nil
        var language = ""

        func flush() {
            if !paragraph.isEmpty { blocks.append(.paragraph(paragraph.joined(separator: "\n"))); paragraph = [] }
            if !list.isEmpty { blocks.append(.list(list, ordered: ordered)); list = [] }
            if !quote.isEmpty { blocks.append(.quote(quote.joined(separator: "\n"))); quote = [] }
        }

        let lines = text.components(separatedBy: "\n")
        var index = 0
        while index < lines.count {
            let line = lines[index]
            index += 1
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if code != nil {
                if trimmed.hasPrefix("```") {
                    blocks.append(.code(language, code!.joined(separator: "\n")))
                    code = nil
                } else {
                    code!.append(line)
                }
                continue
            }
            if trimmed.hasPrefix("```") {
                flush()
                language = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                code = []
                continue
            }
            if trimmed.isEmpty {
                flush()
                continue
            }
            if trimmed == "---" || trimmed == "***" || trimmed == "___" {
                flush()
                blocks.append(.rule)
                continue
            }
            if let hashes = trimmed.firstIndex(where: { $0 != "#" }), trimmed.hasPrefix("#"), trimmed[hashes] == " " {
                flush()
                let level = trimmed.distance(from: trimmed.startIndex, to: hashes)
                blocks.append(.heading(min(level, 4), String(trimmed[hashes...]).trimmingCharacters(in: .whitespaces)))
                continue
            }
            // A table: a row of cells, then a `|---|---|` line.
            if code == nil, trimmed.contains("|"), index < lines.count, let aligns = separator(lines[index]) {
                let header = cells(trimmed)
                if header.count == aligns.count {
                    flush()
                    index += 1
                    var rows: [[String]] = []
                    while index < lines.count {
                        let row = lines[index].trimmingCharacters(in: .whitespaces)
                        guard !row.isEmpty, row.contains("|") else { break }
                        rows.append(cells(row))
                        index += 1
                    }
                    blocks.append(.table(header, aligns, rows))
                    continue
                }
            }
            if trimmed.hasPrefix(">") {
                if !paragraph.isEmpty || !list.isEmpty { flush() }
                quote.append(String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces))
                continue
            }
            let indent = String(line.prefix(while: { $0 == " " }))
            if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("+ ") {
                if !paragraph.isEmpty || !quote.isEmpty || (ordered && !list.isEmpty) { flush() }
                ordered = false
                list.append(indent + String(trimmed.dropFirst(2)))
                continue
            }
            if let dot = trimmed.firstIndex(where: { !$0.isNumber }), dot != trimmed.startIndex,
                trimmed[dot] == "." || trimmed[dot] == ")", trimmed.index(after: dot) < trimmed.endIndex, trimmed[trimmed.index(after: dot)] == " "
            {
                if !paragraph.isEmpty || !quote.isEmpty || (!ordered && !list.isEmpty) { flush() }
                ordered = true
                list.append(indent + String(trimmed[trimmed.index(dot, offsetBy: 2)...]))
                continue
            }
            if !list.isEmpty, line.hasPrefix("  ") {
                list[list.count - 1] += " " + trimmed
                continue
            }
            if !list.isEmpty || !quote.isEmpty { flush() }
            paragraph.append(line)
        }
        if let code { blocks.append(.code(language, code.joined(separator: "\n"))) }
        flush()
        return blocks
    }
}

struct CodeBlockView: View {
    let language: String
    let code: String
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(language.isEmpty ? "code" : language)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(code, forType: .string)
                    copied = true
                    Task {
                        try? await Task.sleep(for: .seconds(1.5))
                        copied = false
                    }
                } label: {
                    Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 11))
                }
                .buttonStyle(.borderless)
                .help("Copy code")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color.primary.opacity(0.04))
            ScrollView(.horizontal, showsIndicators: false) {
                Text(SyntaxHighlighter.highlight(code, language: language))
                    .font(.system(size: 12.5, design: .monospaced))
                    .padding(10)
                    .fixedSize(horizontal: true, vertical: false)
            }
        }
        .background(Color.primary.opacity(0.035))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.hairline))
    }
}

/// A small, dependency-free highlighter: comments, strings, numbers and common keywords.
enum SyntaxHighlighter {
    static let keywords: Set<String> = [
        "func", "let", "var", "if", "else", "for", "while", "return", "import", "struct", "class", "enum", "case", "switch", "def", "from",
        "async", "await", "try", "catch", "throw", "throws", "public", "private", "static", "const", "function", "new", "true", "false",
        "nil", "null", "None", "True", "False", "in", "of", "do", "break", "continue", "guard", "self", "this", "export", "default", "type",
        "interface", "extends", "implements", "fn", "pub", "use", "mod", "impl", "match", "elif", "lambda", "with", "as", "yield", "and",
        "or", "not", "is", "echo", "then", "fi", "done", "esac", "package", "go", "select", "SELECT", "FROM", "WHERE", "INSERT", "UPDATE",
        "DELETE", "JOIN", "ON", "AND", "OR", "GROUP", "ORDER", "BY",
    ]

    static func highlight(_ code: String, language: String) -> AttributedString {
        var out = AttributedString()
        let keywordColor = Color(red: 0.61, green: 0.25, blue: 0.85)
        let stringColor = Color(red: 0.77, green: 0.3, blue: 0.17)
        let commentColor = Color.secondary
        let numberColor = Color(red: 0.1, green: 0.45, blue: 0.75)
        let hashComments = ["python", "py", "sh", "bash", "zsh", "shell", "ruby", "rb", "yaml", "yml", "toml", ""].contains(language.lowercased())
        let chars = Array(code)
        var i = 0
        func append(_ s: String, _ color: Color?) {
            var a = AttributedString(s)
            if let color { a.foregroundColor = color }
            out += a
        }
        while i < chars.count {
            let c = chars[i]
            if c == "/" && i + 1 < chars.count && chars[i + 1] == "/" || (hashComments && c == "#") {
                var j = i
                while j < chars.count && chars[j] != "\n" { j += 1 }
                append(String(chars[i..<j]), commentColor)
                i = j
            } else if c == "\"" || c == "'" || c == "`" {
                var j = i + 1
                while j < chars.count && chars[j] != c && chars[j] != "\n" {
                    if chars[j] == "\\" { j += 1 }
                    j += 1
                }
                j = min(j + 1, chars.count)
                append(String(chars[i..<j]), stringColor)
                i = j
            } else if c.isNumber {
                var j = i
                while j < chars.count && (chars[j].isNumber || chars[j] == ".") { j += 1 }
                append(String(chars[i..<j]), numberColor)
                i = j
            } else if c.isLetter || c == "_" {
                var j = i
                while j < chars.count && (chars[j].isLetter || chars[j].isNumber || chars[j] == "_") { j += 1 }
                let word = String(chars[i..<j])
                append(word, keywords.contains(word) ? keywordColor : nil)
                i = j
            } else {
                append(String(c), nil)
                i += 1
            }
        }
        return out
    }
}
