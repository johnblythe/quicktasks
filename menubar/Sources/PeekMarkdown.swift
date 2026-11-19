// PeekMarkdown.swift -- the answer peek's markdown, made digestible.
//
// The desk's thread pane renders markdown properly (thread.js's mdThread);
// the menubar peek used to strip only the emphasis markers and dump the
// rest as one dense run of text -- headings arrived as "# Status", lists
// as "- item" minus the dash, links as "[text](url)" noise. This file
// gives the peek the same digestibility without a web view:
//
//   peekBlocks(md)          a pure parser: markdown -> [PeekBlock], where a
//                           block is a heading / paragraph / bullet /
//                           ordered item / code fence / quote, inline
//                           syntax still inside its text
//   peekAttributedString(   the styling pass: each block becomes styled
//     blocks, inline:)      runs -- headings semibold, bullets re-bulleted,
//                           code in mono on warm paper, links kept as their
//                           underlined text -- through AttributedString, so
//                           a Text renders it with zero HTML involved
//
// The parse is deliberately forgiving: anything it does not recognise is a
// paragraph, never dropped, never crashed on. A block list is plain data,
// so the `--ask-md-blocks` seam can print it and the tests can pin it.
//
// The same escape-free posture as the desk: we never build markup, only
// attributed runs, so there is nothing to escape against.

import SwiftUI

/// One block of the answer, as the peek will draw it.
struct PeekBlock: Equatable {
    enum Kind: Equatable {
        case heading
        case para
        /// A `-`/`*`/`+` item; the depth is the leading-space step (2
        /// spaces per level), so nested lists nest visually.
        case bullet(depth: Int)
        /// A `3.` item; the number is kept -- an ordered list's order is
        /// information, not decoration.
        case ordered(number: String)
        /// A fenced ``` block; the text is the fence's lines verbatim.
        case code
        /// A `>` line; the marker is not information, the indent is.
        case quote
    }

    let kind: Kind
    /// The block's text with inline syntax (**bold**, `code`, [t](u))
    /// still present -- the styling pass resolves those into runs.
    var text: String

    /// The block as the seam prints it: kind + depth/number where they
    /// exist, so a test can pin a whole parse as one JSON object.
    var json: [String: Any] {
        var out: [String: Any] = ["kind": kindName, "text": text]
        switch kind {
        case .bullet(let depth): out["depth"] = depth
        case .ordered(let number): out["number"] = number
        default: break
        }
        return out
    }

    private var kindName: String {
        switch kind {
        case .heading: return "heading"
        case .para: return "para"
        case .bullet: return "bullet"
        case .ordered: return "ordered"
        case .code: return "code"
        case .quote: return "quote"
        }
    }
}

/// Markdown -> blocks. Pure; no SwiftUI types, so it runs anywhere.
func peekBlocks(_ md: String) -> [PeekBlock] {
    var blocks: [PeekBlock] = []
    var para: [String] = []
    var inFence = false
    var fenceLines: [String] = []

    func flushPara() {
        let text = para.joined(separator: " ").trimmingCharacters(in: .whitespaces)
        if !text.isEmpty {
            // A lone **bold** line is how the models label their sections:
            // read it as the heading it means to be -- the same rule the
            // address page's md_html applies, so both surfaces agree.
            if let inner = allBold(text) {
                blocks.append(PeekBlock(kind: .heading, text: inner))
            } else {
                blocks.append(PeekBlock(kind: .para, text: text))
            }
        }
        para = []
    }

    for rawLine in (md ?? "").split(separator: "\n", omittingEmptySubsequences: false) {
        let line = String(rawLine)
        let trimmed = line.trimmingCharacters(in: .whitespaces)

        // Fences first: inside one, nothing else parses.
        if inFence {
            if trimmed.hasPrefix("```") {
                blocks.append(PeekBlock(kind: .code, text: fenceLines.joined(separator: "\n")))
                fenceLines = []
                inFence = false
            } else {
                fenceLines.append(line)
            }
            continue
        }
        if trimmed.hasPrefix("```") {
            flushPara()
            inFence = true
            continue
        }

        // A horizontal rule says "new section" in a way a menu row cannot
        // draw; a blank line between blocks carries the same break.
        if trimmed.isEmpty { flushPara(); continue }
        if ["---", "***", "___"].contains(trimmed) { flushPara(); continue }

        if let hashes = headingLevel(trimmed) {
            flushPara()
            let text = trimmed.dropFirst(hashes).trimmingCharacters(in: .whitespaces)
            if !text.isEmpty { blocks.append(PeekBlock(kind: .heading, text: text)) }
            continue
        }
        if trimmed.hasPrefix(">") {
            flushPara()
            let text = trimmed.dropFirst().trimmingCharacters(in: .whitespaces)
            if !text.isEmpty { blocks.append(PeekBlock(kind: .quote, text: text)) }
            continue
        }
        if let bullet = bulletItem(line) {
            flushPara()
            if !bullet.text.isEmpty { blocks.append(PeekBlock(kind: .bullet(depth: bullet.depth), text: bullet.text)) }
            continue
        }
        if let ordered = orderedItem(line) {
            flushPara()
            if !ordered.text.isEmpty { blocks.append(PeekBlock(kind: .ordered(number: ordered.number), text: ordered.text)) }
            continue
        }
        // A lazy continuation of the paragraph above (markdown's own rule).
        para.append(trimmed)
    }
    if inFence, !fenceLines.isEmpty {
        // An unterminated fence is still content; draw it as code.
        blocks.append(PeekBlock(kind: .code, text: fenceLines.joined(separator: "\n")))
    }
    flushPara()
    return blocks
}

/// A lone `**bold**` line -- a section label the models write -- or nil
/// when the line is anything else.
private func allBold(_ line: String) -> String? {
    guard line.hasPrefix("**"), line.hasSuffix("**"), line.count > 4 else { return nil }
    let inner = String(line.dropFirst(2).dropLast(2))
    return inner.contains("*") ? nil : inner
}

private func headingLevel(_ line: String) -> Int? {
    var level = 0
    for ch in line {
        if ch == "#" { level += 1 } else { break }
    }
    // 1-6 hashes followed by a space or end-of-line is a heading; more, or
    // no space ("#hashtag"), is just text.
    if (1...6).contains(level),
       level == line.count || line[line.index(line.startIndex, offsetBy: level)] == " " {
        return level
    }
    return nil
}

private func bulletItem(_ line: String) -> (depth: Int, text: String)? {
    let indent = line.prefix { $0 == " " }.count
    let rest = line.dropFirst(indent)
    for marker in ["- ", "* ", "+ "] {
        if rest.hasPrefix(marker) {
            return (depth: min(indent / 2, 3),
                    text: String(rest.dropFirst(marker.count)).trimmingCharacters(in: .whitespaces))
        }
    }
    // A lone marker on its own line is still a (empty) bullet.
    for marker in ["-", "*"] where rest == marker {
        return (depth: min(indent / 2, 3), text: "")
    }
    return nil
}

private func orderedItem(_ line: String) -> (number: String, text: String)? {
    guard let dot = line.firstIndex(of: ".") else { return nil }
    let head = line[line.startIndex..<dot]
    guard !head.isEmpty, head.allSatisfy({ $0.isNumber }) else { return nil }
    let after = line.index(after: dot)
    guard after == line.endIndex || line[after] == " " else { return nil }
    let text = after == line.endIndex ? "" : String(line[line.index(after: after)...]).trimmingCharacters(in: .whitespaces)
    return (number: String(head), text: text)
}

// --- the styling pass -------------------------------------------------------

/// One inline span with the attributes the peek gives it. Plain data, so
/// the parse underneath stays testable; the AttributedString is built from
/// these in one pass.
private struct InlineSpan {
    enum Style { case plain, bold, italic, code, link }
    let style: Style
    let text: String
}

/// Inline markdown -> spans, for one block's text. The same tolerant rule:
/// unmatched or nested-oddly markers are literal text, never dropped.
private func inlineSpans(_ text: String) -> [InlineSpan] {
    var spans: [InlineSpan] = []
    var plain = ""
    var i = text.startIndex

    func flushPlain() {
        if !plain.isEmpty { spans.append(InlineSpan(style: .plain, text: plain)); plain = "" }
    }

    while i < text.endIndex {
        let rest = text[i...]
        if rest.hasPrefix("**"),
           let close = findClosing("**", in: text, after: text.index(i, offsetBy: 2)) {
            let inner = String(text[text.index(i, offsetBy: 2)..<close])
            if !inner.isEmpty {
                flushPlain()
                spans.append(InlineSpan(style: .bold, text: inner))
                i = text.index(close, offsetBy: 2)
                continue
            }
        }
        if rest.hasPrefix("`"),
           let close = findClosing("`", in: text, after: text.index(after: i)) {
            let inner = String(text[text.index(after: i)..<close])
            if !inner.isEmpty {
                flushPlain()
                spans.append(InlineSpan(style: .code, text: inner))
                i = text.index(after: close)
                continue
            }
        }
        // [label](url): the label stays (underlined); the URL is noise in
        // a 480pt peek -- the thread page carries the real link.
        if rest.hasPrefix("["),
           let labelEnd = findClosing("]", in: text, after: text.index(after: i)) {
            let afterBracket = text.index(after: labelEnd)
            if afterBracket < text.endIndex, text[afterBracket] == "(",
               let urlEnd = findClosing(")", in: text, after: text.index(after: afterBracket)) {
                let label = String(text[text.index(after: i)..<labelEnd])
                if !label.isEmpty {
                    flushPlain()
                    spans.append(InlineSpan(style: .link, text: label))
                    i = text.index(after: urlEnd)
                    continue
                }
            }
        }
        if rest.hasPrefix("*"),
           let close = findClosing("*", in: text, after: text.index(after: i)) {
            let inner = String(text[text.index(after: i)..<close])
            if !inner.isEmpty, !inner.contains("*") {
                flushPlain()
                spans.append(InlineSpan(style: .italic, text: inner))
                i = text.index(after: close)
                continue
            }
        }
        plain.append(text[i])
        i = text.index(after: i)
    }
    flushPlain()
    return spans
}

private func findClosing(_ marker: String, in text: String, after: String.Index) -> String.Index? {
    var i = after
    while i < text.endIndex {
        if text[i...].hasPrefix(marker) { return i }
        i = text.index(after: i)
    }
    return nil
}

/// Blocks -> one AttributedString the peek's Text renders. Every block gets
/// its own paragraph break (a newline between blocks, so wrapping and
/// spacing are Text's own), and every inline span its own run.
func peekAttributedString(_ blocks: [PeekBlock]) -> AttributedString {
    var out = AttributedString()
    for (n, block) in blocks.enumerated() {
        if n > 0 { out.append(AttributedString("\n")) }
        out.append(styled(block))
    }
    return out
}

private func styled(_ block: PeekBlock) -> AttributedString {
    let base = Color.primary.opacity(0.8)
    let secondary = Color.secondary
    switch block.kind {
    case .heading:
        return runs(block.text, font: .system(size: 12, weight: .semibold),
                    color: base, inline: false)
    case .para:
        return runs(block.text, font: .system(size: 12), color: base, inline: true)
    case .bullet(let depth):
        let marker = depth == 0 ? "\u{2022}  " : (depth == 1 ? "\u{2013}  " : "\u{00B7}  ")
        var out = AttributedString(marker)
        out.applyingStyle(font: .system(size: 12), color: base)
        out.append(runs(indent(block.text, depth: depth),
                        font: .system(size: 12), color: base, inline: true))
        return out
    case .ordered(let number):
        var out = AttributedString("\(number).  ")
        out.applyingStyle(font: .system(size: 12), color: base)
        out.append(runs(block.text, font: .system(size: 12), color: base, inline: true))
        return out
    case .code:
        // Mono on warm paper: the same affordance the desk's code spans
        // carry, minus a box a menu row cannot draw.
        var out = AttributedString(block.text)
        out.applyingStyle(font: .system(size: 11, design: .monospaced),
                          color: base, background: Color(nsColor: .quaternaryLabelColor))
        return out
    case .quote:
        var out = AttributedString("    ")
        out.append(runs(block.text, font: .system(size: 12), color: secondary, inline: true))
        return out
    }
}

private func indent(_ text: String, depth: Int) -> String {
    depth == 0 ? text : String(repeating: "  ", count: depth) + text
}

private func runs(_ text: String, font: Font, color: Color, inline: Bool) -> AttributedString {
    var out = AttributedString()
    for span in inline ? inlineSpans(text) : [InlineSpan(style: .plain, text: text)] {
        var run = AttributedString(span.text)
        switch span.style {
        case .plain:
            run.applyingStyle(font: font, color: color)
        case .bold:
            run.applyingStyle(font: font.weight(.semibold), color: color)
        case .italic:
            run.applyingStyle(font: font.italic(), color: color)
        case .code:
            run.applyingStyle(font: .system(size: 11, design: .monospaced), color: color)
        case .link:
            run.applyingStyle(font: font, color: .accentColor, underline: true)
        }
        out.append(run)
    }
    return out
}

private extension AttributedString {
    mutating func applyingStyle(font: Font, color: Color,
                                background: Color? = nil, underline: Bool = false) {
        // The SwiftUI attribute scope (import SwiftUI above) resolves
        // these directly; a nil value unsets, which none of these are.
        self.font = font
        self.foregroundColor = color
        if let background { self.backgroundColor = background }
        if underline { self.underlineStyle = .single }
    }
}
