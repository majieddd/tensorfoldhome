import SwiftUI

/// A small Markdown renderer for chat answers: headings, paragraphs, lists, quotes, tables, rules and fenced code
/// blocks (with a copy button). Inline styling (bold, italic, code, links, strikethrough) comes from Foundation.
/// It must cope with half-written text while an answer streams, so an unclosed fence runs to the end.
enum MDBlock: Equatable {
    case heading(Int, String)
    case paragraph(String)
    case code(lang: String, text: String)
    case list([MDItem])
    case quote([MDBlock])
    case table(header: [String], align: [HorizontalAlignment], rows: [[String]])
    case rule

    static func == (a: MDBlock, b: MDBlock) -> Bool { String(describing: a) == String(describing: b) }
}

struct MDItem: Equatable {
    let indent: Int
    let marker: String     // "•" or "3."
    let text: String
}

enum Markdown {
    static func parse(_ src: String) -> [MDBlock] {
        let lines = src.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var out: [MDBlock] = []
        var para: [String] = []
        var i = 0

        func flush() {
            if !para.isEmpty { out.append(.paragraph(para.joined(separator: "\n"))); para = [] }
        }

        while i < lines.count {
            let line = lines[i]
            let t = line.trimmingCharacters(in: .whitespaces)

            // fenced code
            if t.hasPrefix("```") || t.hasPrefix("~~~") {
                flush()
                let fenceChar = t.first!
                let fenceLen = t.prefix { $0 == fenceChar }.count
                let lang = t.dropFirst(fenceLen).trimmingCharacters(in: .whitespaces)
                var body: [String] = []
                i += 1
                while i < lines.count {
                    let l = lines[i].trimmingCharacters(in: .whitespaces)
                    if l.hasPrefix(String(repeating: String(fenceChar), count: fenceLen)) && l.allSatisfy({ $0 == fenceChar }) { break }
                    body.append(lines[i])
                    i += 1
                }
                out.append(.code(lang: lang, text: body.joined(separator: "\n")))
                i += 1
                continue
            }
            if t.isEmpty { flush(); i += 1; continue }

            // heading
            if let m = t.range(of: #"^#{1,6}\s+"#, options: .regularExpression) {
                flush()
                let level = t[m].filter { $0 == "#" }.count
                out.append(.heading(level, String(t[m.upperBound...]).trimmingCharacters(in: CharacterSet(charactersIn: "# "))))
                i += 1
                continue
            }
            // rule
            if t.range(of: #"^([-*_])(\s*\1){2,}$"#, options: .regularExpression) != nil && para.isEmpty {
                out.append(.rule); i += 1; continue
            }
            // table: a row, then a separator row
            if t.contains("|"), i + 1 < lines.count, isSeparator(lines[i + 1]) {
                flush()
                let header = cells(t)
                let align = cells(lines[i + 1]).map { c -> HorizontalAlignment in
                    let l = c.hasPrefix(":"), r = c.hasSuffix(":")
                    return l && r ? .center : r ? .trailing : .leading
                }
                var rows: [[String]] = []
                i += 2
                while i < lines.count, lines[i].contains("|"), !lines[i].trimmingCharacters(in: .whitespaces).isEmpty {
                    rows.append(cells(lines[i]))
                    i += 1
                }
                out.append(.table(header: header, align: align, rows: rows))
                continue
            }
            // quote
            if t.hasPrefix(">") {
                flush()
                var inner: [String] = []
                while i < lines.count {
                    let l = lines[i].trimmingCharacters(in: .whitespaces)
                    guard l.hasPrefix(">") else { break }
                    inner.append(String(l.dropFirst()).replacingOccurrences(of: #"^ "#, with: "", options: .regularExpression))
                    i += 1
                }
                out.append(.quote(parse(inner.joined(separator: "\n"))))
                continue
            }
            // list
            if listMatch(line) != nil {
                flush()
                var items: [MDItem] = []
                while i < lines.count {
                    if let m = listMatch(lines[i]) {
                        items.append(m)
                        i += 1
                    } else if !items.isEmpty, !lines[i].trimmingCharacters(in: .whitespaces).isEmpty,
                              lines[i].hasPrefix("  ") || lines[i].hasPrefix("\t") {
                        let last = items.removeLast()   // a continuation line of the item above
                        items.append(MDItem(indent: last.indent, marker: last.marker,
                                            text: last.text + "\n" + lines[i].trimmingCharacters(in: .whitespaces)))
                        i += 1
                    } else if lines[i].trimmingCharacters(in: .whitespaces).isEmpty, i + 1 < lines.count, listMatch(lines[i + 1]) != nil {
                        i += 1                          // a blank line between items
                    } else { break }
                }
                out.append(.list(items))
                continue
            }
            para.append(line)
            i += 1
        }
        flush()
        return out
    }

    static func listMatch(_ line: String) -> MDItem? {
        guard let m = line.range(of: #"^(\s*)([-*+•]|\d{1,3}[.)])\s+"#, options: .regularExpression) else { return nil }
        let head = String(line[m])
        let indent = head.prefix { $0 == " " || $0 == "\t" }.reduce(0) { $0 + ($1 == "\t" ? 4 : 1) } / 2
        let mark = head.trimmingCharacters(in: .whitespaces)
        let marker = mark.first!.isNumber ? mark.replacingOccurrences(of: ")", with: ".") : "•"
        var text = String(line[m.upperBound...])
        if text.hasPrefix("[ ] ") { text = "☐ " + text.dropFirst(4) }
        if text.lowercased().hasPrefix("[x] ") { text = "☑ " + text.dropFirst(4) }
        return MDItem(indent: min(indent, 4), marker: marker, text: text)
    }

    static func isSeparator(_ line: String) -> Bool {
        line.range(of: #"^\s*\|?\s*:?-{2,}:?\s*(\|\s*:?-{2,}:?\s*)*\|?\s*$"#, options: .regularExpression) != nil
    }

    static func cells(_ line: String) -> [String] {
        var t = line.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("|") { t.removeFirst() }
        if t.hasSuffix("|") && !t.hasSuffix("\\|") { t.removeLast() }
        return t.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
    }

    /// Inline Markdown as an AttributedString, with `code` spans in the monospaced font on a tinted background.
    static func inline(_ s: String, size: CGFloat, pal: Palette) -> AttributedString {
        let opts = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace,
                                                           failurePolicy: .returnPartiallyParsedIfPossible)
        var a = (try? AttributedString(markdown: s, options: opts)) ?? AttributedString(s)
        for run in a.runs {
            if let intent = run.inlinePresentationIntent, intent.contains(.code) {
                a[run.range].font = Fonts.mono(size * 0.9)
                a[run.range].backgroundColor = pal.surface2
                a[run.range].foregroundColor = pal.ink
            }
            if run.link != nil {
                a[run.range].foregroundColor = pal.accentText
                a[run.range].underlineStyle = .single
            }
        }
        return a
    }
}

struct MarkdownView: View {
    @Environment(\.pal) var pal
    let text: String
    var size: CGFloat = 15

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(Markdown.parse(text).enumerated()), id: \.offset) { _, b in
                BlockView(block: b, size: size)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct BlockView: View {
    @Environment(\.pal) var pal
    @EnvironmentObject var model: AppModel
    let block: MDBlock
    let size: CGFloat

    var body: some View {
        switch block {
        case .heading(let level, let text):
            Text(Markdown.inline(text, size: size, pal: pal))
                .outfit(level == 1 ? size + 7 : level == 2 ? size + 4 : level == 3 ? size + 2 : size, .bold)
                .foregroundStyle(pal.ink)
                .padding(.top, level <= 2 ? 6 : 2)
                .textSelection(.enabled)
        case .paragraph(let text):
            Text(Markdown.inline(text, size: size, pal: pal))
                .outfit(size).foregroundStyle(pal.inkSoft).lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        case .code(let lang, let text):
            CodeBlock(lang: lang, text: text)
        case .list(let items):
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, it in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(it.marker).outfit(size, it.marker == "•" ? .bold : .medium).foregroundStyle(pal.inkMuted)
                            .frame(minWidth: it.marker == "•" ? 10 : 22, alignment: .trailing)
                        Text(Markdown.inline(it.text, size: size, pal: pal))
                            .outfit(size).foregroundStyle(pal.inkSoft).lineSpacing(4)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                    .padding(.leading, CGFloat(it.indent) * 20)
                }
            }
        case .quote(let blocks):
            HStack(alignment: .top, spacing: 12) {
                RoundedRectangle(cornerRadius: 2).fill(pal.line).frame(width: 3)
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(blocks.enumerated()), id: \.offset) { _, b in BlockView(block: b, size: size) }
                }
                .opacity(0.85)
            }
            .fixedSize(horizontal: false, vertical: true)
        case .table(let header, let align, let rows):
            TableBlock(header: header, align: align, rows: rows, size: size)
        case .rule:
            Rectangle().fill(pal.line).frame(height: 1).padding(.vertical, 4)
        }
    }
}

private struct CodeBlock: View {
    @Environment(\.pal) var pal
    @EnvironmentObject var model: AppModel
    let lang: String
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(lang.isEmpty ? "code" : lang).font(Fonts.mono(12)).foregroundStyle(pal.codeInk.opacity(0.6))
                Spacer()
                Button {
                    Clip.copy(text)
                    model.toast(.success, "Copied", "", seconds: 1.5)
                } label: {
                    Label("Copy", systemImage: "doc.on.doc").font(Fonts.outfit(12, .medium)).foregroundStyle(pal.codeInk.opacity(0.75))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(Color.white.opacity(0.05))
            ScrollView(.horizontal, showsIndicators: true) {
                Text(text.isEmpty ? " " : text)
                    .font(Fonts.mono(13)).foregroundStyle(pal.codeInk)
                    .lineSpacing(3)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: true, vertical: true)
                    .padding(14)
            }
        }
        .background(RoundedRectangle(cornerRadius: 12).fill(pal.codeBg))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

private struct TableBlock: View {
    @Environment(\.pal) var pal
    let header: [String]
    let align: [HorizontalAlignment]
    let rows: [[String]]
    let size: CGFloat

    var body: some View {
        ScrollView(.horizontal, showsIndicators: true) {
            Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
                GridRow {
                    ForEach(0..<header.count, id: \.self) { c in cell(header[c], c, bold: true) }
                }
                .background(pal.surface2)
                ForEach(0..<rows.count, id: \.self) { r in
                    Divider().overlay(pal.lineSoft).gridCellUnsizedAxes(.horizontal)
                    GridRow {
                        ForEach(0..<header.count, id: \.self) { c in cell(c < rows[r].count ? rows[r][c] : "", c, bold: false) }
                    }
                }
            }
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(pal.line, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
    }

    func cell(_ s: String, _ c: Int, bold: Bool) -> some View {
        Text(Markdown.inline(s, size: size - 1, pal: pal))
            .outfit(size - 1, bold ? .bold : .regular)
            .foregroundStyle(bold ? pal.ink : pal.inkSoft)
            .textSelection(.enabled)
            .padding(.horizontal, 12).padding(.vertical, 8)
            .frame(maxWidth: 360, alignment: Alignment(horizontal: c < align.count ? align[c] : .leading, vertical: .center))
            .gridColumnAlignment(c < align.count ? align[c] : .leading)
    }
}
