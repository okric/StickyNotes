import Foundation
import Security

/// Bearer tokens for Notes API servers, kept in the login Keychain.
///
/// One item per server origin (`https://notes.example.com`), service
/// `com.mdstickynotes.notes-token`. Tokens are never written to `index.json` or
/// settings.json.
enum RemoteCredentials {
    private static let service = "com.mdstickynotes.notes-token"

    static func token(for baseURL: String) -> String? {
        let account = normalize(baseURL)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let token = String(data: data, encoding: .utf8),
              !token.isEmpty else {
            return nil
        }
        return token
    }

    static func setToken(_ token: String?, for baseURL: String) {
        let account = normalize(baseURL)
        let identity: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(identity as CFDictionary)

        guard let token, !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }
        var item = identity
        item[kSecValueData as String] = Data(token.trimmingCharacters(in: .whitespacesAndNewlines).utf8)
        let status = SecItemAdd(item as CFDictionary, nil)
        if status != errSecSuccess {
            print("[RemoteCredentials] Failed to store token for \(account): \(status)")
        }
    }

    static func normalize(_ baseURL: String) -> String {
        var value = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while value.hasSuffix("/") { value.removeLast() }
        return value
    }
}

extension Notification.Name {
    /// Posted when a Notes server token is saved or removed.
    static let remoteTokenChanged = Notification.Name("com.mdstickynotes.remoteTokenChanged")
}

/// Whether a remote note can be edited: it needs a token for its server.
enum RemoteWriteAccess {
    static func canEdit(_ note: Note) -> Bool {
        guard note.isRemote, let base = note.remoteBaseURL else { return false }
        return RemoteCredentials.token(for: base) != nil
    }
}
