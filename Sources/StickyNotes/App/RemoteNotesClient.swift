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

/// Payload of `GET /api/shared/<shareId>` (the subset this app needs).
struct RemoteNote: Decodable {
    let id: String
    let title: String
    let body: String
    let revision: String
}

/// Read access to a Notes API instance.
///
/// Only the open share endpoint is used for now: no token, no writes. The
/// share id is the capability, so polling uses the same URL the user pasted.
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

        var errorDescription: String? {
            switch self {
            case .invalidLink:
                return "Expected a note link like https://notes.example.com/n/<id>."
            case .badStatus(404):
                return "That note is not shared anymore (or the link is wrong)."
            case .badStatus(let code):
                return "The notes server answered HTTP \(code)."
            case .invalidResponse:
                return "The notes server returned an unexpected response."
            }
        }
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
