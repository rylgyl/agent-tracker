import SwiftUI

/// The popover panel, styled after the Claude Code `/usage` screen:
/// LIMITS (session + weekly bars), TOKENS BY DAY, TOKENS BY MODEL.
struct MenuView: View {
    @EnvironmentObject private var store: UsageStore

    private enum Style {
        static let background = Color(red: 0.13, green: 0.13, blue: 0.21)
        static let barTrack = Color.white.opacity(0.16)
        static let barFill = Color.white
        static let accent = Color(red: 0.85, green: 0.35, blue: 0.22) // Claude coral
        static let secondaryText = Color.white.opacity(0.55)
        static let width: CGFloat = 320
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            Divider().overlay(Style.barTrack)
            limitsSection
            Divider().overlay(Style.barTrack)
            tokensByDaySection
            Divider().overlay(Style.barTrack)
            tokensByModelSection
            if let error = store.errorMessage {
                Text(error)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.yellow)
                    .fixedSize(horizontal: false, vertical: true)
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

    // MARK: - Sections

    private var header: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "asterisk")
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(Style.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text("Claude Code")
                    .font(.system(size: 13, weight: .bold, design: .monospaced))
                if let plan = store.subscriptionType {
                    Text(plan)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(Style.secondaryText)
                }
            }
            Spacer()
        }
    }

    private var limitsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("LIMITS")
            if let session = store.limits?.session {
                limitRow(name: "Session", window: session)
            }
            if let weekly = store.limits?.weekly {
                limitRow(name: "Weekly", window: weekly)
            }
            if let opus = store.limits?.weeklyOpus, opus.utilization > 0 {
                limitRow(name: "Weekly (Opus)", window: opus)
            }
            if store.limits == nil {
                Text(store.isRefreshing ? "Loading…" : "No limit data")
                    .foregroundStyle(Style.secondaryText)
            }
        }
    }

    private func limitRow(name: String, window: LimitWindow) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(name)
                Spacer()
                Text(Format.percent(window.utilization))
            }
            bar(fraction: window.utilization / 100)
            Text(Format.resets(at: window.resetsAt))
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(Style.secondaryText)
        }
    }

    private var tokensByDaySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("TOKENS BY DAY")
            let maxTokens = max(store.localUsage.byDay.map(\.tokens).max() ?? 0, 1)
            ForEach(store.localUsage.byDay) { day in
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

    private var tokensByModelSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("TOKENS BY MODEL")
            if store.localUsage.byModel.isEmpty {
                Text("No usage in the last 7 days")
                    .foregroundStyle(Style.secondaryText)
            }
            let maxTokens = max(store.localUsage.byModel.map(\.tokens).max() ?? 0, 1)
            ForEach(store.localUsage.byModel) { model in
                HStack(spacing: 8) {
                    Text(model.model)
                        .frame(width: 80, alignment: .leading)
                        .lineLimit(1)
                    bar(fraction: Double(model.tokens) / Double(maxTokens))
                    Text(Format.tokens(model.tokens))
                        .frame(width: 56, alignment: .trailing)
                }
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
            .help("Refresh now")
            Button {
                NSApp.terminate(nil)
            } label: {
                Image(systemName: "power")
            }
            .buttonStyle(.plain)
            .help("Quit")
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
