import Foundation
import WebKit

/// Bridge between Swift and the shared JavaScript editor.
/// Routes messages by noteId to the appropriate handler.
class SharedEditorBridge: NSObject, WKScriptMessageHandler {

    /// Schemes that note links are allowed to open. Anything else (file://, smb://,
    /// custom app schemes, ...) is dropped so a note cannot launch arbitrary handlers.
    private static let allowedSchemes: Set<String> = ["http", "https", "mailto"]

    // MARK: - WKScriptMessageHandler

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard let body = message.body as? [String: Any],
              let action = body["action"] as? String else {
            print("[SharedEditorBridge] Invalid message format")
            return
        }

        handleAction(action, body: body)
    }

    // MARK: - Action Handling

    private func handleAction(_ action: String, body: [String: Any]) {
        let manager = SharedWebViewManager.shared

        switch action {
        case "ready":
            // markReady() handles loading any queued note internally
            manager.markReady()

        case "contentChanged":
            // Route to the correct note via noteId
            guard let content = body["content"] as? String else { return }
            let noteId: UUID
            if let idString = body["noteId"] as? String, let id = UUID(uuidString: idString) {
                noteId = id
            } else if let activeId = manager.activeNoteId {
                noteId = activeId
            } else {
                return
            }
            manager.coordinator?.handleContentChange(noteId: noteId, content: content)

        case "requestSave":
            if let noteId = manager.activeNoteId,
               let note = manager.coordinator?.noteManager.getNote(noteId) {
                manager.coordinator?.noteManager.saveNoteImmediately(note)
            }

        case "openURL":
            guard let urlString = body["url"] as? String,
                  let url = URL(string: urlString),
                  let scheme = url.scheme?.lowercased(),
                  Self.allowedSchemes.contains(scheme) else {
                print("[SharedEditorBridge] Blocked URL with disallowed scheme")
                return
            }
            NSWorkspace.shared.open(url)

        case "log":
            if let msg = body["message"] as? String {
                print("[SharedEditorBridge][JS] \(msg)")
            }

        case "error":
            if let msg = body["message"] as? String {
                print("[SharedEditorBridge][JS Error] \(msg)")
            }

        default:
            print("[SharedEditorBridge] Unknown action: \(action)")
        }
    }
}
