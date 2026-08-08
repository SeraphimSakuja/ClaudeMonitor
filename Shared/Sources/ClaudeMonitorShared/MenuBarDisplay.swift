import Foundation
import ClaudeMonitorCore

/// Was in der Menüleiste steht: je Account ein Segment, je Segment ein Punkt
/// **pro Limitfenster** mit eigener Zahl und eigener Ampelfarbe.
///
/// Zielbild im Modus „alle Accounts": `●13% ●2% │ ●0% ●21% │ ●0% ●28%`.
///
/// Die Regeln, die hier geprüft festgeschrieben sind:
///
/// 1. ``MenuBarMode/bestAccount`` ⇒ höchstens **ein** Segment (der gerankte
///    erste Account), ``MenuBarMode/allAccounts`` ⇒ alle Accounts.
/// 2. Die Reihenfolge im Modus „alle" ist die **Kennungsordnung**
///    (``AccountIdentifierOrder``), nicht das Ranking: Die Position eines
///    Accounts in der Leiste muss lernbar bleiben und darf nicht springen, nur
///    weil sich ein Prozentwert geändert hat. Das Ranking bleibt zuständig für
///    das Detailfenster und für die Auswahl im Modus „nur bester Account".
/// 3. Gezeigt werden **genau zwei** Fenster in fester Reihenfolge: 5 h, dann
///    7 d. Ausdrücklich nicht „alle Fenster" — ein Max-Abo mit `spend` und
///    mehreren `scoped`-Kontingenten machte die Leiste sonst beliebig breit.
/// 4. **Zahl und Farbe eines Punktes stammen aus demselben ``LimitWindow``**
///    (``LimitWindow/status``), nicht aus ``MonitoredAccount/overallStatus``.
///    Sonst stünde ein roter Punkt neben „2 %".
/// 5. Bindet ein *nicht* gezeigtes Fenster (`spend`, `scoped`, `other`) den
///    Account stärker als beide sichtbaren, bekommt das Segment **einen**
///    zusätzlichen Punkt mit Zahl — höchstens einen.
/// 6. Daraus folgt die Ersatz-Invariante: **Die schlechteste Ampelstufe über
///    alle Punkte eines Segments ist gleich ``MonitoredAccount/overallStatus``.**
///    Sie ersetzt die frühere Zusage „Menüleisten-Zahl == `bindingPercent`",
///    die mit zwei Zahlen pro Account nicht mehr formulierbar ist. Regel 5
///    existiert genau dafür: Ohne sie zeigte ein Account mit 10 %/10 % und
///    einem zu 95 % erschöpften Modellkontingent zwei grüne Punkte.
///    *Grenzfall:* Trägt ein Fenster einen nicht-endlichen Wert, kann
///    ``MonitoredAccount/bindingPercent`` (ein `max` über NaN) an ihm
///    vorbeilaufen; dann ist der Punkt konservativ rot, ``overallStatus`` aber
///    womöglich nicht. Vorsichtiger als die Zusammenfassung zu sein ist hier
///    die gewollte Richtung.
/// 7. Ohne verwertbare Daten (`.noData`, `.authDead`) sind **alle** Werte
///    ``WindowValue/Reading/unavailable``, ``WindowValue/status`` ist `nil`
///    und es gibt **keinen** Zusatzpunkt. Ein toter Token darf keine
///    eingefrorenen Altwerte färben.
/// 8. Fehlt ein Fenster, steht dort „–" mit neutralem Punkt — kein stilles
///    Weglassen, sonst verschöbe sich die Anzeige je nach Abo-Typ.
/// 9. Trägt kein Segment irgendeine Aussage, sind ``segments`` leer. Sonst
///    stünde beim Erststart `● ● │ ● ● │ ● ●` ohne jede Information.
/// 10. Höchstens ``maximumSegments`` Segmente; darüber die ersten in
///    Kennungsordnung plus ``hasMoreAccounts``. Vollständig ist das
///    Detailfenster, nicht die Leiste.
public struct MenuBarDisplay: Equatable, Sendable {

    /// Ein Punkt in der Leiste: ein Limitfenster eines Accounts.
    public struct WindowValue: Equatable, Sendable, Identifiable {

        /// Was über dieses Fenster bekannt ist.
        public enum Reading: Equatable, Sendable {
            /// Darstellbare Zahl.
            case percent(Double)
            /// Fenster vorhanden, Wert nicht endlich ⇒ keine Zahl; die Farbe
            /// bleibt konservativ stehen.
            case unreadable
            /// Fenster fehlt in der Quelle ⇒ „–".
            case missing
            /// Account ohne verwertbare Daten ⇒ gar nichts.
            case unavailable
        }

        /// Kennung des Quellfensters; ohne Quellfenster der Rohschlüssel der
        /// Art. Eigenes Feld, weil ``LimitWindow/Kind`` bewusst nicht
        /// `Hashable` ist und `ForEach` eine stabile Identität braucht.
        public let id: String
        /// Art des Fensters — bestimmt die Beschriftung im Vorlesetext.
        public let kind: LimitWindow.Kind
        /// Was über das Fenster bekannt ist.
        public let reading: Reading
        /// Ampelstufe **dieses** Fensters; `nil` ⇒ neutraler Punkt.
        public let status: StatusLevel?

        public init(id: String, kind: LimitWindow.Kind, reading: Reading, status: StatusLevel?) {
            self.id = id
            self.kind = kind
            self.reading = reading
            self.status = status
        }

        /// Fertiger Text; `nil`, wenn zu diesem Punkt keine Zahl gehört.
        public var text: String? {
            switch reading {
            case .percent(let percent): return PercentFormatting.compact(percent)
            case .missing: return MenuBarDisplay.missingText
            case .unreadable, .unavailable: return nil
            }
        }

        /// Darstellbarer Prozentwert, falls vorhanden.
        public var percent: Double? {
            if case .percent(let percent) = reading { return percent }
            return nil
        }

        /// `true`, wenn dieser Punkt überhaupt etwas aussagt — eine Zahl, ein
        /// „–" oder wenigstens eine Farbe.
        public var isInformative: Bool { text != nil || status != nil }
    }

    /// Ein Account in der Leiste.
    public struct AccountSegment: Equatable, Sendable, Identifiable {

        /// Kennung des Accounts.
        public let id: String
        /// Anzeigename (für den Vorlesetext).
        public let displayName: String
        /// Die Punkte dieses Accounts in Anzeigereihenfolge.
        public let values: [WindowValue]

        public init(id: String, displayName: String, values: [WindowValue]) {
            self.id = id
            self.displayName = displayName
            self.values = values
        }

        /// Der Punkt, der den Account bindet — der höchste darstellbare Wert.
        ///
        /// Das ist genau der Punkt, den der Vorlesetext im Modus „alle
        /// Accounts" nennt: In der Leiste sieht man alles, vorgelesen wird das
        /// Entscheidende. Ist ein Zusatzpunkt nach Regel 5 da, ist er es.
        public var binding: WindowValue? {
            let withNumbers = values.filter { $0.percent != nil }
            if let peak = withNumbers.max(by: { ($0.percent ?? 0) < ($1.percent ?? 0) }) {
                return peak
            }
            return values.first { $0.isInformative }
        }

        /// `true`, wenn dieses Segment überhaupt etwas aussagt.
        public var isInformative: Bool { values.contains(where: \.isInformative) }
    }

    /// Segmente in Anzeigereihenfolge; leer ⇒ nichts anzuzeigen.
    public let segments: [AccountSegment]
    /// `true`, wenn weitere Accounts existieren, die nicht mehr in die Leiste
    /// passen — die UI hängt ein „…" an.
    public let hasMoreAccounts: Bool

    public init(segments: [AccountSegment], hasMoreAccounts: Bool = false) {
        self.segments = segments
        self.hasMoreAccounts = hasMoreAccounts
    }

    /// Fenster, die immer gezeigt werden — in genau dieser Reihenfolge.
    public static let visibleKinds: [LimitWindow.Kind] = [.fiveHour, .sevenDay]

    /// Obergrenze der Segmente in der Leiste. Vier Accounts sind rund 48
    /// Zeichen; darüber kürzt macOS die Leiste ohnehin von rechts, und zwar
    /// ohne Hinweis darauf, dass etwas fehlt.
    public static let maximumSegments = 4

    /// Platzhalter für ein Fenster, das die Quelle nicht liefert.
    public static let missingText = "–"

    /// Leere Anzeige — neutrales Symbol, keine erfundene Zahl.
    public static let unavailable = MenuBarDisplay(segments: [])

    /// Bildet die Anzeige aus dem Gesamtzustand.
    ///
    /// `now` hat einen Vorgabewert, weil die Views ohne eigenen Zeitbezug
    /// aufrufen; Tests reichen einen festen Zeitpunkt herein.
    public static func make(
        for state: MonitorViewState,
        mode: MenuBarMode,
        now: Date = Date()
    ) -> MenuBarDisplay {
        let ranked = state.accounts(now: now)
        guard !ranked.isEmpty else { return .unavailable }

        let chosen: [MonitoredAccount]
        switch mode {
        case .bestAccount:
            chosen = Array(ranked.prefix(1))
        case .allAccounts:
            // Regel 2: feste Kennungsordnung, nicht das Ranking.
            chosen = ranked.sorted { AccountIdentifierOrder.isOrderedBefore($0.id, $1.id) }
        }

        let shown = chosen.prefix(maximumSegments).map(segment(for:))
        // Regel 9: Ohne jede Aussage lieber nichts als eine Reihe stummer Punkte.
        guard shown.contains(where: \.isInformative) else { return .unavailable }

        return MenuBarDisplay(segments: shown, hasMoreAccounts: chosen.count > shown.count)
    }

    /// Bildet das Segment eines einzelnen Accounts.
    ///
    /// Öffentlich, damit die Regeln 3–8 einzeln prüfbar sind; die
    /// Kollaps-Regel 9 steckt dagegen in ``make(for:mode:now:)``.
    public static func segment(for account: MonitoredAccount) -> AccountSegment {
        guard account.hasUsableData else {
            // Regel 7: keine Zahl, keine Farbe, kein Zusatzpunkt.
            return AccountSegment(
                id: account.id,
                displayName: account.displayName,
                values: visibleKinds.map {
                    WindowValue(id: $0.rawKey, kind: $0, reading: .unavailable, status: nil)
                }
            )
        }

        var values = visibleKinds.map { kind in value(of: kind, in: account) }
        if let extra = bindingExtra(for: account, shown: values) {
            values.append(extra)
        }
        return AccountSegment(id: account.id, displayName: account.displayName, values: values)
    }

    /// Ein sichtbares Fenster eines Accounts mit verwertbaren Daten.
    private static func value(of kind: LimitWindow.Kind, in account: MonitoredAccount) -> WindowValue {
        guard let window = account.window(kind: kind) else {
            // Regel 8: fehlendes Fenster ist eine Aussage, kein Weglassen.
            return WindowValue(id: kind.rawKey, kind: kind, reading: .missing, status: nil)
        }
        // Regel 4: Farbe aus genau diesem Fenster.
        guard window.percent.isFinite else {
            return WindowValue(id: window.id, kind: kind, reading: .unreadable, status: window.status)
        }
        return WindowValue(id: window.id, kind: kind, reading: .percent(window.percent), status: window.status)
    }

    /// Regel 5: der zusätzliche Punkt für ein nicht gezeigtes Fenster, das den
    /// Account stärker bindet als beide sichtbaren.
    ///
    /// Nur endliche Werte kommen infrage — ein Zusatzpunkt ohne Zahl erklärte
    /// die Farbe nicht, die er mitbringt.
    private static func bindingExtra(
        for account: MonitoredAccount,
        shown: [WindowValue]
    ) -> WindowValue? {
        let candidate = account.windows
            .filter { window in
                window.percent.isFinite && !visibleKinds.contains(window.kind)
            }
            .max { $0.percent < $1.percent }

        guard let candidate else { return nil }
        if let shownPeak = shown.compactMap(\.percent).max(), candidate.percent <= shownPeak {
            return nil
        }
        return WindowValue(
            id: candidate.id,
            kind: candidate.kind,
            reading: .percent(candidate.percent),
            status: candidate.status
        )
    }
}
