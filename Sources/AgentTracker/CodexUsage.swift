import Foundation

/// A rate-limit window as reported by the Codex CLI in its session logs.
struct CodexLimitWindow: Identifiable {
    var id: Int { windowMinutes }
    /// Length of the rolling window, e.g. 300 (5h) or 10080 (weekly).
    var windowMinutes: Int
    var usedPercent: Double
    var resetsAt: Date?

    /// "5h", "Weekly", "45m"
    var name: String {
        switch windowMinutes {
        case 10080: return "Weekly"
        case 1440: return "Daily"
        case ..<60: return "\(windowMinutes)m"
        default:
            let hours = windowMinutes / 60
            let minutes = windowMinutes % 60
            return minutes == 0 ? "\(hours)h" : "\(hours)h \(minutes)m"
        }
    }
}

/// Everything shown on the Codex tab. Unlike the Claude tab this needs no
/// network call: the Codex CLI records both token usage and the server's
/// rate-limit snapshot into `~/.codex/sessions/**/*.jsonl`.
struct CodexUsage {
    /// False when the Codex CLI has never run on this machine.
    var isInstalled: Bool
    /// Most recent rate-limit windows, newest snapshot wins.
    var limits: [CodexLimitWindow]
    /// e.g. "PLUS", from the same snapshot.
    var planType: String?
    /// When the rate-limit snapshot was taken.
    var limitsCapturedAt: Date?
    var byDay: [LocalUsage.DayTotal]
    var byModel: [LocalUsage.ModelTotal]

    static let empty = CodexUsage(
        isInstalled: false, limits: [], planType: nil, limitsCapturedAt: nil, byDay: [], byModel: []
    )
}

enum CodexUsageScanner {
    private struct RolloutLine: Decodable {
        struct Payload: Decodable {
            struct Info: Decodable {
                struct Tokens: Decodable {
                    let input_tokens: Int?
                    let output_tokens: Int?
                    let total_tokens: Int?

                    var total: Int {
                        total_tokens ?? ((input_tokens ?? 0) + (output_tokens ?? 0))
                    }
                }
                let total_token_usage: Tokens?
                let last_token_usage: Tokens?
            }
            struct RateLimits: Decodable {
                struct Window: Decodable {
                    let used_percent: Double?
                    let window_minutes: Int?
                    let resets_at: Double?
                    let resets_in_seconds: Double?
                }
                let primary: Window?
                let secondary: Window?
                let plan_type: String?
            }
            let type: String?
            /// Present on `turn_context`.
            let model: String?
            let info: Info?
            let rate_limits: RateLimits?
        }
        let timestamp: String?
        let type: String?
        let payload: Payload?
    }

    static func scan(days: Int = 7, now: Date = Date()) -> CodexUsage {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        guard let windowStart = calendar.date(byAdding: .day, value: -(days - 1), to: today) else {
            return .empty
        }

        let sessionsDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/sessions")
        guard FileManager.default.fileExists(atPath: sessionsDir.path) else { return .empty }

        var tokensByDay: [Date: Int] = [:]
        var tokensByModel: [String: Int] = [:]
        var limits: [CodexLimitWindow] = []
        var planType: String?
        var limitsCapturedAt: Date?

        let decoder = JSONDecoder()
        for fileURL in logFiles(in: sessionsDir, modifiedAfter: windowStart) {
            guard let contents = try? String(contentsOf: fileURL, encoding: .utf8) else { continue }

            // Turns inherit the model from the most recent `turn_context`.
            var currentModel: String?
            // Fallback for logs that only carry the cumulative session total.
            var previousCumulative = 0

            for line in contents.split(separator: "\n") {
                let isTurnContext = line.contains("\"turn_context\"")
                guard isTurnContext || line.contains("\"token_count\""),
                      let data = line.data(using: .utf8),
                      let entry = try? decoder.decode(RolloutLine.self, from: data),
                      let payload = entry.payload
                else { continue }

                if isTurnContext, entry.type == "turn_context" {
                    if let model = payload.model { currentModel = model }
                    continue
                }
                guard payload.type == "token_count",
                      let timestamp = entry.timestamp.flatMap(UsageAPI.parseTimestamp)
                else { continue }

                if let rateLimits = payload.rate_limits,
                   limitsCapturedAt == nil || timestamp > limitsCapturedAt! {
                    let windows = [rateLimits.primary, rateLimits.secondary]
                        .compactMap { $0 }
                        .compactMap { window -> CodexLimitWindow? in
                            guard let minutes = window.window_minutes else { return nil }
                            return CodexLimitWindow(
                                windowMinutes: minutes,
                                usedPercent: window.used_percent ?? 0,
                                resetsAt: resetDate(for: window, capturedAt: timestamp)
                            )
                        }
                        .sorted { $0.windowMinutes < $1.windowMinutes }
                    if !windows.isEmpty {
                        limits = windows
                        planType = rateLimits.plan_type?.uppercased()
                        limitsCapturedAt = timestamp
                    }
                }

                let cumulative = payload.info?.total_token_usage?.total ?? 0
                let turnTokens = payload.info?.last_token_usage?.total
                    ?? max(0, cumulative - previousCumulative)
                previousCumulative = max(previousCumulative, cumulative)
                guard turnTokens > 0 else { continue }

                let day = calendar.startOfDay(for: timestamp)
                guard day >= windowStart, day <= today else { continue }
                tokensByDay[day, default: 0] += turnTokens
                if let currentModel {
                    tokensByModel[displayName(for: currentModel), default: 0] += turnTokens
                }
            }
        }

        let weekdayFormatter = DateFormatter()
        weekdayFormatter.dateFormat = "EEE"

        let byDay: [LocalUsage.DayTotal] = (0..<days).compactMap { offset in
            guard let day = calendar.date(byAdding: .day, value: offset, to: windowStart) else {
                return nil
            }
            let isToday = day == today
            return LocalUsage.DayTotal(
                day: day,
                label: isToday ? "Today" : weekdayFormatter.string(from: day),
                tokens: tokensByDay[day] ?? 0,
                isToday: isToday
            )
        }

        let byModel = tokensByModel
            .map { LocalUsage.ModelTotal(model: $0.key, tokens: $0.value) }
            .sorted { $0.tokens > $1.tokens }

        return CodexUsage(
            isInstalled: true,
            limits: limits,
            planType: planType,
            limitsCapturedAt: limitsCapturedAt,
            byDay: byDay,
            byModel: byModel
        )
    }

    private static func resetDate(
        for window: RolloutLine.Payload.RateLimits.Window, capturedAt: Date
    ) -> Date? {
        if let resetsAt = window.resets_at {
            return Date(timeIntervalSince1970: resetsAt)
        }
        // Older CLI versions report the reset as an offset from the event.
        if let seconds = window.resets_in_seconds {
            return capturedAt.addingTimeInterval(seconds)
        }
        return nil
    }

    /// Session logs within the window, plus the newest log overall so the
    /// rate-limit snapshot survives a week without any Codex usage.
    private static func logFiles(in directory: URL, modifiedAfter cutoff: Date) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var files: [URL] = []
        var newest: (url: URL, modified: Date)?
        for case let url as URL in enumerator where url.pathExtension == "jsonl" {
            guard let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate else { continue }
            if modified >= cutoff {
                files.append(url)
            }
            if newest == nil || modified > newest!.modified {
                newest = (url, modified)
            }
        }
        if files.isEmpty, let newest {
            files.append(newest.url)
        }
        // Oldest first, so the newest snapshot is the last one applied.
        return files.sorted { $0.path < $1.path }
    }

    /// "gpt-5.6-luna" -> "GPT-5.6 Luna", "gpt-5-codex" -> "GPT-5 Codex"
    static func displayName(for modelID: String) -> String {
        var parts = modelID.split(separator: "-").map(String.init)
        guard !parts.isEmpty else { return modelID }
        let head = parts.removeFirst()
        let family = head.lowercased() == "gpt" ? "GPT" : head.capitalized
        guard let version = parts.first else { return family }
        let suffix = parts.dropFirst().map(\.capitalized).joined(separator: " ")
        let base = "\(family)-\(version)"
        return suffix.isEmpty ? base : "\(base) \(suffix)"
    }
}
