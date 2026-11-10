import AppKit

/// Font choices for note bodies and the fixed filename line.
///
/// Only the family is user-selectable; sizes stay constant so notes keep a
/// predictable layout. `nil` means the system font.
enum NoteFont {
    static let bodySize: CGFloat = 14
    static let titleSize: CGFloat = 15

    /// Curated families shown in Settings. "System" is stored as `nil`.
    static let choices: [String] = [
        "System",
        "Helvetica Neue",
        "Avenir Next",
        "Georgia",
        "Palatino",
        "Times New Roman",
        "New York",
        "Menlo",
        "Courier New"
    ]

    static func font(family: String?, size: CGFloat, bold: Bool = false) -> NSFont {
        let base: NSFont
        if let family, let named = NSFont(name: family, size: size) {
            base = named
        } else {
            base = NSFont.systemFont(ofSize: size)
        }
        return bold
            ? NSFontManager.shared.convert(base, toHaveTrait: .boldFontMask)
            : base
    }

    static func titleFont(family: String?) -> NSFont {
        font(family: family, size: titleSize, bold: true)
    }

    /// CSS font-family list for the web editor.
    static func bodyCSS(family: String?) -> String {
        guard let family, !family.isEmpty else {
            return "-apple-system, BlinkMacSystemFont, \"Segoe UI\", Helvetica, Arial, sans-serif"
        }
        let escaped = family.replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\", -apple-system, BlinkMacSystemFont, sans-serif"
    }
}
