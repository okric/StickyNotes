import AppKit
import Combine
import Foundation

/// User preferences that outlive the note index.
final class AppSettings: ObservableObject {

    /// Folder used for new notes. Existing notes keep their own paths.
    @Published private(set) var defaultFolderPath: String?

    /// One-shot flag: legacy UserDefaults notes have been imported.
    @Published private(set) var didMigrateLegacyNotes: Bool

    /// Font families for note bodies and the fixed filename line. `nil` = system.
    @Published private(set) var noteFontFamily: String?
    @Published private(set) var titleFontFamily: String?

    /// Last Notes API origin used in Settings. Tokens live in the Keychain,
    /// keyed by this origin; the origin itself is ordinary preference data.
    @Published private(set) var notesServerURL: String?

    /// How often the background inbox pass runs, in minutes.
    @Published private(set) var inboxPollMinutes: Int

    /// Theme picked for the last note or stack; new notes reuse it. `nil` on a
    /// fresh install, which means the first color (yellow).
    @Published private(set) var lastNoteColor: String?

    static let defaultNotesServerURL = ""
    static let inboxPollChoices = [1, 5, 15, 30]

    private let store: NotesStore

    init(store: NotesStore) {
        self.store = store
        let data = store.loadSettings()
        self.defaultFolderPath = data.defaultFolderPath
        self.didMigrateLegacyNotes = data.didMigrateLegacyNotes
        self.noteFontFamily = data.noteFontFamily
        self.titleFontFamily = data.titleFontFamily
        self.notesServerURL = data.notesServerURL
        let storedMinutes = data.inboxPollMinutes ?? 1
        self.inboxPollMinutes = Self.inboxPollChoices.contains(storedMinutes) ? storedMinutes : 1
        self.lastNoteColor = data.lastNoteColor
    }

    /// Color for a note created now: the last one the user picked, or yellow.
    var newNoteColor: NoteColor {
        lastNoteColor.flatMap(NoteColor.init(rawValue:)) ?? NoteColor.allCases.first ?? .yellow
    }

    /// Configured server origin; empty until set in Settings.
    var notesServerURLString: String {
        notesServerURL ?? Self.defaultNotesServerURL
    }

    var defaultFolderURL: URL? {
        guard let defaultFolderPath else { return nil }
        return URL(fileURLWithPath: defaultFolderPath, isDirectory: true)
    }

    /// `~/Documents/Sticky Notes` (whether or not it exists).
    var documentsNotesFolderURL: URL? {
        guard let documents = FileManager.default.urls(
            for: .documentDirectory, in: .userDomainMask
        ).first else { return nil }
        return documents.appendingPathComponent(NotesStore.defaultFolderName, isDirectory: true)
    }

    /// The Documents shortcut is only offered while that folder is missing.
    var documentsNotesFolderExists: Bool {
        guard let url = documentsNotesFolderURL else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }

    /// Sets the folder used for new notes. Does not move existing files.
    func setDefaultFolder(_ url: URL) {
        defaultFolderPath = url.standardizedFileURL.path
        persist()
    }

    /// Creates `~/Documents/Sticky Notes` (if needed) and makes it the default.
    @discardableResult
    func createDefaultFolderInDocuments() -> URL? {
        guard let folder = documentsNotesFolderURL else {
            print("[AppSettings] No Documents directory available")
            return nil
        }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            setDefaultFolder(folder)
            return folder
        } catch {
            print("[AppSettings] Failed to create \(folder.path): \(error)")
            return nil
        }
    }

    /// Folder for new notes. Recreates a configured folder that was deleted;
    /// returns nil when no folder has been chosen yet (the first-launch prompt
    /// owns that case).
    func ensureDefaultFolder() -> URL? {
        guard let url = defaultFolderURL else { return nil }
        if FileManager.default.fileExists(atPath: url.path) {
            return url
        }
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        } catch {
            print("[AppSettings] Configured folder missing and could not be recreated: \(error)")
            return nil
        }
    }

    func revealDefaultFolder() {
        guard let url = defaultFolderURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func setNoteFontFamily(_ family: String?) {
        guard noteFontFamily != family else { return }
        noteFontFamily = family
        persist()
    }

    func setTitleFontFamily(_ family: String?) {
        guard titleFontFamily != family else { return }
        titleFontFamily = family
        persist()
    }

    /// Store the Notes server origin used for the inbox fetch and token lookup.
    func setNotesServerURL(_ raw: String) {
        let normalized = RemoteCredentials.normalize(raw)
        guard notesServerURL != normalized else { return }
        notesServerURL = normalized
        persist()
    }

    /// How often the background inbox pass runs. Only the offered choices stick.
    func setInboxPollMinutes(_ minutes: Int) {
        guard Self.inboxPollChoices.contains(minutes),
              inboxPollMinutes != minutes else { return }
        inboxPollMinutes = minutes
        persist()
    }

    /// Remember the color of the note or stack the user just recolored.
    func setLastNoteColor(_ color: NoteColor) {
        guard lastNoteColor != color.rawValue else { return }
        lastNoteColor = color.rawValue
        persist()
    }

    func markLegacyMigrationDone() {
        didMigrateLegacyNotes = true
        persist()
    }

    private func persist() {
        store.saveSettings(
            NotesStore.SettingsData(
                defaultFolderPath: defaultFolderPath,
                didMigrateLegacyNotes: didMigrateLegacyNotes,
                noteFontFamily: noteFontFamily,
                titleFontFamily: titleFontFamily,
                notesServerURL: notesServerURL,
                inboxPollMinutes: inboxPollMinutes,
                lastNoteColor: lastNoteColor
            )
        )
    }
}
