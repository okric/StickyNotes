import Foundation
import AppKit

/// Manages all note windows
class WindowManager: ObservableObject {
    // MARK: - Private Properties

    /// Dictionary mapping note IDs to their window controllers
    private var windowControllers: [UUID: NoteWindowController] = [:]

    /// The single stack window, when the default stack exists.
    private(set) var stackWindowController: StackWindowController?

    // MARK: - Public Methods

    /// Open a window for a note. Stacked notes are shown by the stack window
    /// instead, so this is a no-op for them.
    /// - Parameters:
    ///   - note: The note to display
    ///   - coordinator: The app coordinator
    /// - Returns: The note window controller, if a window was opened.
    @discardableResult
    func openWindow(for note: Note, coordinator: AppCoordinator) -> NoteWindowController? {
        guard !note.isStacked else { return nil }

        // Check if window already exists
        if let existingController = windowControllers[note.id] {
            existingController.showWindow(nil)
            return existingController
        }

        // Create new window controller
        let windowController = NoteWindowController(note: note, coordinator: coordinator)
        windowControllers[note.id] = windowController
        windowController.showWindow(nil)

        print("[WindowManager] Opened window for note: \(note.id)")
        return windowController
    }

    /// Create the stack window, or refresh the existing one. The window keeps
    /// its own frame; `stack.position` is only read when the window is created.
    @discardableResult
    func openStackWindow(stack: NoteStack, coordinator: AppCoordinator) -> StackWindowController? {
        if let existing = stackWindowController {
            existing.updateStack(stack)
            return existing
        }
        guard let controller = StackWindowController(stack: stack, coordinator: coordinator) else {
            return nil
        }
        stackWindowController = controller
        controller.showWindow(nil)
        print("[WindowManager] Opened stack window at \(stack.position)")
        return controller
    }

    /// Close the stack window (no notes are deleted).
    func closeStackWindow() {
        guard let controller = stackWindowController else { return }
        stackWindowController = nil
        controller.isClosingProgrammatically = true
        controller.close()
        print("[WindowManager] Closed stack window")
    }

    /// Called from the stack window's `windowWillClose` (red button).
    func stackWindowWillClose(_ controller: StackWindowController) {
        if stackWindowController === controller {
            stackWindowController = nil
        }
    }

    /// Remove a window controller from tracking (does NOT call close)
    /// - Parameter noteId: ID of the note
    func removeWindow(for noteId: UUID) {
        guard windowControllers.removeValue(forKey: noteId) != nil else {
            return
        }
        print("[WindowManager] Removed window for note: \(noteId)")
    }

    /// Close a note window because the note moved into the stack. Unlike
    /// `closeWindow(for:)` this must not trash the note.
    func discardWindow(for noteId: UUID) {
        guard let windowController = windowControllers.removeValue(forKey: noteId) else {
            return
        }
        windowController.suppressCloseDeletion = true
        windowController.close()
        print("[WindowManager] Discarded window for stacked note: \(noteId)")
    }

    /// Close a window for a note (used by syncWindowsWithNotes only)
    /// - Parameter noteId: ID of the note
    func closeWindow(for noteId: UUID) {
        guard let windowController = windowControllers.removeValue(forKey: noteId) else {
            return
        }
        windowController.close()
        print("[WindowManager] Closed window for note: \(noteId)")
    }

    /// Get window controller for a note
    /// - Parameter noteId: ID of the note
    /// - Returns: The window controller, if it exists
    func getWindowController(for noteId: UUID) -> NoteWindowController? {
        windowControllers[noteId]
    }

    /// Get all note IDs that have their own window. The stack's front note is
    /// included so Cmd+` can reach it.
    func getAllWindowIds() -> Set<UUID> {
        var ids = Set(windowControllers.keys)
        if let front = stackWindowController?.frontNoteId {
            ids.insert(front)
        }
        return ids
    }

    /// Find which note a given NSWindow belongs to
    func noteId(for window: NSWindow) -> UUID? {
        if stackWindowController?.window === window {
            return stackWindowController?.frontNoteId
        }
        return windowControllers.first(where: { $0.value.window === window })?.key
    }

    /// Close all windows
    func closeAllWindows() {
        for (noteId, _) in windowControllers {
            closeWindow(for: noteId)
        }
        closeStackWindow()
    }

    /// Bring window to front
    /// - Parameter noteId: ID of the note
    func bringToFront(_ noteId: UUID) {
        if let windowController = windowControllers[noteId] {
            windowController.window?.makeKeyAndOrderFront(nil)
            return
        }
        if let stack = stackWindowController, stack.contains(noteId) {
            stack.window?.makeKeyAndOrderFront(nil)
        }
    }

    /// Get count of open windows
    var openWindowCount: Int {
        windowControllers.count + (stackWindowController == nil ? 0 : 1)
    }
}

