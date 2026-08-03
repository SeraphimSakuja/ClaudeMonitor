import SwiftUI
import ClaudeMonitorShared

/// Hinweisfeld für die Fehlzustände der Datenquelle.
///
/// Jeder Fall erklärt, was zu tun ist — ein reines „Fehler" hilft niemandem.
struct IssueBannerView: View {

    let issue: MonitorIssue

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label { title.font(.callout.weight(.semibold)) } icon: { icon }
            explanation
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let detail {
                Text(verbatim: detail)
                    .font(.caption2)
                    .monospaced()
                    .foregroundStyle(.tertiary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    /// Symbol und Schweregrad kommen aus ``IssuePresentation`` in `Shared/` —
    /// dort sind sie geprüft. In der View wären sie es nicht.
    private var icon: some View {
        Image(systemName: IssuePresentation.symbolName(for: issue))
            .foregroundStyle(
                IssuePresentation.isSevere(issue)
                    ? Color(nsColor: .systemRed)
                    : Color(nsColor: .systemOrange)
            )
    }

    @ViewBuilder private var title: some View {
        switch issue {
        case .storeNotFound: Text("claude-swap not found")
        case .unsupportedSchema: Text("Unsupported data format")
        case .unreadable: Text("Cache not readable right now")
        }
    }

    @ViewBuilder private var explanation: some View {
        switch issue {
        case .storeNotFound:
            Text("ClaudeMonitor reads the local cache of claude-swap. Install claude-swap and let it run once.")
        case .unsupportedSchema:
            Text("The cache format of claude-swap has changed. Values stay hidden so that no wrong numbers are shown.")
        case .unreadable:
            Text("claude-swap is probably writing right now. This usually resolves itself with the next read.")
        }
    }

    /// Technische Details bleiben unübersetzt — sie sind Diagnosetext.
    private var detail: String? {
        switch issue {
        case .storeNotFound(let paths):
            return paths.isEmpty ? nil : paths.joined(separator: "\n")
        case .unsupportedSchema(let found, let expected):
            return "schemaVersion \(found.map(String.init) ?? "?") ≠ \(expected)"
        case .unreadable(let reason):
            return reason
        }
    }
}
