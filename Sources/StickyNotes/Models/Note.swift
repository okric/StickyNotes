import Foundation
import CoreGraphics

/// Where a note's markdown lives.
enum NoteSourceKind: String, Codable, Equatable {
    /// Absolute POSIX path to a local Markdown file.
    case file
    /// Reserved for remote notes. Not implemented yet; decoding keeps it so the
    /// schema can grow without breaking existing indexes.
    case remoteURL
}

/// A sticky note backed by an external Markdown file.
///
/// Only presentation metadata is stored in the index (`index.json`); `content`
/// is read from `path` at launch and written back on edit.
struct Note: Identifiable, Equatable {
    /// Unique identifier for the note
    let id: UUID

    /// Backing storage kind
    var sourceKind: NoteSourceKind

    /// Absolute POSIX path of the Markdown file
    var path: String

    /// Display name, derived from the file name (without `.md`)
    var title: String

    /// Markdown source. Loaded from disk; never persisted in the index.
    var content: String

    /// True when the backing file was not found at load time.
    var isMissing: Bool

    /// Window position on screen
    var position: CGPoint

    /// Window size on screen
    var size: CGSize

    /// Whether the window is minimized
    var isMinimized: Bool

    /// Window opacity (0.0 to 1.0)
    var opacity: Double

    /// Color theme name (yellow, pink, blue, green, purple, orange)
    var colorTheme: String

    /// Cursor position (character offset) for restoring on reopen
    var cursorPosition: Int

    /// Scroll position (pixels from top) for restoring on reopen
    var scrollTop: Double

    /// Whether this note should always stay on top of other windows
    var alwaysOnTop: Bool

    /// Creation timestamp
    let createdAt: Date

    /// Last modification timestamp
    var modifiedAt: Date

    /// File URL for file-backed notes
    var fileURL: URL? {
        sourceKind == .file ? URL(fileURLWithPath: path) : nil
    }

    init(
        id: UUID = UUID(),
        sourceKind: NoteSourceKind = .file,
        path: String,
        title: String,
        content: String = "",
        isMissing: Bool = false,
        position: CGPoint = CGPoint(x: 100, y: 100),
        size: CGSize = CGSize(width: 300, height: 360),
        isMinimized: Bool = false,
        opacity: Double = 0.95,
        colorTheme: String = "yellow",
        cursorPosition: Int = 0,
        scrollTop: Double = 0,
        alwaysOnTop: Bool = false,
        createdAt: Date = Date(),
        modifiedAt: Date = Date()
    ) {
        self.id = id
        self.sourceKind = sourceKind
        self.path = path
        self.title = title
        self.content = content
        self.isMissing = isMissing
        self.position = position
        self.size = size
        self.isMinimized = isMinimized
        self.opacity = opacity
        self.colorTheme = colorTheme
        self.cursorPosition = cursorPosition
        self.scrollTop = scrollTop
        self.alwaysOnTop = alwaysOnTop
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
    }

    /// Update the modification timestamp
    mutating func updateModificationDate() {
        self.modifiedAt = Date()
    }
}

// MARK: - Codable Conformance

extension Note: Codable {
    enum CodingKeys: String, CodingKey {
        case id, sourceKind, path, title, position, size, isMinimized, opacity
        case colorTheme, cursorPosition, scrollTop, alwaysOnTop, createdAt, modifiedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        sourceKind = try container.decodeIfPresent(NoteSourceKind.self, forKey: .sourceKind) ?? .file
        path = try container.decodeIfPresent(String.self, forKey: .path) ?? ""
        title = try container.decodeIfPresent(String.self, forKey: .title) ?? ""

        // Transient state, filled in by NoteManager from the backing file.
        content = ""
        isMissing = path.isEmpty

        // Decode CGPoint
        let positionDict = try container.decodeIfPresent([String: Double].self, forKey: .position) ?? [:]
        position = CGPoint(x: positionDict["x"] ?? 100, y: positionDict["y"] ?? 100)

        // Decode CGSize
        let sizeDict = try container.decodeIfPresent([String: Double].self, forKey: .size) ?? [:]
        size = CGSize(width: sizeDict["width"] ?? 300, height: sizeDict["height"] ?? 360)

        isMinimized = try container.decodeIfPresent(Bool.self, forKey: .isMinimized) ?? false
        opacity = try container.decodeIfPresent(Double.self, forKey: .opacity) ?? 0.95
        colorTheme = try container.decodeIfPresent(String.self, forKey: .colorTheme) ?? "yellow"
        cursorPosition = try container.decodeIfPresent(Int.self, forKey: .cursorPosition) ?? 0
        scrollTop = try container.decodeIfPresent(Double.self, forKey: .scrollTop) ?? 0
        alwaysOnTop = try container.decodeIfPresent(Bool.self, forKey: .alwaysOnTop) ?? false
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        modifiedAt = try container.decodeIfPresent(Date.self, forKey: .modifiedAt) ?? createdAt
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(sourceKind, forKey: .sourceKind)
        try container.encode(path, forKey: .path)
        try container.encode(title, forKey: .title)

        // Encode CGPoint as dictionary
        let positionDict = ["x": position.x, "y": position.y]
        try container.encode(positionDict, forKey: .position)

        // Encode CGSize as dictionary
        let sizeDict = ["width": size.width, "height": size.height]
        try container.encode(sizeDict, forKey: .size)

        try container.encode(isMinimized, forKey: .isMinimized)
        try container.encode(opacity, forKey: .opacity)
        try container.encode(colorTheme, forKey: .colorTheme)
        try container.encode(cursorPosition, forKey: .cursorPosition)
        try container.encode(scrollTop, forKey: .scrollTop)
        try container.encode(alwaysOnTop, forKey: .alwaysOnTop)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(modifiedAt, forKey: .modifiedAt)
    }
}
