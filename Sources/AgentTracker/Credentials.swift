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

/// Supplies a valid OAuth access token, preferring a credential this app owns.
///
/// The Claude CLI rewrites its own Keychain item ("Claude Code-credentials")
/// whenever it refreshes, which regenerates that item's ACL and drops whatever
/// "Always Allow" grant was given to us. So we seed from the CLI's item once,
/// then keep our own item that only this app writes — that grant survives, and
/// the CLI is consulted again only if our own refresh token stops working.
enum CredentialsProvider {
    private static let keychainService = "Claude Code-credentials"
    private static let ownService = "com.agent-tracker.usage"
    private static let ownAccount = "credentials"
    // Claude Code's public OAuth client id, needed for refresh_token grants.
    private static let oauthClientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    private static let tokenEndpoint = URL(string: "https://console.anthropic.com/v1/oauth/token")!

    /// Reads the Claude CLI's credential. This is the call that can raise a
    /// Keychain prompt, so it runs only when our own copy is missing or dead.
    static func load() throws -> ClaudeCredentials {
        let data: Data
        if let keychainData = readKeychain(service: keychainService, account: nil) {
            data = keychainData
        } else if let fileData = readCredentialsFile() {
            data = fileData
        } else {
            throw CredentialsError.notFound
        }
        return try parse(data)
    }

    /// Returns a credential set with a currently-valid access token.
    ///
    /// Prefers our own stored credential, refreshing it in place when expired,
    /// and re-seeds from the CLI only when we have nothing usable left.
    static func loadValid() async throws -> ClaudeCredentials {
        if let own = try? loadOwn() {
            if !own.isExpired { return own }
            if let refreshed = try? await refresh(own) {
                storeOwn(refreshed)
                return refreshed
            }
        }

        var creds = try load()
        if creds.isExpired {
            creds = try await refresh(creds)
        }
        storeOwn(creds)
        return creds
    }

    /// Exchanges a refresh token for a fresh access token.
    private static func refresh(_ credentials: ClaudeCredentials) async throws -> ClaudeCredentials {
        guard let refreshToken = credentials.refreshToken else {
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

        var updated = credentials
        updated.accessToken = accessToken
        // The rotated refresh token has to be kept, or the next refresh fails
        // and we are back to prompting for the CLI's item.
        if let newRefresh = json["refresh_token"] as? String {
            updated.refreshToken = newRefresh
        }
        if let expiresIn = json["expires_in"] as? Double {
            updated.expiresAt = (Date().timeIntervalSince1970 + expiresIn) * 1000
        }
        return updated
    }

    // MARK: - Our own Keychain item

    /// Reads the credential this app wrote. Nothing else updates this item, so
    /// its "Always Allow" grant is not invalidated behind our back.
    private static func loadOwn() throws -> ClaudeCredentials {
        guard let data = readKeychain(service: ownService, account: ownAccount) else {
            throw CredentialsError.notFound
        }
        return try parse(data)
    }

    /// Writes the credential to our own item, replacing any previous value.
    /// Best-effort: a failure here only costs us a prompt on the next refresh.
    private static func storeOwn(_ credentials: ClaudeCredentials) {
        var oauth: [String: Any] = ["accessToken": credentials.accessToken]
        if let refreshToken = credentials.refreshToken { oauth["refreshToken"] = refreshToken }
        if let expiresAt = credentials.expiresAt { oauth["expiresAt"] = expiresAt }
        if let subscription = credentials.subscriptionType { oauth["subscriptionType"] = subscription }
        guard let data = try? JSONSerialization.data(withJSONObject: ["claudeAiOauth": oauth]) else {
            return
        }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: ownService,
            kSecAttrAccount as String: ownAccount,
        ]
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        guard status == errSecItemNotFound else { return }

        var insert = query
        insert[kSecValueData as String] = data
        // The app runs unattended in the menu bar, so it has to be readable
        // after a reboot without the user unlocking anything first.
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(insert as CFDictionary, nil)
    }

    // MARK: - Storage backends

    private static func readKeychain(service: String, account: String?) -> Data? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        if let account {
            query[kSecAttrAccount as String] = account
        }
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
