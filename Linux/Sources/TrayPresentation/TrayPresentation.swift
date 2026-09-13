import Foundation
import ClaudeMonitorCore
import ClaudeMonitorShared

/// Was das Tray-Item gerade zeigt — Beschriftung, Symbol, Menü.
public struct TrayView: Equatable, Sendable {

    /// Der Text neben dem Symbol im Panel (`XAyatanaLabel`).
    /// Darf leer sein — ein leerer Text ja, ein verschwundenes Item nie
    /// (Fachentscheid 5.2).
    public let labelText: String
    /// Das eine Symbol des Items.
    public let icon: TrayIconStatus
    /// Die Einträge des Menüs, flach, in Anzeigereihenfolge.
    public let menu: [TrayMenuItem]

    public init(labelText: String, icon: TrayIconStatus, menu: [TrayMenuItem]) {
        self.labelText = labelText
        self.icon = icon
        self.menu = menu
    }
}

/// Der **eine** Übersetzungspunkt von ``MonitorViewState`` auf die
/// Tray-Oberfläche.
///
/// Alles, was auf macOS die Views entscheiden, entscheiden dort bereits die
/// framework-freien Typen aus `Shared/` — ``MenuBarDisplay``,
/// ``PopoverContent``, ``AccountWindowsDisplay``, ``AccountCardDisplay``,
/// ``AccountStatusLine``, ``AccountBindingDisplay``, ``WindowKindNaming``,
/// ``PercentFormatting``, ``ResetDisplay``, ``ResetCountdownFormat``,
/// ``DataAgeDisplay``, ``ActiveAccountDisplay``, ``IssuePresentation``. Diese
/// Datei **benutzt** sie und entscheidet nichts davon neu. Jede Regel, die hier
/// noch einmal stünde, liefe früher oder später gegen ihre macOS-Fassung.
///
/// `Shared/` bekommt in dieser Karte null Diff; alle genannten Typen waren
/// bereits `public`.
public enum TrayPresentation {

    /// Der Modus der Leiste ist auf Linux **fest** ``MenuBarMode/overview``.
    ///
    /// Der Umschalter (`MonitorPopoverView.swift:143-146`) ist ausdrücklich
    /// abgetrennt (§3.1): Er bräuchte eine Persistenz, und der Tray-Prozess hat
    /// zugesagt, nie zu schreiben.
    public static let mode = MenuBarMode.overview

    /// Zwischen zwei Account-Segmenten im Panel-Text.
    static let segmentSeparator = "  "

    /// Einrückung der Auskunftszeilen unter einem Account.
    static let indent = "   "

    /// Bildet die gesamte Oberfläche aus dem Zustand.
    public static func make(for state: MonitorViewState, now: Date = Date()) -> TrayView {
        let display = MenuBarDisplay.make(for: state, mode: mode, now: now)
        return TrayView(
            labelText: labelText(for: display),
            icon: TrayIconAggregation.provisionalIcon(for: display),
            menu: menu(for: state, now: now)
        )
    }

    // MARK: - Panel-Text

    /// Der Text im Panel: `▸74/28 2h04  97/11  0/28`.
    ///
    /// Reihenfolge je Segment: **Marker · Zahlen · Restzeit** (Auflage 1). Die
    /// Restzeit trägt höchstens ein Segment — das mit der Reset-Rolle —, und
    /// sie ist der Grund, warum man überhaupt hinsieht: „auf diesen hier
    /// wartest du".
    ///
    /// Ohne Ampelpunkte, anders als auf macOS: Dort zeichnet
    /// `MenuBarImageRenderer` ein einziges Bild mit farbigen Punkten; das
    /// SNI-Label ist reiner Text und kann keine Farbe tragen. Die Ampel sitzt
    /// hier im Symbol (siehe ``TrayIconAggregation``).
    ///
    /// Keine Account-Namen — Parität zu `MenuBarLabelView.swift:5-7`; die
    /// Namen stehen im Menü (Fachentscheid 5.3).
    static func labelText(for display: MenuBarDisplay) -> String {
        display.segments.map { segment in
            var parts: [String] = []
            if let marker = segment.markerText { parts.append(marker) }
            parts.append(segment.numbersText)
            if let reset = segment.resetText { parts.append(" " + reset) }
            return parts.joined()
        }
        .joined(separator: segmentSeparator)
    }

    // MARK: - Menü

    /// Der vollständige Menüaufbau.
    ///
    /// **Inventar gegen das macOS-Detailfenster** (Auflage 8) — je Posten
    /// „drin/draußen + Grund":
    ///
    /// | Posten (`MonitorPopoverView.swift`) | Hier | Grund |
    /// |---|---|---|
    /// | Kopfzeile „ClaudeMonitor" (`:59`) | drin | Menükopf |
    /// | Versionszeile (`:65,304-309`) | drin | einzige Auskunft, welche Fassung läuft |
    /// | „Jetzt aktualisieren" (`:69-77`) | drin | sonst wartet man bis zu 30 s |
    /// | Hinweisbalken (`IssueBannerView`) Titel + Erklärung | drin | erklärt, warum keine Zahlen da sind |
    /// | Hinweisbalken Diagnose-Detail (`IssueBannerView.swift:63-72`) | **draußen** | enthält Pfade und fremden Decoder-Text; ein Menüeintrag ist weder markierbar noch mehrzeilig, und der Wert gehört in die Diagnose, nicht in die Oberfläche. Er geht redigiert nach stderr. |
    /// | Account-Kärtchen (`AccountCardView`) | drin | Kern der Parität |
    /// | Statuszeile (`AccountCardView.swift:104-141`) | drin | Auflage 7 |
    /// | Fensterzeilen (`LimitWindowRowView`) | drin | ohne sie keine Zahlen |
    /// | Fortschrittsbalken (`LimitWindowRowView.swift:37-39`) | **draußen** | ein dbusmenu-Eintrag ist eine Textzeile; die Zahl steht daneben |
    /// | Kärtchen-Fußzeile „Updated … ago" (`AccountCardView.swift:36-41`) | drin | bedingt, wie dort |
    /// | „Loading…"/„No accounts" (`:96-103`) | drin | sonst wäre ein leeres Menü mehrdeutig |
    /// | Globale Fußzeile „Checked … ago" (`:284-288`) | drin | Einordnung des Datenalters |
    /// | „Beenden" (`:292-297`) | drin | **Pflicht** — ein residenter Prozess ohne Programmmenü wäre sonst nicht beendbar |
    /// | Umschalter Aktiv/Überblick (`:143-146`) | **draußen** | abgetrennte Randmenge §3.1, bräuchte Persistenz |
    /// | „Beim Anmelden starten" (`:170-200`) | **draußen** | gehört zu `CM-21` (§3.2) |
    /// | Update-Block (`:208-278`) | **draußen** | Sparkle ist macOS-only; die Linux-Auslieferung entscheidet `CM-22` |
    static func menu(for state: MonitorViewState, now: Date) -> [TrayMenuItem] {
        var items: [TrayMenuItem] = [
            .information(key: "header", label: TrayTexts.header),
            .separator(key: "header.separator")
        ]

        if let issue = state.issue {
            items.append(.information(key: "issue.title", label: TrayTexts.issueTitle(for: issue)))
            items.append(.information(
                key: "issue.explanation",
                label: TrayTexts.issueExplanation(for: issue)
            ))
            items.append(.separator(key: "issue.separator"))
        }

        switch PopoverContent.make(for: state, now: now) {
        case .issueOnly:
            // Der Hinweis darüber erklärt die Lage bereits — eine zweite Zeile
            // wäre nur Lärm (dieselbe Entscheidung wie `:93-95`).
            break
        case .loading:
            items.append(.information(key: "content.loading", label: TrayTexts.loading))
        case .empty:
            items.append(.information(key: "content.empty", label: TrayTexts.noAccounts))
        case .accounts(let accounts):
            // Reihenfolge: nach Account-Nummer, nicht nach Ranking — das Menü
            // ist die Nachschlage-, nicht die Empfehlungsansicht
            // (Fachentscheid 5.4, `PopoverContent.swift:36-48`).
            for (index, account) in accounts.enumerated() {
                if index > 0 { items.append(.separator(key: "account.\(account.id).separator")) }
                items += card(for: account, now: now)
            }
        }

        items.append(.separator(key: "footer.separator"))
        if let capturedAt = state.snapshot?.capturedAt,
           let age = TrayAgeFormat.text(for: now.timeIntervalSince(capturedAt)) {
            items.append(.information(key: "footer.checked", label: TrayTexts.checked(ago: age)))
        }
        items.append(TrayMenuItem(key: "action.refresh", role: .refresh, label: TrayTexts.refresh))
        items.append(TrayMenuItem(key: "action.quit", role: .quit, label: TrayTexts.quit))
        return items
    }

    /// Ein Account-Kärtchen als Folge flacher Einträge.
    static func card(for account: MonitoredAccount, now: Date) -> [TrayMenuItem] {
        let statusLine = AccountStatusLine.make(for: account, now: now)
        var items: [TrayMenuItem] = [
            .information(key: "account.\(account.id)", label: headerText(for: account))
        ]

        if statusLine.isWarning, let text = TrayTexts.statusText(for: statusLine, now: now) {
            items.append(.information(key: "account.\(account.id).status", label: indent + text))
        }

        switch AccountWindowsDisplay.make(for: account) {
        case .noUsableData:
            items.append(.information(
                key: "account.\(account.id).noData",
                label: indent + TrayTexts.noUsableData
            ))
        case .windows(let windows):
            for window in windows {
                items.append(.information(
                    key: "account.\(account.id).window.\(window.id)",
                    label: indent + windowText(for: window, now: now)
                ))
            }
        }

        // Nicht doppelt: Nennt die Statuszeile das Alter schon, entfällt diese
        // Zeile. Die Regel steht geprüft in `Shared/`.
        if let fetchedAt = account.fetchedAt,
           AccountCardDisplay.showsUpdatedFooter(statusLine: statusLine),
           let age = TrayAgeFormat.text(for: now.timeIntervalSince(fetchedAt)) {
            items.append(.information(
                key: "account.\(account.id).updated",
                label: indent + TrayTexts.updated(ago: age)
            ))
        }
        return items
    }

    /// Kopfzeile eines Kärtchens: `▸ Alias  #12  74%`.
    ///
    /// Der aktive Account trägt **nur** den Marker aus ``ActiveAccountDisplay``
    /// — die Fettschrift der macOS-Fassung entfällt ersatzlos (Auflage 18,
    /// Fachentscheid 5.16): Ein SNI-Menüeintrag ist reiner Text ohne
    /// Auszeichnungsmöglichkeit. Das Zeichen trägt die Aussage allein, so wie
    /// es das auf macOS im Kärtchenkopf ohnehin schon tut
    /// (`AccountCardView.swift:56-60`).
    static func headerText(for account: MonitoredAccount) -> String {
        // Der Marker klebt am Namen, statt eine eigene Spalte zu bilden: Er
        // zeichnet den Account aus und ist keine eigene Angabe.
        let marker = ActiveAccountDisplay.marker(isActive: account.isActive).map { $0 + " " } ?? ""
        var parts: [String] = [marker + account.displayName]
        parts.append("#\(account.id)")
        // Kein Wert heißt kein Wert — hier steht bewusst nie „0 %"
        // (`AccountCardView.swift:78-83`).
        parts.append(AccountBindingDisplay.make(for: account).text ?? MenuBarDisplay.missingText)
        return parts.joined(separator: "  ")
    }

    /// Eine Fensterzeile: `5 hours  42%  2h04`.
    ///
    /// Der Fortschrittsbalken der macOS-Zeile entfällt — ein Menüeintrag ist
    /// eine Textzeile. Name, Zahl und Restzeit kommen unverändert aus denselben
    /// `Shared/`-Typen wie dort (`LimitWindowRowView.swift:67-92`).
    static func windowText(for window: LimitWindow, now: Date) -> String {
        var parts = [WindowKindNaming.name(for: window.kind)]
        if let percent = PercentFormatting.compact(window.percent) { parts.append(percent) }
        switch ResetDisplay.make(for: window, now: now) {
        case .unknown:
            // Ohne bekannten Reset steht hier nichts — die fehlende Angabe
            // sagt bereits alles (`LimitWindowRowView.swift:73-76`).
            break
        case .due:
            parts.append("due")
        case .counting(let until):
            if let text = ResetCountdownFormat.text(for: .remaining(until.timeIntervalSince(now))) {
                parts.append(text)
            }
        }
        return parts.joined(separator: "  ")
    }
}
