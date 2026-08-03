import SwiftUI
import ClaudeMonitorCore
import ClaudeMonitorShared

/// Die Kompaktanzeige in der Menüleiste: farbiger Punkt plus Prozentwert des
/// besten Accounts.
///
/// Zwei Zeichen plus Symbol — die Breite bleibt auch bei fünf und mehr Accounts
/// konstant, weil immer nur **ein** Account gezeigt wird.
struct MenuBarLabelView: View {

    let display: MenuBarDisplay

    var body: some View {
        HStack(spacing: 3) {
            if let icon = MenuBarIcon.image(for: display.status) {
                Image(nsImage: icon)
            }
            if let text = display.text {
                // `verbatim`: bereits fertig formatierte Zahl, keine Übersetzung.
                Text(verbatim: text)
                    .font(.system(size: 12, weight: .medium))
                    .monospacedDigit()
            }
        }
        .accessibilityElement(children: .combine)
        // Ohne eigenes Label läse VoiceOver nur die Zahl und nichts über die
        // Farbe — die Ampel ist für sehende Nutzer die halbe Information. Ein
        // festes „Claude usage" wäre aber noch schlechter: Es überschriebe das
        // kombinierte Label und verschwiege Prozentwert **und** Farbe.
        .accessibilityLabel(accessibilityLabel)
    }

    private var accessibilityLabel: Text {
        guard let text = display.text else {
            return Text("Claude usage: no data")
        }
        return Text("Claude usage: \(text), \(statusDescription)")
    }

    /// Die Ampelstufe in Worten — die Farbe allein ist nicht vorlesbar.
    private var statusDescription: String {
        switch display.status {
        case .green: return String(localized: "normal")
        case .yellow: return String(localized: "elevated")
        case .red: return String(localized: "critical")
        case nil: return String(localized: "unknown")
        }
    }
}
