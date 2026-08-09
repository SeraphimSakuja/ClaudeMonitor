import SwiftUI
import ClaudeMonitorCore
import ClaudeMonitorShared

/// Die Kompaktanzeige in der Menüleiste: je Account **ein** Ampelpunkt und
/// dahinter die beiden Zahlen `5h/7d`, Accounts nur durch Abstand getrennt —
/// `▸●74/28  ●97/11  ●0/28`. Der aktive Account trägt `▸` und fette Zahlen.
///
/// Wie viele Accounts gezeigt werden, entscheidet ``MenuBarMode``. Modus und
/// Zustand kommen von außen; diese View bildet daraus ``MenuBarDisplay`` und
/// gibt es an ``MenuBarImageRenderer`` — die Regeln dazu liegen geprüft in
/// `Shared/`, gezeichnet wird in AppKit.
///
/// **Warum ein einziges Bild und kein `HStack`:** Ein `NSStatusItem` hat genau
/// ein Bild und einen Titel. Mehrere `Image`/`Text` nebeneinander überleben die
/// Abbildung eines `MenuBarExtra`-Labels darauf nicht — am Gerät blieb von
/// sechs Werten nur `●74%` stehen. Der Vorlesetext hängt dagegen weiterhin am
/// Label und ist von der Zeichenweise unberührt.
///
/// Der Modus wird ausdrücklich **nicht** hier per `@AppStorage` gelesen: Ein
/// `MenuBarExtra`-Label wertet seinen Rumpf bei einer reinen
/// `UserDefaults`-Änderung nicht neu aus, die Umschaltung blieb dann unsichtbar,
/// obwohl der Wert korrekt gespeichert war. Er ist deshalb Eigenschaft der Szene
/// (siehe ``ClaudeMonitorApp``).
struct MenuBarLabelView: View {

    let state: MonitorViewState
    let mode: MenuBarMode

    /// Nötig, weil das Bild **kein** Schablonenbild ist und AppKit den Text
    /// deshalb nicht mehr selbst einfärbt: Der Zeichner braucht die passende
    /// Textfarbe, und das Lesen hier sorgt dafür, dass ein Wechsel hell↔dunkel
    /// den Rumpf überhaupt neu auswertet.
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let display = MenuBarDisplay.make(for: state, mode: mode)

        Group {
            if let image = MenuBarImageRenderer.image(for: display, colorScheme: colorScheme) {
                Image(nsImage: image)
            }
        }
        // Ein `NSStatusItem` ist für VoiceOver **ein** Element; einzelne Werte
        // wären ohnehin nicht einzeln fokussierbar.
        .accessibilityElement(children: .combine)
        // Ohne eigenes Label läse VoiceOver nur die Zahlen und nichts über die
        // Farben — die Ampel ist für sehende Nutzer die halbe Information.
        .accessibilityLabel(accessibilityLabel(for: display))
    }

    // MARK: - Vorlesetext

    /// Im Modus „Überblick" je Account Name, bindender Wert und
    /// **Account-Ampel** — die Einzelfenster stehen im Detailfenster. Im Modus
    /// „Aktiver" zusätzlich beide Fenster einzeln, weil dort Platz für die
    /// vollständige Aussage ist.
    ///
    /// Die Restzeit wird **mitgesprochen**, wo sie sichtbar ist: Sie ist die
    /// Antwort auf „wann kommt Kontingent zurück" und dürfte einem
    /// VoiceOver-Nutzer nicht allein deshalb fehlen, weil sie in der Leiste als
    /// kleine graue Zahl steht.
    ///
    /// Die gesprochene Stufe ist in beiden Fällen ``MenuBarDisplay/AccountSegment/status``
    /// und nicht die Stufe des genannten Fensters: Genau das ist die Zusage,
    /// die auch der Punkt trägt — ein zu 95 % erschöpftes Modellkontingent
    /// macht den Account kritisch, obwohl 5 h und 7 d entspannt sind. Käme die
    /// Stufe vom Fenster, verschwiege der Vorlesetext, was die Leiste zeigt.
    private func accessibilityLabel(for display: MenuBarDisplay) -> Text {
        guard !display.segments.isEmpty else { return Text("Claude usage: no data") }

        var parts: [String] = display.segments.flatMap { segment -> [String] in
            let summary = spoken(
                name: name(of: segment),
                value: segment.visibleBinding,
                status: segment.status
            )
            let reset = segment.resetText.map {
                [String(localized: "Resets in \($0)")]
            } ?? []

            switch mode {
            case .overview:
                return [summary] + reset
            case .activeAccount:
                return [summary] + segment.values.map { value in
                    spoken(
                        name: WindowKindNaming.name(for: value.kind),
                        value: value,
                        status: value.status
                    )
                } + reset
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

    /// Name des Accounts, beim aktiven um das Wort „aktiv" ergänzt.
    ///
    /// Die Markierung in der Leiste ist ein Zeichen (`▸`) und eine fette
    /// Schrift — beides ist nicht vorlesbar. Ohne diesen Zusatz ginge die
    /// Auskunft, welcher Account gerade aktiv ist, für VoiceOver verloren.
    private func name(of segment: MenuBarDisplay.AccountSegment) -> String {
        guard segment.isActive else { return segment.displayName }
        return String(
            format: String(
                localized: "%@ (active)",
                comment: "Vorlesetext: Name des in claude-swap aktiven Accounts"
            ),
            segment.displayName
        )
    }

    /// „Name: 13 %, normal" — Bezeichnung, Wert, Ampelstufe in Worten.
    ///
    /// Ohne Zahl wird ausdrücklich „keine Daten" gesprochen und **nicht** der
    /// Strich aus der Leiste: Ein vorgelesenes „–" ist keine Aussage.
    private func spoken(name: String, value: MenuBarDisplay.WindowValue?, status: StatusLevel?) -> String {
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
            description(of: status)
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
