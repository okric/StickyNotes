import AppKit
import SwiftUI
import Combine
import UniformTypeIdentifiers

/// Main coordinator that manages the application state and components
class AppCoordinator: ObservableObject {
    // MARK: - Published Properties

    @Published var noteManager: NoteManager
    @Published var windowManager: WindowManager

    // MARK: - Properties

    /// Set to true during app termination to prevent note deletion on window close
    var isQuitting = false

    /// Notes folder and migration preferences (Settings window)
    @Published var settings: AppSettings

    // MARK: - Private Properties

    private let store: NotesStore
    private var cancellables = Set<AnyCancellable>()

    /// Polls open remote notes for newer revisions.
    private var remotePollTimer: Timer?
    private var isPollingRemote = false

    /// Pending debounced PATCHes for remote notes.
    private var remoteSaveTimers: [UUID: Timer] = [:]
    private let remoteSaveDelay: TimeInterval = 0.8

    /// Toast offering to undo the last move to the Trash.
    private var trashToast: TrashUndoToast?

    // MARK: - Initialization

    init() {
        let store = NotesStore()
        let settings = AppSettings(store: store)
        self.store = store
        self.settings = settings
        self.noteManager = NoteManager(store: store, settings: settings)
        self.windowManager = WindowManager()

        // Wire up SharedWebViewManager
        SharedWebViewManager.shared.coordinator = self

        setupBindings()
        importNotesFromNotesFolder()
        openInitialWindows()
        startRemotePolling()

        NotificationCenter.default.addObserver(
            forName: .remoteTokenChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.refreshRemoteEditingPolicy()
        }
    }

    deinit {
        remotePollTimer?.invalidate()
        remoteSaveTimers.values.forEach { $0.invalidate() }
    }

    // MARK: - Public Methods

    /// Create a new note and open its window on the current screen
    func createNewNote() {
        let position = calculateNewNotePosition()
        guard let note = noteManager.createNote(position: position) else {
            NSSound.beep()
            return
        }
        windowManager.openWindow(for: note, coordinator: self)
    }

    /// Called when a note window is closing (from windowWillClose delegate).
    /// If the app is quitting, skip — saveAllNotesImmediately() handles bulk save.
    /// Otherwise, remove the note from the index and move its file to the Trash.
    func closeNoteWindow(_ noteId: UUID) {
        remoteSaveTimers[noteId]?.invalidate()
        remoteSaveTimers[noteId] = nil
        windowManager.removeWindow(for: noteId)
        SharedWebViewManager.shared.removeCachedState(for: noteId)

        if isQuitting {
            return
        }
        if let trashed = noteManager.deleteNote(noteId, trashingFile: true) {
            showTrashUndoToast(for: trashed)
        }
    }

    /// Offer to undo a close that moved the note's file to the Trash.
    private func showTrashUndoToast(for trashed: NoteManager.TrashedNote) {
        trashToast?.dismiss()
        trashToast = nil

        var toast: TrashUndoToast?
        toast = TrashUndoToast(
            title: trashed.note.title,
            onUndo: { [weak self] in self?.undoTrash(trashed) },
            onDismiss: { [weak self, weak toast] in
                guard let self, let toast, self.trashToast === toast else { return }
                self.trashToast = nil
            }
        )
        trashToast = toast
        toast?.present()
    }

    /// Put a trashed note back where it was and reopen its window.
    private func undoTrash(_ trashed: NoteManager.TrashedNote) {
        do {
            try noteManager.restoreTrashedNote(trashed)
        } catch {
            let alert = NSAlert()
            alert.messageText = "Could not restore the note"
            alert.informativeText = "“\(trashed.fileURL.lastPathComponent)” is still in the Trash. \(error.localizedDescription)"
            alert.alertStyle = .warning
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
            return
        }

        windowManager.openWindow(for: trashed.note, coordinator: self)
        windowManager.bringToFront(trashed.note.id)
    }

    /// Show the standard Open panel and open the chosen Markdown files.
    func promptOpenFiles() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.resolvesAliases = true
        panel.allowedContentTypes = [UTType(importedAs: "net.daringfireball.markdown")]
        panel.message = "Choose Markdown files to open as sticky notes"
        panel.prompt = "Open"

        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK else { return }
        openFiles(panel.urls)
    }

    /// Open Markdown files or note URLs handed over by Launch Services (Finder
    /// "Open With", drag onto the Dock icon, `open -a StickyNotes note.md`,
    /// `open -a StickyNotes https://notes.../n/<id>`). Each file gets a note; a
    /// file that already has a live note just brings its window forward.
    /// - Returns: `true` if at least one input produced a note.
    @discardableResult
    func openFiles(_ urls: [URL]) -> Bool {
        var opened = false
        for url in urls {
            if NoteManager.isMarkdownFile(url) {
                if openFile(url) != nil { opened = true }
            } else if let link = RemoteNoteLink.parse(url) {
                openRemoteLink(link)
                opened = true
            }
        }
        return opened
    }

    /// Open a single Markdown file at an arbitrary path. Files are not moved or
    /// copied; the note keeps pointing at its original location.
    @discardableResult
    func openFile(_ url: URL) -> Note? {
        let canonical = url.standardizedFileURL.resolvingSymlinksInPath()
        guard let note = noteManager.addNote(
            forFileURL: canonical,
            position: calculateNewNotePosition()
        ) else {
            NSSound.beep()
            return nil
        }
        windowManager.openWindow(for: note, coordinator: self)
        windowManager.bringToFront(note.id)
        return note
    }

    // MARK: - Remote notes (Notes API)

    /// Open a shared note link (`https://notes.example.com/n/<id>`).
    func openRemoteURL(_ url: URL) {
        guard let link = RemoteNoteLink.parse(url) else {
            presentRemoteError(RemoteNotesClient.ClientError.invalidLink)
            return
        }
        openRemoteLink(link)
    }

    /// Ask for a note URL and open it.
    func promptOpenRemoteURL() {
        let alert = NSAlert()
        alert.messageText = "Open Note URL"
        alert.informativeText = "Paste a shared note link from your Notes server."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 360, height: 24))
        field.placeholderString = "https://notes.example.com/n/…"
        if let clip = NSPasteboard.general.string(forType: .string) {
            let trimmed = clip.trimmingCharacters(in: .whitespacesAndNewlines)
            if let url = URL(string: trimmed), RemoteNoteLink.parse(url) != nil {
                field.stringValue = trimmed
            }
        }
        alert.accessoryView = field
        alert.addButton(withTitle: "Open")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field

        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let raw = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: raw), RemoteNoteLink.parse(url) != nil else {
            presentRemoteError(RemoteNotesClient.ClientError.invalidLink)
            return
        }
        openRemoteURL(url)
    }

    private func openRemoteLink(_ link: RemoteNoteLink) {
        if let existing = noteManager.notes.first(where: {
            $0.isRemote
                && $0.remoteShareID == link.shareID
                && $0.remoteBaseURL == link.baseURL.absoluteString
        }) {
            windowManager.openWindow(for: existing, coordinator: self)
            windowManager.bringToFront(existing.id)
            refreshRemoteNote(existing)
            return
        }

        RemoteNotesClient.shared.fetchSharedNote(link) { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error):
                self.presentRemoteError(error)
            case .success(let remote):
                let note = self.noteManager.addRemoteNote(
                    link: link,
                    remoteNoteID: remote.id,
                    title: remote.title,
                    content: remote.body,
                    revision: remote.revision,
                    position: self.calculateNewNotePosition()
                )
                self.windowManager.openWindow(for: note, coordinator: self)
                self.windowManager.bringToFront(note.id)
            }
        }
    }

    private func startRemotePolling() {
        remotePollTimer?.invalidate()
        remotePollTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            self?.pollRemoteNotes()
        }
    }

    /// Fetch every open remote note and apply newer revisions.
    private func pollRemoteNotes() {
        guard !isPollingRemote else { return }
        let notes = noteManager.remoteNotes
        guard !notes.isEmpty else { return }

        isPollingRemote = true
        let group = DispatchGroup()
        for note in notes {
            guard let base = note.remoteBaseURL.flatMap({ URL(string: $0) }),
                  let shareID = note.remoteShareID else { continue }
            group.enter()
            RemoteNotesClient.shared.fetchSharedNote(
                RemoteNoteLink(baseURL: base, shareID: shareID)
            ) { [weak self] result in
                defer { group.leave() }
                guard let self, case .success(let remote) = result else { return }
                guard remote.revision != note.remoteRevision else { return }
                // Don't stomp unsaved keystrokes.
                guard self.remoteSaveTimers[note.id] == nil else { return }
                self.noteManager.updateRemoteNote(
                    note.id,
                    title: remote.title,
                    content: remote.body,
                    revision: remote.revision
                )
                self.windowManager.getWindowController(for: note.id)?
                    .applyRemoteUpdate(content: remote.body)
            }
        }
        group.notify(queue: .main) { [weak self] in
            self?.isPollingRemote = false
        }
    }

    private func refreshRemoteNote(_ note: Note) {
        guard let base = note.remoteBaseURL.flatMap({ URL(string: $0) }),
              let shareID = note.remoteShareID else { return }
        RemoteNotesClient.shared.fetchSharedNote(
            RemoteNoteLink(baseURL: base, shareID: shareID)
        ) { [weak self] result in
            guard let self, case .success(let remote) = result else { return }
            guard remote.revision != note.remoteRevision else { return }
            self.noteManager.updateRemoteNote(
                note.id,
                title: remote.title,
                content: remote.body,
                revision: remote.revision
            )
            self.windowManager.getWindowController(for: note.id)?
                .applyRemoteUpdate(content: remote.body)
        }
    }

    private func scheduleRemoteSave(_ noteId: UUID) {
        guard noteManager.getNote(noteId)?.isRemote == true else { return }
        remoteSaveTimers[noteId]?.invalidate()
        remoteSaveTimers[noteId] = Timer.scheduledTimer(
            withTimeInterval: remoteSaveDelay,
            repeats: false
        ) { [weak self] _ in
            self?.remoteSaveTimers[noteId] = nil
            self?.saveRemoteNote(noteId)
        }
    }

    private func saveRemoteNote(_ noteId: UUID) {
        guard let note = noteManager.getNote(noteId), note.isRemote,
              let baseString = note.remoteBaseURL,
              let base = URL(string: baseString),
              let noteID = note.remoteNoteID,
              let revision = note.remoteRevision,
              let token = RemoteCredentials.token(for: baseString) else {
            return
        }

        RemoteNotesClient.shared.patchNote(
            baseURL: base,
            noteID: noteID,
            body: note.content,
            revision: revision,
            token: token
        ) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let remote):
                self.noteManager.updateRemoteNote(
                    noteId,
                    title: remote.title,
                    content: remote.body,
                    revision: remote.revision
                )
            case .failure(RemoteNotesClient.ClientError.conflict(let remote)):
                self.resolveRemoteConflict(noteId: noteId, remote: remote)
            case .failure(let error):
                // Keep the local text and cache; the next successful save (or a
                // poll) reconciles it.
                print("[AppCoordinator] Remote save failed: \(error.localizedDescription)")
            }
        }
    }

    private func resolveRemoteConflict(noteId: UUID, remote: RemoteNote) {
        let alert = NSAlert()
        alert.messageText = "This note changed on the server"
        alert.informativeText = "Another client saved a newer version. Reload their version or overwrite it with yours?"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Reload Theirs")
        alert.addButton(withTitle: "Keep Mine")
        NSApp.activate(ignoringOtherApps: true)

        if alert.runModal() == .alertSecondButtonReturn {
            // Overwrite: adopt the new revision, then save our text again.
            let local = noteManager.getNote(noteId)?.content ?? ""
            noteManager.updateRemoteNote(
                noteId,
                title: nil,
                content: local,
                revision: remote.revision
            )
            saveRemoteNote(noteId)
        } else {
            noteManager.updateRemoteNote(
                noteId,
                title: remote.title,
                content: remote.body,
                revision: remote.revision
            )
            windowManager.getWindowController(for: noteId)?
                .applyRemoteUpdate(content: remote.body)
        }
    }

    /// A token was added/removed: let open remote notes switch between
    /// read-only and editable without reopening them.
    private func refreshRemoteEditingPolicy() {
        for note in noteManager.remoteNotes {
            windowManager.getWindowController(for: note.id)?.refreshEditingPolicy()
        }
    }

    private func presentRemoteError(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "Could not open the note"
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    /// Handle note content changes from the editor
    func handleContentChange(noteId: UUID, content: String) {
        noteManager.updateNoteContent(noteId, content: content)

        if noteManager.getNote(noteId)?.isRemote == true {
            scheduleRemoteSave(noteId)
        }
    }

    /// Handle window state changes
    func handleWindowStateChange(
        noteId: UUID,
        position: CGPoint? = nil,
        size: CGSize? = nil,
        isMinimized: Bool? = nil,
        screenUUID: String? = nil,
        screenOffset: CGPoint? = nil
    ) {
        noteManager.updateNoteWindow(
            noteId,
            position: position,
            size: size,
            isMinimized: isMinimized,
            screenUUID: screenUUID,
            screenOffset: screenOffset
        )
    }

    /// Reopen windows for all existing notes
    func showAllNotes() {
        for note in noteManager.notes {
            windowManager.openWindow(for: note, coordinator: self)
        }
    }

    /// Change a note's color theme
    func changeNoteColor(noteId: UUID, colorTheme: String) {
        noteManager.updateNoteColor(noteId, colorTheme: colorTheme)
        windowManager.getWindowController(for: noteId)?.setColorTheme(colorTheme)
    }

    /// Change a note's opacity
    func setNoteOpacity(noteId: UUID, opacity: Double) {
        noteManager.updateNoteWindow(noteId, opacity: opacity)
        windowManager.getWindowController(for: noteId)?.setOpacity(opacity)
    }

    /// Toggle a note's always-on-top setting
    func setNoteAlwaysOnTop(noteId: UUID, alwaysOnTop: Bool) {
        noteManager.updateNoteAlwaysOnTop(noteId, alwaysOnTop: alwaysOnTop)
        windowManager.getWindowController(for: noteId)?.setAlwaysOnTop(alwaysOnTop)
    }

    /// Get the note ID of the currently focused window
    func focusedNoteId() -> UUID? {
        guard let keyWindow = NSApp.keyWindow else { return nil }
        return windowManager.noteId(for: keyWindow)
    }

    /// Cycle focus to the next note window (Cmd+`)
    func cycleToNextWindow() {
        let allIds = windowManager.getAllWindowIds()
            .sorted { $0.uuidString < $1.uuidString }
        guard !allIds.isEmpty else { return }

        if let currentId = focusedNoteId(),
           let idx = allIds.firstIndex(of: currentId) {
            let next = allIds[(idx + 1) % allIds.count]
            windowManager.bringToFront(next)
        } else {
            windowManager.bringToFront(allIds[0])
        }
    }

    // MARK: - Last Active Note Persistence

    private static let lastActiveNoteKey = "lastActiveNoteId"

    /// Save the currently focused note ID to UserDefaults
    func saveLastActiveNote() {
        if let noteId = focusedNoteId() {
            UserDefaults.standard.set(noteId.uuidString, forKey: Self.lastActiveNoteKey)
        }
    }

    /// Restore focus to the last active note (called after app launch)
    func restoreLastActiveNote() {
        guard let idString = UserDefaults.standard.string(forKey: Self.lastActiveNoteKey),
              let noteId = UUID(uuidString: idString) else { return }

        // Small delay to ensure windows are fully loaded
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.windowManager.bringToFront(noteId)
        }
    }

    /// Flush JS editor content and cursor position, then save — called on app termination
    func saveAllNotesImmediately() {
        // Flush the single shared WKWebView's current state
        SharedWebViewManager.shared.flushCurrentNoteState()

        // Write pending bodies and the index. Empty notes are kept: they are
        // real files the user may want to fill in later.
        noteManager.saveAll()
    }

    // MARK: - Private Methods

    private func setupBindings() {
        noteManager.$notes
            .sink { [weak self] notes in
                self?.syncWindowsWithNotes(notes)
            }
            .store(in: &cancellables)
    }

    /// Open windows for all persisted notes
    private func openInitialWindows() {
        for note in noteManager.notes {
            windowManager.openWindow(for: note, coordinator: self)
        }
    }

    /// Markdown files dropped into the notes folder while the app was closed
    /// open as stickies on launch.
    private func importNotesFromNotesFolder() {
        noteManager.importNotesFromFolder { index in
            calculateNewNotePosition(additionalOffset: index)
        }
    }

    /// Calculate position for a new note: mouse cursor's screen, cascade from center
    private func calculateNewNotePosition(additionalOffset: Int = 0) -> CGPoint {
        let noteSize = CGSize(width: 300, height: 360)

        let mouseLocation = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouseLocation) }
            ?? NSScreen.main ?? NSScreen.screens[0]
        let visibleFrame = screen.visibleFrame

        let existingFrames: [NSRect] = windowManager.getAllWindowIds().compactMap {
            windowManager.getWindowController(for: $0)?.window?.frame
        }
        let count = existingFrames.filter { visibleFrame.intersects($0) }.count
            + additionalOffset

        let step: CGFloat = 30
        let x = visibleFrame.midX - noteSize.width / 2 + CGFloat(count) * step
        let y = visibleFrame.midY - noteSize.height / 2 - CGFloat(count) * step

        return CGPoint(
            x: min(max(x, visibleFrame.minX), visibleFrame.maxX - noteSize.width),
            y: min(max(y, visibleFrame.minY), visibleFrame.maxY - noteSize.height)
        )
    }

    private func syncWindowsWithNotes(_ notes: [Note]) {
        let noteIds = Set(notes.map { $0.id })
        let windowIds = Set(windowManager.getAllWindowIds())

        let windowsToClose = windowIds.subtracting(noteIds)
        for windowId in windowsToClose {
            windowManager.closeWindow(for: windowId)
        }
    }
}
