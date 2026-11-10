import SwiftUI
import AppKit

// MARK: - App Delegate

/// Keeps the app alive when all windows are closed and provides dock menu
class AppDelegate: NSObject, NSApplicationDelegate {
    let coordinator = AppCoordinator()

    /// Files handed over by Launch Services before the app finished launching
    /// (Finder "Open With", drag onto the Dock icon, `open -a StickyNotes file.md`).
    private var pendingOpenURLs: [URL] = []
    private var didFinishLaunching = false

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        coordinator.isQuitting = true
        coordinator.saveLastActiveNote()
        coordinator.saveAllNotesImmediately()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        didFinishLaunching = true
        // Opening a file counts as user intent; don't steal focus back to the
        // last active note afterwards.
        if !drainPendingOpenURLs() {
            coordinator.restoreLastActiveNote()
        }
    }

    /// Launch Services delivers files here, both at launch and for a running app.
    func application(_ application: NSApplication, open urls: [URL]) {
        pendingOpenURLs.append(contentsOf: urls)
        if didFinishLaunching {
            drainPendingOpenURLs()
        }
    }

    @discardableResult
    private func drainPendingOpenURLs() -> Bool {
        guard !pendingOpenURLs.isEmpty else { return false }
        let urls = pendingOpenURLs
        pendingOpenURLs.removeAll()
        let opened = coordinator.openFiles(urls)
        if opened {
            NSApp.activate(ignoringOtherApps: true)
        }
        return opened
    }

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()
        let newNoteItem = NSMenuItem(
            title: "New Note",
            action: #selector(createNewNote),
            keyEquivalent: ""
        )
        newNoteItem.target = self
        menu.addItem(newNoteItem)
        return menu
    }

    @objc func createNewNote() {
        coordinator.createNewNote()
    }
}

// MARK: - App Entry Point

@main
struct StickyNotesApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        MenuBarCommands(coordinator: appDelegate.coordinator)
    }
}

// MARK: - Menu Bar

struct MenuBarCommands: Scene {
    @ObservedObject var coordinator: AppCoordinator

    var body: some Scene {
        Settings {
            SettingsView(settings: coordinator.settings)
        }
        .commands {
            // File menu
            CommandGroup(replacing: .newItem) {
                Button("New Note") {
                    coordinator.createNewNote()
                }
                .keyboardShortcut("n", modifiers: .command)

                Button("Open…") {
                    coordinator.promptOpenFiles()
                }
                .keyboardShortcut("o", modifiers: .command)

                Button("Open Note URL…") {
                    coordinator.promptOpenRemoteURL()
                }
                .keyboardShortcut("o", modifiers: [.command, .shift])

                Divider()

                Button("Show All Notes") {
                    coordinator.showAllNotes()
                }

                Button("Move Note to Stack") {
                    if let noteId = coordinator.focusedNoteId() {
                        coordinator.moveNoteToStack(noteId: noteId)
                    }
                }

                Button("Rename Note…") {
                    if let noteId = coordinator.focusedNoteId() {
                        coordinator.promptRenameNote(noteId: noteId)
                    }
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])

                Button("Show Notes Folder") {
                    coordinator.settings.revealDefaultFolder()
                }
            }

            // Edit menu — Find in note (Cmd+F → shared WKWebView)
            CommandGroup(replacing: .textEditing) {
                Button("Find...") {
                    if coordinator.focusedNoteId() != nil {
                        SharedWebViewManager.shared.webView.evaluateJavaScript("window.openSearch()")
                    }
                }
                .keyboardShortcut("f", modifiers: .command)

                Button("Find and Replace...") {
                    if coordinator.focusedNoteId() != nil {
                        SharedWebViewManager.shared.webView.evaluateJavaScript("window.openSearchWithReplace()")
                    }
                }
                .keyboardShortcut("f", modifiers: [.command, .shift])
            }

            // Window menu — Cmd+` to cycle between note windows
            CommandGroup(before: .windowList) {
                Button("Cycle Through Notes") {
                    coordinator.cycleToNextWindow()
                }
                .keyboardShortcut("`", modifiers: .command)
            }

            // Format menu
            CommandMenu("Format") {
                Menu("Note Color") {
                    ForEach(NoteColor.allCases, id: \.self) { color in
                        Button(color.displayName) {
                            if let noteId = coordinator.focusedNoteId() {
                                coordinator.changeNoteColor(noteId: noteId, colorTheme: color.rawValue)
                            }
                        }
                    }
                }

                Divider()

                Menu("Opacity") {
                    Button("100%") { setOpacity(1.0) }
                    Button("75%") { setOpacity(0.75) }
                    Button("50%") { setOpacity(0.5) }
                    Button("25%") { setOpacity(0.25) }
                }

                Divider()

                Button("Pin on Top") {
                    if let noteId = coordinator.focusedNoteId(),
                       let note = coordinator.noteManager.getNote(noteId) {
                        coordinator.setNoteAlwaysOnTop(noteId: noteId, alwaysOnTop: !note.alwaysOnTop)
                    }
                }
                .keyboardShortcut("p", modifiers: [.command, .shift])
            }
        }
    }

    private func setOpacity(_ opacity: Double) {
        if let noteId = coordinator.focusedNoteId() {
            coordinator.setNoteOpacity(noteId: noteId, opacity: opacity)
        }
    }

    init(coordinator: AppCoordinator) {
        self.coordinator = coordinator
    }
}
