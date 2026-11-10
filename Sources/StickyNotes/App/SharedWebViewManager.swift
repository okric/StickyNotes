import AppKit
import WebKit

/// Singleton that owns the single WKWebView shared across all note windows.
/// Active window gets the live WKWebView; inactive windows show snapshots.
class SharedWebViewManager {
    static let shared = SharedWebViewManager()

    // MARK: - Properties

    /// The single shared WKWebView
    let webView: WKWebView

    /// The bridge handling JS→Swift messages
    let bridge: SharedEditorBridge

    /// Currently active note ID (the note being edited)
    private(set) var activeNoteId: UUID?

    /// Window currently holding the WebView. Tracked explicitly: the same note
    /// can briefly have both a note window and the stack window registered.
    private(set) weak var activeHost: WebViewHost?

    /// Cached serialized EditorState per note (JSON string from serializeState)
    private var stateCache: [UUID: String] = [:]

    /// Whether the editor JS has finished loading
    private(set) var isReady = false

    /// Superview the WebView had when the current pre-render pass started.
    /// If a window attaches mid-pass, `superview` changes and the pass stops.
    private weak var preRenderSuperview: NSView?

    /// Coordinator reference for bridge callbacks
    weak var coordinator: AppCoordinator?

    // MARK: - Initialization

    private init() {
        let configuration = WKWebViewConfiguration()

        let userContentController = WKUserContentController()
        configuration.userContentController = userContentController

        // Inject console.log interceptor
        let consoleScript = WKUserScript(
            source: """
            (function() {
                var originalLog = console.log;
                console.log = function() {
                    var message = Array.prototype.slice.call(arguments).join(' ');
                    window.webkit.messageHandlers.bridge.postMessage({
                        action: 'log',
                        message: message
                    });
                    originalLog.apply(console, arguments);
                };
                var originalError = console.error;
                console.error = function() {
                    var message = Array.prototype.slice.call(arguments).join(' ');
                    window.webkit.messageHandlers.bridge.postMessage({
                        action: 'error',
                        message: 'ERROR: ' + message
                    });
                    originalError.apply(console, arguments);
                };
            })();
            """,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        )
        userContentController.addUserScript(consoleScript)

        // Create bridge and register
        let bridge = SharedEditorBridge()
        userContentController.add(bridge, name: "bridge")
        self.bridge = bridge

        // Create the single WKWebView
        let wv = WKWebView(frame: .zero, configuration: configuration)
        wv.setValue(false, forKey: "drawsBackground")
        self.webView = wv

        // Load the editor HTML
        loadEditor()
    }

    // MARK: - Editor Loading

    private func loadEditor() {
        let bundleURL = Bundle.main.bundleURL
        let htmlURL = bundleURL.appendingPathComponent("Contents/Resources/Editor/index.html")

        guard FileManager.default.fileExists(atPath: htmlURL.path) else {
            print("[SharedWebViewManager] Error: Could not find index.html at \(htmlURL.path)")
            return
        }

        let resourcesDir = bundleURL.appendingPathComponent("Contents/Resources")
        webView.loadFileURL(htmlURL, allowingReadAccessTo: resourcesDir)
        print("[SharedWebViewManager] Loading editor from: \(htmlURL.path)")
    }

    // MARK: - Note Switching

    /// Called by the bridge when JS editor signals "ready".
    /// Pre-renders all inactive notes (WebView is still alpha=0) then loads the active note.
    func markReady() {
        isReady = true
        print("[SharedWebViewManager] Editor is ready")
        applyNoteFont(coordinator?.settings.noteFontFamily)

        // Pre-render inactive notes while WebView is still hidden (alpha=0)
        preRenderInactiveNotes { [weak self] in
            guard let self = self else { return }

            // Load the active note
            if let noteId = self.activeNoteId,
               let note = self.coordinator?.noteManager.getNote(noteId) {
                self.loadNoteContent(noteId, note: note)
                self.setReadOnly(RemoteWriteAccess.isReadOnly(note))
            }

            // Reveal WebView in the active window
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                guard let self = self else { return }
                let host = self.activeHost
                    ?? self.activeNoteId.flatMap { self.coordinator?.webViewHost(for: $0) }
                host?.revealWebView()
            }
        }
    }

    // MARK: - Pre-rendering

    /// Render each inactive note in the hidden WebView, take a snapshot, and show it on its window.
    private func preRenderInactiveNotes(completion: @escaping () -> Void) {
        guard let coordinator = coordinator else {
            completion()
            return
        }

        preRenderSuperview = webView.superview

        let otherNotes = coordinator.noteManager.notes
            .filter { $0.id != activeNoteId }
            .filter { !$0.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            // Stacked notes other than the front sheet have no window to show
            // a snapshot in; don't render them into nowhere.
            .filter { coordinator.webViewHost(for: $0.id) != nil }

        guard !otherNotes.isEmpty else {
            completion()
            return
        }

        preRenderNext(notes: otherNotes, index: 0, completion: completion)
    }

    /// Recursively pre-render one note at a time: setContent → wait → snapshot → next.
    private func preRenderNext(notes: [Note], index: Int, completion: @escaping () -> Void) {
        guard index < notes.count else {
            completion()
            return
        }

        // A window attached the WebView while we were rendering previews. Stop:
        // pre-rendering must only touch the editor it started with.
        guard webView.superview === preRenderSuperview else {
            completion()
            return
        }

        let note = notes[index]
        let targetController = coordinator?.webViewHost(for: note.id)

        // The shared WebView is sitting in the active window. Render this note
        // at the size of the window that will display the snapshot, otherwise
        // the image is aspect-scaled into a smaller window and its text shrinks.
        let activeSize = webView.superview?.bounds.size ?? webView.frame.size
        let targetSize = targetController?.contentSize ?? activeSize
        if targetSize != webView.frame.size {
            webView.frame.size = targetSize
            webView.needsLayout = true
            webView.layoutSubtreeIfNeeded()
        }

        // Set content + enter snapshot mode in one JS call (single transaction, single DOM update).
        // suppressContentChange in JS prevents the contentChanged debounce from firing
        // and corrupting the active note's content in NoteManager.
        webView.callAsyncJavaScript(
            """
            window.setContentForSnapshot(content);
            await new Promise(r => requestAnimationFrame(() => requestAnimationFrame(r)));
            """,
            arguments: ["content": note.content],
            in: nil,
            in: .page
        ) { [weak self] _ in
            guard let self = self else { return }

            // Double-rAF completed — compositor has painted, safe to snapshot
            self.webView.takeSnapshot(with: WKSnapshotConfiguration()) { [weak self] image, _ in
                guard let self = self else { return }

                self.webView.evaluateJavaScript("window.endSnapshotMode()")

                // If the WebView was reparented while this render was in
                // flight, leave its frame/content alone and stop.
                let moved = self.webView.superview !== self.preRenderSuperview
                if moved {
                    completion()
                    return
                }

                if let image = image, targetController?.hasWebView != true {
                    targetController?.showSnapshot(image)
                }

                // Back to the active window's size for the next note / reveal.
                if self.webView.frame.size != activeSize {
                    self.webView.frame.size = activeSize
                    self.webView.needsLayout = true
                }

                // Continue to next note
                self.preRenderNext(notes: notes, index: index + 1, completion: completion)
            }
        }
    }

    /// Apply the Settings font family to the editor body.
    func applyNoteFont(_ family: String?) {
        webView.callAsyncJavaScript(
            "window.setNoteFont(fontFamily)",
            arguments: ["fontFamily": NoteFont.bodyCSS(family: family)],
            in: nil,
            in: .page,
            completionHandler: nil
        )
    }

    /// Toggle editing in the editor (remote notes are read-only for now).
    func setReadOnly(_ readOnly: Bool) {
        webView.callAsyncJavaScript(
            "window.setReadOnly(readOnly)",
            arguments: ["readOnly": readOnly],
            in: nil,
            in: .page,
            completionHandler: nil
        )
    }

    /// Serialize the active note and leave a snapshot/preview in the window the
    /// WebView is about to leave. Call before reparenting the WebView.
    ///
    /// Runs synchronously (RunLoop-spins) because the WebView must still be in
    /// the old window when `takeSnapshot` runs.
    func snapshotActiveHostBeforeMove() {
        guard let oldId = activeNoteId,
              let oldHost = activeHost,
              oldHost.hasWebView else { return }

        oldHost.hasWebView = false

        guard isReady else {
            // Editor has not rendered yet; don't serialize an empty state.
            oldHost.showTextPreview()
            return
        }

        // A. Serialize state first (preserves cursor/scroll before reset).
        var serializedState: String?
        var serializeDone = false
        webView.evaluateJavaScript("window.serializeState()") { result, _ in
            serializedState = result as? String
            serializeDone = true
        }
        let serializeDeadline = Date().addingTimeInterval(0.1)
        while !serializeDone && Date() < serializeDeadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
        if let json = serializedState {
            cacheSerializedState(json, for: oldId)
        }

        // B. Collapse cursor unfolds, disable transitions, and blur.
        var prepareDone = false
        webView.evaluateJavaScript("window.prepareForSnapshot()") { _, _ in
            prepareDone = true
        }
        let prepareDeadline = Date().addingTimeInterval(0.1)
        while !prepareDone && Date() < prepareDeadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }

        // C. Wait for one paint cycle (transitions are off).
        let renderDeadline = Date().addingTimeInterval(0.05)
        while Date() < renderDeadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }

        // D. Snapshot while the WebView is still in the old window.
        var snapshot: NSImage?
        var done = false
        webView.takeSnapshot(with: WKSnapshotConfiguration()) { image, _ in
            snapshot = image
            done = true
        }
        let deadline = Date().addingTimeInterval(0.1)
        while !done && Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }

        // E. Re-enable transitions.
        webView.evaluateJavaScript("window.endSnapshotMode()")

        if let image = snapshot {
            oldHost.showSnapshot(image)
        } else {
            oldHost.showTextPreview()
        }
    }

    /// Switch the editor to a different note.
    /// Serializes current note state, then loads the target note.
    func switchToNote(_ noteId: UUID, note: Note) {
        guard isReady else {
            // Editor not ready yet — markReady() will call loadNoteContent
            activeNoteId = noteId
            return
        }

        // If already showing this note, nothing to do
        if activeNoteId == noteId { return }

        // 1. Serialize current note state (if any).
        //    JS evaluations are queued in order, so serializeState() executes
        //    BEFORE setContent/restoreState below, capturing the OLD content.
        if let currentId = activeNoteId {
            webView.evaluateJavaScript("window.serializeState()") { [weak self] result, _ in
                guard let self = self, let json = result as? String else { return }
                self.cacheSerializedState(json, for: currentId)
            }
        }

        // 2. Set the new note ID and load content
        activeNoteId = noteId
        loadNoteContent(noteId, note: note)
        setReadOnly(RemoteWriteAccess.isReadOnly(note))
    }

    /// Load note content into the editor (shared by switchToNote and markReady)
    private func loadNoteContent(_ noteId: UUID, note: Note) {
        // Set noteId in JS
        let idString = noteId.uuidString
        webView.evaluateJavaScript("window.setCurrentNoteId('\(idString)')")

        // Restore cached state or load fresh content
        if let cached = stateCache[noteId] {
            // Use callAsyncJavaScript to pass JSON directly — avoids fragile string escaping
            webView.callAsyncJavaScript(
                "window.restoreState(state)",
                arguments: ["state": cached],
                in: nil,
                in: .page,
                completionHandler: nil
            )
        } else {
            // First time — load from Note model via callAsyncJavaScript
            webView.callAsyncJavaScript(
                "window.setContent(content)",
                arguments: ["content": note.content],
                in: nil,
                in: .page,
                completionHandler: nil
            )

            // Restore cursor position
            if note.cursorPosition > 0 {
                webView.evaluateJavaScript("window.setCursorPosition(\(note.cursorPosition))")
            }

            // Restore scroll position
            if note.scrollTop > 0 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                    self?.webView.evaluateJavaScript("window.setScrollTop(\(note.scrollTop))")
                }
            }
        }

        // Initialize note controls (titlebar mask color).
        // Values are passed as arguments so nothing is interpolated into script source.
        webView.callAsyncJavaScript(
            "window.initNoteControls(colorTheme, opacity, alwaysOnTop)",
            arguments: [
                "colorTheme": note.colorTheme,
                "opacity": note.opacity,
                "alwaysOnTop": note.alwaysOnTop
            ],
            in: nil,
            in: .page,
            completionHandler: nil
        )
        applyNoteFont(coordinator?.settings.noteFontFamily)

        print("[SharedWebViewManager] Loaded note: \(noteId)")
    }

    /// Cache a serialized editor state for a note (called from attachWebView before cursor reset).
    /// Extracts doc, cursor position, and scroll top to persist in NoteManager.
    func cacheSerializedState(_ json: String, for noteId: UUID) {
        stateCache[noteId] = json
        if let data = json.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let doc = obj["doc"] as? String {
                coordinator?.handleContentChange(noteId: noteId, content: doc)
            }
            if let anchor = obj["anchor"] as? Int {
                coordinator?.noteManager.updateNoteCursorPosition(noteId, cursorPosition: anchor)
            }
            if let scrollTop = obj["scrollTop"] as? Double {
                coordinator?.noteManager.updateNoteScrollTop(noteId, scrollTop: scrollTop)
            }
        }
    }

    /// Switch to a note without re-serializing the old note (state was already cached externally).
    func switchToNoteSkippingSerialization(_ noteId: UUID, note: Note) {
        guard isReady else {
            activeNoteId = noteId
            return
        }
        activeNoteId = noteId
        loadNoteContent(noteId, note: note)
        setReadOnly(RemoteWriteAccess.isReadOnly(note))
    }

    /// Flush current note's content/cursor/scroll to NoteManager (for app termination)
    func flushCurrentNoteState() {
        guard let currentId = activeNoteId else { return }

        var pending = 3

        webView.evaluateJavaScript("window.getContent()") { [weak self] result, _ in
            if let content = result as? String {
                self?.coordinator?.noteManager.updateNoteContent(currentId, content: content)
            }
            pending -= 1
        }

        webView.evaluateJavaScript("window.getCursorPosition()") { [weak self] result, _ in
            if let position = result as? Int {
                self?.coordinator?.noteManager.updateNoteCursorPosition(currentId, cursorPosition: position)
            }
            pending -= 1
        }

        webView.evaluateJavaScript("window.getScrollTop()") { [weak self] result, _ in
            if let scrollTop = result as? Double {
                self?.coordinator?.noteManager.updateNoteScrollTop(currentId, scrollTop: scrollTop)
            }
            pending -= 1
        }

        // Spin RunLoop to let async JS callbacks complete (max 0.5s)
        let deadline = Date().addingTimeInterval(0.5)
        while pending > 0 && Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
    }

    /// Record the window that just took ownership of the WebView.
    func setActiveHost(_ host: WebViewHost) {
        activeHost = host
    }

    /// The host is going away; stop treating it as the owner.
    func hostWillClose(_ host: WebViewHost) {
        if activeHost === host {
            activeHost = nil
        }
    }

    /// Drop cached state for a note so the next switch reads its current body.
    func invalidateCachedState(for noteId: UUID) {
        stateCache.removeValue(forKey: noteId)
    }

    /// Remove cached state for a deleted note
    func removeCachedState(for noteId: UUID) {
        stateCache.removeValue(forKey: noteId)
        if activeNoteId == noteId {
            activeNoteId = nil
        }
    }

}
