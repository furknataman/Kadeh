//
//  PlaytimeView.swift
//  Whisky
//
//  This file is part of Whisky.
//
//  Whisky is free software: you can redistribute it and/or modify it under the terms
//  of the GNU General Public License as published by the Free Software Foundation,
//  either version 3 of the License, or (at your option) any later version.
//
//  Whisky is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY;
//  without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.
//  See the GNU General Public License for more details.
//
//  You should have received a copy of the GNU General Public License along with Whisky.
//  If not, see https://www.gnu.org/licenses/.
//

import Charts
import SwiftUI
import WhiskyKit

/// How much has been played: this week and month, the last eight weeks, and
/// every game by its total.
///
/// The week-by-week part can only show what Kadeh itself watched, since
/// Steam keeps no such history anyone else can read. Totals are Steam's own
/// for Steam games, so they include play from before Kadeh and other PCs.
struct PlaytimeView: View {
    let entries: [LibraryEntry]
    let onOpenGame: (LibraryEntry) -> Void

    @State private var summary: PlaytimeSummary?

    init(entries: [LibraryEntry], onOpenGame: @escaping (LibraryEntry) -> Void) {
        self.entries = entries
        self.onOpenGame = onOpenGame
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                if let summary {
                    overview(summary)
                    gameList(summary)
                } else {
                    ProgressView()
                        .frame(maxWidth: .infinity, minHeight: 200)
                }
            }
            .padding(.horizontal, 32)
            .padding(.vertical, 24)
            .frame(maxWidth: 900, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("playtime.title")
        .task(id: entries.map(\.id)) { summary = await PlaytimeSummary.load(entries: entries) }
        .onReceive(NotificationCenter.default.publisher(for: .playtimeChanged)) { _ in
            Task { summary = await PlaytimeSummary.load(entries: entries) }
        }
    }

    // MARK: - This week, this month, the chart

    /// The two figures are always there, "0 dk." before anything was
    /// played; the chart needs history, and a line explains its absence.
    private func overview(_ summary: PlaytimeSummary) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 40) {
                    StatNumber(title: "playtime.thisWeek", seconds: summary.thisWeek)
                    StatNumber(title: "playtime.thisMonth", seconds: summary.thisMonth)
                }
                Text("playtime.countedNote")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            if summary.hasHistory {
                WeeklyChart(weeks: summary.weeks)
                    .frame(height: 170)
            } else {
                Label {
                    Text("playtime.noHistory")
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "chart.bar")
                        .foregroundStyle(.secondary)
                }
                .foregroundStyle(.secondary)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    // MARK: - Games by total

    @ViewBuilder
    private func gameList(_ summary: PlaytimeSummary) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("playtime.games")
                .font(.title3.weight(.semibold))
                .accessibilityAddTraits(.isHeader)

            if summary.games.isEmpty {
                Text("playtime.noGames")
                    .foregroundStyle(.secondary)
            } else {
                VStack(spacing: 2) {
                    ForEach(summary.games) { game in
                        PlaytimeGameRow(game: game, longest: summary.longest) {
                            onOpenGame(game.entry)
                        }
                    }
                }
                if summary.games.contains(where: \.isSteam) {
                    Text("playtime.steamNote")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(.top, 4)
                }
            }
        }
    }
}

/// A big number with its label above it.
private struct StatNumber: View {
    let title: LocalizedStringKey
    let seconds: TimeInterval

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text(PlaytimeFormat.short(seconds))
                .font(.system(size: 30, weight: .semibold, design: .rounded))
                .monospacedDigit()
        }
        .accessibilityElement(children: .combine)
    }
}

/// The last eight weeks, one bar each, this week emphasized.
private struct WeeklyChart: View {
    let weeks: [PlayHistoryStats.Week]
    @State private var selected: Date?

    private var current: Date? { weeks.last?.start }

    var body: some View {
        Chart(weeks) { week in
            BarMark(
                x: .value("playtime.chart.week", week.start, unit: .weekOfYear),
                y: .value("playtime.chart.hours", week.seconds / 3_600),
                width: .ratio(0.55)
            )
            .cornerRadius(4, style: .continuous)
            .foregroundStyle(Color.accentColor.opacity(barOpacity(for: week)))
            .accessibilityLabel(PlaytimePageFormat.week(week.start))
            .accessibilityValue(PlaytimeFormat.short(week.seconds))

            if let selected, selected == week.start {
                RuleMark(x: .value("playtime.chart.week", week.start, unit: .weekOfYear))
                    .foregroundStyle(.clear)
                    .annotation(position: .top, overflowResolution: .init(x: .fit, y: .disabled)) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(PlaytimePageFormat.week(week.start))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(PlaytimeFormat.short(week.seconds))
                                .font(.callout.weight(.semibold))
                                .monospacedDigit()
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
                    }
            }
        }
        .chartXSelection(value: Binding(
            get: { selected },
            set: { date in selected = date.flatMap(weekStart(containing:)) }
        ))
        .chartXAxis {
            AxisMarks(values: weeks.map(\.start)) { value in
                AxisValueLabel(centered: true) {
                    if let date = value.as(Date.self) {
                        Text(
                            date == current
                                ? String(localized: "playtime.chart.thisWeek") : PlaytimePageFormat.day(date)
                        )
                    }
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { value in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                    .foregroundStyle(.secondary.opacity(0.35))
                AxisValueLabel {
                    if let hours = value.as(Double.self) {
                        Text(PlaytimePageFormat.hoursAxis(hours))
                    }
                }
            }
        }
        .accessibilityLabel(Text("playtime.chart.accessibility"))
    }

    private func barOpacity(for week: PlayHistoryStats.Week) -> Double {
        if let selected { return week.start == selected ? 1 : 0.4 }
        return week.start == current ? 1 : 0.55
    }

    private func weekStart(containing date: Date) -> Date? {
        weeks.last { $0.start <= date }?.start
    }
}

/// One game: its cover, name, last played, total, and a bar for its share.
private struct PlaytimeGameRow: View {
    let game: PlaytimeSummary.Game
    let longest: TimeInterval
    let open: () -> Void

    @State private var cover: Image?
    @State private var isHovering = false

    var body: some View {
        Button(action: open) {
            HStack(spacing: 14) {
                coverView
                VStack(alignment: .leading, spacing: 5) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(game.entry.name)
                            .font(.body.weight(.medium))
                            .lineLimit(1)
                        Spacer(minLength: 12)
                        Text(PlaytimeFormat.short(game.seconds))
                            .font(.body.weight(.semibold))
                            .monospacedDigit()
                    }
                    ProportionBar(fraction: longest > 0 ? game.seconds / longest : 0)
                    if let lastPlayed = game.lastPlayed {
                        Text("playtime.lastPlayed \(PlaytimeText.relative(lastPlayed))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isHovering ? Color.primary.opacity(0.06) : .clear)
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(game.entry.name))
        .accessibilityValue(accessibilityValue)
        .accessibilityHint(Text("playtime.row.hint"))
        .accessibilityAddTraits(.isButton)
        .task(id: game.entry.id) { await loadCover() }
    }

    private var accessibilityValue: Text {
        let total = Text(PlaytimeText.full(game.seconds))
        guard let lastPlayed = game.lastPlayed else { return total }
        return total + Text(", ") + Text("playtime.lastPlayed \(PlaytimeText.relative(lastPlayed))")
    }

    /// Without art the cover is the executable's icon, shown whole.
    private var isIcon: Bool { game.entry.portraitURL == nil && game.entry.artworkURL == nil }

    @ViewBuilder
    private var coverView: some View {
        let shape = RoundedRectangle(cornerRadius: 5, style: .continuous)
        ZStack {
            shape.fill(Color.secondary.opacity(0.15))
            if let cover {
                cover
                    .resizable()
                    .aspectRatio(contentMode: isIcon ? .fit : .fill)
                    .padding(isIcon ? 6 : 0)
            } else {
                Image(systemName: "gamecontroller")
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 40, height: 60)
        .clipShape(shape)
        .accessibilityHidden(true)
    }

    private func loadCover() async {
        if let url = game.entry.portraitURL ?? game.entry.artworkURL,
           let sampled = await IconCache.shared.sampledArtwork(for: url) {
            cover = Image(nsImage: sampled.image)
        } else if let iconURL = game.entry.iconURL {
            cover = Image(nsImage: await IconCache.shared.sampledIcon(for: iconURL).image)
        }
    }
}

/// A thin track with a filled part for one game's share of the longest.
private struct ProportionBar: View {
    let fraction: Double

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.15))
                Capsule()
                    .fill(Color.accentColor)
                    .frame(width: max(4, proxy.size.width * min(max(fraction, 0), 1)))
            }
        }
        .frame(height: 4)
        .accessibilityHidden(true)
    }
}

// MARK: - Data

/// Everything the page shows, read off the main thread in one go.
struct PlaytimeSummary: Sendable {
    struct Game: Identifiable, Sendable {
        let entry: LibraryEntry
        let seconds: TimeInterval
        let lastPlayed: Date?
        var id: String { entry.id }
        var isSteam: Bool {
            if case .steam = entry.launch { return true }
            return false
        }
    }

    let hasHistory: Bool
    let thisWeek: TimeInterval
    let thisMonth: TimeInterval
    let weeks: [PlayHistoryStats.Week]
    let games: [Game]

    var longest: TimeInterval { games.first?.seconds ?? 0 }

    static func load(entries: [LibraryEntry]) async -> PlaytimeSummary {
        await Task.detached(priority: .userInitiated) {
            let history = PlayHistoryStore().sessions()
            let counted = PlaytimeStore().all()
            var steam: [URL: [Int: SteamPlayRecord]] = [:]
            for bottle in Set(entries.map(\.bottleURL)) {
                steam[bottle] = SteamPlaytimeReader.records(inBottleAt: bottle)
            }
            let lastSession = Dictionary(
                history.map { ($0.entryID, $0.end) }, uniquingKeysWith: { max($0, $1) }
            )
            let games = entries
                .filter { !$0.isLauncher }
                .compactMap { entry -> Game? in
                    let played = Playtime.combined(for: entry, steam: steam[entry.bottleURL] ?? [:], counted: counted)
                    guard let played, played.seconds >= 60 else { return nil }
                    let last = [played.lastPlayed, lastSession[entry.id]].compactMap { $0 }.max()
                    return Game(entry: entry, seconds: played.seconds, lastPlayed: last)
                }
                .sorted { $0.seconds > $1.seconds }
            return PlaytimeSummary(
                hasHistory: !history.isEmpty,
                thisWeek: PlayHistoryStats.seconds(of: history, inCurrent: .weekOfYear),
                thisMonth: PlayHistoryStats.seconds(of: history, inCurrent: .month),
                weeks: PlayHistoryStats.weeks(of: history, count: 8),
                games: games
            )
        }.value
    }
}

/// The chart's wordings, on Apple's formatters so the units are the
/// system's ("sa." in Turkish). Durations use WhiskyKit's ``PlaytimeFormat``.
enum PlaytimePageFormat {
    /// An axis tick: "2 sa.".
    static func hoursAxis(_ hours: Double) -> String {
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .short
        formatter.allowedUnits = [.hour]
        formatter.zeroFormattingBehavior = .default
        return formatter.string(from: hours * 3_600) ?? ""
    }

    /// "13 Eki".
    static func day(_ date: Date) -> String {
        date.formatted(.dateTime.day().month(.abbreviated))
    }

    /// "13–19 Eki".
    static func week(_ start: Date) -> String {
        let formatter = DateIntervalFormatter()
        formatter.dateTemplate = "dMMM"
        let end = Calendar.current.date(byAdding: .day, value: 6, to: start) ?? start
        return formatter.string(from: start, to: end)
    }
}
