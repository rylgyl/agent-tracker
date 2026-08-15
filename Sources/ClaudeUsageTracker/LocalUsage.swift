import Foundation

/// Token totals aggregated from the Claude CLI's local session logs
/// (`~/.claude/projects/**/*.jsonl`). Everything is computed on-device;
/// no log content leaves the machine.
struct LocalUsage {
    struct DayTotal: Identifiable {
        var id: Date { day }
        /// Start of day, local time zone.
        var day: Date
        var label: String
        var tokens: Int
        var isToday: Bool
    }

    struct ModelTotal: Identifiable {
        var id: String { model }
        /// Display name, e.g. "Sonnet 5".
        var model: String
        var tokens: Int
    }

    /// Oldest day first, always exactly 7 entries ending with today.
    var byDay: [DayTotal]
    /// Largest first. Scoped to the same 7-day window.
    var byModel: [ModelTotal]

    static let empty = LocalUsage(byDay: [], byModel: [])
}

enum LocalUsageScanner {
    private struct LogLine: Decodable {
        struct Message: Decodable {
            struct Usage: Decodable {
                let input_tokens: Int?
                let output_tokens: Int?
                let cache_creation_input_tokens: Int?
                let cache_read_input_tokens: Int?

                var total: Int {
                    (input_tokens ?? 0) + (output_tokens ?? 0)
                        + (cache_creation_input_tokens ?? 0) + (cache_read_input_tokens ?? 0)
                }
            }
            let id: String?
            let model: String?
            let usage: Usage?
        }
        let type: String?
        let timestamp: String?
        let requestId: String?
        let message: Message?
    }

    static func scan(days: Int = 7, now: Date = Date()) -> LocalUsage {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        guard let windowStart = calendar.date(byAdding: .day, value: -(days - 1), to: today) else {
            return .empty
        }

        var tokensByDay: [Date: Int] = [:]
        var tokensByModel: [String: Int] = [:]
        // The CLI can log the same API response into multiple JSONL files
        // (e.g. resumed sessions); count each message+request pair once.
        var seen = Set<String>()

        let decoder = JSONDecoder()
        for fileURL in logFiles(modifiedAfter: windowStart) {
            guard let contents = try? String(contentsOf: fileURL, encoding: .utf8) else { continue }
            for line in contents.split(separator: "\n") {
                guard line.contains("\"usage\""), let data = line.data(using: .utf8),
                      let entry = try? decoder.decode(LogLine.self, from: data),
                      entry.type == "assistant",
                      let usage = entry.message?.usage,
                      usage.total > 0,
                      let rawTimestamp = entry.timestamp,
                      let timestamp = UsageAPI.parseTimestamp(rawTimestamp)
                else { continue }

                let day = calendar.startOfDay(for: timestamp)
                guard day >= windowStart, day <= today else { continue }

                if let messageID = entry.message?.id {
                    let key = "\(messageID):\(entry.requestId ?? "")"
                    guard seen.insert(key).inserted else { continue }
                }

                tokensByDay[day, default: 0] += usage.total
                if let model = entry.message?.model, model != "<synthetic>" {
                    tokensByModel[displayName(for: model), default: 0] += usage.total
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

        return LocalUsage(byDay: byDay, byModel: byModel)
    }

    private static func logFiles(modifiedAfter cutoff: Date) -> [URL] {
        let projectsDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects")
        guard let enumerator = FileManager.default.enumerator(
            at: projectsDir,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var files: [URL] = []
        for case let url as URL in enumerator where url.pathExtension == "jsonl" {
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate
            if let modified, modified >= cutoff {
                files.append(url)
            }
        }
        return files
    }

    /// "claude-sonnet-5" -> "Sonnet 5", "claude-opus-4-1-20250805" -> "Opus 4.1"
    static func displayName(for modelID: String) -> String {
        var parts = modelID.split(separator: "-").map(String.init)
        if parts.first == "claude" { parts.removeFirst() }
        // Drop a trailing date stamp like 20250805.
        if let last = parts.last, last.count == 8, Int(last) != nil { parts.removeLast() }
        guard let family = parts.first else { return modelID }
        let version = parts.dropFirst().joined(separator: ".")
        let name = family.prefix(1).uppercased() + family.dropFirst()
        return version.isEmpty ? name : "\(name) \(version)"
    }
}
