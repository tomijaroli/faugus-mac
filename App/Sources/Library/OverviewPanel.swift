import FaugusCore
import SwiftUI

/// The panel with the selected game's title, categories, playtime and last played date
/// (`build_overview_panel`, `update_overview_panel`).
struct OverviewPanel: View {
    let model: AppModel
    let game: Game
    let appearance: LibraryAppearance
    let width: CGFloat

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let t = model.translator
            let color = appearance.overviewColor
            let stats = stats(t, now: context.date)
            VStack(spacing: 0) {
                Text(game.title)
                    .font(.system(size: 56, weight: .bold))
                    .foregroundStyle(color)
                    .shadow(color: .black.opacity(0.6), radius: 3, y: 2)
                    .lineLimit(1)
                    .truncationMode(.tail)
                LinearGradient(
                    stops: [
                        .init(color: color.opacity(0), location: 0), .init(color: color, location: 0.25),
                        .init(color: color, location: 0.75), .init(color: color.opacity(0), location: 1),
                    ], startPoint: .leading, endPoint: .trailing
                )
                .frame(height: 3)
                .padding(.vertical, 20)
                HStack(spacing: 14) {
                    ForEach(Array(stats.enumerated()), id: \.offset) { index, text in
                        if index > 0 {
                            Text("•")
                        }
                        Text(text)
                    }
                }
                .font(.system(size: 22))
                .foregroundStyle(color)
                .shadow(color: .black.opacity(0.6), radius: 2, y: 1)
            }
            .frame(width: min(1200, max(240, width - 80)))
            .padding(.top, 20)
            .padding(.bottom, 10)
            .accessibilityElement(children: .combine)
        }
    }

    /// The visible stat lines, in order: categories, playtime, last played or playing for.
    private func stats(_ t: Translator, now: Date) -> [String] {
        var out: [String] = []
        let running = model.isRunning(game)
        let session = running ? model.playSession(for: game) : nil

        let seconds: Int = if running, let session, let start = session.start {
            session.baseline + Int(max(0, now.timeIntervalSince(start)))
        } else {
            model.playtimeSeconds(game)
        }
        let playtime = GameFormatting.playtimeDisplay(seconds: seconds, t)
        let categories = GameFormatting.categoryLine(game.categoryNames)

        if !categories.isEmpty {
            out.append(categories)
        }
        if let playtime {
            out.append(t.format("Playtime: {}", playtime))
        }

        if running {
            if let start = session?.start {
                out.append(t.format("Playing for: {}", GameFormatting.playingFor(start: start, now: now, t)))
            }
        } else {
            let last = GameFormatting.lastPlayed(iso: game.lastPlayed, now: now, t)
            if let last {
                out.append(t.format("Last played: {}", last))
            } else if playtime == nil {
                out.append(t("Never played"))
            }
        }
        return out
    }
}
