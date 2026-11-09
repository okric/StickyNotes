import AppKit
import SwiftUI
import Combine

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
        openInitialWindows()
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
    /// Otherwise, remove the note from the index. Its Markdown file stays on disk.
    func closeNoteWindow(_ noteId: UUID) {
        windowManager.removeWindow(for: noteId)
        SharedWebViewManager.shared.removeCachedState(for: noteId)

        if isQuitting {
            return
        }
        // User explicitly closed — drop it from the index, keep the file
        noteManager.deleteNote(noteId)
    }

    /// Open Markdown files handed over by Launch Services (Finder "Open With",
    /// drag onto the Dock icon, `open -a StickyNotes note.md`). Each file gets a
    /// note; a file that already has a live note just brings its window forward.
    /// - Returns: `true` if at least one file produced a note.
    @discardableResult
    func openFiles(_ urls: [URL]) -> Bool {
        var opened = false
        for url in urls where NoteManager.isMarkdownFile(url) {
            if openFile(url) != nil { opened = true }
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

    /// Handle note content changes from the editor
    func handleContentChange(noteId: UUID, content: String) {
        noteManager.updateNoteContent(noteId, content: content)
    }

    /// Handle window state changes
    func handleWindowStateChange(
        noteId: UUID,
        position: CGPoint? = nil,
        size: CGSize? = nil,
        isMinimized: Bool? = nil
    ) {
        noteManager.updateNoteWindow(
            noteId,
            position: position,
            size: size,
            isMinimized: isMinimized
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

    /// Calculate position for a new note: mouse cursor's screen, cascade from center
    private func calculateNewNotePosition() -> CGPoint {
        let noteSize = CGSize(width: 300, height: 360)

        let mouseLocation = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouseLocation) }
            ?? NSScreen.main ?? NSScreen.screens[0]
        let visibleFrame = screen.visibleFrame

        let existingFrames: [NSRect] = windowManager.getAllWindowIds().compactMap {
            windowManager.getWindowController(for: $0)?.window?.frame
        }
        let count = existingFrames.filter { visibleFrame.intersects($0) }.count

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
