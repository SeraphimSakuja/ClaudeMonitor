import SwiftUI
import ClaudeMonitorCore
import ClaudeMonitorShared

/// Eine Zeile pro Limitfenster: Name, Auslastung, Fortschritt, Reset.
struct LimitWindowRowView: View {

    let window: LimitWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline) {
                windowName
                    .font(.callout)
                Spacer(minLength: 8)
                if let text = PercentFormatting.compact(window.percent) {
                    Text(verbatim: text)
                        .font(.callout.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(StatusAppearance.color(for: window.status))
                }
            }

            ProgressView(value: PercentFormatting.fraction(window.percent) ?? 0)
                .progressViewStyle(.linear)
                .tint(StatusAppearance.color(for: window.status))

            resetLine
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// Bekannte Fenstertypen bekommen einen übersetzten Namen; alles andere
    /// wird wörtlich aus der Quelle übernommen, statt es zu verschlucken.
    @ViewBuilder private var windowName: some View {
        switch window.kind {
        case .fiveHour: Text("5 hours")
        case .sevenDay: Text("7 days")
        case .spend: Text("Spend")
        case .scoped(let name): Text(verbatim: name)
        case .other(let rawKey): Text(verbatim: rawKey)
        }
    }

    /// Restzeit läuft live gegen das Reset-Datum — kein zum Anzeigezeitpunkt
    /// eingefrorener String, und nie ein negativer Countdown.
    @ViewBuilder private var resetLine: some View {
        switch ResetDisplay.make(for: window) {
        case .unknown:
            Text("Reset time unknown")
        case .due:
            Text("Reset due")
        case .counting(let until):
            HStack(spacing: 4) {
                Text("Resets in \(until, style: .timer)")
                    .monospacedDigit()
                Text(verbatim: "·")
                Text(until, format: .dateTime.weekday(.abbreviated).hour().minute())
            }
        }
    }
}
