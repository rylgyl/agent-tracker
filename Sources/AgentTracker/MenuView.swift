import CryptoKit
import SwiftUI

/// Which tool the panel is showing. Persisted so the menu bar icon and the
/// panel agree, and so the choice survives a relaunch.
enum MenuTab: String, CaseIterable, Identifiable {
    case claude = "Claude"
    case codex = "Codex"

    static let storageKey = "selectedTab"

    var id: String { rawValue }

    /// Also used as the menu bar icon for the selected tab.
    var icon: String {
        switch self {
        case .claude: return "asterisk"
        case .codex: return "chevron.left.forwardslash.chevron.right"
        }
    }

    var title: String {
        switch self {
        case .claude: return "Claude Code"
        case .codex: return "Codex"
        }
    }
}

/// The popover panel, styled after the Claude Code `/usage` screen:
/// LIMITS (session + weekly bars), TOKENS BY DAY, TOKENS BY MODEL.
/// Two tabs: Claude (usage API + local logs) and Codex (local logs only).
struct MenuView: View {
    @EnvironmentObject private var store: UsageStore
    @AppStorage(MenuTab.storageKey) private var tab: MenuTab = .claude

    private enum Style {
        static let background = Color(red: 0.13, green: 0.13, blue: 0.21)
        static let barTrack = Color.white.opacity(0.16)
        static let barFill = Color.white
        static let claudeAccent = Color(red: 0.85, green: 0.35, blue: 0.22) // Claude coral
        static let codexAccent = Color(red: 0.36, green: 0.76, blue: 0.66) // Codex teal
        static let secondaryText = Color.white.opacity(0.55)
        static let width: CGFloat = 320

        static func accent(for tab: MenuTab) -> Color {
            switch tab {
            case .claude: return claudeAccent
            case .codex: return codexAccent
            }
        }
    }

    /// Easter egg: a little love note, shown only on one specific Mac account.
    /// Matched by digest so the account name isn't sitting in the source.
    private static let noteAccountDigest =
        "dc2415a4aefa5bbdc9baad1937f4bdf4c9a11bea88ead33e3cb26752b64f3b9d"

    private var showsNote: Bool {
        let digest = SHA256.hash(data: Data(NSUserName().utf8))
        return digest.map { String(format: "%02x", $0) }.joined() == Self.noteAccountDigest
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            tabBar
            Divider().overlay(Style.barTrack)
            switch tab {
            case .claude: claudeTab
            case .codex: codexTab
            }
            footer
        }
        .padding(16)
        .frame(width: Style.width)
        .background(Style.background)
        .colorScheme(.dark)
        .font(.system(size: 12, design: .monospaced))
        .foregroundStyle(.white)
    }

    // MARK: - Chrome

    private var header: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: tab.icon)
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(Style.accent(for: tab))
            VStack(alignment: .leading, spacing: 2) {
                Text(tab.title)
                    .font(.system(size: 13, weight: .bold, design: .monospaced))
                if let plan = tab == .claude ? store.subscriptionType : store.codexUsage.planType {
                    Text(plan)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(Style.secondaryText)
                }
            }
            Spacer()
            if showsNote {
                Text("hi love \u{2764}\u{FE0F}")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Color.pink)
            }
        }
    }

    private var tabBar: some View {
        HStack(spacing: 6) {
            ForEach(MenuTab.allCases) { item in
                Button {
                    tab = item
                } label: {
                    Text(item.rawValue)
                        .font(.system(size: 11, weight: tab == item ? .bold : .regular,
                                      design: .monospaced))
                        .foregroundStyle(tab == item ? Color.white : Style.secondaryText)
                        .padding(.vertical, 4)
                        .frame(maxWidth: .infinity)
                        .background(
                            RoundedRectangle(cornerRadius: 5)
                                .fill(tab == item ? Style.accent(for: item).opacity(0.28) : Color.white.opacity(0.06))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 5)
                                .stroke(tab == item ? Style.accent(for: item) : Color.clear, lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var footer: some View {
        HStack {
            if let updated = store.lastUpdated {
                Text("Updated \(updated.formatted(date: .omitted, time: .shortened))")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Style.secondaryText)
            }
            Spacer()
            Button {
                store.refresh()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .opacity(store.isRefreshing ? 0.4 : 1)
            }
            .buttonStyle(.plain)
            .disabled(store.isRefreshing)
            .help(store.isRateLimited
                  ? "Claude limits rate limited until \(store.rateLimitedUntil?.formatted(date: .omitted, time: .shortened) ?? "shortly")"
                  : "Refresh now")
            Button {
                NSApp.terminate(nil)
            } label: {
                Image(systemName: "power")
            }
            .buttonStyle(.plain)
            .help("Quit")
        }
    }

    // MARK: - Tabs

    private var claudeTab: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 10) {
                sectionTitle("LIMITS")
                if let session = store.limits?.session {
                    limitRow(name: "Session", percent: session.utilization, resetsAt: session.resetsAt)
                }
                if let weekly = store.limits?.weekly {
                    limitRow(name: "Weekly", percent: weekly.utilization, resetsAt: weekly.resetsAt)
                }
                if let opus = store.limits?.weeklyOpus, opus.utilization > 0 {
                    limitRow(name: "Weekly (Opus)", percent: opus.utilization, resetsAt: opus.resetsAt)
                }
                if store.limits == nil {
                    Text(store.isRefreshing ? "Loading…" : "No limit data")
                        .foregroundStyle(Style.secondaryText)
                }
            }
            Divider().overlay(Style.barTrack)
            tokensByDaySection(store.localUsage.byDay)
            Divider().overlay(Style.barTrack)
            tokensByModelSection(store.localUsage.byModel)
            if let error = store.errorMessage {
                Text(error)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.yellow)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var codexTab: some View {
        VStack(alignment: .leading, spacing: 16) {
            if !store.codexUsage.isInstalled {
                Text("No Codex sessions found in ~/.codex/sessions")
                    .foregroundStyle(Style.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    sectionTitle("LIMITS")
                    ForEach(store.codexUsage.limits) { window in
                        limitRow(
                            name: window.name,
                            percent: window.usedPercent,
                            resetsAt: window.resetsAt
                        )
                    }
                    if store.codexUsage.limits.isEmpty {
                        Text(store.isRefreshing ? "Loading…" : "No limit data")
                            .foregroundStyle(Style.secondaryText)
                    } else if let captured = store.codexUsage.limitsCapturedAt {
                        // Codex only reports limits while it runs, so the
                        // snapshot can be older than the last refresh.
                        Text("As of \(captured.formatted(date: .omitted, time: .shortened))")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(Style.secondaryText)
                    }
                }
                Divider().overlay(Style.barTrack)
                tokensByDaySection(store.codexUsage.byDay)
                Divider().overlay(Style.barTrack)
                tokensByModelSection(store.codexUsage.byModel)
            }
        }
    }

    // MARK: - Sections

    private func limitRow(name: String, percent: Double, resetsAt: Date?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(name)
                Spacer()
                Text(Format.percent(percent))
            }
            bar(fraction: percent / 100)
            Text(Format.resets(at: resetsAt))
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(Style.secondaryText)
        }
    }

    private func tokensByDaySection(_ days: [LocalUsage.DayTotal]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("TOKENS BY DAY")
            let maxTokens = max(days.map(\.tokens).max() ?? 0, 1)
            ForEach(days) { day in
                HStack(spacing: 8) {
                    Text(day.label)
                        .frame(width: 44, alignment: .leading)
                        .fontWeight(day.isToday ? .bold : .regular)
                    bar(fraction: Double(day.tokens) / Double(maxTokens))
                    Text(Format.tokens(day.tokens))
                        .frame(width: 56, alignment: .trailing)
                        .fontWeight(day.isToday ? .bold : .regular)
                }
            }
        }
    }

    private func tokensByModelSection(_ models: [LocalUsage.ModelTotal]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("TOKENS BY MODEL")
            if models.isEmpty {
                Text("No usage in the last 7 days")
                    .foregroundStyle(Style.secondaryText)
            }
            let maxTokens = max(models.map(\.tokens).max() ?? 0, 1)
            ForEach(models) { model in
                HStack(spacing: 8) {
                    Text(model.model)
                        // Wide enough for names like "GPT-5.6 Luna".
                        .frame(width: 104, alignment: .leading)
                        .lineLimit(1)
                    bar(fraction: Double(model.tokens) / Double(maxTokens))
                    Text(Format.tokens(model.tokens))
                        .frame(width: 56, alignment: .trailing)
                }
            }
        }
    }

    // MARK: - Pieces

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 10, weight: .semibold, design: .monospaced))
            .foregroundStyle(Style.secondaryText)
            .kerning(1)
    }

    private func bar(fraction: Double) -> some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Style.barTrack)
                Capsule()
                    .fill(Style.barFill)
                    .frame(width: max(geometry.size.width * min(max(fraction, 0), 1), fraction > 0 ? 3 : 0))
            }
        }
        .frame(height: 4)
        .frame(maxWidth: .infinity)
    }
}
