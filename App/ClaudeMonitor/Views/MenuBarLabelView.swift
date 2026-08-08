import SwiftUI
import ClaudeMonitorCore
import ClaudeMonitorShared

/// Die Kompaktanzeige in der Menüleiste: je Account ein Punkt pro Limitfenster
/// (5 h und 7 d) mit eigener Farbe und eigener Zahl, Accounts durch `│` getrennt.
///
/// Wie viele Accounts gezeigt werden, entscheidet ``MenuBarMode``. Modus und
/// Zustand kommen von außen; diese View bildet daraus ``MenuBarDisplay`` und
/// zeichnet — die Regeln dazu liegen geprüft in `Shared/`.
///
/// Der Modus wird ausdrücklich **nicht** hier per `@AppStorage` gelesen: Ein
/// `MenuBarExtra`-Label wertet seinen Rumpf bei einer reinen
/// `UserDefaults`-Änderung nicht neu aus, die Umschaltung blieb dann unsichtbar,
/// obwohl der Wert korrekt gespeichert war. Er ist deshalb Eigenschaft der Szene
/// (siehe ``ClaudeMonitorApp``).
struct MenuBarLabelView: View {

    let state: MonitorViewState
    let mode: MenuBarMode

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
                    spoken(name: WindowKindNaming.name(for: value.kind), value: value)
                }
            }
        }
        if display.hasMoreAccounts {
            parts.append(String(localized: "More accounts in the window"))
        }
        // Auch das Trennzeichen ist Sprache: Ein hartkodiertes „; " zwischen
        // lokalisierten Bausteinen wäre die einzige Stelle, die keine
        // Übersetzung bekäme.
        let separator = String(
            localized: "; ",
            comment: "Trennzeichen zwischen den Abschnitten des Menüleisten-Vorlesetexts"
        )
        return Text(verbatim: parts.joined(separator: separator))
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
            format: String(
                localized: "%1$@: %2$@, %3$@",
                comment: "Menüleisten-Vorlesetext: %1$@ = Bezeichnung (Account oder Limitfenster), %2$@ = Wert, %3$@ = Ampelstufe in Worten"
            ),
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
}
