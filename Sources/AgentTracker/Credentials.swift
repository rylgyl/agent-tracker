import Foundation
import Security

/// The OAuth credentials Claude Code (the CLI) stores after `claude` login.
struct ClaudeCredentials {
    var accessToken: String
    // The stored refresh token is intentionally not read: see CredentialsProvider.
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
    case expired

    var errorDescription: String? {
        switch self {
        case .notFound:
            return "No Claude CLI credentials found. Run `claude` in a terminal and log in first."
        case .malformed:
            return "Claude CLI credentials could not be parsed."
        case .expired:
            return "Claude CLI token has expired. Run `claude` in a terminal to refresh it."
        }
    }
}

/// Supplies the Claude CLI's OAuth access token, read-only.
///
/// This app deliberately never performs a `refresh_token` grant. That endpoint
/// rotates the refresh token — presenting the CLI's token invalidates the copy
/// the CLI still has on disk, which logs the user out of `claude` the next time
/// they use it. So the CLI is the sole owner of the credential and the only
/// thing that renews it; we just read whatever it currently holds.
///
/// We keep a cached copy in our own Keychain item so a poll doesn't have to
/// touch the CLI's item while the token is still valid.
enum CredentialsProvider {
    private static let keychainService = "Claude Code-credentials"
    private static let cacheService = "com.agent-tracker.usage"
    private static let cacheAccount = "credentials"

    /// Reads the Claude CLI's credential.
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

    /// Returns a credential with a currently-valid access token, or throws.
    ///
    /// Never renews anything: an expired token is reported as such and the user
    /// runs `claude` to renew it, which is also what repopulates this app.
    static func loadValid() throws -> ClaudeCredentials {
        if let cached = try? loadCached(), !cached.isExpired {
            return cached
        }

        let credentials = try load()
        guard !credentials.isExpired else {
            // The CLI renews lazily, on its next use, so there is nothing to do
            // but wait for it. Drop the stale cache so we keep re-reading.
            clearCache()
            throw CredentialsError.expired
        }
        storeCache(credentials)
        return credentials
    }

    // MARK: - Cache

    /// Reads our cached copy of the CLI's credential.
    private static func loadCached() throws -> ClaudeCredentials {
        guard let data = readKeychain(service: cacheService, account: cacheAccount) else {
            throw CredentialsError.notFound
        }
        return try parse(data)
    }

    private static func clearCache() {
        SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: cacheService,
            kSecAttrAccount as String: cacheAccount,
        ] as CFDictionary)
    }

    /// Caches the credential, replacing any previous value. Best-effort: a
    /// failure here only costs us a read of the CLI's item on the next poll.
    private static func storeCache(_ credentials: ClaudeCredentials) {
        // The refresh token is deliberately not cached: this app never uses it,
        // and a copy we don't need is a secret we shouldn't be holding.
        var oauth: [String: Any] = ["accessToken": credentials.accessToken]
        if let expiresAt = credentials.expiresAt { oauth["expiresAt"] = expiresAt }
        if let subscription = credentials.subscriptionType { oauth["subscriptionType"] = subscription }
        guard let data = try? JSONSerialization.data(withJSONObject: ["claudeAiOauth": oauth]) else {
            return
        }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: cacheService,
            kSecAttrAccount as String: cacheAccount,
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
            expiresAt: oauth["expiresAt"] as? Double,
            subscriptionType: oauth["subscriptionType"] as? String
        )
    }
}
