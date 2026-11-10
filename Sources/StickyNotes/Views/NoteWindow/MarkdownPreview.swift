import AppKit
import Foundation

/// Lightweight Markdown rendering for the startup preview.
///
/// Before the shared WKWebView attaches, a note window shows its content as
/// plain text. Raw Markdown makes headings and code look much smaller than the
/// live editor, so the preview is styled with the editor's own sizes
/// (14pt body, 1.8em/1.5em/… headings, monospaced code).
enum MarkdownPreview {
    static let baseFontSize: CGFloat = 14
    private static let bodyColor = NSColor(white: 0.1, alpha: 0.85)

    static func attributedString(
        for markdown: String,
        fontFamily: String? = nil
    ) -> NSAttributedString {
        let baseFont = NoteFont.font(family: fontFamily, size: baseFontSize)
        let fallback = NSAttributedString(
            string: markdown,
            attributes: [.font: baseFont, .foregroundColor: bodyColor]
        )
        guard !markdown.isEmpty,
              let parsed = try? AttributedString(
                  markdown: markdown,
                  options: .init(
                      interpretedSyntax: .full,
                      failurePolicy: .returnPartiallyParsedIfPossible
                  )
              ) else {
            return fallback
        }

        let output = NSMutableAttributedString()
        var currentListItem: String?
        var previousBlockIdentity: Int?

        for run in parsed.runs {
            let text = String(parsed[run.range].characters)
            guard !text.isEmpty else { continue }

            var headerLevel = 0
            var listDepth = 0
            var ordered: Bool?
            var ordinal = 0
            var inQuote = false
            var inCodeBlock = false

            if let intent = run.presentationIntent {
                for component in intent.components {
                    switch component.kind {
                    case .header(let level):
                        headerLevel = max(headerLevel, level)
                    case .listItem(let number):
                        listDepth += 1
                        ordinal = number
                    case .orderedList:
                        ordered = true
                    case .unorderedList:
                        ordered = false
                    case .blockQuote:
                        inQuote = true
                    case .codeBlock:
                        inCodeBlock = true
                    default:
                        break
                    }
                }
            }

            var font = baseFont
            var color = bodyColor
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineSpacing = inCodeBlock ? 1 : 3
            paragraph.paragraphSpacing = 6

            if headerLevel > 0 {
                let scale: CGFloat = [1.8, 1.5, 1.25, 1.1, 1.05, 1.0][min(headerLevel, 6) - 1]
                font = NoteFont.font(
                    family: fontFamily,
                    size: (baseFontSize * scale).rounded(),
                    bold: true
                )
                paragraph.paragraphSpacingBefore = 10
                paragraph.paragraphSpacing = 4
            } else if inCodeBlock {
                font = NSFont.monospacedSystemFont(ofSize: baseFontSize * 0.9, weight: .regular)
            } else if inQuote {
                color = .secondaryLabelColor
                paragraph.headIndent = 12
                paragraph.firstLineHeadIndent = 12
            }

            if run.inlinePresentationIntent?.contains(.stronglyEmphasized) == true {
                font = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
            }
            if run.inlinePresentationIntent?.contains(.emphasized) == true {
                font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
            }
            if run.inlinePresentationIntent?.contains(.code) == true {
                font = NSFont.monospacedSystemFont(ofSize: baseFontSize * 0.9, weight: .regular)
            }

            var attributes: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: color,
                .paragraphStyle: paragraph
            ]
            if run.inlinePresentationIntent?.contains(.strikethrough) == true {
                attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
            }

            var rendered = text
            // Foundation's full markdown parse drops block separators from the
            // characters; each block's presentation intent has a unique
            // identity, so re-insert the newline at block boundaries.
            let blockIdentity = run.presentationIntent?.components.first?.identity
            if let blockIdentity,
               blockIdentity != previousBlockIdentity,
               output.length > 0,
               !rendered.hasPrefix("\n") {
                rendered = "\n" + rendered
            }

            if listDepth > 0 {
                let signature = "\(listDepth)-\(ordinal)-\(ordered.map(String.init) ?? "-")"
                if currentListItem != signature, !isWhitespaceOnly(text) {
                    let indent = String(repeating: "    ", count: max(0, listDepth - 1))
                    let marker = ordered == true ? "\(max(ordinal, 1)). " : "•  "
                    let separator = rendered.hasPrefix("\n") ? "\n" : ""
                    rendered = separator + indent + marker + text
                    currentListItem = signature
                }
            } else {
                currentListItem = nil
            }

            output.append(NSAttributedString(string: rendered, attributes: attributes))
            previousBlockIdentity = blockIdentity ?? previousBlockIdentity
        }

        return output.length > 0 ? output : fallback
    }

    private static func isWhitespaceOnly(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
