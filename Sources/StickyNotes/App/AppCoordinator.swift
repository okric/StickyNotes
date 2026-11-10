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

    /// True while a Notes inbox fetch/import is in flight; disables the menu item.
    @Published private(set) var isFetchingInbox = false

    // MARK: - Private Properties

    private let store: NotesStore
    private var cancellables = Set<AnyCancellable>()

    /// Polls open remote notes for newer revisions.
    private var remotePollTimer: Timer?
    private var isPollingRemote = false

    /// Pending debounced PATCHes for remote notes.
    private var remoteSaveTimers: [UUID: Timer] = [:]
    private let remoteSaveDelay: TimeInterval = 0.8

    /// Watches the notes folder for files added, edited or deleted outside the app.
    private var folderMonitor: NotesFolderMonitor?

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
        syncNotesFolder()
        openInitialWindows()
        startFolderMonitor()
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
        folderMonitor?.stop()
    }

    // MARK: - Public Methods

    /// Create a new note on its own window. Cmd+N is a placed note; files that
    /// appear in the notes folder from outside still join the stack.
    func createNewNote() {
        guard let note = noteManager.createNote(position: calculateNewNotePosition()) else {
            NSSound.beep()
            return
        }
        windowManager.openWindow(for: note, coordinator: self)
        windowManager.bringToFront(note.id)
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
        noteManager.deleteNote(noteId, trashingFile: true)
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
        if note.isStacked {
            syncStackWindow()
            windowManager.stackWindowController?.refreshFromModel()
            windowManager.bringToFront(note.id)
        } else {
            windowManager.openWindow(for: note, coordinator: self)
            windowManager.bringToFront(note.id)
        }
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
                    .applyExternalUpdate(content: remote.body)
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
                .applyExternalUpdate(content: remote.body)
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
                .applyExternalUpdate(content: remote.body)
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

    // MARK: - Notes inbox

    /// Pull every note from the Notes API into the notes folder and the default
    /// stack, then delete the server copies (File > Fetch Notes Inbox).
    func fetchNotesInbox() {
        guard !isFetchingInbox else { return }
        guard let folder = settings.defaultFolderURL else {
            presentInboxError("Choose a notes folder in Settings first.")
            return
        }

        let baseString = RemoteCredentials.normalize(settings.notesServerURLString)
        guard let base = URL(string: baseString), base.scheme != nil, base.host != nil else {
            presentInboxError("Set a Notes server URL in Settings.")
            return
        }
        guard let token = RemoteCredentials.token(for: baseString) else {
            presentInboxError("No token stored for \(baseString). Add one in Settings.")
            return
        }

        isFetchingInbox = true
        RemoteNotesClient.shared.listNotes(baseURL: base, token: token) { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error):
                self.isFetchingInbox = false
                self.presentInboxError(error.localizedDescription)

            case .success(let remoteNotes):
                let stackPosition = self.noteManager.stack?.position
                    ?? self.calculateNewNotePosition()
                NotesInboxImporter.run(
                    remoteNotes: remoteNotes,
                    baseURL: baseString,
                    token: token,
                    folder: folder,
                    stackPosition: stackPosition,
                    noteManager: self.noteManager,
                    store: self.store
                ) { [weak self] outcome in
                    guard let self else { return }
                    self.isFetchingInbox = false
                    if outcome.imported > 0 {
                        self.syncStackWindow()
                        self.windowManager.stackWindowController?.refreshFromModel()
                        self.windowManager.stackWindowController?.window?
                            .makeKeyAndOrderFront(nil)
                    }
                    self.presentInboxOutcome(outcome)
                }
            }
        }
    }

    private func presentInboxOutcome(_ outcome: NotesInboxImporter.Outcome) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Fetch Notes Inbox"
        var text = "Imported \(outcome.imported) notes, deleted \(outcome.deleted), "
            + "kept \(outcome.kept) on the server."
        if outcome.kept > 0 {
            text += "\n\nA note kept on the server already has a local copy; "
                + "the next fetch skips it instead of duplicating it."
        }
        alert.informativeText = text
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    private func presentInboxError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Could not fetch the notes inbox"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    /// Handle note content changes from the editor
    func handleContentChange(noteId: UUID, content: String) {
        // The editor echoes content pushed in from the API or the file system;
        // it is not a user edit, so nothing needs saving.
        guard noteManager.getNote(noteId)?.content != content else { return }

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

    /// Reopen windows for all existing notes (the stack is one window)
    func showAllNotes() {
        syncStackWindow()
        for note in noteManager.notes where !note.isStacked {
            windowManager.openWindow(for: note, coordinator: self)
        }
    }

    /// Change appearance. Member notes take it from the stack, not themselves.
    func changeNoteColor(noteId: UUID, colorTheme: String) {
        if noteManager.getNote(noteId)?.isStacked == true {
            noteManager.updateStackAppearance(colorTheme: colorTheme)
            windowManager.stackWindowController?.applyColorTheme(colorTheme)
            return
        }
        noteManager.updateNoteColor(noteId, colorTheme: colorTheme)
        windowManager.getWindowController(for: noteId)?.setColorTheme(colorTheme)
    }

    func setNoteOpacity(noteId: UUID, opacity: Double) {
        if noteManager.getNote(noteId)?.isStacked == true {
            noteManager.updateStackAppearance(opacity: opacity)
            windowManager.stackWindowController?.applyOpacity(opacity)
            return
        }
        noteManager.updateNoteWindow(noteId, opacity: opacity)
        windowManager.getWindowController(for: noteId)?.setOpacity(opacity)
    }

    func setNoteAlwaysOnTop(noteId: UUID, alwaysOnTop: Bool) {
        if noteManager.getNote(noteId)?.isStacked == true {
            noteManager.updateStackAppearance(alwaysOnTop: alwaysOnTop)
            windowManager.stackWindowController?.applyAlwaysOnTopSetting(alwaysOnTop)
            return
        }
        noteManager.updateNoteAlwaysOnTop(noteId, alwaysOnTop: alwaysOnTop)
        windowManager.getWindowController(for: noteId)?.setAlwaysOnTop(alwaysOnTop)
    }

    /// The window (note or stack) that owns the shared WebView for a note.
    func webViewHost(for noteId: UUID) -> WebViewHost? {
        if let controller = windowManager.getWindowController(for: noteId) {
            return controller
        }
        if let stack = windowManager.stackWindowController, stack.contains(noteId) {
            return stack
        }
        return nil
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

    // MARK: - Rename

    /// Ask for a new file name and rename the Markdown file. The title is the
    /// file name, so the note window and stack update from the same value.
    func promptRenameNote(noteId: UUID) {
        guard let note = noteManager.getNote(noteId) else { return }
        if note.isRemote {
            let alert = NSAlert()
            alert.messageText = "Remote note"
            alert.informativeText = "Remote notes are renamed on the Notes server, not on disk."
            alert.addButton(withTitle: "OK")
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
            return
        }

        let alert = NSAlert()
        alert.messageText = "Rename Note"
        alert.informativeText = "The Markdown file will be renamed. Its contents do not change."
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 360, height: 24))
        field.stringValue = note.title
        field.placeholderString = "File name"
        alert.accessoryView = field
        alert.window.initialFirstResponder = field

        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        do {
            let updated = try noteManager.renameNote(noteId, to: field.stringValue)
            windowManager.getWindowController(for: noteId)?.refreshTitle()
            windowManager.stackWindowController?.refreshFromModel()
            print("[AppCoordinator] Note renamed: \(updated.title)")
        } catch {
            let failure = NSAlert()
            failure.messageText = "Could not rename the note"
            failure.informativeText = error.localizedDescription
            failure.alertStyle = .warning
            failure.addButton(withTitle: "OK")
            failure.runModal()
        }
    }

    // MARK: - Stack

    /// Take a note out of the stack (⌥-drag) and give it its own window at the
    /// drop point. The Markdown file is untouched; only stack membership and
    /// window placement change.
    func pullOutFrontNote(noteId: UUID, to position: CGPoint, size: CGSize) {
        guard let note = noteManager.getNote(noteId), note.isStacked else { return }
        guard noteManager.pullOutNote(noteId, to: position) != nil else { return }
        noteManager.updateNoteWindow(noteId, size: size)

        syncStackWindow()
        guard let updated = noteManager.getNote(noteId),
              let controller = windowManager.openWindow(for: updated, coordinator: self) else {
            return
        }
        controller.window?.makeKeyAndOrderFront(nil)
    }

    /// Put a placed note into the stack (drag onto the stack, or the File menu).
    /// The note's window closes without trashing the file.
    func moveNoteToStack(noteId: UUID) {
        guard let note = noteManager.getNote(noteId), !note.isStacked else {
            NSSound.beep()
            return
        }

        let controller = windowManager.getWindowController(for: noteId)
        if controller?.hasWebView == true {
            // Capture the last keystrokes before the note window goes away.
            SharedWebViewManager.shared.flushCurrentNoteState()
        }

        guard noteManager.stackNote(noteId) != nil else { return }

        if controller != nil {
            windowManager.discardWindow(for: noteId)
        }
        syncStackWindow()
        windowManager.stackWindowController?.refreshFromModel()
        windowManager.stackWindowController?.window?.makeKeyAndOrderFront(nil)
    }

    /// Keep one stack window alive for as long as the default stack has notes.
    private func syncStackWindow() {
        guard let stack = noteManager.stack, !noteManager.stackedNotes.isEmpty else {
            if windowManager.stackWindowController != nil {
                // Deferred: this can be reached in the middle of a note mutation
                // (or a tear-out drag) and closing the window synchronously would
                // yank the WebView out from under the caller.
                DispatchQueue.main.async { [weak self] in
                    self?.windowManager.closeStackWindow()
                }
            }
            return
        }
        windowManager.openStackWindow(stack: stack, coordinator: self)
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
                guard let self else { return }
                self.syncWindowsWithNotes(notes)
                // @Published sends in willSet, so `noteManager.notes` still
                // holds the previous array here. Read it on the next turn.
                DispatchQueue.main.async { [weak self] in
                    self?.windowManager.stackWindowController?.refreshFromModel()
                }
            }
            .store(in: &cancellables)

        settings.$defaultFolderPath
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.syncNotesFolder()
                self?.startFolderMonitor()
            }
            .store(in: &cancellables)

        settings.$noteFontFamily
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.applyFontPreferences()
            }
            .store(in: &cancellables)

        settings.$titleFontFamily
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.applyFontPreferences()
            }
            .store(in: &cancellables)
    }

    private func applyFontPreferences() {
        SharedWebViewManager.shared.applyNoteFont(settings.noteFontFamily)
        windowManager.refreshFonts()
    }

    /// Open windows for all persisted notes. Stacked notes share one window.
    private func openInitialWindows() {
        syncStackWindow()
        for note in noteManager.notes where !note.isStacked {
            windowManager.openWindow(for: note, coordinator: self)
        }
    }

    /// Watch the notes folder for changes made outside the app.
    private func startFolderMonitor() {
        folderMonitor?.stop()
        folderMonitor = nil

        guard let folder = settings.defaultFolderURL else { return }
        let monitor = NotesFolderMonitor(folder: folder) { [weak self] in
            self?.syncNotesFolder()
        }
        folderMonitor = monitor
        monitor.start()
    }

    /// Reconcile open notes with the notes folder: register files dropped in,
    /// close notes whose file was deleted, and reload externally edited bodies.
    private func syncNotesFolder() {
        let result = noteManager.syncWithFolder { index in
            calculateNewNotePosition(additionalOffset: index)
        }

        // Removed notes disappear through syncWindowsWithNotes; here we only
        // need to refresh what is on screen.
        if !result.added.isEmpty {
            syncStackWindow()
            windowManager.stackWindowController?.refreshFromModel()
        }
        for note in result.changed {
            if let controller = windowManager.getWindowController(for: note.id) {
                controller.applyExternalUpdate(content: note.content)
            } else if windowManager.stackWindowController?.frontNoteId == note.id {
                windowManager.stackWindowController?.applyExternalUpdate(content: note.content)
            }
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
