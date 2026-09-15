//
//  MarkdownText.swift
//  HappyQuickAI
//
//  Renders an AI reply on the shelf. Foundation's markdown parser turns the
//  inline styles (bold, italic, strikethrough, links, inline code) into an
//  AttributedString, and this view adds the block layer on top for the layout
//  shelf chat replies actually use: headings, the `---` / `***` rules as a
//  thin separator, and fenced code blocks, all sized for a 520pt shelf.
//
//  Only the assistant's replies go through here; the user's own text stays
//  exactly as typed.
//

import AppKit
import DroppyKit
import SwiftUI

struct MarkdownText: View {
    let markdown: String

    /// The badge/secondary colour, passed in so a user-set Widget Text colour
    /// still rules inside the markdown block.
    var secondary: Color = AdaptiveColors.notchSurfaceSecondaryText

    var body: some View {
        let blocks = Self.parse(markdown)
        return VStack(alignment: .leading, spacing: DroppySpacing.xsm) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                render(block)
            }
        }
        .environment(\.openURL, OpenURLAction { url in
            NSWorkspace.shared.open(url)
            return .handled
        })
    }

    // MARK: Blocks

    private enum Block {
        case paragraph(AttributedString)
        case heading(Int, AttributedString)
        case code(String)
        case rule
    }

    @ViewBuilder
    private func render(_ block: Block) -> some View {
        switch block {
        case .paragraph(let attr):
            Text(attr)
                .font(.system(size: 12))
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        case .heading(let level, let attr):
            Text(attr)
                .font(.system(size: level <= 2 ? 14 : 12.5, weight: .semibold))
                .fixedSize(horizontal: false, vertical: true)
        case .code(let code):
            Text(code)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(secondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, DroppySpacing.smd)
                .padding(.vertical, DroppySpacing.xsm)
                .background(
                    RoundedRectangle(cornerRadius: DroppyRadius.xs, style: .continuous)
                        .fill(AdaptiveColors.overlayAuto(0.06))
                )
        case .rule:
            Rectangle()
                .fill(secondary.opacity(0.35))
                .frame(height: 1)
                .padding(.vertical, 1)
        }
    }

    // MARK: Parsing

    /// Splits the reply into paragraphs, headings, rules and fenced code
    /// blocks. The in-between blocks are parsed with the inline syntax only,
    /// so an unbalanced `**` never swallows the rest of the message.
    private static func parse(_ string: String) -> [Block] {
        var blocks: [Block] = []
        var rest = Substring(string)

        while !rest.isEmpty {
            if let fence = rest.firstRange(of: "```") {
                addMarkdownBlocks(String(rest[..<fence.lowerBound]), to: &blocks)
                var after = rest[fence.upperBound...]
                if let newline = after.firstIndex(of: "\n") {
                    after = after[newline...]      // drop the language tag
                } else {
                    after = ""
                }
                if let close = after.firstRange(of: "```") {
                    let code = after[..<close.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
                    if !code.isEmpty { blocks.append(.code(code)) }
                    rest = after[close.upperBound...]
                } else {
                    let code = after.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !code.isEmpty { blocks.append(.code(code)) }
                    rest = ""
                }
            } else {
                addMarkdownBlocks(String(rest), to: &blocks)
                rest = ""
            }
        }
        return blocks
    }

    private static func addMarkdownBlocks(_ chunk: String, to blocks: inout [Block]) {
        var paragraph: [String] = []

        func flush() {
            let text = paragraph.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { addParagraph(text, to: &blocks) }
            paragraph.removeAll()
        }

        for line in chunk.components(separatedBy: .newlines) {
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                flush()
            } else {
                paragraph.append(line)
            }
        }
        flush()
    }

    private static func addParagraph(_ text: String, to blocks: inout [Block]) {
        let lines = text.components(separatedBy: .newlines)
        let single = lines.count == 1
        let trimmedLine = text.trimmingCharacters(in: .whitespaces)

        // Headings: one line starting with 1-6 `#` and a space.
        if single,
           let _ = lines[0].range(of: #"^\s{0,3}#{1,6}\s+"#, options: .regularExpression) {
            let count = hashPrefixCount(lines[0])
            let content = String(lines[0].dropFirst(count)).trimmingCharacters(in: .whitespaces)
            if content.isEmpty { return }   // a stray line of hashes
            return blocks.append(.heading(count, inline(content)))
        }

        // Thematic break: one line of `-`, `*` or `_`, three or more.
        if single, trimmedLine.count >= 3, Set(trimmedLine).isSubset(of: ["-", "*", "_"]) {
            return blocks.append(.rule)
        }

        // A run of bullets (`-` / `*` / `+` at the start of every line) reads
        // better with the markdown dash swapped for a real bullet.
        var isBulletRun = !lines.isEmpty
        var bullets: [String] = []
        for line in lines {
            let t = line.trimmingCharacters(in: .whitespaces)
            guard let marker = t.range(of: #"^[-*+]\s+"#, options: .regularExpression) else {
                isBulletRun = false
                break
            }
            bullets.append("•  " + String(t[marker.upperBound...]))
        }
        if isBulletRun, !bullets.isEmpty {
            return blocks.append(.paragraph(inline(bullets.joined(separator: "\n"))))
        }

        blocks.append(.paragraph(inline(text)))
    }

    private static func hashPrefixCount(_ line: String) -> Int {
        var count = 0
        for ch in line {
            if ch == "#" { count += 1 } else { break }
        }
        return min(count, 6)
    }

    /// Parses just the inline markdown (bold, italic, strikethrough, links,
    /// inline code), keeping the source's own line breaks and surviving
    /// malformed syntax by keeping whatever parses.
    private static func inline(_ string: String) -> AttributedString {
        var options = AttributedString.MarkdownParsingOptions()
        options.interpretedSyntax = .inlineOnly
        options.failurePolicy = .returnPartiallyParsedIfPossible
        return (try? AttributedString(markdown: string, options: options)) ?? AttributedString(string)
    }

    /// A single-flowing-line teaser for the compact widget's preview.
    static func teaser(_ string: String) -> AttributedString {
        inline(string)
    }
}