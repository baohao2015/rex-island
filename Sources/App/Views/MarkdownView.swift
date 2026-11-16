import SwiftUI

/// Enough Markdown for a plan: headings, lists, checkboxes, quotes, code blocks and inline styles.
struct MarkdownView: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(Array(MarkdownBlock.parse(text).enumerated()), id: \.offset) { _, block in
                view(for: block)
            }
        }
        .textSelection(.enabled)
    }

    @ViewBuilder private func view(for block: MarkdownBlock) -> some View {
        switch block {
        case .heading(let level, let text):
            inline(text)
                .font(.system(size: level == 1 ? 14.5 : level == 2 ? 13.5 : 12.5, weight: .semibold))
                .foregroundStyle(Theme.primary)
                .padding(.top, level <= 2 ? 4 : 2)
        case .item(let indent, let marker, let text):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(marker).foregroundStyle(marker == "☑" ? Theme.green : Theme.tertiary)
                inline(text).foregroundStyle(Theme.primary.opacity(0.9))
            }
            .font(.system(size: 12))
            .padding(.leading, CGFloat(indent) * 12)
        case .quote(let text):
            HStack(spacing: 8) {
                Rectangle().fill(Theme.hairline).frame(width: 2)
                inline(text).font(.system(size: 12)).foregroundStyle(Theme.secondary)
            }
        case .code(let code):
            Text(code)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Theme.primary.opacity(0.9))
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.05)))
        case .rule:
            Rectangle().fill(Theme.hairline).frame(height: 1).padding(.vertical, 2)
        case .paragraph(let text):
            inline(text).font(.system(size: 12)).foregroundStyle(Theme.primary.opacity(0.9))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func inline(_ text: String) -> Text {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return Text((try? AttributedString(markdown: text, options: options)) ?? AttributedString(text))
    }
}
