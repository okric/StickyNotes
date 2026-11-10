import Foundation

/// A link to a note on a Notes API instance, as pasted by the user.
struct RemoteNoteLink: Equatable {
    /// API origin, e.g. `https://notes.example.com`
    let baseURL: URL
    /// Public share id from `/n/<shareId>`
    let shareID: String

    /// Canonical share page URL (stored as the note's `path`).
    var pageURL: URL {
        baseURL.appendingPathComponent("n").appendingPathComponent(shareID)
    }

    /// Accepts `/n/<shareId>` (share page) and `/api/shared/<shareId>` (API).
    static func parse(_ url: URL) -> RemoteNoteLink? {
        guard let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
              let host = url.host else { return nil }

        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        components.port = url.port
        guard let base = components.url else { return nil }

        let parts = url.pathComponents.filter { $0 != "/" }
        let shareID: String?
        if parts.count >= 2, parts[0] == "n" {
            shareID = parts[1]
        } else if parts.count >= 3, parts[0] == "api", parts[1] == "shared" {
            shareID = parts[2]
        } else {
            shareID = nil
        }

        guard let shareID, UUID(uuidString: shareID) != nil else { return nil }
        return RemoteNoteLink(baseURL: base, shareID: shareID)
    }
}

/// Payload of `GET /api/shared/<shareId>` and `GET /api/notes` (the subset this
/// app needs). `createdAt`/`updatedAt` are ISO 8601 strings; they are optional
/// because the shared-note payload does not carry them.
struct RemoteNote: Decodable {
    let id: String
    let title: String
    let body: String
    let revision: String
    let createdAt: String?
    let updatedAt: String?

    /// Server creation time, when the payload carries one.
    var createdDate: Date? { Self.parseTimestamp(createdAt) }

    /// Server modification time, when the payload carries one.
    var updatedDate: Date? { Self.parseTimestamp(updatedAt) }

    /// The API sends `new Date().toISOString()` (fractional seconds); older
    /// files may not have them. Accept both.
    private static func parseTimestamp(_ value: String?) -> Date? {
        guard let value, !value.isEmpty else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: value)
    }
}

/// Access to a Notes API instance.
///
/// Reads use the open share endpoint (no token) or the token-protected list;
/// writes (PATCH, DELETE) need `Authorization: Bearer nk_…`.
final class RemoteNotesClient {
    static let shared = RemoteNotesClient()

    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    enum ClientError: LocalizedError {
        case badStatus(Int)
        case invalidResponse
        case invalidLink
        case conflict(RemoteNote)
        case revisionMismatch
        case unauthorized

        var errorDescription: String? {
            switch self {
            case .invalidLink:
                return "Expected a note link like https://notes.example.com/n/<id>."
            case .unauthorized:
                return "The notes server rejected the token (401). Check it in Settings."
            case .conflict, .revisionMismatch:
                return "The note changed on the server since it was loaded."
            case .badStatus(404):
                return "That note is not shared anymore (or the link is wrong)."
            case .badStatus(let code):
                return "The notes server answered HTTP \(code)."
            case .invalidResponse:
                return "The notes server returned an unexpected response."
            }
        }
    }

    /// Every note on the server in card (`position`) order.
    func listNotes(
        baseURL: URL,
        token: String,
        completion: @escaping (Result<[RemoteNote], Error>) -> Void
    ) {
        let url = baseURL
            .appendingPathComponent("api")
            .appendingPathComponent("notes")

        var request = URLRequest(url: url, timeoutInterval: 15)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")

        session.dataTask(with: request) { data, response, error in
            let result: Result<[RemoteNote], Error>
            if let error {
                result = .failure(error)
            } else if let http = response as? HTTPURLResponse {
                switch http.statusCode {
                case 200..<300:
                    if let data, let notes = try? JSONDecoder().decode([RemoteNote].self, from: data) {
                        result = .success(notes)
                    } else {
                        result = .failure(ClientError.invalidResponse)
                    }
                case 401, 403:
                    result = .failure(ClientError.unauthorized)
                default:
                    result = .failure(ClientError.badStatus(http.statusCode))
                }
            } else {
                result = .failure(ClientError.invalidResponse)
            }
            DispatchQueue.main.async { completion(result) }
        }.resume()
    }

    /// Conditional delete. `If-Match` makes the server answer 409 when the note
    /// changed since `revision` was read, so a stale client never deletes a
    /// newer version. A 404 counts as deleted: the server copy is already gone.
    func deleteNote(
        baseURL: URL,
        noteID: String,
        revision: String,
        token: String,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        let url = baseURL
            .appendingPathComponent("api")
            .appendingPathComponent("notes")
            .appendingPathComponent(noteID)

        var request = URLRequest(url: url, timeoutInterval: 15)
        request.httpMethod = "DELETE"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("\"\(revision)\"", forHTTPHeaderField: "If-Match")

        session.dataTask(with: request) { _, response, error in
            let result: Result<Void, Error>
            if let error {
                result = .failure(error)
            } else if let http = response as? HTTPURLResponse {
                switch http.statusCode {
                case 200..<300, 404:
                    result = .success(())
                case 401, 403:
                    result = .failure(ClientError.unauthorized)
                case 409:
                    result = .failure(ClientError.revisionMismatch)
                default:
                    result = .failure(ClientError.badStatus(http.statusCode))
                }
            } else {
                result = .failure(ClientError.invalidResponse)
            }
            DispatchQueue.main.async { completion(result) }
        }.resume()
    }

    /// Conditional write: `If-Match` makes the server answer 409 when the file
    /// changed since `revision` was read.
    func patchNote(
        baseURL: URL,
        noteID: String,
        body: String,
        revision: String,
        token: String,
        completion: @escaping (Result<RemoteNote, Error>) -> Void
    ) {
        let url = baseURL
            .appendingPathComponent("api")
            .appendingPathComponent("notes")
            .appendingPathComponent(noteID)

        var request = URLRequest(url: url, timeoutInterval: 10)
        request.httpMethod = "PATCH"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("\"\(revision)\"", forHTTPHeaderField: "If-Match")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["body": body])

        session.dataTask(with: request) { data, response, error in
            let result: Result<RemoteNote, Error>
            if let error {
                result = .failure(error)
            } else if let http = response as? HTTPURLResponse {
                switch http.statusCode {
                case 200..<300:
                    if let data, let note = try? JSONDecoder().decode(RemoteNote.self, from: data) {
                        result = .success(note)
                    } else {
                        result = .failure(ClientError.invalidResponse)
                    }
                case 401, 403:
                    result = .failure(ClientError.unauthorized)
                case 409:
                    if let data,
                       let conflict = try? JSONDecoder().decode(ConflictResponse.self, from: data) {
                        result = .failure(ClientError.conflict(conflict.note))
                    } else {
                        result = .failure(ClientError.badStatus(409))
                    }
                default:
                    result = .failure(ClientError.badStatus(http.statusCode))
                }
            } else {
                result = .failure(ClientError.invalidResponse)
            }
            DispatchQueue.main.async { completion(result) }
        }.resume()
    }

    private struct ConflictResponse: Decodable {
        let note: RemoteNote
    }

    func fetchSharedNote(
        _ link: RemoteNoteLink,
        completion: @escaping (Result<RemoteNote, Error>) -> Void
    ) {
        let url = link.baseURL
            .appendingPathComponent("api")
            .appendingPathComponent("shared")
            .appendingPathComponent(link.shareID)

        var request = URLRequest(url: url, timeoutInterval: 10)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")

        session.dataTask(with: request) { data, response, error in
            let result: Result<RemoteNote, Error>
            if let error {
                result = .failure(error)
            } else if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                result = .failure(ClientError.badStatus(http.statusCode))
            } else if let data, let note = try? JSONDecoder().decode(RemoteNote.self, from: data) {
                result = .success(note)
            } else {
                result = .failure(ClientError.invalidResponse)
            }
            DispatchQueue.main.async { completion(result) }
        }.resume()
    }
}
