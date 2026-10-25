import CryptoKit
import SwiftUI

/// Which tool the panel is showing. Persisted so the menu bar icon and the
/// panel agree, and so the choice survives a relaunch.
enum MenuTab: String, CaseIterable, Identifiable {
    case claude = "Claude"
    case codex = "Codex"
    case grok = "Grok"

    static let storageKey = "selectedTab"

    var id: String { rawValue }

    /// SF Symbol for the menu bar and header. Grok is drawn with `GrokMark`.
    var symbolName: String? {
        switch self {
        case .claude: return "asterisk"
        case .codex: return "chevron.left.forwardslash.chevron.right"
        case .grok: return nil
        }
    }

    var title: String {
        switch self {
        case .claude: return "Claude Code"
        case .codex: return "Codex"
        case .grok: return "Grok"
        }
    }
}

/// Which platforms the panel lists. Stored as a comma-separated list of tab
/// names. An empty or unrecognized value falls back to every platform, and a
/// toggle that would hide the last one is ignored.
struct VisiblePlatforms: RawRepresentable, Equatable {
    var tabs: Set<MenuTab>

    static let storageKey = "visiblePlatforms"
    static let all = VisiblePlatforms(tabs: Set(MenuTab.allCases))

    /// `MenuTab.allCases` order, so the tab bar and the saved string stay stable.
    var ordered: [MenuTab] {
        MenuTab.allCases.filter { tabs.contains($0) }
    }

    func contains(_ tab: MenuTab) -> Bool {
        tabs.contains(tab)
    }

    /// The tab to show when `tab` has been hidden.
    func selecting(_ tab: MenuTab) -> MenuTab {
        if tabs.contains(tab) { return tab }
        return ordered.first ?? .claude
    }

    func toggling(_ tab: MenuTab) -> VisiblePlatforms {
        var next = tabs
        if next.contains(tab) {
            guard next.count > 1 else { return self }
            next.remove(tab)
        } else {
            next.insert(tab)
        }
        return VisiblePlatforms(tabs: next)
    }

    var rawValue: String {
        ordered.map(\.rawValue).joined(separator: ",")
    }

    init(tabs: Set<MenuTab>) {
        self.tabs = tabs.isEmpty ? Set(MenuTab.allCases) : tabs
    }

    init?(rawValue: String) {
        let parsed = Set(
            rawValue.split(separator: ",").compactMap { MenuTab(rawValue: String($0)) }
        )
        guard !parsed.isEmpty else { return nil }
        tabs = parsed
    }
}

/// The popover panel, styled after the Claude Code `/usage` screen:
/// LIMITS (session + weekly bars), TOKENS BY DAY, TOKENS BY MODEL.
/// Three tabs: Claude (usage API + local logs), Codex (local logs only),
/// and Grok (weekly pool split by product).
struct MenuView: View {
    @EnvironmentObject private var store: UsageStore
    @AppStorage(MenuTab.storageKey) private var tab: MenuTab = .claude
    @AppStorage(VisiblePlatforms.storageKey) private var visible = VisiblePlatforms.all
    @State private var choosingPlatforms = false

    /// The open platform, redirected when the saved one is currently hidden.
    private var shown: MenuTab { visible.selecting(tab) }

    private enum Style {
        static let background = Color(red: 0.13, green: 0.13, blue: 0.21)
        static let barTrack = Color.white.opacity(0.16)
        static let barFill = Color.white
        static let claudeAccent = Color(red: 0.85, green: 0.35, blue: 0.22) // Claude coral
        static let codexAccent = Color(red: 0.36, green: 0.76, blue: 0.66) // Codex teal
        static let grokAccent = Color(red: 0.36, green: 0.55, blue: 0.98) // Usage-screen blue
        static let secondaryText = Color.white.opacity(0.55)
        static let width: CGFloat = 320

        static func accent(for tab: MenuTab) -> Color {
            switch tab {
            case .claude: return claudeAccent
            case .codex: return codexAccent
            case .grok: return grokAccent
            }
        }

        /// Segment colors for the weekly pool, stable per product name.
        static func productColor(_ name: String) -> Color {
            switch name {
            case "Chat": return Color(red: 0.32, green: 0.52, blue: 0.98)
            case "Imagine": return Color(red: 0.48, green: 0.66, blue: 1.0)
            case "Build": return Color(red: 0.38, green: 0.78, blue: 0.96)
            case "Voice": return Color(red: 0.62, green: 0.76, blue: 0.98)
            case "API": return Color(red: 0.72, green: 0.80, blue: 0.98)
            case "Bot": return Color(red: 0.42, green: 0.64, blue: 0.86)
            case "Cursor": return Color(red: 0.78, green: 0.84, blue: 0.96)
            default: return Color.white.opacity(0.75)
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

    private var planLabel: String? {
        switch shown {
        case .claude: return store.subscriptionType
        case .codex: return store.codexUsage.planType
        case .grok: return store.grokUsage.planType
        }
    }

    private var refreshHelp: String {
        if shown == .claude, store.isRateLimited {
            let when = store.rateLimitedUntil?.formatted(date: .omitted, time: .shortened) ?? "shortly"
            return "Claude limits rate limited until \(when)"
        }
        if shown == .grok, store.isGrokRateLimited {
            let when = store.grokRateLimitedUntil?.formatted(date: .omitted, time: .shortened) ?? "shortly"
            return "Grok usage rate limited until \(when)"
        }
        return "Refresh now"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            if visible.ordered.count > 1 {
                tabBar
            }
            if choosingPlatforms {
                platformChooser
            }
            Divider().overlay(Style.barTrack)
            switch shown {
            case .claude: claudeTab
            case .codex: codexTab
            case .grok: grokTab
            }
            footer
        }
        .padding(16)
        .frame(width: Style.width)
        .background(Style.background)
        .colorScheme(.dark)
        .font(.system(size: 12, design: .monospaced))
        .foregroundStyle(.white)
        .onAppear { tab = visible.selecting(tab) }
    }

    // MARK: - Chrome

    private var header: some View {
        HStack(alignment: .top, spacing: 8) {
            PlatformIcon(tab: shown)
                .foregroundStyle(Style.accent(for: shown))
            VStack(alignment: .leading, spacing: 2) {
                Text(shown.title)
                    .font(.system(size: 13, weight: .bold, design: .monospaced))
                if let plan = planLabel {
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
            ForEach(visible.ordered) { item in
                Button {
                    tab = item
                } label: {
                    Text(item.rawValue)
                        .font(.system(size: 11, weight: shown == item ? .bold : .regular,
                                      design: .monospaced))
                        .foregroundStyle(shown == item ? Color.white : Style.secondaryText)
                        .padding(.vertical, 4)
                        .frame(maxWidth: .infinity)
                        .background(
                            RoundedRectangle(cornerRadius: 5)
                                .fill(shown == item ? Style.accent(for: item).opacity(0.28) : Color.white.opacity(0.06))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 5)
                                .stroke(shown == item ? Style.accent(for: item) : Color.clear, lineWidth: 1)
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
                choosingPlatforms.toggle()
            } label: {
                Image(systemName: "slider.horizontal.3")
                    .padding(3)
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(choosingPlatforms ? Color.white.opacity(0.16) : Color.clear)
                    )
            }
            .buttonStyle(.plain)
            .help("Choose platforms")
            Button {
                store.refresh()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .opacity(store.isRefreshing ? 0.4 : 1)
            }
            .buttonStyle(.plain)
            .disabled(store.isRefreshing)
            .help(refreshHelp)
            Button {
                NSApp.terminate(nil)
            } label: {
                Image(systemName: "power")
            }
            .buttonStyle(.plain)
            .help("Quit")
        }
    }

    private var platformChooser: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("PLATFORMS")
            HStack(spacing: 6) {
                ForEach(MenuTab.allCases) { item in
                    let enabled = visible.contains(item)
                    Button {
                        let next = visible.toggling(item)
                        visible = next
                        tab = next.selecting(tab)
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: enabled ? "checkmark" : "circle")
                                .font(.system(size: 9, weight: .bold))
                            Text(item.rawValue)
                                .font(.system(size: 11, weight: enabled ? .bold : .regular,
                                              design: .monospaced))
                        }
                        .foregroundStyle(enabled ? Color.white : Style.secondaryText)
                        .padding(.vertical, 4)
                        .frame(maxWidth: .infinity)
                        .background(
                            RoundedRectangle(cornerRadius: 5)
                                .fill(enabled ? Style.accent(for: item).opacity(0.28) : Color.white.opacity(0.06))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 5)
                                .stroke(enabled ? Style.accent(for: item) : Color.clear, lineWidth: 1)
                        )
                    }
                    .buttonStyle(.plain)
                    .help(enabled && visible.ordered.count == 1
                          ? "At least one platform stays visible"
                          : (enabled ? "Hide \(item.rawValue)" : "Show \(item.rawValue)"))
                }
            }
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

    /// Weekly pool the way grok.com Settings → Usage draws it: one total,
    /// a segmented bar, and each product's share of that total.
    private var grokTab: some View {
        VStack(alignment: .leading, spacing: 16) {
            if !store.grokUsage.isSignedIn {
                Text(store.grokErrorMessage
                     ?? "No Grok CLI credentials found. Run `grok login` in a terminal.")
                    .foregroundStyle(Style.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    sectionTitle("WEEKLY LIMIT")
                    if let percent = store.grokUsage.weeklyPercent {
                        HStack {
                            Text("Weekly")
                            Spacer()
                            Text("\(Format.percent(percent)) of total")
                        }
                        splitBar(store.grokUsage.products, total: percent)
                        Text(Format.resets(at: store.grokUsage.resetsAt))
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(Style.secondaryText)
                    } else if store.grokUsage.resetsAt != nil {
                        Text(store.isRefreshing ? "Loading…" : "Usage not reported yet")
                            .foregroundStyle(Style.secondaryText)
                        Text(Format.resets(at: store.grokUsage.resetsAt))
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(Style.secondaryText)
                    } else {
                        Text(store.isRefreshing ? "Loading…" : "No limit data")
                            .foregroundStyle(Style.secondaryText)
                    }

                    if !store.grokUsage.products.isEmpty {
                        ForEach(store.grokUsage.products) { product in
                            HStack(spacing: 8) {
                                Circle()
                                    .fill(Style.productColor(product.name))
                                    .frame(width: 6, height: 6)
                                Text(product.name)
                                Spacer()
                                Text("\(Format.percent(product.usagePercent)) of total")
                                    .foregroundStyle(Style.secondaryText)
                            }
                        }
                    }
                }

                if let balance = store.grokUsage.extraCreditsUSD {
                    Divider().overlay(Style.barTrack)
                    VStack(alignment: .leading, spacing: 8) {
                        sectionTitle("EXTRA CREDITS")
                        HStack {
                            Text("Balance")
                            Spacer()
                            Text(Format.dollars(balance))
                        }
                    }
                }

                if let error = store.grokErrorMessage {
                    Text(error)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.yellow)
                        .fixedSize(horizontal: false, vertical: true)
                }
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

    /// One track for the weekly pool. Each product is a segment; the unused
    /// remainder stays the track color, matching the usage screen.
    private func splitBar(_ products: [GrokProductUsage], total: Double) -> some View {
        GeometryReader { geometry in
            let gap: CGFloat = products.count > 1 ? 2 : 0
            let gaps = gap * CGFloat(max(products.count - 1, 0))
            let usable = max(geometry.size.width - gaps, 0)
            ZStack(alignment: .leading) {
                Capsule().fill(Style.barTrack)
                HStack(spacing: gap) {
                    ForEach(products) { product in
                        let width = usable * CGFloat(min(max(product.usagePercent, 0), 100) / 100)
                        Capsule()
                            .fill(Style.productColor(product.name))
                            .frame(width: max(width, product.usagePercent > 0 ? 3 : 0))
                    }
                    if products.isEmpty, total > 0 {
                        Capsule()
                            .fill(Style.barFill)
                            .frame(width: max(usable * CGFloat(min(max(total, 0), 100) / 100), 3))
                    }
                }
            }
        }
        .frame(height: 6)
        .frame(maxWidth: .infinity)
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
