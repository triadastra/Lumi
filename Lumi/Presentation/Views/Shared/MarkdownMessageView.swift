//
//  MarkdownMessageView.swift
//  LumiAgent
//
//  Shared Markdown rendering for agent messages.
//

import SwiftUI

// MARK: - Markdown Message View
// Splits agent text into plain-text segments and fenced code blocks,
// rendering each appropriately.

struct MarkdownMessageView: View {
    let text: String
    let agents: [Agent]
    var fontSize: CGFloat = 13

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(segments.enumerated()), id: \.offset) { _, seg in
                switch seg {
                case .prose(let s):
                    MentionText(text: s, agents: agents, fontSize: fontSize)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                case .code(let code, let lang):
                    CodeBlockView(code: code, language: lang)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                }
            }
        }
    }

    private enum Segment { case prose(String); case code(String, String?) }

    private var segments: [Segment] {
        var result: [Segment] = []
        var remaining = text
        let marker = "```"

        while let start = remaining.range(of: marker) {
            let before = String(remaining[..<start.lowerBound])
            if !before.isEmpty { result.append(.prose(before)) }
            remaining = String(remaining[start.upperBound...])

            // First line is the optional language tag
            let nlIdx = remaining.firstIndex(of: "\n") ?? remaining.endIndex
            let lang = String(remaining[..<nlIdx]).trimmingCharacters(in: .whitespaces)
            remaining = nlIdx < remaining.endIndex
                ? String(remaining[remaining.index(after: nlIdx)...])
                : ""

            if let end = remaining.range(of: marker) {
                result.append(.code(String(remaining[..<end.lowerBound]), lang.isEmpty ? nil : lang))
                remaining = String(remaining[end.upperBound...])
            } else {
                result.append(.prose(marker + lang + "\n" + remaining))
                remaining = ""
            }
        }

        if !remaining.isEmpty { result.append(.prose(remaining)) }
        return result.isEmpty ? [.prose(text)] : result
    }
}

// MARK: - Code Block View

struct CodeBlockView: View {
    let code: String
    let language: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let lang = language {
                Text(lang)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.top, 6)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                Text(code.trimmingCharacters(in: .newlines))
                    .font(.system(.callout, design: .monospaced))
                    #if os(macOS)
                    .textSelection(.enabled)
                    #endif
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

// MARK: - Mention Text
// Renders inline markdown (bold, italic, inline code, links) plus @mention highlights.

struct MentionText: View {
    let text: String
    let agents: [Agent]
    var fontSize: CGFloat = 13

    var body: some View {
        Text(attributedText)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var attributedText: AttributedString {
        // Parse inline markdown first
        var result = (try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(text)

        // Then highlight @mentions on top
        for agent in agents {
            let mention = "@\(agent.name)"
            var searchStart = result.startIndex
            while searchStart < result.endIndex,
                  let range = result[searchStart...].range(of: mention) {
                result[range].swiftUI.foregroundColor = Color.accentColor
                result[range].swiftUI.font = Font.system(size: fontSize, weight: .semibold)
                searchStart = range.upperBound
            }
        }
        
        return result
    }
}
