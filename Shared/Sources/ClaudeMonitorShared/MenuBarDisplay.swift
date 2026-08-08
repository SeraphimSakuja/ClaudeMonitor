import Foundation
import ClaudeMonitorCore

/// Was in der Menüleiste steht: je Account **ein** Segment mit **einem**
/// Ampelpunkt und den beiden Zahlen `5h/7d` dahinter.
///
/// Zielbild im Modus „alle Accounts": `▸●74/28  ●97/11  ●0/28` — der in
/// claude-swap **aktive** Account trägt ein vorangestelltes `▸`. Accounts sind
/// nur durch Abstand getrennt — kein Trennstrich, kein `%`-Zeichen: In der
/// Leiste ist der Platz die knappste Ressource, und dass es Prozente sind,
/// erklärt das Detailfenster.
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
///    Sortiert wird ausschließlich über ``AccountIdentifierOrder`` — kein
///    `localizedStandardCompare` und kein nacktes `sorted()` auf Kennungen,
///    beides hängt an der Locale des Systems. Ein Quellwächter im Core-Paket
///    prüft das für dieses Verzeichnis mit.
/// 3. Ein Segment trägt **genau zwei** Zahlen in fester Reihenfolge: 5 h, dann
///    7 d. Ausdrücklich nicht „alle Fenster" — ein Max-Abo mit `spend` und
///    mehreren `scoped`-Kontingenten machte die Leiste sonst beliebig breit.
/// 4. **Die Farbe des Punktes ist die Account-Ampel**
///    (``AccountSegment/status`` = ``MonitoredAccount/overallStatus``), also
///    die schlechteste Stufe über **alle** Fenster — auch über die nicht
///    gezeigten `spend`/`scoped`. Damit ist die Zusage aus `b215246` direkt
///    erfüllt: Ein Account mit 10 %/10 % und einem zu 95 % erschöpften
///    Modellkontingent zeigt einen **roten** Punkt, obwohl beide sichtbaren
///    Zahlen grün wären. Ein früherer Zusatzpunkt für versteckte Fenster ist
///    damit ersatzlos entfallen — er war nur der Umweg zu genau dieser Zusage.
/// 5. Die **Zahlen** stammen weiterhin aus dem jeweiligen ``LimitWindow``
///    selbst (``WindowValue``), nicht aus einer Zusammenfassung. Sie sind die
///    Detailaussage, der Punkt die Gesamtaussage; beide Ebenen dürfen
///    auseinandergehen und tun es bei einem versteckten Engpass auch.
/// 6. Ohne verwertbare Daten (`.noData`, `.authDead`) ist ``AccountSegment/status``
///    `nil` **und** beide Werte sind ``WindowValue/Reading/unavailable``. Ein
///    toter Token darf weder eingefrorene Altwerte zeigen noch färben.
/// 7. Fehlt ein Fenster, steht dort „–" — kein stilles Weglassen, sonst
///    verschöbe sich die Anzeige je nach Abo-Typ. Ein Fenster mit
///    nicht-endlichem Wert ergibt ``WindowValue/Reading/unreadable``, also
///    ebenfalls keine Zahl; die Account-Ampel steht dann konservativ auf rot,
///    weil `∞` ``MonitoredAccount/bindingPercent`` (ein `max`) mitzieht.
/// 8. Trägt kein Segment irgendeine Aussage, sind ``segments`` leer. Sonst
///    stünde beim Erststart `●–/– ●–/–` ohne jede Information.
/// 9. Höchstens ``maximumSegments`` Segmente; darüber die ersten in
///    Kennungsordnung plus ``hasMoreAccounts``. Vollständig ist das
///    Detailfenster, nicht die Leiste.
/// 10. Der in claude-swap **aktive** Account trägt ``AccountSegment/isActive``
///    und wird ausgezeichnet (`▸` davor, Zahlen fett) — in **beiden** Modi.
///    Die Auszeichnung ändert **nichts** an Auswahl, Reihenfolge oder
///    Ranking, und sie macht ein Segment ausdrücklich **nicht** informativ:
///    Wäre der aktive Account der einzige ohne verwertbare Daten, stünde in
///    der Leiste sonst allein `▸●–/–`. Fehlt `sequence.json`, ist überall
///    `false` — die Zahlen laufen davon unberührt weiter.
///
/// Gezeichnet wird das alles im App-Target als **ein einziges** `NSImage`
/// (`MenuBarImageRenderer`): Ein `NSStatusItem` hat genau ein Bild und einen
/// Titel; mehrere `Image`/`Text` in einem `MenuBarExtra`-Label überleben die
/// Abbildung darauf nicht — es blieb nur das erste Paar stehen. Diese Datei
/// bleibt davon unberührt und framework-frei.
public struct MenuBarDisplay: Equatable, Sendable {

    /// Eine Zahl in der Leiste: ein Limitfenster eines Accounts.
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
        /// Ampelstufe **dieses** Fensters; `nil` ⇒ keine Aussage.
        ///
        /// Färbt in der Leiste **nichts** — dort trägt der eine Punkt je
        /// Account die Account-Ampel (``AccountSegment/status``). Diese Stufe
        /// ist die Detailaussage: Sie geht in den Vorlesetext ein, der die
        /// einzelnen Fenster benennt.
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

        /// `true`, wenn dieser Wert überhaupt etwas aussagt — eine Zahl, ein
        /// „–" oder wenigstens eine Stufe.
        public var isInformative: Bool { text != nil || status != nil }
    }

    /// Ein Account in der Leiste: ein Ampelpunkt und zwei Zahlen.
    public struct AccountSegment: Equatable, Sendable, Identifiable {

        /// Kennung des Accounts.
        public let id: String
        /// Anzeigename (für den Vorlesetext).
        public let displayName: String
        /// **Die Farbe des Punktes** — die Account-Ampel
        /// (``MonitoredAccount/overallStatus``), also die schlechteste Stufe
        /// über alle Fenster inklusive der nicht gezeigten `spend`/`scoped`.
        /// `nil` ⇒ neutraler Punkt, kein verwertbarer Datenstand.
        public let status: StatusLevel?
        /// Die beiden Zahlen dieses Accounts in Anzeigereihenfolge (5 h, 7 d).
        public let values: [WindowValue]
        /// Ob dieser Account in claude-swap gerade **aktiv** ist
        /// (``MonitoredAccount/isActive``) — gilt in **beiden** Modi: Ist der
        /// im Modus „nur bester" gezeigte Account zugleich der aktive, wird er
        /// ebenso ausgezeichnet.
        ///
        /// Der Zeichner erfindet die Markierung nicht selbst, er liest sie hier.
        public let isActive: Bool

        public init(
            id: String,
            displayName: String,
            status: StatusLevel?,
            values: [WindowValue],
            isActive: Bool = false
        ) {
            self.id = id
            self.displayName = displayName
            self.status = status
            self.values = values
            self.isActive = isActive
        }

        /// Das vorangestellte Zeichen des aktiven Accounts; `nil` bei allen
        /// anderen. Regel und Zeichen stehen in ``ActiveAccountDisplay``.
        public var markerText: String? { ActiveAccountDisplay.marker(isActive: isActive) }

        /// Der Wert, der den Account unter den **gezeigten** Fenstern bindet —
        /// der höchste darstellbare.
        ///
        /// Das ist die Zahl, die der Vorlesetext im Modus „alle Accounts"
        /// nennt: In der Leiste sieht man beide, vorgelesen wird die
        /// entscheidende. Die *Stufe* dazu kommt aus ``status`` und nicht von
        /// hier — sonst verschwiege der Vorlesetext einen versteckten Engpass,
        /// den der Punkt sichtbar rot färbt.
        public var binding: WindowValue? {
            let withNumbers = values.filter { $0.percent != nil }
            if let peak = withNumbers.max(by: { ($0.percent ?? 0) < ($1.percent ?? 0) }) {
                return peak
            }
            return values.first { $0.isInformative }
        }

        /// Die beiden Zahlen als fertige Zeichenkette: `74/28`.
        ///
        /// Steht hier und nicht im Zeichner, weil es eine **Anzeigeregel** ist
        /// und die Widget-Extension später dieselbe braucht — zwei Kopien
        /// liefen garantiert auseinander.
        ///
        /// **Ohne Prozentzeichen** (``PercentFormatting/bare(_:)``): Es käme in
        /// der Leiste bis zu achtmal vor und kostete Breite, ohne etwas zu
        /// unterscheiden. Der Vorlesetext und das Detailfenster benutzen
        /// weiterhin ``WindowValue/text`` **mit** Zeichen — vorgelesen ist „74"
        /// ohne Einheit keine Aussage.
        ///
        /// Ein Wert ohne Zahl wird als „–" gesetzt und **nicht** weggelassen:
        /// Sonst verschöbe sich die Bedeutung der verbleibenden Zahl (`74`
        /// hieße mal 5 h, mal 7 d), und ein toter Token sähe aus wie ein
        /// Account mit nur einem Limit.
        public var numbersText: String {
            values
                .map { $0.percent.flatMap(PercentFormatting.bare) ?? MenuBarDisplay.missingText }
                .joined(separator: MenuBarDisplay.valueSeparator)
        }

        /// `true`, wenn dieses Segment überhaupt etwas aussagt.
        public var isInformative: Bool { status != nil || values.contains(where: \.isInformative) }
    }

    /// Segmente in Anzeigereihenfolge; leer ⇒ nichts anzuzeigen.
    public let segments: [AccountSegment]
    /// `true`, wenn weitere Accounts existieren, die nicht mehr in die Leiste
    /// passen — die UI hängt ein „…" an.
    ///
    /// Gilt **nur** im Modus ``MenuBarMode/allAccounts``. Im Standardmodus
    /// ``MenuBarMode/bestAccount`` ist der Wert auch bei sechs Accounts
    /// `false`, und das ist kein Versehen: Dieser Modus zeigt bewusst genau
    /// einen Account: Ein „…" widerspräche der schmalen Leiste und behauptete
    /// eine Kürzung, wo in Wahrheit eine Auswahl getroffen wurde.
    /// ``MenuBarDisplayTests`` hält die Entscheidung fest.
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

    /// Platzhalter für einen Wert, zu dem es keine Zahl gibt.
    public static let missingText = "–"

    /// Trennt die beiden Zahlen eines Accounts: `74/28`.
    public static let valueSeparator = "/"

    /// Hinweis auf Accounts, die nicht mehr in die Leiste passen.
    public static let overflowText = "…"

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

        // Regel 8 wird über **alle** gewählten Accounts geprüft, nicht erst
        // über die vier gezeigten: Wären die ersten vier in Kennungsordnung
        // datenlos und der fünfte hätte Werte, kollabierte sonst die ganze
        // Leiste — samt `hasMoreAccounts == false`. Die Accounts mit echten
        // Daten verschwänden restlos, ohne auch nur ein „…".
        let all = chosen.map(segment(for:))
        guard all.contains(where: \.isInformative) else { return .unavailable }

        let shown = Array(all.prefix(maximumSegments))
        return MenuBarDisplay(segments: shown, hasMoreAccounts: all.count > shown.count)
    }

    /// Bildet das Segment eines einzelnen Accounts.
    ///
    /// Öffentlich, damit die Regeln 3–7 einzeln prüfbar sind; die
    /// Kollaps-Regel 8 steckt dagegen in ``make(for:mode:now:)``.
    public static func segment(for account: MonitoredAccount) -> AccountSegment {
        guard account.hasUsableData else {
            // Regel 6: keine Zahl, keine Farbe. `overallStatus` ist hier
            // ohnehin `nil`; die Werte müssen es ausdrücklich auch sein.
            return AccountSegment(
                id: account.id,
                displayName: account.displayName,
                status: nil,
                values: visibleKinds.map {
                    WindowValue(id: $0.rawKey, kind: $0, reading: .unavailable, status: nil)
                },
                // Regel 10: Die Markierung hängt am Account, nicht an seinen
                // Zahlen — der aktive Account bleibt auch dann erkennbar, wenn
                // sein Token tot ist. Gerade dann ist die Auskunft wertvoll.
                isActive: account.isActive
            )
        }

        return AccountSegment(
            id: account.id,
            displayName: account.displayName,
            // Regel 4: die Account-Ampel, gelesen statt nachgebaut — nur so
            // schlägt ein versteckter `spend`/`scoped`-Engpass auf den Punkt
            // durch.
            status: account.overallStatus,
            values: visibleKinds.map { kind in value(of: kind, in: account) },
            isActive: account.isActive
        )
    }

    /// Ein sichtbares Fenster eines Accounts mit verwertbaren Daten.
    private static func value(of kind: LimitWindow.Kind, in account: MonitoredAccount) -> WindowValue {
        guard let window = account.window(kind: kind) else {
            // Regel 7: fehlendes Fenster ist eine Aussage, kein Weglassen.
            return WindowValue(id: kind.rawKey, kind: kind, reading: .missing, status: nil)
        }
        // Regel 5: Zahl und Detailstufe aus genau diesem Fenster.
        guard window.percent.isFinite else {
            return WindowValue(id: window.id, kind: kind, reading: .unreadable, status: window.status)
        }
        return WindowValue(id: window.id, kind: kind, reading: .percent(window.percent), status: window.status)
    }
}
