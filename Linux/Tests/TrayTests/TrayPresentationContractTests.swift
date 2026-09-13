import Foundation
import Testing
import ClaudeMonitorCore
import ClaudeMonitorShared
import DBusWire
@testable import TrayPresentation

/// Bauhelfer für die Tray-Testfälle — anonymisiert, fester Zeitbezug.
private enum TrayFixture {

    /// Fester Bezugszeitpunkt, damit Restzeiten reproduzierbar sind.
    static let now = Date(timeIntervalSince1970: 1_800_000_000)

    static func window(
        _ kind: LimitWindow.Kind,
        percent: Double,
        resetsAt: Date? = nil
    ) -> LimitWindow {
        LimitWindow(
            id: kind.rawKey,
            kind: kind,
            label: kind.rawKey,
            percent: percent,
            resetsAt: resetsAt
        )
    }

    static func account(
        id: String,
        name: String,
        windows: [LimitWindow],
        isActive: Bool = false
    ) -> MonitoredAccount {
        MonitoredAccount(
            id: id,
            displayName: name,
            windows: windows,
            fetchedAt: now,
            state: .ok,
            isActive: isActive
        )
    }

    static func state(_ accounts: [MonitoredAccount]) -> MonitorViewState {
        MonitorViewState(
            snapshot: AccountsSnapshot(
                accounts: accounts,
                capturedAt: now,
                sourceSchemaVersion: ClaudeMonitorCore.supportedSchemaVersion
            ),
            isLoading: false
        )
    }
}

@Suite("CM-20 · Tray-Oberfläche: Panel, Menü-Kennungen, Symbol, Eigenschaften")
struct TrayPresentationContractTests {

    // MARK: - T1 · Panel-Text

    /// Auflage 1 (Fachentscheid 5.3): Der Panel-Text trägt **Marker · Zahlen ·
    /// Restzeit** in genau dieser Reihenfolge und **keine** Account-Namen.
    ///
    /// Erwartungswert wörtlich aus der Spezifikation: „Panel zeigt bei
    /// gesetztem Reset `▸74/28 2h04`".
    ///
    /// ⚠️ Zum Aufbau: Die Restzeit steht nur an einem Segment mit **roter**
    /// Account-Ampel (`MenuBarRoleSelection.qualifiesForReset`, ab 85 %). Mit
    /// 74 %/28 % allein ist der Account gelb und die Restzeit entfiele — der
    /// Fall der Spezifikation ist deshalb der dokumentierte versteckte Engpass
    /// (`MenuBarDisplay` Regel 4): ein `spend`-Fenster bindet den Account rot,
    /// die beiden **sichtbaren** Zahlen bleiben 74/28, und die Restzeit gehört
    /// dem Engpassfenster.
    @Test("Panel-Text: Marker, Zahlen, Restzeit — in dieser Reihenfolge, ohne Namen")
    func labelTextCarriesMarkerNumbersAndCountdown() {
        let now = TrayFixture.now
        let account = TrayFixture.account(
            id: "1",
            name: "privat",
            windows: [
                TrayFixture.window(.fiveHour, percent: 74),
                TrayFixture.window(.sevenDay, percent: 28),
                // Engpassfenster: Reset 2 h 04 min nach `now`.
                TrayFixture.window(.spend, percent: 92, resetsAt: now.addingTimeInterval(7440))
            ],
            isActive: true
        )

        let label = TrayPresentation.make(for: TrayFixture.state([account]), now: now).labelText

        #expect(label == "▸74/28 2h04")
        // Fachentscheid 5.3: Namen stehen im Menü, nie im Panel.
        #expect(!label.contains("privat"))
    }

    // MARK: - T2 · Menü-Kennungen

    /// Auflage 6 / Fachentscheid 5.13: Die Kennungen der übrigen Einträge
    /// bleiben unverändert, wenn ein Account wegfällt — sie stammen aus dem
    /// stabilen `MonitoredAccount.id` über ein prozesslebenslanges Register,
    /// nicht aus der Position in der Liste.
    @Test("Menü-Kennungen überleben das Entfernen eines Accounts")
    func menuIdentifiersSurviveAccountRemoval() {
        let now = TrayFixture.now
        func account(_ id: String) -> MonitoredAccount {
            TrayFixture.account(
                id: id,
                name: "account-\(id)",
                windows: [
                    TrayFixture.window(.fiveHour, percent: 12),
                    TrayFixture.window(.sevenDay, percent: 34)
                ]
            )
        }

        // Dasselbe Register über beide Durchläufe — so lebt es im Prozess.
        let identifiers = TrayMenuIdentifiers()

        func identifiersOfMenu(for accounts: [MonitoredAccount]) -> [String: Int32] {
            let items = TrayPresentation.menu(for: TrayFixture.state(accounts), now: now)
            let layout = TrayMenuLayout.layout(
                of: items,
                identifiers: identifiers,
                parent: TrayMenuIdentifiers.root,
                depth: -1,
                propertyNames: []
            )
            guard case .structure(let root) = layout,
                  case .int32(let rootIdentifier) = root[0],
                  case .array(_, let children) = root[2]
            else {
                Issue.record("Layout hat nicht die Form (ia{sv}av)")
                return [:]
            }
            // Wurzel-ID bleibt 0.
            #expect(rootIdentifier == TrayMenuIdentifiers.root)

            var result: [String: Int32] = [:]
            for (index, child) in children.enumerated() {
                guard case .variant(let node) = child,
                      case .structure(let fields) = node,
                      case .int32(let identifier) = fields[0]
                else {
                    Issue.record("Kindknoten hat nicht die Form (ia{sv}av)")
                    continue
                }
                result[items[index].key] = identifier
            }
            return result
        }

        let before = identifiersOfMenu(for: [account("1"), account("2"), account("3")])
        let after = identifiersOfMenu(for: [account("2"), account("3")])

        #expect(before["account.2"] != nil)
        #expect(before["account.3"] != nil)
        #expect(after["account.2"] == before["account.2"])
        #expect(after["account.3"] == before["account.3"])
    }

    // MARK: - T3 · Symbol

    /// Auflage 2 (+ Fachentscheid 5.2/5.14): **Jeder** der fünf Zustände
    /// liefert ein nicht-leeres 22×22-ARGB32-Pixmap. Ein leeres Pixmap ergäbe
    /// im Panel den Fehler-Platzhalter `image-loading-symbolic`.
    @Test("Alle fünf Symbolzustände liefern ein nicht-leeres 22×22-ARGB32-Pixmap")
    func everyIconStateYieldsANonEmptyPixmap() {
        let states: [TrayIconStatus] = [
            .level(.green), .level(.yellow), .level(.red), .neutral, .noData
        ]

        for status in states {
            let bytes = TrayIconPixmap.argb32(for: status)
            #expect(TrayIconPixmap.size == 22)
            // 22 × 22 × 4 bei `rowStride = width * 4` (Fachentscheid 5.14).
            #expect(bytes.count == 1936)
            #expect(!bytes.isEmpty)
            // Mindestens ein sichtbares Pixel — sonst wäre das Bild zwar
            // formal da, aber leer im Sinne der Anzeige.
            #expect(bytes.enumerated().contains { $0.offset % 4 == 0 && $0.element > 0 })
        }

        // Byte-Reihenfolge am voll gedeckten Mittelpunkt der gelben Stufe:
        // A, dann R=255, G=149, B=0 (sRGB 255,149,0, Fachentscheid 5.14).
        let yellow = TrayIconPixmap.argb32(for: .level(.yellow))
        let center = (11 * TrayIconPixmap.size + 11) * 4
        #expect(yellow[center] == 255)
        #expect(yellow[center + 1] == 255)
        #expect(yellow[center + 2] == 149)
        #expect(yellow[center + 3] == 0)
    }

    // MARK: - T4 · Eigenschafts-Dispatcher

    /// Auflage 3: Der Dispatcher beantwortet **jede** Eigenschaftsanfrage mit
    /// einem Wert — unbekannte mit einem typgerechten Leerwert, nie mit einem
    /// Fehler. Eine `Unknown*`-Fehlerantwort zerstört das Item in der
    /// `ubuntu-appindicators`-Extension.
    @Test("Jede Eigenschaftsanfrage bekommt einen Wert, keine Fehlerantwort")
    func propertyDispatcherAlwaysAnswersWithAValue() {
        let now = TrayFixture.now
        let account = TrayFixture.account(
            id: "1",
            name: "account-1",
            windows: [
                TrayFixture.window(.fiveHour, percent: 74),
                TrayFixture.window(.sevenDay, percent: 28)
            ],
            isActive: true
        )
        let view = TrayPresentation.make(for: TrayFixture.state([account]), now: now)
        let table = TraySNIProperties.itemTable(for: view, menuPath: "/StatusNotifierItem/Menu")

        // Fachentscheid 5.2: immer „Active", auch im Fehlerfall.
        #expect(TraySNIProperties.value(named: "Status", in: table) == .string("Active"))

        // Auflage 2: das eigene Symbol ist nie leer.
        let pixmap = TraySNIProperties.value(named: "IconPixmap", in: table)
        if case .array(let signature, let elements) = pixmap {
            #expect(signature == "(iiay)")
            #expect(!elements.isEmpty)
        } else {
            Issue.record("IconPixmap ist kein a(iiay)")
        }

        // Die eine Eigenschaft, die die Spezifikation bewusst ausklammert.
        #expect(
            TraySNIProperties.value(named: "OverlayIconPixmap", in: table)
                == .array(elementSignature: "(iiay)", elements: [])
        )

        // Unbekannter Name: EIN typgerechter Leerwert. Der Rückgabetyp ist
        // nicht optional — „kein Wert" ist an dieser Stelle nicht darstellbar,
        // und ein Fehlername als Wert wäre genau die verbotene Antwort.
        #expect(TraySNIProperties.value(named: "AnythingUnknown", in: table) == .string(""))
    }
}
