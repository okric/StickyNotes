import Foundation
import CoreGraphics

/// Where a note's markdown lives.
enum NoteSourceKind: String, Codable, Equatable {
    /// Absolute POSIX path to a local Markdown file.
    case file
    /// Note served by a Notes API instance (`/n/<shareId>`), cached locally.
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

    /// Stack this note belongs to, or `nil` when it is placed on its own.
    /// Stack membership is presentation metadata only: the Markdown file is
    /// identical whether the note is in a stack or standing alone.
    var stackID: String?

    /// Markdown source. Loaded from disk; never persisted in the index.
    var content: String

    /// True when the backing file was not found at load time.
    var isMissing: Bool

    /// Window position on screen
    var position: CGPoint

    /// UUID of the display the window was last on (see ScreenGeometry)
    var screenUUID: String?

    /// Window origin relative to that display's origin
    var screenOffset: CGPoint?

    /// Notes API origin (scheme + host[:port]); remote notes only
    var remoteBaseURL: String?

    /// Notes API note id (the one `PATCH /api/notes/:id` uses)
    var remoteNoteID: String?

    /// Public share id from the `/n/<shareId>` link, if the note has one
    var remoteShareID: String?

    /// Content revision of the last successful fetch/save
    var remoteRevision: String?

    /// Notes API note id this local file was imported from (inbox only).
    /// Kept after the server copy is deleted, and used to skip a note whose
    /// DELETE failed so a second pass does not duplicate it.
    var originNoteID: String?

    /// Notes API origin (`scheme://host[:port]`) that `originNoteID` belongs to
    var originBaseURL: String?

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

    /// True for notes served by the Notes API
    var isRemote: Bool { sourceKind == .remoteURL }

    /// True when the note is shown in a stack instead of having its own window.
    var isStacked: Bool { stackID != nil }

    init(
        id: UUID = UUID(),
        sourceKind: NoteSourceKind = .file,
        path: String,
        title: String,
        stackID: String? = nil,
        content: String = "",
        isMissing: Bool = false,
        position: CGPoint = CGPoint(x: 100, y: 100),
        screenUUID: String? = nil,
        screenOffset: CGPoint? = nil,
        remoteBaseURL: String? = nil,
        remoteNoteID: String? = nil,
        remoteShareID: String? = nil,
        remoteRevision: String? = nil,
        originNoteID: String? = nil,
        originBaseURL: String? = nil,
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
        self.stackID = stackID
        self.content = content
        self.isMissing = isMissing
        self.position = position
        self.screenUUID = screenUUID
        self.screenOffset = screenOffset
        self.remoteBaseURL = remoteBaseURL
        self.remoteNoteID = remoteNoteID
        self.remoteShareID = remoteShareID
        self.remoteRevision = remoteRevision
        self.originNoteID = originNoteID
        self.originBaseURL = originBaseURL
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
        case id, sourceKind, path, title, stackID, position, size, isMinimized, opacity
        case colorTheme, cursorPosition, scrollTop, alwaysOnTop, createdAt, modifiedAt
        case screenUUID, screenOffset
        case remoteBaseURL, remoteNoteID, remoteShareID, remoteRevision
        case originNoteID, originBaseURL
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        sourceKind = try container.decodeIfPresent(NoteSourceKind.self, forKey: .sourceKind) ?? .file
        path = try container.decodeIfPresent(String.self, forKey: .path) ?? ""
        title = try container.decodeIfPresent(String.self, forKey: .title) ?? ""
        stackID = try container.decodeIfPresent(String.self, forKey: .stackID)

        // Transient state, filled in by NoteManager from the backing file.
        content = ""
        isMissing = path.isEmpty

        // Decode CGPoint
        let positionDict = try container.decodeIfPresent([String: Double].self, forKey: .position) ?? [:]
        position = CGPoint(x: positionDict["x"] ?? 100, y: positionDict["y"] ?? 100)

        remoteBaseURL = try container.decodeIfPresent(String.self, forKey: .remoteBaseURL)
        remoteNoteID = try container.decodeIfPresent(String.self, forKey: .remoteNoteID)
        remoteShareID = try container.decodeIfPresent(String.self, forKey: .remoteShareID)
        remoteRevision = try container.decodeIfPresent(String.self, forKey: .remoteRevision)
        originNoteID = try container.decodeIfPresent(String.self, forKey: .originNoteID)
        originBaseURL = try container.decodeIfPresent(String.self, forKey: .originBaseURL)

        screenUUID = try container.decodeIfPresent(String.self, forKey: .screenUUID)
        if let offsetDict = try container.decodeIfPresent([String: Double].self, forKey: .screenOffset) {
            screenOffset = CGPoint(x: offsetDict["x"] ?? 0, y: offsetDict["y"] ?? 0)
        } else {
            screenOffset = nil
        }

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
        try container.encodeIfPresent(stackID, forKey: .stackID)

        // Encode CGPoint as dictionary
        let positionDict = ["x": position.x, "y": position.y]
        try container.encode(positionDict, forKey: .position)

        try container.encodeIfPresent(remoteBaseURL, forKey: .remoteBaseURL)
        try container.encodeIfPresent(remoteNoteID, forKey: .remoteNoteID)
        try container.encodeIfPresent(remoteShareID, forKey: .remoteShareID)
        try container.encodeIfPresent(remoteRevision, forKey: .remoteRevision)
        try container.encodeIfPresent(originNoteID, forKey: .originNoteID)
        try container.encodeIfPresent(originBaseURL, forKey: .originBaseURL)

        try container.encodeIfPresent(screenUUID, forKey: .screenUUID)
        if let screenOffset {
            try container.encode(
                ["x": screenOffset.x, "y": screenOffset.y],
                forKey: .screenOffset
            )
        }

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
