import SwiftUI
import ClaudeMonitorCore
import ClaudeMonitorShared

/// Ein Account im Detailfenster: Name, Zustand, alle Limitfenster.
struct AccountCardView: View {

    let account: MonitoredAccount

    private var statusLine: AccountStatusLine { AccountStatusLine.make(for: account) }
    private var display: MenuBarDisplay { MenuBarDisplay.make(for: account) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header

            if statusLine.isWarning {
                statusText
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if account.windows.isEmpty {
                Text("No limit windows reported")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(account.windows) { window in
                    LimitWindowRowView(window: window)
                }
            }

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
            Text(verbatim: account.displayName)
                .font(.headline)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            if let text = display.text {
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

    @ViewBuilder private var statusText: some View {
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
        case .stale:
            Label("Data is outdated", systemImage: "clock.arrow.circlepath")
        }
    }
}
