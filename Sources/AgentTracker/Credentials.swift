import Foundation
import Security

/// The OAuth credentials Claude Code (the CLI) stores after `claude` login.
struct ClaudeCredentials {
    var accessToken: String
    var refreshToken: String?
    /// Milliseconds since epoch, as stored by the CLI.
    var expiresAt: Double?
    var subscriptionType: String?

    var isExpired: Bool {
        guard let expiresAt else { return false }
        // Refresh a minute early to avoid racing the expiry.
        return Date(timeIntervalSince1970: expiresAt / 1000) < Date().addingTimeInterval(60)
    }
}

enum CredentialsError: LocalizedError {
    case notFound
    case malformed
    case refreshFailed(String)

    var errorDescription: String? {
        switch self {
        case .notFound:
            return "No Claude CLI credentials found. Run `claude` in a terminal and log in first."
        case .malformed:
            return "Claude CLI credentials could not be parsed."
        case .refreshFailed(let detail):
            return "Token refresh failed (\(detail)). Run `claude` to re-authenticate."
        }
    }
}

/// Loads (and refreshes) the OAuth token from the Claude CLI's storage:
/// the macOS Keychain item "Claude Code-credentials", falling back to
/// `~/.claude/.credentials.json` on setups that use the plaintext file.
enum CredentialsProvider {
    private static let keychainService = "Claude Code-credentials"
    // Claude Code's public OAuth client id, needed for refresh_token grants.
    private static let oauthClientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    private static let tokenEndpoint = URL(string: "https://console.anthropic.com/v1/oauth/token")!

    static func load() throws -> ClaudeCredentials {
        let data: Data
        if let keychainData = readKeychain() {
            data = keychainData
        } else if let fileData = readCredentialsFile() {
            data = fileData
        } else {
            throw CredentialsError.notFound
        }
        return try parse(data)
    }

    /// Returns a credential set with a currently-valid access token,
    /// refreshing via the CLI's refresh token when the stored one is expired.
    static func loadValid() async throws -> ClaudeCredentials {
        var creds = try load()
        guard creds.isExpired else { return creds }
        guard let refreshToken = creds.refreshToken else {
            throw CredentialsError.refreshFailed("token expired and no refresh token stored")
        }

        var request = URLRequest(url: tokenEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": oauthClientID,
        ])

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw CredentialsError.refreshFailed("HTTP \(code)")
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let accessToken = json["access_token"] as? String else {
            throw CredentialsError.refreshFailed("unexpected response")
        }

        creds.accessToken = accessToken
        if let newRefresh = json["refresh_token"] as? String {
            creds.refreshToken = newRefresh
        }
        if let expiresIn = json["expires_in"] as? Double {
            creds.expiresAt = (Date().timeIntervalSince1970 + expiresIn) * 1000
        }
        // Kept in memory only; the CLI remains the owner of the stored credential.
        return creds
    }

    // MARK: - Storage backends

    private static func readKeychain() -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess else { return nil }
        return item as? Data
    }

    private static func readCredentialsFile() -> Data? {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/.credentials.json")
        return try? Data(contentsOf: url)
    }

    private static func parse(_ data: Data) throws -> ClaudeCredentials {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CredentialsError.malformed
        }
        // Stored as {"claudeAiOauth": {...}}; tolerate a flat layout too.
        let oauth = (root["claudeAiOauth"] as? [String: Any]) ?? root
        guard let accessToken = oauth["accessToken"] as? String else {
            throw CredentialsError.malformed
        }
        return ClaudeCredentials(
            accessToken: accessToken,
            refreshToken: oauth["refreshToken"] as? String,
            expiresAt: oauth["expiresAt"] as? Double,
            subscriptionType: oauth["subscriptionType"] as? String
        )
    }
}
