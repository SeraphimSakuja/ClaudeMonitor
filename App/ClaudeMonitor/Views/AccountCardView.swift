import SwiftUI
import ClaudeMonitorCore
import ClaudeMonitorShared

/// Ein Account im Detailfenster: Name, Zustand, alle Limitfenster.
struct AccountCardView: View {

    let account: MonitoredAccount

    var body: some View {
        // Sekundentakt: Restzeiten und der Umschlag „läuft noch" → „Reset
        // fällig" hängen an `now`. Ohne Ticker wären sie nur so frisch wie der
        // letzte `body`-Aufruf — das Fenster zeigte dann zeitweise „Resets in
        // 0:12", obwohl der Reset längst fällig ist.
        TimelineView(.periodic(from: .now, by: 1)) { context in
            card(now: context.date)
        }
    }

    private func card(now: Date) -> some View {
        let statusLine = AccountStatusLine.make(for: account, now: now)

        return VStack(alignment: .leading, spacing: 8) {
            header

            if statusLine.isWarning {
                statusText(statusLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            windows(now: now)

            if let fetchedAt = account.fetchedAt {
                Text("Updated \(fetchedAt, style: .relative) ago")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var header: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(account.overallStatus.map(StatusAppearance.color(for:)) ?? StatusAppearance.neutral)
                .frame(width: 8, height: 8)
            // Dieselbe Markierung wie in der Menüleiste — Zeichen statt Farbe:
            // Farbe trägt hier ausschließlich die Ampel, und der Punkt steht
            // unmittelbar daneben. Der Vorlesetext hängt am Zeichen selbst,
            // damit VoiceOver die Auszeichnung nicht verschluckt.
            if account.isActive {
                Text(verbatim: ActiveAccountDisplay.marker)
                    .font(.headline)
                    .accessibilityLabel(Text("Active"))
            }
            Text(verbatim: account.displayName)
                .font(.headline)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            if let text = AccountBindingDisplay.make(for: account).text {
                Text(verbatim: text)
                    .font(.headline)
                    .monospacedDigit()
            } else {
                // Kein Wert heißt kein Wert — hier steht bewusst nie „0 %".
                Text(verbatim: "–")
                    .font(.headline)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// Fensterzeilen nur, wenn es verwertbare Zahlen gibt. Die Entscheidung
    /// trifft ``AccountWindowsDisplay`` in `Shared/` — ein toter Token darf
    /// nicht unter einem „–" seine eingefrorenen Altwerte als
    /// Fortschrittsbalken weiterzeigen.
    @ViewBuilder private func windows(now: Date) -> some View {
        switch AccountWindowsDisplay.make(for: account) {
        case .noUsableData:
            Text("No usable data")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .windows(let windows):
            ForEach(windows) { window in
                LimitWindowRowView(window: window, now: now)
            }
        }
    }

    @ViewBuilder private func statusText(_ statusLine: AccountStatusLine) -> some View {
        switch statusLine {
        case .upToDate:
            EmptyView()
        case .noData:
            Label("No data yet", systemImage: "clock.badge.questionmark")
        case .reLoginRequired:
            Label("Re-login required in claude-swap", systemImage: "person.badge.key")
        case .paused(let until):
            Label {
                Text("Paused, retrying in \(until, style: .timer)")
            } icon: {
                Image(systemName: "pause.circle")
            }
        case .fetchFailed:
            Label("Last fetch failed", systemImage: "exclamationmark.triangle")
        case .stale(let age):
            Label {
                // Die SSOT verlangt die Altersangabe — „veraltet" allein lässt
                // offen, ob es um Minuten oder um Tage geht.
                if let duration = DataAgeDisplay.duration(for: age) {
                    Text("Data is outdated: \(duration, format: .units(allowed: [.days, .hours, .minutes], width: .abbreviated))")
                } else {
                    Text("Data is outdated")
                }
            } icon: {
                Image(systemName: "clock.arrow.circlepath")
            }
        }
    }
}
