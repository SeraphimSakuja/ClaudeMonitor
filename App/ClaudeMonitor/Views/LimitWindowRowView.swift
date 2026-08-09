import SwiftUI
import ClaudeMonitorCore
import ClaudeMonitorShared

/// Ein Limitfenster in **einer** Zeile: Name, Balken, Prozent, Restzeit.
///
/// Bis v1.0 waren es drei Zeilen (Name+Prozent, Balken, Reset). Bei drei
/// Accounts war das Detailfenster damit über 500 px hoch und musste scrollen,
/// obwohl kaum Information dastand — die dritte Zeile lautete beim
/// 5-Stunden-Fenster regelmäßig „Reset-Zeitpunkt unbekannt".
///
/// Die Spaltenbreiten sind **fest**, damit die Balken aller Fenster
/// untereinander bündig stehen. Ohne das richtete sich jede Zeile nach der
/// Länge ihres eigenen Namens aus, und die Karte sähe zerfranst aus.
struct LimitWindowRowView: View {

    let window: LimitWindow
    /// Bezugszeitpunkt für die Restzeit. Kommt vom Sekunden-Ticker des
    /// Kärtchens, damit der Umschlag auf „Reset fällig" nicht bis zum nächsten
    /// `body`-Aufruf wartet.
    let now: Date

    /// Reicht für „5 Stunden" und „7 Tage" in beiden Sprachen; längere
    /// `scoped`-Namen werden gekürzt statt die Spalte zu sprengen.
    private let nameWidth: CGFloat = 62
    private let percentWidth: CGFloat = 36
    private let resetWidth: CGFloat = 48

    var body: some View {
        HStack(spacing: 6) {
            windowName
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(width: nameWidth, alignment: .leading)

            ProgressView(value: PercentFormatting.fraction(window.percent) ?? 0)
                .progressViewStyle(.linear)
                .tint(StatusAppearance.color(for: window.status))

            if let text = PercentFormatting.compact(window.percent) {
                Text(verbatim: text)
                    .font(.caption.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(StatusAppearance.color(for: window.status))
                    .frame(width: percentWidth, alignment: .trailing)
            } else {
                Color.clear.frame(width: percentWidth, height: 0)
            }

            resetColumn
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .frame(width: resetWidth, alignment: .trailing)
        }
        // Der genaue Zeitpunkt ist aus der Zeile gewichen, nicht aus der App:
        // Er steht jetzt im Tooltip. Die Restzeit beantwortet die Frage „wie
        // lange noch", der Zeitpunkt nur „wann genau" — und danach fragt man
        // selten genug, um dafür zu zeigen.
        .help(tooltip)
    }

    /// Die Abbildung auf den Anzeigenamen liegt in ``WindowKindNaming`` und
    /// nicht hier: Der Vorlesetext der Menüleiste braucht denselben Namen.
    /// `verbatim`, weil der String bereits aufgelöst ist.
    private var windowName: Text {
        Text(verbatim: WindowKindNaming.name(for: window.kind))
    }

    /// Restzeit, grob und schmal — dasselbe Format wie in der Menüleiste
    /// (``ResetCountdownFormat``), damit beide Anzeigen nicht auseinanderlaufen.
    ///
    /// Ohne bekannten Reset steht hier **nichts**. Ein „Reset-Zeitpunkt
    /// unbekannt" kostete eine volle Zeile und sagte nichts, was das Fehlen der
    /// Angabe nicht selbst sagt.
    ///
    /// Ein überfälliger Reset zeigt „fällig" und **nie** einen negativen
    /// Countdown — das ist ein Pflicht-Zustand der Spezifikation, nur kürzer
    /// gesetzt als früher.
    @ViewBuilder private var resetColumn: some View {
        switch ResetDisplay.make(for: window, now: now) {
        case .unknown:
            EmptyView()
        case .due:
            Text("due")
        case .counting(let until):
            if let text = ResetCountdownFormat.text(for: .remaining(until.timeIntervalSince(now))) {
                Text(verbatim: text)
            }
        }
    }

    /// Genauer Reset-Zeitpunkt für den Tooltip; leer, wenn keiner bekannt ist.
    private var tooltip: Text {
        guard let resetsAt = window.resetsAt else { return Text(verbatim: "") }
        return Text("Resets at \(resetsAt, format: .dateTime.weekday(.abbreviated).hour().minute())")
    }
}
