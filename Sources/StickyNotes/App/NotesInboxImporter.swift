import Foundation
import CoreGraphics

/// Pulls every note from the Notes API into the notes folder (File > Fetch
/// Notes Inbox), joins the default stack, then deletes the server copies.
///
/// The local side is finished before any DELETE goes out: files are written,
/// the notes are added to the index, and only then are the server notes
/// removed. A failed delete keeps both copies; the local note carries the
/// origin id so the next pass skips it instead of duplicating it.
///
/// Everything here runs on the main queue (the client marshals its completions
/// there). Writing and registering a note therefore finishes inside one turn
/// of the run loop, before `NotesFolderMonitor` can see the new file and
/// register it a second time.
enum NotesInboxImporter {

    struct Outcome {
        var imported = 0
        var deleted = 0
        var kept = 0
    }

    /// - Parameters:
    ///   - remoteNotes: server notes in `position` order.
    ///   - baseURL: normalized server origin, recorded on each local note.
    ///   - folder: notes folder that receives the Markdown files.
    ///   - stackPosition: where a new stack appears; ignored when one exists.
    static func run(
        remoteNotes: [RemoteNote],
        baseURL: String,
        token: String,
        folder: URL,
        stackPosition: CGPoint,
        noteManager: NoteManager,
        store: NotesStore,
        completion: @escaping (Outcome) -> Void
    ) {
        var created: [Note] = []
        var pendingDeletes: [RemoteNote] = []

        for remote in remoteNotes {
            let alreadyImported = noteManager.notes.contains {
                $0.originNoteID == remote.id && $0.originBaseURL == baseURL
            }
            guard !alreadyImported else { continue }

            do {
                let url = try store.createNoteFile(
                    in: folder,
                    baseTitle: NotesStore.sanitizeFileName(remote.title),
                    content: remote.body
                )
                let createdDate = remote.createdDate ?? Date()
                let modifiedDate = remote.updatedDate ?? createdDate
                var note = Note(
                    path: url.path,
                    title: url.deletingPathExtension().lastPathComponent,
                    stackID: NoteStack.defaultID,
                    content: remote.body,
                    position: stackPosition,
                    colorTheme: noteManager.newNoteColorTheme,
                    createdAt: createdDate,
                    modifiedAt: modifiedDate
                )
                note.originNoteID = remote.id
                note.originBaseURL = baseURL
                created.append(note)
                pendingDeletes.append(remote)
            } catch {
                print("[NotesInbox] Could not write \(remote.title).md: \(error.localizedDescription)")
            }
        }

        guard !created.isEmpty else {
            completion(Outcome())
            return
        }

        // Newest import goes on top of the stack.
        let newest = created.max { $0.createdAt < $1.createdAt } ?? created[0]
        noteManager.addImportedNotes(created, at: stackPosition, frontNoteID: newest.id)

        // Index is durable now; server copies may go.
        deleteNext(
            pendingDeletes,
            at: 0,
            baseURL: baseURL,
            token: token,
            outcome: Outcome(imported: created.count),
            completion: completion
        )
    }

    private static func deleteNext(
        _ notes: [RemoteNote],
        at index: Int,
        baseURL: String,
        token: String,
        outcome: Outcome,
        completion: @escaping (Outcome) -> Void
    ) {
        guard index < notes.count else {
            completion(outcome)
            return
        }
        guard let base = URL(string: baseURL) else {
            var outcome = outcome
            outcome.kept += notes.count - index
            completion(outcome)
            return
        }

        let note = notes[index]
        RemoteNotesClient.shared.deleteNote(
            baseURL: base,
            noteID: note.id,
            revision: note.revision,
            token: token
        ) { result in
            var next = outcome
            switch result {
            case .success:
                next.deleted += 1
            case .failure(let error):
                next.kept += 1
                print("[NotesInbox] Kept \(note.id) on the server: \(error.localizedDescription)")
            }
            deleteNext(
                notes,
                at: index + 1,
                baseURL: baseURL,
                token: token,
                outcome: next,
                completion: completion
            )
        }
    }
}
