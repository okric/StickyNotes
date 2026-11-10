import Foundation

/// Owns the app's own storage: the note index and settings.
///
/// ```
/// ~/Library/Application Support/com.mdstickynotes/index.json     note metadata
/// ~/Library/Application Support/com.mdstickynotes/settings.json  app settings
/// ```
///
/// Note bodies are *not* stored here. Each note points at a Markdown file in
/// the folder the user picked, so files can live in an Obsidian vault.
final class NotesStore {

    struct SettingsData: Codable {
        var defaultFolderPath: String?
        var didMigrateLegacyNotes: Bool
        var noteFontFamily: String?
        var titleFontFamily: String?
        var notesServerURL: String?
        var inboxPollMinutes: Int?
        var lastNoteColor: String?

        init(
            defaultFolderPath: String? = nil,
            didMigrateLegacyNotes: Bool = false,
            noteFontFamily: String? = nil,
            titleFontFamily: String? = nil,
            notesServerURL: String? = nil,
            inboxPollMinutes: Int? = nil,
            lastNoteColor: String? = nil
        ) {
            self.defaultFolderPath = defaultFolderPath
            self.didMigrateLegacyNotes = didMigrateLegacyNotes
            self.noteFontFamily = noteFontFamily
            self.titleFontFamily = titleFontFamily
            self.notesServerURL = notesServerURL
            self.inboxPollMinutes = inboxPollMinutes
            self.lastNoteColor = lastNoteColor
        }
    }

    /// Default folder created under `~/Documents` for the simple setup.
    static let defaultFolderName = "Sticky Notes"

    private static let appSupportFolderName = "com.mdstickynotes"

    let baseDirectory: URL
    var indexURL: URL { baseDirectory.appendingPathComponent("index.json") }
    var settingsURL: URL { baseDirectory.appendingPathComponent("settings.json") }
    var stackURL: URL { baseDirectory.appendingPathComponent("stack.json") }

    private let fileManager = FileManager.default
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    /// - Parameter baseDirectory: overrides the Application Support location
    ///   (used by tests). The `STICKY_NOTES_HOME` environment variable is also
    ///   honoured when no directory is passed.
    init(baseDirectory: URL? = nil) {
        if let baseDirectory {
            self.baseDirectory = baseDirectory
        } else if let override = ProcessInfo.processInfo.environment["STICKY_NOTES_HOME"],
                  !override.isEmpty {
            self.baseDirectory = URL(fileURLWithPath: override, isDirectory: true)
        } else {
            let support = FileManager.default.urls(
                for: .applicationSupportDirectory, in: .userDomainMask
            ).first ?? URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent("Library/Application Support", isDirectory: true)
            self.baseDirectory = support.appendingPathComponent(
                Self.appSupportFolderName, isDirectory: true
            )
        }

        encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
    }

    // MARK: - Index

    func loadIndex() -> [Note] {
        guard let data = try? Data(contentsOf: indexURL) else { return [] }
        do {
            return try decoder.decode([Note].self, from: data)
        } catch {
            print("[NotesStore] Failed to decode index: \(error)")
            backupCorruptedIndex(data)
            return []
        }
    }

    func saveIndex(_ notes: [Note]) {
        do {
            try ensureBaseDirectory()
            let data = try encoder.encode(notes)
            try data.write(to: indexURL, options: .atomic)
        } catch {
            print("[NotesStore] Failed to save index: \(error)")
        }
    }

    // MARK: - Stack

    /// The single default stack's window placement and front note.
    func loadStack() -> NoteStack? {
        guard let data = try? Data(contentsOf: stackURL) else { return nil }
        return try? decoder.decode(NoteStack.self, from: data)
    }

    /// Passing `nil` removes the file (no stacked notes left).
    func saveStack(_ stack: NoteStack?) {
        guard let stack else {
            try? fileManager.removeItem(at: stackURL)
            return
        }
        do {
            try ensureBaseDirectory()
            let data = try encoder.encode(stack)
            try data.write(to: stackURL, options: .atomic)
        } catch {
            print("[NotesStore] Failed to save stack: \(error)")
        }
    }

    // MARK: - Settings

    func loadSettings() -> SettingsData {
        guard let data = try? Data(contentsOf: settingsURL) else {
            return SettingsData()
        }
        return (try? decoder.decode(SettingsData.self, from: data)) ?? SettingsData()
    }

    func saveSettings(_ settings: SettingsData) {
        do {
            try ensureBaseDirectory()
            let data = try encoder.encode(settings)
            try data.write(to: settingsURL, options: .atomic)
        } catch {
            print("[NotesStore] Failed to save settings: \(error)")
        }
    }

    // MARK: - Note bodies

    /// Reads the backing file. Returns nil when it does not exist or is unreadable.
    func readContent(for note: Note) -> String? {
        guard let url = note.fileURL else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    /// Writes the body atomically, creating the file if it went missing.
    func writeContent(_ content: String, for note: Note) throws {
        guard let url = note.fileURL else { return }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(content.utf8).write(to: url, options: .atomic)
    }

    // MARK: - Remote note cache

    /// Remote notes keep their last body here so they open offline.
    var remoteCacheDirectory: URL {
        baseDirectory.appendingPathComponent("remote", isDirectory: true)
    }

    func remoteCacheURL(for note: Note) -> URL {
        remoteCacheDirectory.appendingPathComponent("\(note.id.uuidString).md")
    }

    func readRemoteContent(for note: Note) -> String? {
        try? String(contentsOf: remoteCacheURL(for: note), encoding: .utf8)
    }

    func writeRemoteContent(_ content: String, for note: Note) throws {
        let url = remoteCacheURL(for: note)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(content.utf8).write(to: url, options: .atomic)
    }

    /// Deletes the cached body when a remote note is removed from the index.
    func removeRemoteContent(for note: Note) {
        try? FileManager.default.removeItem(at: remoteCacheURL(for: note))
    }

    /// Creates a new empty Markdown file and returns its URL.
    func createNoteFile(in folder: URL, baseTitle: String, content: String) throws -> URL {
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = uniqueFileURL(in: folder, baseTitle: baseTitle)
        try Data(content.utf8).write(to: url, options: .atomic)
        return url
    }

    /// `baseTitle.md`, `baseTitle 2.md`, … whichever is free.
    func uniqueFileURL(in folder: URL, baseTitle: String) -> URL {        let title = Self.sanitizeFileName(baseTitle)
        var candidate = folder.appendingPathComponent(title).appendingPathExtension("md")
        var counter = 2
        while fileManager.fileExists(atPath: candidate.path) {
            candidate = folder
                .appendingPathComponent("\(title) \(counter)")
                .appendingPathExtension("md")
            counter += 1
        }
        return candidate
    }

    /// Default file name for a fresh note: `Note 2026-11-08 143012`
    static func defaultTitle(date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HHmmss"
        return "Note \(formatter.string(from: date))"
    }

    /// Strips path separators and control characters from a prospective file name.
    static func sanitizeFileName(_ raw: String) -> String {
        var name = raw
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty { name = "Note" }
        if name.count > 80 { name = String(name.prefix(80)) }
        return name
    }

    // MARK: - Private

    private func ensureBaseDirectory() throws {
        try fileManager.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
    }

    private func backupCorruptedIndex(_ data: Data) {
        let stamp = Int(Date().timeIntervalSince1970)
        let backup = baseDirectory.appendingPathComponent("index.corrupted.\(stamp).json")
        try? data.write(to: backup, options: .atomic)
        print("[NotesStore] Backed up corrupted index to \(backup.path)")
    }
}
