import Foundation

/// One product's share of the weekly usage pool, as shown on grok.com
/// Settings → Usage. Percents are shares of the whole pool and sum to the
/// weekly total.
struct GrokProductUsage: Identifiable {
    /// Wire name, e.g. "GrokChat".
    var product: String
    /// Dashboard label, e.g. "Chat".
    var name: String
    /// 0–100 percent of the weekly pool.
    var usagePercent: Double

    var id: String { product }
}

/// The Grok usage screen: one weekly pool, a product split, and the prepaid
/// extra-credits balance. Fetched from the same billing endpoint the Grok
/// CLI's `/usage` screen uses. Nothing is written back to `~/.grok/auth.json`;
/// `grok login` stays the owner of the credential.
struct GrokUsage {
    var isSignedIn: Bool
    /// Display name from `/v1/settings`, e.g. "SuperGrok".
    var planType: String?
    /// Nil when the API omits `creditUsagePercent`. That is unknown, not 0%.
    var weeklyPercent: Double?
    var resetsAt: Date?
    /// Dashboard order: Chat, Imagine, Build, Voice, then any others.
    var products: [GrokProductUsage]
    /// Prepaid extra-usage balance in US dollars. Nil when the payload omits it.
    var extraCreditsUSD: Double?

    var hasSnapshot: Bool { weeklyPercent != nil || !products.isEmpty }

    static let empty = GrokUsage(
        isSignedIn: false, planType: nil, weeklyPercent: nil, resetsAt: nil,
        products: [], extraCreditsUSD: nil
    )

    static let signedInEmpty = GrokUsage(
        isSignedIn: true, planType: nil, weeklyPercent: nil, resetsAt: nil,
        products: [], extraCreditsUSD: nil
    )
}

struct GrokLoadResult {
    var usage: GrokUsage?
    /// Nil clears a previous error. Set only when this refresh has something to say.
    var errorMessage: String?
    var clearError = false
    var rateLimitedUntil: Date?
    var clearRateLimit = false
    /// Leave the last good snapshot on screen.
    var keepPrevious = false
}

enum GrokUsageError: LocalizedError {
    case notFound
    case malformed
    case unauthorized
    case rateLimited(Date?)
    case http(Int)
    case unexpected
    case refreshFailed(String)

    var errorDescription: String? {
        switch self {
        case .notFound:
            return "No Grok CLI credentials found. Run `grok login` in a terminal."
        case .malformed:
            return "Grok CLI credentials could not be parsed."
        case .unauthorized:
            return "Not authorized. Run `grok login` in a terminal to sign in again."
        case .rateLimited(let resetsAt):
            if let resetsAt {
                return "Rate limited by the Grok usage API. Resets \(resetsAt.formatted(date: .omitted, time: .shortened))."
            }
            return "Rate limited by the Grok usage API. Try again shortly."
        case .http(let code):
            return "Grok usage API returned HTTP \(code)."
        case .unexpected:
            return "Grok usage API returned an unexpected response."
        case .refreshFailed(let detail):
            return "Grok token refresh failed (\(detail)). Run `grok login` to sign in again."
        }
    }
}

enum GrokUsageAPI {
    private static let proxyBase = URL(string: "https://cli-chat-proxy.grok.com/v1")!
    private static let tokenHeader = "xai-grok-cli"
    private static let refreshSkew: TimeInterval = 60
    private static let requestTimeout: TimeInterval = 15
    /// Legend order on Settings → Usage, then products added to the pool since.
    private static let displayOrder = ["Chat", "Imagine", "Build", "Voice", "API", "Bot", "Cursor"]

    static func load(skipNetwork: Bool) async -> GrokLoadResult {
        if skipNetwork {
            return GrokLoadResult(keepPrevious: true)
        }
        let session: GrokSession
        do {
            session = try loadSession()
        } catch {
            return GrokLoadResult(usage: .empty, errorMessage: error.localizedDescription)
        }

        do {
            let authed = try await validSession(session)
            let usage = try await fetchUsage(session: authed)
            return GrokLoadResult(usage: usage, clearError: true, clearRateLimit: true)
        } catch GrokUsageError.rateLimited(let resetsAt) {
            let until = resetsAt ?? Date().addingTimeInterval(60)
            return GrokLoadResult(
                usage: .signedInEmpty,
                errorMessage: GrokUsageError.rateLimited(resetsAt).localizedDescription,
                rateLimitedUntil: until,
                keepPrevious: true
            )
        } catch {
            return GrokLoadResult(
                usage: .signedInEmpty,
                errorMessage: error.localizedDescription,
                keepPrevious: true
            )
        }
    }

    // MARK: - Billing

    private static func fetchUsage(session: GrokSession) async throws -> GrokUsage {
        let version = clientVersion()
        let creditsData = try await get(
            url: endpoint("billing", query: [URLQueryItem(name: "format", value: "credits")]),
            session: session,
            version: version
        )
        // Plan name is a label. A failure here still leaves the usage split.
        let plan = try? await fetchPlan(session: session, version: version)
        return try parseUsage(creditsData, plan: plan)
    }

    private static func fetchPlan(session: GrokSession, version: String) async throws -> String? {
        let data = try await get(
            url: endpoint("settings"),
            session: session,
            version: version
        )
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let name = json["subscription_tier_display"] as? String,
              !name.isEmpty
        else { return nil }
        return name
    }

    private static func get(url: URL, session: GrokSession, version: String) async throws -> Data {
        var request = URLRequest(url: url, timeoutInterval: requestTimeout)
        request.setValue("Bearer \(session.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(tokenHeader, forHTTPHeaderField: "X-XAI-Token-Auth")
        request.setValue(version, forHTTPHeaderField: "x-grok-client-version")
        request.setValue("cli", forHTTPHeaderField: "x-grok-client-mode")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let userId = session.userId {
            request.setValue(userId, forHTTPHeaderField: "x-userid")
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw GrokUsageError.http(-1) }
        if http.statusCode == 401 || http.statusCode == 403 { throw GrokUsageError.unauthorized }
        if http.statusCode == 429 { throw GrokUsageError.rateLimited(UsageAPI.retryAfter(http)) }
        guard (200..<300).contains(http.statusCode) else { throw GrokUsageError.http(http.statusCode) }
        return data
    }

    static func parseUsage(_ data: Data, plan: String?) throws -> GrokUsage {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw GrokUsageError.unexpected
        }
        let config = (root["config"] as? [String: Any]) ?? root
        let period = config["currentPeriod"] as? [String: Any]
        let resetsAt = (period?["end"] as? String).flatMap(UsageAPI.parseTimestamp)
            ?? (config["billingPeriodEnd"] as? String).flatMap(UsageAPI.parseTimestamp)

        let products = parseProducts(config["productUsage"])
        let weekly = number(config["creditUsagePercent"])
        let extra = (config["prepaidBalance"] as? [String: Any]).flatMap { balance -> Double? in
            guard let cents = number(balance["val"]) else { return nil }
            return cents / 100
        }

        // A weekly window with neither a percent nor a split is a real empty
        // period only when the API says 0. An omitted percent stays unknown.
        if weekly == nil, products.isEmpty, period == nil {
            throw GrokUsageError.unexpected
        }

        return GrokUsage(
            isSignedIn: true,
            planType: plan,
            weeklyPercent: weekly,
            resetsAt: resetsAt,
            products: products,
            extraCreditsUSD: extra
        )
    }

    private static func parseProducts(_ raw: Any?) -> [GrokProductUsage] {
        guard let rows = raw as? [[String: Any]] else { return [] }
        let products: [GrokProductUsage] = rows.compactMap { row in
            guard let product = row["product"] as? String, !product.isEmpty,
                  let percent = number(row["usagePercent"])
            else { return nil }
            return GrokProductUsage(
                product: product, name: displayName(for: product), usagePercent: percent
            )
        }
        return products.sorted { lhs, rhs in
            let left = displayOrder.firstIndex(of: lhs.name) ?? displayOrder.count
            let right = displayOrder.firstIndex(of: rhs.name) ?? displayOrder.count
            if left != right { return left < right }
            if lhs.usagePercent != rhs.usagePercent { return lhs.usagePercent > rhs.usagePercent }
            return lhs.name < rhs.name
        }
    }

    /// "GrokChat" → "Chat", "GrokBuild" → "Build". Unknown names drop a leading "Grok".
    static func displayName(for product: String) -> String {
        switch product {
        case "GrokChat": return "Chat"
        case "GrokBuild": return "Build"
        case "GrokImagine": return "Imagine"
        case "GrokVoice": return "Voice"
        case "GrokApi", "GrokAPI", "API": return "API"
        case "GrokBot": return "Bot"
        case "Cursor": return "Cursor"
        default:
            guard product.hasPrefix("Grok"), product.count > 4 else { return product }
            return String(product.dropFirst(4))
        }
    }

    private static func number(_ value: Any?) -> Double? {
        if let number = value as? Double { return number }
        if let number = value as? Int { return Double(number) }
        if let number = value as? String { return Double(number) }
        return nil
    }

    private static func endpoint(_ path: String, query: [URLQueryItem] = []) -> URL {
        guard var components = URLComponents(
            url: proxyBase.appendingPathComponent(path), resolvingAgainstBaseURL: false
        ) else { return proxyBase }
        if !query.isEmpty { components.queryItems = query }
        return components.url ?? proxyBase
    }

    private static func clientVersion() -> String {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".grok/version.json")
        if let data = try? Data(contentsOf: url),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let version = json["version"] as? String, !version.isEmpty {
            return version
        }
        return "1.0.70"
    }

    // MARK: - Credentials

    private struct GrokSession {
        var accessToken: String
        var refreshToken: String?
        var expiresAt: Date?
        var userId: String?
        var principalType: String?
        var principalId: String?
        var issuer: String
        var clientId: String

        var isExpired: Bool {
            guard let expiresAt else { return false }
            return expiresAt < Date().addingTimeInterval(refreshSkew)
        }
    }

    /// `~/.grok/auth.json` is `{ "<issuer>::<client-id>": { key, refresh_token, … } }`.
    /// When several sessions are stored, the one that expires latest wins.
    private static func loadSession() throws -> GrokSession {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".grok/auth.json")
        guard FileManager.default.fileExists(atPath: url.path) else { throw GrokUsageError.notFound }
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw GrokUsageError.malformed }

        var best: GrokSession?
        for (_, value) in root {
            guard let entry = value as? [String: Any], let session = parseSession(entry) else { continue }
            if best == nil || (session.expiresAt ?? .distantPast) > (best?.expiresAt ?? .distantPast) {
                best = session
            }
        }
        if let best { return best }
        if let session = parseSession(root) { return session }
        throw GrokUsageError.notFound
    }

    private static func parseSession(_ entry: [String: Any]) -> GrokSession? {
        guard let accessToken = (entry["key"] as? String) ?? (entry["access_token"] as? String),
              !accessToken.isEmpty
        else { return nil }
        let issuer = (entry["oidc_issuer"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            ?? "https://auth.x.ai"
        let clientId = (entry["oidc_client_id"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            ?? "b1a00492-073a-47ea-816f-4c329264a828"
        return GrokSession(
            accessToken: accessToken,
            refreshToken: entry["refresh_token"] as? String,
            expiresAt: (entry["expires_at"] as? String).flatMap(UsageAPI.parseTimestamp),
            userId: entry["user_id"] as? String,
            principalType: entry["principal_type"] as? String,
            principalId: entry["principal_id"] as? String,
            issuer: issuer,
            clientId: clientId
        )
    }

    /// Refreshes in memory when the stored access token is inside the skew
    /// window. The new token is not written back.
    private static func validSession(_ session: GrokSession) async throws -> GrokSession {
        guard session.isExpired else { return session }
        guard let refreshToken = session.refreshToken, !refreshToken.isEmpty else {
            throw GrokUsageError.refreshFailed("token expired and no refresh token stored")
        }
        let issuer = session.issuer.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let tokenURL = URL(string: issuer + "/oauth2/token") else {
            throw GrokUsageError.refreshFailed("invalid OIDC issuer")
        }

        var request = URLRequest(url: tokenURL, timeoutInterval: requestTimeout)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        var items = [
            URLQueryItem(name: "grant_type", value: "refresh_token"),
            URLQueryItem(name: "refresh_token", value: refreshToken),
            URLQueryItem(name: "client_id", value: session.clientId),
        ]
        if let principalType = session.principalType {
            items.append(URLQueryItem(name: "principal_type", value: principalType))
        }
        if let principalId = session.principalId {
            items.append(URLQueryItem(name: "principal_id", value: principalId))
        }
        var components = URLComponents()
        components.queryItems = items
        request.httpBody = components.percentEncodedQuery?.data(using: .utf8)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw GrokUsageError.refreshFailed(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw GrokUsageError.refreshFailed("no HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            if http.statusCode == 400 || http.statusCode == 401 {
                throw GrokUsageError.unauthorized
            }
            throw GrokUsageError.refreshFailed("HTTP \(http.statusCode)")
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let accessToken = json["access_token"] as? String, !accessToken.isEmpty
        else { throw GrokUsageError.refreshFailed("unexpected response") }

        var refreshed = session
        refreshed.accessToken = accessToken
        if let next = json["refresh_token"] as? String, !next.isEmpty {
            refreshed.refreshToken = next
        }
        if let expiresIn = number(json["expires_in"]) {
            refreshed.expiresAt = Date().addingTimeInterval(expiresIn)
        }
        return refreshed
    }
}

