import SwiftUI
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
        .accessibilityLabel(Text("Claude usage"))
    }
}
