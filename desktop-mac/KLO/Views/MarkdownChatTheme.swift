import MarkdownUI
import SwiftUI

/// Klo's MarkdownUI theme. Apply via `.markdownTheme(.klo)` on any
/// `Markdown` view in the chat panel.
///
/// The theme styles every block + inline element the agent typically
/// produces so responses with `**bold**`, `### heading`, `- bullets`,
/// `` `code` ``, fenced code blocks, blockquotes, and GFM tables
/// render properly instead of showing literal markdown syntax.
///
/// Built on top of `Theme.basic` (the lightest default) so we only
/// have to override what we actually want different from system
/// defaults — text color, brand accents, font sizes that match the
/// rest of the chat panel.
extension Theme {
    static let klo = Theme.basic
        // ── Inline text styles ──────────────────────────────────
        .text {
            ForegroundColor(.white.opacity(0.94))
            FontSize(15)
        }
        .strong {
            FontWeight(.semibold)
            ForegroundColor(KloColors.cream)
        }
        .emphasis {
            FontStyle(.italic)
        }
        .code {
            FontFamilyVariant(.monospaced)
            FontSize(.em(0.9))
            ForegroundColor(KloColors.olive)
        }
        .link {
            ForegroundColor(KloColors.copper)
            UnderlineStyle(.single)
        }
        .strikethrough {
            StrikethroughStyle(.single)
            ForegroundColor(.white.opacity(0.45))
        }

        // ── Headings ─────────────────────────────────────────────
        .heading1 { config in
            config.label
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(KloColors.cream)
                .markdownMargin(top: 12, bottom: 4)
        }
        .heading2 { config in
            config.label
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(KloColors.cream)
                .markdownMargin(top: 10, bottom: 4)
        }
        .heading3 { config in
            config.label
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(KloColors.cream)
                .markdownMargin(top: 8, bottom: 3)
        }
        .heading4 { config in
            config.label
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(KloColors.cream.opacity(0.9))
                .markdownMargin(top: 6, bottom: 2)
        }

        // ── Block-level content ──────────────────────────────────
        .paragraph { config in
            config.label
                .lineSpacing(5)
                .markdownMargin(top: 4, bottom: 4)
        }
        .codeBlock { config in
            // Fenced ``` block — chunky monospace with a faint bg
            // and an olive accent on the left edge so it reads as
            // distinct from inline `code`.
            config.label
                .font(.system(size: 13, design: .monospaced))
                .foregroundStyle(Color.white.opacity(0.90))
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.white.opacity(0.05))
                )
                .overlay(alignment: .leading) {
                    Rectangle()
                        .fill(KloColors.olive.opacity(0.55))
                        .frame(width: 2)
                }
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .markdownMargin(top: 6, bottom: 6)
        }
        .blockquote { config in
            config.label
                .padding(.leading, 12)
                .overlay(alignment: .leading) {
                    Rectangle()
                        .fill(KloColors.cream.opacity(0.35))
                        .frame(width: 3)
                }
                .foregroundStyle(.white.opacity(0.78))
                .markdownMargin(top: 6, bottom: 6)
        }
        .listItem { config in
            config.label
                .markdownMargin(top: 2, bottom: 2)
        }
        .table { config in
            config.label
                .markdownMargin(top: 6, bottom: 6)
        }
}
