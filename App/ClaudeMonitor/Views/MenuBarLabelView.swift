import SwiftUI
import ClaudeMonitorCore
import ClaudeMonitorShared

/// Die Kompaktanzeige in der Menüleiste: je Account ein Punkt pro Limitfenster
/// (5 h und 7 d) mit eigener Farbe und eigener Zahl, Accounts durch `│` getrennt.
///
/// Wie viele Accounts gezeigt werden, entscheidet ``MenuBarMode``. Der
/// Modus wird **hier** gelesen und nicht im Poller: Eine Umschaltung muss
/// sofort wirken und darf nicht auf den nächsten 30-s-Durchlauf warten. Aus
/// demselben Grund bekommt diese View den Zustand und bildet ``MenuBarDisplay``
/// selbst — die Regeln dazu liegen geprüft in `Shared/`, hier wird nur gezeichnet.
struct MenuBarLabelView: View {

    let state: MonitorViewState

    /// Bewusst als `String` und nicht `RawRepresentable`: Sonst konvertierte
    /// SwiftUI selbst und ``MenuBarMode/init(storedValue:)`` — die einzige
    /// Stelle, die einen unbekannten Wert auf den Standard zurückholt — wäre
    /// toter Code. `UserDefaults.standard` genügt, weil nur die Menüleiste die
    /// Einstellung liest; damit hängt sie nicht an der App-Group.
    @AppStorage("menuBarMode") private var rawMode: String = MenuBarMode.bestAccount.rawValue

    private var mode: MenuBarMode { MenuBarMode(storedValue: rawMode) }

    var body: some View {
        let display = MenuBarDisplay.make(for: state, mode: mode)

        HStack(spacing: 3) {
            if display.segments.isEmpty {
                icon(for: nil)
            } else {
                ForEach(Array(display.segments.enumerated()), id: \.element.id) { index, segment in
                    if index > 0 {
                        // Ohne `foregroundStyle`: AppKit rendert das Label als
                        // Schablonenbild, eine gesetzte Farbe ginge verloren
                        // (siehe ``MenuBarIcon``). Abstufung über die Deckkraft.
                        Text(verbatim: "│").opacity(0.35)
                    }
                    ForEach(segment.values) { value in
                        point(value)
                    }
                }
            }
            if display.hasMoreAccounts {
                Text(verbatim: "…").opacity(0.6)
            }
        }
        // Ein `NSStatusItem` ist für VoiceOver **ein** Element; einzelne Punkte
        // wären ohnehin nicht einzeln fokussierbar.
        .accessibilityElement(children: .combine)
        // Ohne eigenes Label läse VoiceOver nur die Zahlen und nichts über die
        // Farben — die Ampel ist für sehende Nutzer die halbe Information.
        .accessibilityLabel(accessibilityLabel(for: display))
    }

    @ViewBuilder private func point(_ value: MenuBarDisplay.WindowValue) -> some View {
        HStack(spacing: 2) {
            icon(for: value.status)
            if let text = value.text {
                // `verbatim`: bereits fertig formatierte Zahl, keine Übersetzung.
                Text(verbatim: text)
                    .font(.system(size: 12, weight: .medium))
                    .monospacedDigit()
            }
        }
    }

    @ViewBuilder private func icon(for status: StatusLevel?) -> some View {
        if let image = MenuBarIcon.image(for: status) {
            Image(nsImage: image)
        }
    }

    // MARK: - Vorlesetext

    /// Im Modus „alle Accounts" je Account nur Name, bindender Wert und Stufe —
    /// die Einzelfenster stehen im Detailfenster. Im Modus „nur bester Account"
    /// beide Fenster, weil dort Platz für die vollständige Aussage ist. Der
    /// Zusatzpunkt (`spend`/`scoped`) wird in beiden Fällen mitgesprochen: im
    /// ersten als bindender Wert, im zweiten als eigener Eintrag.
    private func accessibilityLabel(for display: MenuBarDisplay) -> Text {
        guard !display.segments.isEmpty else { return Text("Claude usage: no data") }

        var parts: [String]
        switch mode {
        case .allAccounts:
            parts = display.segments.map { segment in
                spoken(name: segment.displayName, value: segment.binding)
            }
        case .bestAccount:
            parts = display.segments.flatMap { segment in
                [segment.displayName] + segment.values.map { value in
                    spoken(name: name(for: value.kind), value: value)
                }
            }
        }
        if display.hasMoreAccounts {
            parts.append(String(localized: "More accounts in the window"))
        }
        return Text(verbatim: parts.joined(separator: "; "))
    }

    /// „Name: 13 %, normal" — Bezeichnung, Wert, Ampelstufe in Worten.
    ///
    /// Ohne Zahl wird ausdrücklich „keine Daten" gesprochen und **nicht** der
    /// Strich aus der Leiste: Ein vorgelesenes „–" ist keine Aussage.
    private func spoken(name: String, value: MenuBarDisplay.WindowValue?) -> String {
        let text: String
        if case .percent = value?.reading, let number = value?.text {
            text = number
        } else {
            text = String(localized: "no data")
        }
        return String(
            format: String(localized: "%1$@: %2$@, %3$@", comment: "Menüleisten-Vorlesetext: Bezeichnung, Wert, Ampelstufe"),
            name,
            text,
            description(of: value?.status)
        )
    }

    /// Die Ampelstufe in Worten — die Farbe allein ist nicht vorlesbar.
    private func description(of status: StatusLevel?) -> String {
        switch status {
        case .green: return String(localized: "normal")
        case .yellow: return String(localized: "elevated")
        case .red: return String(localized: "critical")
        case nil: return String(localized: "unknown")
        }
    }

    /// Bezeichnung eines Limitfensters für den Vorlesetext. `scoped`- und
    /// unbekannte Fenster tragen Namen aus der Quelle — die sind nicht
    /// übersetzbar und werden deshalb unverändert gesprochen.
    private func name(for kind: LimitWindow.Kind) -> String {
        switch kind {
        case .fiveHour: return String(localized: "5 hours")
        case .sevenDay: return String(localized: "7 days")
        case .spend: return String(localized: "Spend")
        case .scoped(let name): return name
        case .other(let rawKey): return rawKey
        }
    }
}
