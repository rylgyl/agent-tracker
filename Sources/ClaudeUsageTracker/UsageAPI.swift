import Foundation

/// Rate-limit state for one window (session / weekly / weekly Opus),
/// as reported by the endpoint behind the CLI's `/usage` screen.
struct LimitWindow {
    /// 0–100 percent of the window consumed.
    var utilization: Double
    var resetsAt: Date?
}

struct UsageLimits {
    var session: LimitWindow?
    var weekly: LimitWindow?
    var weeklyOpus: LimitWindow?
}

enum UsageAPIError: LocalizedError {
    case unauthorized
    case http(Int)
    case malformed

    var errorDescription: String? {
        switch self {
        case .unauthorized:
            return "Not authorized. Run `claude` in a terminal to log in again."
        case .http(let code):
            return "Usage API returned HTTP \(code)."
        case .malformed:
            return "Usage API returned an unexpected response."
        }
    }
}

enum UsageAPI {
    private static let endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!

    static func fetchLimits(accessToken: String) async throws -> UsageLimits {
        var request = URLRequest(url: endpoint)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw UsageAPIError.malformed }
        if http.statusCode == 401 || http.statusCode == 403 { throw UsageAPIError.unauthorized }
        guard (200..<300).contains(http.statusCode) else { throw UsageAPIError.http(http.statusCode) }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw UsageAPIError.malformed
        }

        return UsageLimits(
            session: window(json["five_hour"]),
            weekly: window(json["seven_day"]),
            weeklyOpus: window(json["seven_day_opus"])
        )
    }

    private static func window(_ value: Any?) -> LimitWindow? {
        guard let dict = value as? [String: Any] else { return nil }
        let utilization: Double
        if let number = dict["utilization"] as? Double {
            utilization = number
        } else if let number = dict["utilization"] as? Int {
            utilization = Double(number)
        } else {
            return nil
        }
        var resetsAt: Date?
        if let raw = dict["resets_at"] as? String {
            resetsAt = parseTimestamp(raw)
        } else if let epoch = dict["resets_at"] as? Double {
            resetsAt = Date(timeIntervalSince1970: epoch)
        }
        return LimitWindow(utilization: utilization, resetsAt: resetsAt)
    }

    static func parseTimestamp(_ raw: String) -> Date? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFraction.date(from: raw) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: raw)
    }
}
