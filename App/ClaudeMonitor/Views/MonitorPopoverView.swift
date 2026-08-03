import SwiftUI
import ClaudeMonitorCore
import ClaudeMonitorShared

/// Das Detailfenster hinter dem Menüleisten-Symbol.
///
/// Zeigt alle Accounts mit allen Limitfenstern, den besten zuoberst. Die
/// Reihenfolge kommt aus ``AccountRanking``; hier wird nichts umsortiert.
struct MonitorPopoverView: View {

    @EnvironmentObject private var monitor: UsageMonitor

    /// Ab dieser Höhe wird gescrollt — bei drei bis sechs Accounts passt alles
    /// ohne Scrollen, darüber bleibt das Fenster handhabbar.
    private let maximumHeight: CGFloat = 460

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .padding(12)
        .frame(width: 320)
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
