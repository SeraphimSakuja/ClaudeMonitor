import SwiftUI
import ClaudeMonitorCore
import ClaudeMonitorShared

/// Das Detailfenster hinter dem Menüleisten-Symbol.
///
/// Zeigt alle Accounts mit allen Limitfenstern, den besten zuoberst. Die
/// Reihenfolge kommt aus ``AccountRanking``; hier wird nichts umsortiert.
struct MonitorPopoverView: View {

    @EnvironmentObject private var monitor: UsageMonitor

    /// Dieselbe Einstellung, die ``MenuBarLabelView`` liest — bewusst als
    /// `String`, damit die Umschlüsselung unbekannter Werte an genau einer
    /// Stelle sitzt (``MenuBarMode/init(storedValue:)``). Eine `Settings`-Scene
    /// gibt es nicht: Eine reine Menüleisten-App (`LSUIElement`) müsste sich
    /// dafür erst aktivieren.
    @AppStorage("menuBarMode") private var rawMode: String = MenuBarMode.bestAccount.rawValue

    /// Das Anmeldeobjekt. `@StateObject` und nicht `@ObservedObject`: Anders als
    /// der Monitor hängt es an keinem App-weiten Lebenszyklus — es fragt nur das
    /// System und besitzt keinen laufenden Poller.
    @StateObject private var loginItem = LoginItemController()

    /// Ab dieser Höhe wird gescrollt — bei drei bis sechs Accounts passt alles
    /// ohne Scrollen, darüber bleibt das Fenster handhabbar.
    private let maximumHeight: CGFloat = 460

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            Divider()
            content
            Divider()
            modeRow
            loginItemRow
            footer
        }
        .padding(12)
        .frame(width: 320)
        // Das Anmeldeobjekt lässt sich jederzeit außerhalb der App umschalten.
        // Beim Öffnen neu erfragen ist genau oft genug — ein Poller wäre für
        // eine Einstellung, die sich praktisch nie ändert, verschwendet.
        .onAppear { loginItem.refresh() }
    }

    private var header: some View {
        HStack {
            Text("ClaudeMonitor").font(.headline)
            Spacer()
            Button {
                Task { await monitor.refresh() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help(Text("Refresh now"))
            .accessibilityLabel(Text("Refresh now"))
        }
    }

    /// Welcher der vier Fälle gilt, entscheidet ``PopoverContent`` in
    /// `Shared/` — dort ist die Verzweigung geprüft. Hier wird sie nur
    /// gezeichnet. Insbesondere gibt es keinen Fall mehr, in dem unter einem
    /// Hinweisbalken ein leerer Scrollbereich stehen bleibt.
    @ViewBuilder private var content: some View {
        let state = monitor.state

        VStack(alignment: .leading, spacing: 10) {
            if let issue = state.issue {
                IssueBannerView(issue: issue)
            }

            switch PopoverContent.make(for: state) {
            case .issueOnly:
                // Der Hinweisbalken darüber erklärt die Lage bereits.
                EmptyView()
            case .loading:
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Loading…").foregroundStyle(.secondary)
                }
            case .empty:
                Text("No accounts in claude-swap")
                    .foregroundStyle(.secondary)
            case .accounts(let accounts):
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(accounts) { account in
                            AccountCardView(account: account)
                        }
                    }
                }
                .frame(maxHeight: maximumHeight)
                // Ohne Scrollbalken-Reserve springt das Fenster beim Erscheinen
                // der Leiste um.
                .scrollBounceBehavior(.basedOnSize)
            }
        }
    }

    /// Wie viele Accounts die Leiste zeigt. „Nur bester" bleibt der Standard:
    /// Drei Accounts mit je zwei Fenstern sind rund 36 Zeichen, und macOS
    /// kürzt bei Platzmangel wortlos von rechts.
    private var modeRow: some View {
        HStack(spacing: 8) {
            Text("Menu bar")
                .font(.caption)
                .foregroundStyle(.secondary)
            Picker(selection: $rawMode) {
                Text("Best account").tag(MenuBarMode.bestAccount.rawValue)
                Text("All accounts").tag(MenuBarMode.allAccounts.rawValue)
            } label: {
                Text("Menu bar")
            }
            .labelsHidden()
            .pickerStyle(.segmented)
        }
    }

    /// „Beim Anmelden starten" — mitsamt der beiden Zustände, in denen der
    /// Schalter allein nicht weiterhilft.
    ///
    /// Die Verzweigung entscheidet ``LoginItemState`` in `Shared/`; hier wird
    /// sie nur gezeichnet. Ohne die beiden Erklärzeilen wäre der Schalter in
    /// genau den Fällen wortlos tot, in denen der Nutzer eine Erklärung
    /// braucht: gesperrt in den Systemeinstellungen, oder App noch nicht in
    /// `/Programme`.
    private var loginItemRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle(isOn: Binding(
                get: { loginItem.state.isOn },
                set: { loginItem.setEnabled($0) }
            )) {
                Text("Start at login").font(.caption)
            }
            .toggleStyle(.switch)
            .controlSize(.mini)
            .disabled(!loginItem.state.isToggleable)

            if loginItem.state.needsSystemSettings {
                Button {
                    loginItem.openSystemSettings()
                } label: {
                    Text("Blocked in System Settings — open them")
                        .font(.caption2)
                }
                .buttonStyle(.link)
            } else if loginItem.state.needsRelocation {
                Text("Move ClaudeMonitor to the Applications folder first.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else if let failure = loginItem.lastFailure {
                // `verbatim`: Der Text kommt vom System, ist bereits übersetzt
                // und darf nicht als Lokalisierungsschlüssel behandelt werden.
                Text(verbatim: failure)
                    .font(.caption2)
                    .foregroundStyle(.red)
            }
        }
    }

    private var footer: some View {
        HStack {
            if let capturedAt = monitor.state.snapshot?.capturedAt {
                Text("Checked \(capturedAt, style: .relative) ago")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            // Eine reine Menüleisten-App (LSUIElement) hat kein Programm-Menü;
            // ohne diesen Knopf käme man nicht mehr heraus.
            Button {
                NSApplication.shared.terminate(nil)
            } label: {
                Text("Quit")
            }
            .keyboardShortcut("q")
        }
    }
}
