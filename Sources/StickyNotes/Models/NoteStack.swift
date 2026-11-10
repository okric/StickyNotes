import Foundation
import CoreGraphics

/// A pile of notes shown as one window.
///
/// The stack owns the window position; member notes have no position of their
/// own. Membership lives on `Note.stackID` and is presentation metadata only —
/// the Markdown file on disk is the same as any other note.
///
/// The app supports one stack for now (`NoteStack.defaultID`). Persisted in
/// `Application Support/com.mdstickynotes/stack.json`.
struct NoteStack: Codable, Equatable {
    /// Identifier stored on member notes. Only one stack exists today, but the
    /// field leaves room for named stacks later.
    static let defaultID = "default"

    var id: String
    var position: CGPoint

    /// Card size shown by the stack window. The stack keeps this size while
    /// switching sheets, so the window never jumps; `nil` falls back to the
    /// front note's size (older stack.json, or first launch).
    var size: CGSize?

    /// Appearance is stack-level. Member notes ignore their own values while
    /// stacked and inherit these when they are pulled out.
    var colorTheme: String?
    var opacity: Double?
    var alwaysOnTop: Bool?
    var isMinimized: Bool?

    var screenUUID: String?
    var screenOffset: CGPoint?

    /// Note currently on top of the pile. Falls back to the newest member.
    var frontNoteID: UUID?

    init(
        id: String = NoteStack.defaultID,
        position: CGPoint,
        size: CGSize? = nil,
        colorTheme: String? = nil,
        opacity: Double? = nil,
        alwaysOnTop: Bool? = nil,
        isMinimized: Bool? = nil,
        screenUUID: String? = nil,
        screenOffset: CGPoint? = nil,
        frontNoteID: UUID? = nil
    ) {
        self.id = id
        self.position = position
        self.size = size
        self.colorTheme = colorTheme
        self.opacity = opacity
        self.alwaysOnTop = alwaysOnTop
        self.isMinimized = isMinimized
        self.screenUUID = screenUUID
        self.screenOffset = screenOffset
        self.frontNoteID = frontNoteID
    }

    /// A new stack adopts the seed note's appearance.
    init(seeding note: Note, at position: CGPoint) {
        self.init(
            position: position,
            size: note.size,
            colorTheme: note.colorTheme,
            opacity: note.opacity,
            alwaysOnTop: note.alwaysOnTop,
            isMinimized: false,
            frontNoteID: note.id
        )
    }

    // MARK: - Codable

    enum CodingKeys: String, CodingKey {
        case id, position, size, colorTheme, opacity, alwaysOnTop, isMinimized
        case screenUUID, screenOffset, frontNoteID
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(String.self, forKey: .id) ?? Self.defaultID

        let positionDict = try container.decodeIfPresent([String: Double].self, forKey: .position) ?? [:]
        position = CGPoint(x: positionDict["x"] ?? 100, y: positionDict["y"] ?? 100)

        if let sizeDict = try container.decodeIfPresent([String: Double].self, forKey: .size) {
            size = CGSize(
                width: sizeDict["width"] ?? 300,
                height: sizeDict["height"] ?? 360
            )
        } else {
            size = nil
        }

        colorTheme = try container.decodeIfPresent(String.self, forKey: .colorTheme)
        opacity = try container.decodeIfPresent(Double.self, forKey: .opacity)
        alwaysOnTop = try container.decodeIfPresent(Bool.self, forKey: .alwaysOnTop)
        isMinimized = try container.decodeIfPresent(Bool.self, forKey: .isMinimized)

        screenUUID = try container.decodeIfPresent(String.self, forKey: .screenUUID)
        if let offsetDict = try container.decodeIfPresent([String: Double].self, forKey: .screenOffset) {
            screenOffset = CGPoint(x: offsetDict["x"] ?? 0, y: offsetDict["y"] ?? 0)
        }
        frontNoteID = try container.decodeIfPresent(UUID.self, forKey: .frontNoteID)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(["x": position.x, "y": position.y], forKey: .position)
        if let size {
            try container.encode(
                ["width": size.width, "height": size.height],
                forKey: .size
            )
        }
        try container.encodeIfPresent(colorTheme, forKey: .colorTheme)
        try container.encodeIfPresent(opacity, forKey: .opacity)
        try container.encodeIfPresent(alwaysOnTop, forKey: .alwaysOnTop)
        try container.encodeIfPresent(isMinimized, forKey: .isMinimized)
        try container.encodeIfPresent(screenUUID, forKey: .screenUUID)
        if let screenOffset {
            try container.encode(
                ["x": screenOffset.x, "y": screenOffset.y],
                forKey: .screenOffset
            )
        }
        try container.encodeIfPresent(frontNoteID, forKey: .frontNoteID)
    }
}
