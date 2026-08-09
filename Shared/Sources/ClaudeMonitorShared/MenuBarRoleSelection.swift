import Foundation
import ClaudeMonitorCore

/// Welche Accounts die Menüleiste zeigt — und **warum** gerade die.
///
/// Statt „die ersten vier in Kennungsordnung" (bis v0.x) wählt die Leiste nach
/// **Rollen**. Bei zehn Accounts waren die vier alphabetisch ersten eine
/// Auswahl ohne Aussage; diese hier beantwortet drei Fragen, die man wirklich
/// hat:
///
/// | Position | Rolle | Frage |
/// |---|---|---|
/// | 1 | ``Role/active`` | Womit arbeite ich gerade? |
/// | 2 | ``Role/best`` | Wohin könnte ich wechseln? |
/// | 3 | ``Role/reset`` | Wann kommt Kontingent zurück? |
///
/// **Ein Account, der mehrere Rollen hält, erscheint genau einmal** — an der
/// vordersten seiner Positionen, mit allen Rollen vermerkt. Der Normalfall ist
/// genau das: Man wechselt auf den besten Account, also ist der aktive
/// zugleich der beste, und die Leiste zeigt zwei Segmente statt drei. Es wird
/// **nicht aufgefüllt**: Ein vierter Account ohne Rolle wäre wieder eine
/// willkürliche Auswahl — also genau das Problem, das diese Datei löst.
///
/// Die Reihenfolge ist **fest** und hängt nicht an Zahlen. Damit bleibt die
/// Position lernbar: Vorne steht immer der aktive, nicht mal dieser und mal
/// jener, weil sich ein Prozentwert geändert hat. Sortiert wird hier
/// ausschließlich über ``AccountIdentifierOrder`` — kein
/// `localizedStandardCompare` und kein nacktes `sorted()` auf Kennungen, beides
/// hängt an der Locale des Systems. Ein Quellwächter im Core-Paket prüft das
/// für dieses Verzeichnis mit.
public struct MenuBarRoleSelection: Equatable, Sendable {

    /// Die drei Rollen in Anzeigereihenfolge.
    public enum Role: Sendable, Equatable, Hashable, CaseIterable {
        /// In claude-swap gerade aktiv.
        case active
        /// Gerankter erster — die beste Ausweichmöglichkeit.
        case best
        /// Kommt als Nächstes zurück (siehe ``resetRoleAccount(among:now:)``).
        case reset
    }

    /// Ein gezeigter Account mit den Rollen, die er hält.
    public struct Entry: Equatable, Sendable, Identifiable {

        public let account: MonitoredAccount
        /// Alle Rollen dieses Accounts — mindestens eine.
        public let roles: Set<Role>

        public var id: String { account.id }

        /// Ob an diesem Segment die Restzeit steht. Genau der Account mit der
        /// Reset-Rolle trägt sie, unabhängig davon, welche Rollen er sonst hat.
        public var showsReset: Bool { roles.contains(.reset) }

        public init(account: MonitoredAccount, roles: Set<Role>) {
            self.account = account
            self.roles = roles
        }
    }

    /// Die gezeigten Accounts in Anzeigereihenfolge; ein bis drei Einträge,
    /// leer nur ohne Accounts.
    public let entries: [Entry]

    public init(entries: [Entry]) {
        self.entries = entries
    }

    // MARK: - Auswahl

    /// Die Rollenauswahl über alle Accounts.
    ///
    /// - Parameter ranked: Accounts in Ranking-Reihenfolge (bester zuerst).
    public static func make(from ranked: [MonitoredAccount], now: Date = Date()) -> MenuBarRoleSelection {
        guard !ranked.isEmpty else { return MenuBarRoleSelection(entries: []) }

        var claimed: [(account: MonitoredAccount, roles: Set<Role>)] = []

        func claim(_ account: MonitoredAccount?, as role: Role) {
            guard let account else { return }
            if let index = claimed.firstIndex(where: { $0.account.id == account.id }) {
                claimed[index].roles.insert(role)
            } else {
                claimed.append((account, [role]))
            }
        }

        // Reihenfolge der Aufrufe = Reihenfolge in der Leiste.
        claim(activeRoleAccount(among: ranked), as: .active)
        claim(ranked.first, as: .best)
        claim(resetRoleAccount(among: ranked, now: now), as: .reset)

        return MenuBarRoleSelection(entries: claimed.map { Entry(account: $0.account, roles: $0.roles) })
    }

    /// Die Auswahl für den schmalen Modus: **nur** der aktive Account, mit
    /// Restzeit, falls er die Bedingung dafür erfüllt.
    ///
    /// Getrennt von ``make(from:now:)``, weil hier ausdrücklich **keine**
    /// weitere Rolle dazukommen darf — auch dann nicht, wenn ein anderer
    /// Account gerade zurückkommt. Der Modus verspricht einen Account.
    public static func activeOnly(from ranked: [MonitoredAccount], now: Date = Date()) -> MenuBarRoleSelection {
        guard let account = activeRoleAccount(among: ranked) else {
            return MenuBarRoleSelection(entries: [])
        }
        var roles: Set<Role> = [.active]
        if qualifiesForReset(account, now: now) { roles.insert(.reset) }
        return MenuBarRoleSelection(entries: [Entry(account: account, roles: roles)])
    }

    /// Wer die Rolle ``Role/active`` hält.
    ///
    /// Der in claude-swap aktive Account; ist keiner markiert — etwa weil
    /// `sequence.json` fehlt oder unlesbar ist —, der gerankte erste. Ein
    /// **Rückfall statt einer Leere**: Eine leere Leiste wäre die schlechteste
    /// Antwort auf eine fehlende Nebendatei, deren Ausfall ausdrücklich keinen
    /// Fehlzustand erzeugen soll.
    public static func activeRoleAccount(among accounts: [MonitoredAccount]) -> MonitoredAccount? {
        accounts.first { $0.isActive } ?? accounts.first
    }

    /// Wer die Rolle ``Role/reset`` hält: der rote Account mit dem frühesten
    /// Reset seines Engpass-Fensters. `nil`, wenn kein Account rot ist — dann
    /// wartet niemand auf Kontingent und die Rolle bleibt unbesetzt.
    public static func resetRoleAccount(
        among accounts: [MonitoredAccount],
        now: Date = Date()
    ) -> MonitoredAccount? {
        let candidates = accounts.filter { qualifiesForReset($0, now: now) }
        return candidates.min { lhs, rhs in
            let left = sortableRemaining(of: lhs, now: now)
            let right = sortableRemaining(of: rhs, now: now)
            if left != right { return left < right }
            // Gleichstand: stabile, locale-freie Ordnung. Ohne sie könnte die
            // Leiste bei zwei gleichzeitig zurückkehrenden Accounts zwischen
            // ihnen flackern.
            return AccountIdentifierOrder.isOrderedBefore(lhs.id, rhs.id)
        }
    }

    /// Ob an diesem Account eine Restzeit stehen darf: **rote** Ampel und ein
    /// bekannter Reset am Engpass-Fenster.
    ///
    /// Beides ist nötig. Ohne die Ampel stünde die Zahl auch bei entspannter
    /// Lage da — bei einem freien Account wartet niemand auf den Reset; ohne
    /// den bekannten Reset gäbe es nichts zu zeigen.
    ///
    /// **Warum die Ampel und keine eigene Schwelle:** ``StatusLevel/red``
    /// (ab 85 %) ist die im Projekt bereits kalibrierte Grenze für „hier wird
    /// es eng". Die Restzeit erbt damit genau die Bedeutung, die der rote Punkt
    /// ohnehin trägt; eine zweite Schwelle daneben wäre eine zweite Wahrheit.
    /// Bewusst 85 % und nicht erst 100 %: Bei 85 % kann man noch entscheiden,
    /// ob man weitermacht oder wechselt — bei 100 % ist die Entscheidung
    /// gefallen. Nicht-endliche Werte gelten über ``StatusLevel`` konservativ
    /// als rot, was hier genau richtig ist.
    ///
    /// ⚠️ Die Stufe steht **fest** und ist ausdrücklich kein Regler: Der
    /// Vergleich ist eine Gleichheit auf die oberste Stufe. Trüge er eine
    /// Konstante, die jemand auf `.yellow` setzt, wären plötzlich die *roten*
    /// Accounts ausgeschlossen — das Gegenteil der Absicht.
    public static func qualifiesForReset(_ account: MonitoredAccount, now: Date = Date()) -> Bool {
        guard account.hasUsableData, account.overallStatus == .red else { return false }
        return remainingSeconds(of: account, now: now) != nil
    }

    /// Restzeit des Engpass-Fensters; `nil`, wenn dort kein Reset bekannt ist.
    ///
    /// Liest ``AccountRanking/bottleneckWindow(of:now:)`` — dieselbe Größe, nach
    /// der das Ranking sortiert. Zwei Implementierungen derselben Regel wären
    /// der Weg, auf dem Auswahl und Anzeige auseinanderlaufen.
    ///
    /// Getrennte Namen statt zweier Überladungen, die sich nur im Rückgabetyp
    /// unterscheiden: Welche gemeint ist, entschiede sonst der Kontext der
    /// Aufrufstelle — und ein `nil` würde stillschweigend zu
    /// `greatestFiniteMagnitude`.
    static func remainingSeconds(of account: MonitoredAccount, now: Date) -> TimeInterval? {
        AccountRanking.bottleneckWindow(of: account, now: now)?
            .resetTiming(now: now)
            .remainingSeconds
    }

    /// Restzeit als endlicher Sortierwert; ohne bekannten Reset der
    /// schlechtestmögliche. Nur für die Auswahl des frühesten Resets.
    private static func sortableRemaining(of account: MonitoredAccount, now: Date) -> TimeInterval {
        remainingSeconds(of: account, now: now) ?? .greatestFiniteMagnitude
    }

    /// Fertiger Restzeit-Text für ein Segment; `nil`, wenn dort keiner steht.
    public static func resetText(for entry: Entry, now: Date = Date()) -> String? {
        guard entry.showsReset else { return nil }
        guard let window = AccountRanking.bottleneckWindow(of: entry.account, now: now) else { return nil }
        return ResetCountdownFormat.text(for: window.resetTiming(now: now))
    }
}
