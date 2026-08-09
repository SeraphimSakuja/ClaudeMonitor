import SwiftUI
import ClaudeMonitorCore
import ClaudeMonitorShared

/// Eine Zeile pro Limitfenster: Name, Auslastung, Fortschritt, Reset.
struct LimitWindowRowView: View {

    let window: LimitWindow
    /// Bezugszeitpunkt für die Restzeit. Kommt vom Sekunden-Ticker des
    /// Kärtchens, damit der Umschlag auf „Reset fällig" nicht bis zum nächsten
    /// `body`-Aufruf wartet.
    let now: Date

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

            spendLine

            resetLine
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// Beim Ausgabenfenster die echten Beträge — „12,34 $ von 50,00 $".
    ///
    /// Nur dort: Alle anderen Fenster zählen Anfragen, keine Währung. Die
    /// Zahlen selbst formatiert ``SpendAmountDisplay`` in `Shared/`, damit die
    /// Fehlfälle (fehlende Währung, Limit null, kaputte Werte) geprüft sind;
    /// hier steht nur der Satzbau, weil der in den Sprachkatalog gehört.
    @ViewBuilder private var spendLine: some View {
        if let spend = window.spend, let amounts = SpendAmountDisplay.amounts(for: spend) {
            Group {
                if let limit = amounts.limit {
                    Text("\(amounts.used) of \(limit)")
                } else {
                    Text(verbatim: amounts.used)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .monospacedDigit()
        }
    }

    /// Die Abbildung auf den Anzeigenamen liegt in ``WindowKindNaming`` und
    /// nicht hier: Der Vorlesetext der Menüleiste braucht denselben Namen.
    /// `verbatim`, weil der String bereits aufgelöst ist.
    private var windowName: Text {
        Text(verbatim: WindowKindNaming.name(for: window.kind))
    }

    /// Restzeit läuft live gegen das Reset-Datum — kein zum Anzeigezeitpunkt
    /// eingefrorener String, und nie ein negativer Countdown.
    @ViewBuilder private var resetLine: some View {
        switch ResetDisplay.make(for: window, now: now) {
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
