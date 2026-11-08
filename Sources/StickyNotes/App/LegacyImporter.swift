import Foundation

/// One-time import of notes written by the pre-fork storage
/// (`UserDefaults`, key `sticky_notes`) into individual Markdown files.
///
/// The legacy blob is left untouched so a failed migration loses nothing.
enum LegacyImporter {

    static let userDefaultsKey = "sticky_notes"

    private struct LegacyNote: Decodable {
        let id: UUID
        let content: String
        let position: [String: Double]?
        let size: [String: Double]?
        let isMinimized: Bool?
        let opacity: Double?
        let colorTheme: String?
        let cursorPosition: Int?
        let scrollTop: Double?
        let alwaysOnTop: Bool?
        let createdAt: Date?
        let modifiedAt: Date?
    }

    /// Writes each legacy note to `folder` and returns the new note records.
    static func migrate(store: NotesStore, into folder: URL) -> [Note] {
        guard let data = UserDefaults.standard.data(forKey: userDefaultsKey) else {
            return []
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let legacy = try? decoder.decode([LegacyNote].self, from: data) else {
            print("[LegacyImporter] Could not decode legacy notes")
            return []
        }

        var migrated: [Note] = []
        for old in legacy {
            let baseTitle = title(from: old.content) ?? NotesStore.defaultTitle()
            guard let url = try? store.createNoteFile(
                in: folder, baseTitle: baseTitle, content: old.content
            ) else {
                print("[LegacyImporter] Failed to write legacy note \(old.id)")
                continue
            }

            let position = CGPoint(
                x: old.position?["x"] ?? 100,
                y: old.position?["y"] ?? 100
            )
            let size = CGSize(
                width: old.size?["width"] ?? 300,
                height: old.size?["height"] ?? 360
            )

            migrated.append(Note(
                id: old.id,
                path: url.path,
                title: url.deletingPathExtension().lastPathComponent,
                content: old.content,
                position: position,
                size: size,
                isMinimized: old.isMinimized ?? false,
                opacity: old.opacity ?? 0.95,
                colorTheme: old.colorTheme ?? "yellow",
                cursorPosition: old.cursorPosition ?? 0,
                scrollTop: old.scrollTop ?? 0,
                alwaysOnTop: old.alwaysOnTop ?? false,
                createdAt: old.createdAt ?? Date(),
                modifiedAt: old.modifiedAt ?? Date()
            ))
        }

        print("[LegacyImporter] Migrated \(migrated.count) notes into \(folder.path)")
        return migrated
    }

    /// First Markdown heading, if the note has one.
    private static func title(from content: String) -> String? {
        for line in content.split(separator: "\n", omittingEmptySubsequences: true) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("#") else { continue }
            let heading = trimmed.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces)
            guard !heading.isEmpty else { continue }
            return String(heading.prefix(60))
        }
        return nil
    }
}
