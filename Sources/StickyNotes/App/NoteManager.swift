import Foundation
import Combine

enum NoteRenameError: LocalizedError {
    case remoteNote
    case invalidName
    case nameInUse(String)

    var errorDescription: String? {
        switch self {
        case .remoteNote:
            return "Remote notes are renamed on the server, not on disk."
        case .invalidName:
            return "Enter a valid file name."
        case .nameInUse(let title):
            return "“\(title).md” already exists in this folder."
        }
    }
}

/// Manages the collection of notes.
///
/// Metadata lives in `NotesStore.index`, note bodies live in external Markdown
/// files. Edits are debounced, written to the file, and the index is refreshed
/// alongside.
class NoteManager: ObservableObject {
    // MARK: - Published Properties

    @Published private(set) var notes: [Note] = []

    /// The single default stack (position + front note), if it exists.
    @Published private(set) var stack: NoteStack?

    // MARK: - Private Properties

    private let store: NotesStore
    private let settings: AppSettings

    /// Debounce timer for auto-save
    private var saveTimer: Timer?
    private let saveDelay: TimeInterval = 0.5

    /// Notes whose body changed since the last flush
    private var dirtyNoteIds = Set<UUID>()

    /// Index needs rewriting (window state, cursor, ordering)
    private var indexDirty = false

    // MARK: - Initialization

    init(store: NotesStore, settings: AppSettings) {
        self.store = store
        self.settings = settings
        self.stack = store.loadStack()
        loadNotes()
        reconcileStack()
    }

    // MARK: - Loading

    /// Load the index and read each note's body from its file.
    func loadNotes() {
        notes = store.loadIndex().map(loadingContent)

        guard notes.isEmpty else { return }

        if !settings.didMigrateLegacyNotes {
            if let folder = settings.ensureDefaultFolder() {
                let migrated = LegacyImporter.migrate(store: store, into: folder)
                settings.markLegacyMigrationDone()
                if !migrated.isEmpty {
                    notes = migrated
                    store.saveIndex(notes)
                    return
                }
            } else {
                settings.markLegacyMigrationDone()
            }
        }

        // Markdown files already in the folder become stickies at launch (see
        // AppCoordinator.importNotesFromNotesFolder). Don't drop a welcome note
        // next to them.
        if let folder = settings.defaultFolderURL,
           !markdownFiles(in: folder).isEmpty {
            return
        }

        createDefaultNote()
    }

    private func loadingContent(_ note: Note) -> Note {
        var note = note

        if note.isRemote {
            // Remote notes come from the Notes API; the cached body is the
            // offline copy until the first successful fetch.
            if let cached = store.readRemoteContent(for: note) {
                note.content = cached
            }
            note.isMissing = false
            return note
        }

        if let content = store.readContent(for: note) {
            note.content = content
            note.isMissing = false
        } else {
            note.content = ""
            note.isMissing = true
            print("[NoteManager] Backing file missing for note \(note.id): \(note.path)")
        }
        return note
    }

    // MARK: - Stack

    /// Member notes, front sheet first (newest note on top).
    var stackedNotes: [Note] {
        guard let stackID = stack?.id else { return [] }
        return notes
            .filter { $0.stackID == stackID }
            .sorted(by: Self.stackOrder)
    }

    /// Newest first; stable when files were added in the same instant.
    private static func stackOrder(_ a: Note, _ b: Note) -> Bool {
        if a.createdAt != b.createdAt {
            return a.createdAt > b.createdAt
        }
        return a.id.uuidString < b.id.uuidString
    }

    /// The note currently shown by the stack window.
    var frontStackedNote: Note? {
        guard let stack, !stackedNotes.isEmpty else { return nil }
        if let frontNoteID = stack.frontNoteID,
           let note = notes.first(where: {
               $0.id == frontNoteID && $0.stackID == stack.id
           }) {
            return note
        }
        return stackedNotes.first
    }

    /// Make `noteId` the front sheet. Persisted so it survives relaunch.
    func setStackFront(_ noteId: UUID) {
        guard var stack,
              notes.contains(where: {
                  $0.id == noteId && $0.stackID == stack.id
              }) else { return }
        guard stack.frontNoteID != noteId else { return }
        stack.frontNoteID = noteId
        self.stack = stack
        store.saveStack(stack)
    }

    /// Create the default stack, or move it when it already exists.
    @discardableResult
    func ensureStack(
        at position: CGPoint,
        seedNote: Note? = nil,
        frontNoteID: UUID? = nil
    ) -> NoteStack {
        if var stack {
            if let frontNoteID { stack.frontNoteID = frontNoteID }
            seed(&stack, from: seedNote)
            self.stack = stack
            store.saveStack(stack)
            return stack
        }
        let stack: NoteStack
        if let seedNote {
            var seeded = NoteStack(seeding: seedNote, at: position)
            if let frontNoteID { seeded.frontNoteID = frontNoteID }
            stack = seeded
        } else {
            stack = NoteStack(position: position, frontNoteID: frontNoteID)
        }
        self.stack = stack
        store.saveStack(stack)
        return stack
    }

    /// Fill stack-level appearance only when it is missing (older stack.json).
    private func seed(_ stack: inout NoteStack, from note: Note?) {
        guard let note else { return }
        if stack.size == nil { stack.size = note.size }
        if stack.colorTheme == nil { stack.colorTheme = note.colorTheme }
        if stack.opacity == nil { stack.opacity = note.opacity }
        if stack.alwaysOnTop == nil { stack.alwaysOnTop = note.alwaysOnTop }
        if stack.isMinimized == nil { stack.isMinimized = false }
    }

    /// Remember where the stack window is. Called from `windowDidMove` only.
    func updateStackPlacement(
        position: CGPoint,
        screenUUID: String?,
        screenOffset: CGPoint?
    ) {
        guard var stack else { return }
        guard stack.position != position
                || stack.screenUUID != screenUUID
                || stack.screenOffset != screenOffset else { return }
        stack.position = position
        stack.screenUUID = screenUUID
        stack.screenOffset = screenOffset
        self.stack = stack
        store.saveStack(stack)
    }

    /// Remember the stack window's card size. Switching sheets never changes it.
    func updateStackSize(_ size: CGSize) {
        guard var stack else { return }
        guard stack.size != size else { return }
        stack.size = size
        self.stack = stack
        store.saveStack(stack)
    }

    /// Stack-level appearance (color, opacity, pin, minimized).
    func updateStackAppearance(
        colorTheme: String? = nil,
        opacity: Double? = nil,
        alwaysOnTop: Bool? = nil,
        isMinimized: Bool? = nil
    ) {
        guard var stack else { return }
        var changed = false
        if let colorTheme, stack.colorTheme != colorTheme {
            stack.colorTheme = colorTheme; changed = true
        }
        if let opacity, stack.opacity != opacity {
            stack.opacity = opacity; changed = true
        }
        if let alwaysOnTop, stack.alwaysOnTop != alwaysOnTop {
            stack.alwaysOnTop = alwaysOnTop; changed = true
        }
        if let isMinimized, stack.isMinimized != isMinimized {
            stack.isMinimized = isMinimized; changed = true
        }
        guard changed else { return }
        self.stack = stack
        store.saveStack(stack)
    }

    /// Put a placed note back into the default stack and make it the front sheet.
    @discardableResult
    func stackNote(_ noteId: UUID) -> Note? {
        guard let index = notes.firstIndex(where: { $0.id == noteId }) else {
            return nil
        }
        guard !notes[index].isStacked else { return notes[index] }

        let stackPosition = stack?.position ?? notes[index].position
        ensureStack(at: stackPosition, seedNote: notes[index], frontNoteID: noteId)

        notes[index].stackID = NoteStack.defaultID
        notes[index].position = stackPosition
        notes[index].updateModificationDate()
        store.saveIndex(notes)
        reconcileStack()
        print("[NoteManager] Added note \(noteId) to the stack")
        return notes.first { $0.id == noteId }
    }

    /// Register notes written by the Notes inbox importer. All of them join the
    /// default stack, and the index is saved before this returns so the folder
    /// monitor's next pass finds the note by path instead of adding it again.
    @discardableResult
    func addImportedNotes(
        _ imported: [Note],
        at stackPosition: CGPoint,
        frontNoteID: UUID?
    ) -> [Note] {
        guard !imported.isEmpty else { return [] }

        var inserted = imported
        for index in inserted.indices {
            inserted[index].stackID = NoteStack.defaultID
            inserted[index].position = stackPosition
        }
        notes.append(contentsOf: inserted)
        ensureStack(
            at: stackPosition,
            seedNote: inserted.first,
            frontNoteID: frontNoteID ?? inserted.first?.id
        )
        store.saveIndex(notes)
        reconcileStack()
        print("[NoteManager] Imported \(inserted.count) notes into the stack")
        return notes.filter { note in inserted.contains(where: { $0.id == note.id }) }
    }

    /// Rename the backing Markdown file. The title is the file name, so the
    /// note and any open window follow it.
    @discardableResult
    func renameNote(_ noteId: UUID, to rawTitle: String) throws -> Note {
        guard let index = notes.firstIndex(where: { $0.id == noteId }) else {
            throw NoteRenameError.invalidName
        }
        guard !notes[index].isRemote else {
            throw NoteRenameError.remoteNote
        }

        let title = NotesStore.sanitizeFileName(rawTitle)
        guard !title.isEmpty else { throw NoteRenameError.invalidName }
        guard title != notes[index].title else { return notes[index] }

        let oldURL = URL(fileURLWithPath: notes[index].path)
        let folder = oldURL.deletingLastPathComponent()
        let newURL = folder
            .appendingPathComponent(title)
            .appendingPathExtension("md")

        if newURL.path.caseInsensitiveCompare(oldURL.path) != .orderedSame,
           FileManager.default.fileExists(atPath: newURL.path) {
            throw NoteRenameError.nameInUse(title)
        }

        if FileManager.default.fileExists(atPath: oldURL.path) {
            try FileManager.default.moveItem(at: oldURL, to: newURL)
        } else {
            // The file went missing; recreate it under the new name so the
            // note keeps its content instead of becoming a dangling path.
            var target = notes[index]
            target.path = newURL.path
            try store.writeContent(notes[index].content, for: target)
        }

        notes[index].path = newURL.path
        notes[index].title = title
        notes[index].isMissing = false
        notes[index].updateModificationDate()
        store.saveIndex(notes)
        print("[NoteManager] Renamed note \(noteId) to \(title).md")
        return notes[index]
    }

    /// Take a note out of the stack. It gets its own window position again.
    @discardableResult
    func pullOutNote(
        _ noteId: UUID,
        to position: CGPoint,
        screenUUID: String? = nil,
        screenOffset: CGPoint? = nil
    ) -> Note? {
        guard let index = notes.firstIndex(where: {
            $0.id == noteId && $0.isStacked
        }) else { return nil }

        notes[index].stackID = nil
        notes[index].position = position
        notes[index].screenUUID = screenUUID
        notes[index].screenOffset = screenOffset

        // The note inherits the stack's appearance now that it stands alone.
        if let stack {
            if let size = stack.size { notes[index].size = size }
            if let colorTheme = stack.colorTheme { notes[index].colorTheme = colorTheme }
            if let opacity = stack.opacity { notes[index].opacity = opacity }
            if let alwaysOnTop = stack.alwaysOnTop { notes[index].alwaysOnTop = alwaysOnTop }
        }
        notes[index].isMinimized = false
        notes[index].updateModificationDate()
        store.saveIndex(notes)
        reconcileStack()
        print("[NoteManager] Pulled note \(noteId) out of the stack")
        return notes.first { $0.id == noteId }
    }

    /// Drop stack membership when there are no member notes left, and make
    /// sure the stored front sheet still exists (newest fallback).
    private func reconcileStack() {
        if stack == nil, let member = notes.first(where: { $0.isStacked }) {
            // stack.json went missing: rebuild from a member's saved position
            // rather than dropping every note out of the stack.
            stack = NoteStack(
                id: member.stackID ?? NoteStack.defaultID,
                position: member.position,
                frontNoteID: member.id
            )
        }
        guard var stack else { return }
        let members = notes
            .filter { $0.stackID == stack.id }
            .sorted(by: Self.stackOrder)

        guard !members.isEmpty else {
            self.stack = nil
            store.saveStack(nil)
            print("[NoteManager] Stack is empty; removed stack.json")
            return
        }

        if let front = stack.frontNoteID,
           members.contains(where: { $0.id == front }) {
            self.stack = stack
            return
        }

        stack.frontNoteID = members.first?.id
        self.stack = stack
        store.saveStack(stack)
    }

    // MARK: - Public Methods

    /// Extensions the app can open. Kept in sync with the `UTImportedTypeDeclarations`
    /// entry in Info.plist.
    static let markdownExtensions: Set<String> = [
        "md", "markdown", "mdown", "mkdn", "mkd", "mdwn"
    ]

    static func isMarkdownFile(_ url: URL) -> Bool {
        url.isFileURL && markdownExtensions.contains(url.pathExtension.lowercased())
    }

    /// Register an existing Markdown file (already on disk, anywhere) and return
    /// its note. If the file is already open, its body is re-read from disk so
    /// external edits show up, and the existing note is returned.
    @discardableResult
    func addNote(forFileURL url: URL, position: CGPoint = CGPoint(x: 100, y: 100)) -> Note? {
        guard Self.isMarkdownFile(url),
              FileManager.default.fileExists(atPath: url.path) else {
            print("[NoteManager] Not an openable Markdown file: \(url.path)")
            return nil
        }

        if let index = notes.firstIndex(where: {
            Self.sameFile(URL(fileURLWithPath: $0.path), url)
        }) {
            if let content = store.readContent(for: notes[index]) {
                notes[index].content = content
                notes[index].isMissing = false
            }
            if notes[index].isStacked {
                setStackFront(notes[index].id)
            }
            return notes[index]
        }

        guard let content = try? String(contentsOf: url, encoding: .utf8) else {
            print("[NoteManager] Could not read \(url.path) as UTF-8")
            return nil
        }

        // Files opened from the notes folder are "added to the folder", so they
        // join the default stack. Files opened from anywhere else stay placed.
        let joinsStack = settings.defaultFolderURL.map {
            Self.isInside(url, $0.standardizedFileURL)
        } ?? false

        let colors = NoteColor.allCases
        var note = Note(
            path: url.path,
            title: url.deletingPathExtension().lastPathComponent,
            stackID: joinsStack ? NoteStack.defaultID : nil,
            content: content,
            position: position,
            colorTheme: colors[notes.count % colors.count].rawValue
        )
        if joinsStack {
            let stack = ensureStack(
                at: position,
                seedNote: note,
                frontNoteID: note.id
            )
            note.position = stack.position
        }
        notes.append(note)
        store.saveIndex(notes)
        print("[NoteManager] Opened external file: \(url.path)")
        return note
    }

    /// True when both URLs point at the same file, even through a symlinked
    /// folder (`/tmp` vs `/private/tmp`, iCloud Drive aliases) or a case
    /// difference on a case-insensitive volume.
    private static func sameFile(_ a: URL, _ b: URL) -> Bool {
        if a.path.compare(b.path, options: .caseInsensitive) == .orderedSame {
            return true
        }
        let keys: Set<URLResourceKey> = [.fileResourceIdentifierKey]
        guard let idA = try? a.resourceValues(forKeys: keys).fileResourceIdentifier,
              let idB = try? b.resourceValues(forKeys: keys).fileResourceIdentifier else {
            return false
        }
        return idA.isEqual(idB)
    }

    /// Register a note served by the Notes API. `link.pageURL` is the share URL
    /// that identifies it; the body is cached locally for offline opens.
    @discardableResult
    func addRemoteNote(
        link: RemoteNoteLink,
        remoteNoteID: String,
        title: String,
        content: String,
        revision: String,
        position: CGPoint = CGPoint(x: 100, y: 100)
    ) -> Note {
        if let index = notes.firstIndex(where: {
            $0.isRemote && $0.remoteShareID == link.shareID && $0.remoteBaseURL == link.baseURL.absoluteString
        }) {
            notes[index].content = content
            notes[index].title = title
            notes[index].remoteNoteID = remoteNoteID
            notes[index].remoteRevision = revision
            notes[index].isMissing = false
            try? store.writeRemoteContent(content, for: notes[index])
            return notes[index]
        }

        let colors = NoteColor.allCases
        let note = Note(
            sourceKind: .remoteURL,
            path: link.pageURL.absoluteString,
            title: title,
            content: content,
            position: position,
            remoteBaseURL: link.baseURL.absoluteString,
            remoteNoteID: remoteNoteID,
            remoteShareID: link.shareID,
            remoteRevision: revision,
            colorTheme: colors[notes.count % colors.count].rawValue
        )
        notes.append(note)
        try? store.writeRemoteContent(content, for: note)
        store.saveIndex(notes)
        print("[NoteManager] Opened remote note: \(note.path)")
        return note
    }

    /// Apply a newer revision fetched from the API.
    func updateRemoteNote(
        _ noteId: UUID,
        title: String?,
        content: String,
        revision: String
    ) {
        guard let index = notes.firstIndex(where: { $0.id == noteId }) else { return }
        notes[index].content = content
        notes[index].remoteRevision = revision
        if let title { notes[index].title = title }
        notes[index].isMissing = false
        notes[index].updateModificationDate()
        try? store.writeRemoteContent(content, for: notes[index])
        store.saveIndex(notes)
    }

    /// Remote notes that are currently open (the index only holds open notes).
    var remoteNotes: [Note] {
        notes.filter { $0.isRemote }
    }

    /// What a pass over the notes folder changed on disk.
    struct FolderSyncResult {
        var added: [Note] = []
        var changed: [Note] = []
        var removed: [UUID] = []
    }

    /// Reconcile the index with the notes folder after it changed on disk.
    ///
    /// New files become notes, deleted files drop out, and edited files reload
    /// their body — unless local edits are still pending, in which case the note
    /// is left alone. Only top-level files inside the notes folder are considered:
    /// the folder can be an Obsidian vault with thousands of notes in subfolders.
    /// - Parameter position: Window position for the n-th added note.
    @discardableResult
    func syncWithFolder(
        position: (Int) -> CGPoint = { _ in CGPoint(x: 100, y: 100) }
    ) -> FolderSyncResult {
        var result = FolderSyncResult()
        guard let folder = settings.defaultFolderURL else { return result }

        let folderURL = folder.standardizedFileURL
        let files = markdownFiles(in: folder)
        let localNotes = notes.filter {
            !$0.isRemote && Self.isInside(URL(fileURLWithPath: $0.path), folderURL)
        }

        // Files that no longer exist: forget the note, unless edits are pending
        // (the next autosave would recreate the file anyway).
        var removedIds = Set<UUID>()
        for note in localNotes {
            let url = URL(fileURLWithPath: note.path)
            if files.contains(where: { Self.sameFile(url, $0) }) { continue }
            if isDirty(note.id) { continue }
            removedIds.insert(note.id)
        }

        // Files that appeared since the last pass. They join the default stack;
        // the stack keeps its existing spot, or appears where the first added
        // note would have gone.
        let known = localNotes.map { URL(fileURLWithPath: $0.path) }
        var added: [Note] = []
        let stackPosition = stack?.position ?? position(0)
        for url in files where !known.contains(where: { Self.sameFile($0, url) }) {
            guard let content = try? String(contentsOf: url, encoding: .utf8) else {
                print("[NoteManager] Skipped unreadable file: \(url.path)")
                continue
            }
            let colors = NoteColor.allCases
            added.append(Note(
                path: url.path,
                title: url.deletingPathExtension().lastPathComponent,
                stackID: NoteStack.defaultID,
                content: content,
                position: stackPosition,
                colorTheme: colors[(notes.count + added.count) % colors.count].rawValue
            ))
        }

        // Bodies edited outside the app. Skip notes with unsaved local keystrokes.
        var changed: [Note] = []
        for note in localNotes where !removedIds.contains(note.id) && !isDirty(note.id) {
            let url = URL(fileURLWithPath: note.path)
            guard files.contains(where: { Self.sameFile(url, $0) }),
                  let disk = try? String(contentsOf: url, encoding: .utf8),
                  disk != note.content else { continue }

            var updated = note
            updated.content = disk
            changed.append(updated)
        }

        guard !removedIds.isEmpty || !added.isEmpty || !changed.isEmpty else {
            return result
        }

        if !removedIds.isEmpty {
            notes.removeAll { removedIds.contains($0.id) }
            result.removed = Array(removedIds)
        }
        for updated in changed {
            if let index = notes.firstIndex(where: { $0.id == updated.id }) {
                notes[index] = updated
            }
        }
        if !added.isEmpty {
            notes.append(contentsOf: added)
            if stack == nil {
                ensureStack(
                    at: stackPosition,
                    seedNote: added.first,
                    frontNoteID: added.first?.id
                )
            }
        }
        store.saveIndex(notes)
        reconcileStack()

        result.added = added
        result.changed = changed
        print("[NoteManager] Notes folder changed: +\(added.count) ~\(changed.count) -\(removedIds.count)")
        return result
    }

    /// Notes whose body has unsaved edits, so an external reload would stomp them.
    private func isDirty(_ noteId: UUID) -> Bool {
        dirtyNoteIds.contains(noteId)
    }

    /// True when `url` sits directly in `folder`.
    ///
    /// Compares the parent directory by file identity rather than path text:
    /// `/var/...` and `/private/var/...` name the same folder, and a deleted
    /// file cannot resolve its own path.
    private static func isInside(_ url: URL, _ folder: URL) -> Bool {
        sameFile(url.deletingLastPathComponent(), folder)
    }

    /// Markdown files directly inside `folder`, sorted by name.
    private func markdownFiles(in folder: URL) -> [URL] {
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        return entries
            .filter { Self.isMarkdownFile($0) }
            .sorted {
                $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent)
                    == .orderedAscending
            }
    }

    /// Create a new note file in the default folder and register it.
    @discardableResult
    func createNote(
        content: String = "",
        position: CGPoint = CGPoint(x: 100, y: 100),
        baseTitle: String? = nil
    ) -> Note? {
        guard let folder = settings.ensureDefaultFolder() else {
            print("[NoteManager] No notes folder available")
            return nil
        }

        do {
            let url = try store.createNoteFile(
                in: folder,
                baseTitle: baseTitle ?? NotesStore.defaultTitle(),
                content: content
            )
            let colors = NoteColor.allCases
            // Cmd+N places a note on its own. Only files that appear in the
            // folder from outside join the default stack automatically.
            let note = Note(
                path: url.path,
                title: url.deletingPathExtension().lastPathComponent,
                content: content,
                position: position,
                colorTheme: colors[notes.count % colors.count].rawValue
            )
            notes.append(note)
            store.saveIndex(notes)
            print("[NoteManager] Created note file: \(url.path)")
            return note
        } catch {
            print("[NoteManager] Failed to create note file: \(error)")
            return nil
        }
    }

    /// Update an existing note (all fields, including body).
    func updateNote(_ note: Note) {
        guard let index = notes.firstIndex(where: { $0.id == note.id }) else {
            print("[NoteManager] Warning: Attempting to update non-existent note: \(note.id)")
            return
        }

        var updatedNote = note
        updatedNote.updateModificationDate()
        notes[index] = updatedNote

        dirtyNoteIds.insert(note.id)
        scheduleSave()
        print("[NoteManager] Updated note: \(note.id)")
    }

    /// Update note content
    func updateNoteContent(_ noteId: UUID, content: String) {
        guard let index = notes.firstIndex(where: { $0.id == noteId }),
              notes[index].content != content else {
            return
        }

        notes[index].content = content
        notes[index].isMissing = false
        notes[index].updateModificationDate()

        dirtyNoteIds.insert(noteId)
        scheduleSave()
    }

    /// Update note window state (position, size, opacity, minimized)
    func updateNoteWindow(
        _ noteId: UUID,
        position: CGPoint? = nil,
        size: CGSize? = nil,
        opacity: Double? = nil,
        isMinimized: Bool? = nil,
        screenUUID: String? = nil,
        screenOffset: CGPoint? = nil
    ) {
        guard let index = notes.firstIndex(where: { $0.id == noteId }) else {
            return
        }

        if let position { notes[index].position = position }
        if let size { notes[index].size = size }
        if let opacity { notes[index].opacity = opacity }
        if let isMinimized { notes[index].isMinimized = isMinimized }
        if let screenUUID { notes[index].screenUUID = screenUUID }
        if let screenOffset { notes[index].screenOffset = screenOffset }

        notes[index].updateModificationDate()
        scheduleSave()
    }

    /// Update note color theme
    func updateNoteColor(_ noteId: UUID, colorTheme: String) {
        guard let index = notes.firstIndex(where: { $0.id == noteId }) else { return }
        notes[index].colorTheme = colorTheme
        notes[index].updateModificationDate()
        scheduleSave()
    }

    /// Update note cursor position (restored on reopen)
    func updateNoteCursorPosition(_ noteId: UUID, cursorPosition: Int) {
        guard let index = notes.firstIndex(where: { $0.id == noteId }) else { return }
        notes[index].cursorPosition = cursorPosition
        indexDirty = true
    }

    /// Update note scroll position (restored on reopen)
    func updateNoteScrollTop(_ noteId: UUID, scrollTop: Double) {
        guard let index = notes.firstIndex(where: { $0.id == noteId }) else { return }
        notes[index].scrollTop = scrollTop
        indexDirty = true
    }

    /// Update note always-on-top setting
    func updateNoteAlwaysOnTop(_ noteId: UUID, alwaysOnTop: Bool) {
        guard let index = notes.firstIndex(where: { $0.id == noteId }) else { return }
        notes[index].alwaysOnTop = alwaysOnTop
        scheduleSave()
    }

    /// Remove a note from the app.
    ///
    /// With `trashingFile`, the Markdown file moves to the system Trash, where
    /// the user can restore it. Remote notes keep only their cached body, which
    /// is deleted either way.
    func deleteNote(_ noteId: UUID, trashingFile: Bool = false) {
        // Flush pending edits so closing a window never loses the last keystrokes.
        if dirtyNoteIds.contains(noteId), let note = getNote(noteId) {
            if note.isRemote {
                try? store.writeRemoteContent(note.content, for: note)
            } else {
                try? store.writeContent(note.content, for: note)
            }
            dirtyNoteIds.remove(noteId)
        }

        guard let note = getNote(noteId) else { return }

        if note.isRemote {
            store.removeRemoteContent(for: note)
        }

        if trashingFile, let url = note.fileURL,
           FileManager.default.fileExists(atPath: url.path) {
            do {
                try FileManager.default.trashItem(at: url, resultingItemURL: nil)
                print("[NoteManager] Moved note \(noteId) to the Trash")
            } catch {
                print("[NoteManager] Could not move \(url.path) to the Trash: \(error)")
            }
        }

        notes.removeAll { $0.id == noteId }
        store.saveIndex(notes)
        reconcileStack()
        print("[NoteManager] Removed note \(noteId) from the index")
    }

    /// Save a note immediately (for critical operations)
    func saveNoteImmediately(_ note: Note) {
        updateNote(note)
        flush()
    }

    /// Write every pending body edit and the index. Called on app termination.
    func saveAll() {
        flush(forceIndex: true)
    }

    /// Get a note by ID
    func getNote(_ noteId: UUID) -> Note? {
        notes.first { $0.id == noteId }
    }

    // MARK: - Private Methods

    private func scheduleSave() {
        indexDirty = true
        saveTimer?.invalidate()
        saveTimer = Timer.scheduledTimer(withTimeInterval: saveDelay, repeats: false) { [weak self] _ in
            self?.flush()
        }
    }

    private func flush(forceIndex: Bool = false) {
        saveTimer?.invalidate()
        saveTimer = nil

        for id in dirtyNoteIds {
            guard let note = getNote(id) else { continue }
            do {
                if note.isRemote {
                    try store.writeRemoteContent(note.content, for: note)
                } else {
                    try store.writeContent(note.content, for: note)
                }
            } catch {
                print("[NoteManager] Failed to write \(note.path): \(error)")
            }
        }
        dirtyNoteIds.removeAll()

        if indexDirty || forceIndex {
            store.saveIndex(notes)
            indexDirty = false
        }
    }

    /// Create the default welcome note
    private func createDefaultNote() {
        let welcomeContent = """
        # Welcome to Sticky Notes!

        This note is a Markdown file on your disk. Changes are saved straight
        back to the file, so you can edit it here or in any other editor.

        ## Features
        - Live markdown preview
        - Math equations: $E = mc^2$
        - Code blocks
        - Files live wherever you point the notes folder (Settings, Cmd+,)

        Start typing to get started.
        """

        createNote(content: welcomeContent, baseTitle: "Welcome")
    }
}
