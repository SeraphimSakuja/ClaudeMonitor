import Foundation
import ClaudeMonitorCore
import ClaudeMonitorShared

/// Alle Texte des Tray-Prozesses — **englisch, unlokalisiert**.
///
/// Das ist eine bewusste Abweichung von den beiden iOS-Apps und steht als
/// Kundenwirkung in der Spezifikation (§9.7): Ein `.xcstrings`-Katalog löst
/// gegen `Bundle.main` auf, und ein einzeln ausgeliefertes Linux-Binary hat
/// kein Bundle. Eine halbe Lokalisierung, die auf dem Zielsystem nie greift,
/// wäre schlechter als eine ehrliche einsprachige Oberfläche.
///
/// Warum die Texte hier und nicht in `Shared/` stehen: `Shared/` bekommt in
/// dieser Karte **null Diff**. Die drei Fehlzustands-Titel und -Erklärungen
/// sind zudem ohnehin neu — aus ``IssuePresentation`` wird nur ``isSevere``
/// übernommen, die `symbolName`-Seite liefert SF-Symbol-Namen
/// (`IssuePresentation.swift:12-18`), die auf GNOME keine Bedeutung haben
/// (Auflage 9, Fachentscheid 5.17). Kein einziger dieser Namen kommt in
/// `Linux/` vor — auch nicht zitiert, damit die Gegenprobe per `grep` sauber
/// null ergibt.
public enum TrayTexts {

    /// Produktname im Menükopf und als `Title` des Items.
    public static let applicationName = "ClaudeMonitor"

    /// Fassung des Tray-Prozesses.
    ///
    /// ⚠️ Von Hand geführt und **nicht** aus einem Bundle gelesen: Auf Linux
    /// gibt es keines. Die Marketing-Version der macOS-App steht im
    /// Xcode-Projekt, das diese Karte nicht anfasst (Null-Diff-Zusage). Die
    /// Zusammenführung beider Stellen gehört zur Paketierung (`CM-22`).
    public static let version = "1.0.2"

    /// Kopfzeile des Menüs: „ClaudeMonitor 1.0.2".
    ///
    /// Warum überhaupt (Auflage 8): Bei automatischen Updates ist die
    /// Versionszeile die einzige Stelle, an der Nutzer und Support feststellen
    /// können, welche Fassung läuft — auf macOS wie hier.
    public static var header: String { "\(applicationName) \(version)" }

    // MARK: - Aktionen

    public static let refresh = "Refresh now"
    public static let quit = "Quit"

    // MARK: - Inhaltsfälle des Detailfensters

    public static let loading = "Loading…"
    public static let noAccounts = "No accounts in claude-swap"
    public static let noUsableData = "No usable data"

    /// Globale Fußzeile („Checked … ago", `MonitorPopoverView.swift:284-288`).
    public static func checked(ago age: String) -> String { "Checked \(age) ago" }

    /// Fußzeile eines Kärtchens („Updated … ago", `AccountCardView.swift:38`).
    public static func updated(ago age: String) -> String { "Updated \(age) ago" }

    // MARK: - Fehlzustände (Auflage 9)

    /// Titel — Wortlaut wie `IssueBannerView.swift:45-48`, mit einem
    /// vorangestellten Ausrufezeichen bei schweren Fällen (``isSevere``).
    ///
    /// Warum überhaupt eine Kennzeichnung (Auflage 9): Das Menü ist reiner
    /// Text ohne Farbe — `IssueBannerView` unterscheidet schwer/leicht optisch
    /// über die Bannerfarbe, das hat hier keine Entsprechung. Ohne ein
    /// textliches Gegenstück sähen ein „Cache gerade nicht lesbar" (vergeht
    /// von selbst) und ein „nicht unterstütztes Format" (bleibt, bis
    /// aktualisiert wird) im Menü gleich dringend aus.
    public static func issueTitle(for issue: MonitorIssue) -> String {
        let prefix = isSevere(issue) ? "! " : ""
        switch issue {
        case .storeNotFound: return prefix + "claude-swap not found"
        case .unsupportedSchema: return prefix + "Unsupported data format"
        case .unreadable: return prefix + "Cache not readable right now"
        }
    }

    /// Erklärung — Wortlaut wie `IssueBannerView.swift:53-58`.
    public static func issueExplanation(for issue: MonitorIssue) -> String {
        switch issue {
        case .storeNotFound:
            return "ClaudeMonitor reads the local cache of claude-swap. "
                + "Install claude-swap and let it run once."
        case .unsupportedSchema:
            return "The cache format of claude-swap has changed. "
                + "Values stay hidden so that no wrong numbers are shown."
        case .unreadable:
            return "claude-swap is probably writing right now. "
                + "This usually resolves itself with the next read."
        }
    }

    /// Schweregrad — der **einzige** Posten, der aus ``IssuePresentation``
    /// übernommen wird.
    public static func isSevere(_ issue: MonitorIssue) -> Bool {
        IssuePresentation.isSevere(issue)
    }

    // MARK: - Statuszeile eines Accounts (Auflage 7)

    /// Die sechs Fälle aus ``AccountStatusLine`` im Wortlaut von
    /// `AccountCardView.swift:104-141`.
    ///
    /// Ohne diese Abbildung fehlte „Re-login required in claude-swap" auf Linux
    /// vollständig — also genau die Auskunft, die dem Nutzer sagt, warum seine
    /// Zahlen stehen bleiben.
    ///
    /// - Returns: `nil` im Fall ``AccountStatusLine/upToDate`` — dort zeigt
    ///   auch macOS nichts an (`isWarning == false`).
    public static func statusText(for line: AccountStatusLine, now: Date) -> String? {
        switch line {
        case .upToDate:
            return nil
        case .noData:
            return "No data yet"
        case .reLoginRequired:
            return "Re-login required in claude-swap"
        case .paused(let until):
            let remaining = ResetCountdownFormat.text(for: ResetTiming(resetsAt: until, now: now))
            return remaining.map { "Paused, retrying in \($0)" } ?? "Paused"
        case .fetchFailed(_, let staleAge):
            // Der `message`-Anteil bleibt draußen: Er stammt aus der
            // Fremddatei und ist fremdbestimmter Text.
            guard let staleAge, let age = TrayAgeFormat.text(for: staleAge) else {
                return "Last fetch failed"
            }
            return "Last fetch failed — data is outdated: \(age)"
        case .stale(let age):
            guard let text = TrayAgeFormat.text(for: age) else { return "Data is outdated" }
            return "Data is outdated: \(text)"
        }
    }
}

/// Datenalter als kurzer Text.
///
/// **Eigener Fachentscheid, weil `Shared/` hier bewusst aufhört** (Auflage 7):
/// ``DataAgeDisplay`` liefert nur eine `Duration`; das Formatieren überlässt es
/// SwiftUI, damit Sprache und Maßeinheiten zum System passen
/// (`DataAgeDisplay.swift:140-143`). Auf Linux gibt es dieses SwiftUI nicht.
///
/// Entschieden ist: dasselbe Zahlenbild wie beim Reset-Countdown
/// (``ResetCountdownFormat``) — grob, einstellig, ohne Bruchteile. Zwei
/// verschiedene Zeitformate in einem Menü wären für den Leser zwei Systeme,
/// die er auseinanderhalten müsste. Unterhalb einer Minute steht die
/// Sekundenzahl, weil ein frisch gelesener Stand sonst als „<1m" erschiene und
/// damit älter aussähe, als er ist.
public enum TrayAgeFormat {

    /// Fertiger Text; `nil`, wenn das Alter nicht darstellbar ist.
    ///
    /// Klemmung und Obergrenze kommen aus ``DataAgeDisplay`` — die Regeln
    /// werden benutzt und nicht nachgebaut.
    public static func text(for age: TimeInterval) -> String? {
        guard let duration = DataAgeDisplay.duration(for: age) else { return nil }
        let seconds = duration.components.seconds
        if seconds < 60 { return "\(seconds)s" }
        return ResetCountdownFormat.text(for: .remaining(TimeInterval(seconds)))
    }
}
