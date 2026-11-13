import Foundation
import ClaudeMonitorCore
import ClaudeMonitorShared

/// Die Schnittstelle zwischen dem Tray-Prozess und dem GNOME-Popover (CM-41).
///
/// Ein drittes D-Bus-Objekt des Tray-Prozesses liefert den Popover-Zustand
/// strukturiert: `GetState` (out `s`, der JSON-String aus
/// ``TrayPopoverState/json()``), das Signal `StateChanged` (`s`, derselbe
/// String, nur bei Änderung), `Invoke` (in `s` = Schlüssel eines Menüeintrags,
/// out `b`) und `Opened`. Die Gegenstelle ist die Shell-Extension (CM-42); sie
/// meldet sich an, indem sie ``extensionBusName`` besitzt.
///
/// **Pflichten der Gegenstelle:**
/// 1. Den Namen ``extensionBusName`` erst besitzen, wenn das Popover im Panel
///    steht und `GetState` gelesen ist. Der Tray blendet sein eigenes Symbol
///    aus (`Status = Passive`), solange der Name einen Eigentümer hat — ein
///    zu früh besessener Name, gefolgt von einem Scheitern, ließe kein
///    Symbol übrig. In `disable()` den Namen **zuerst** freigeben.
/// 2. Protokoll 1 wächst nur additiv: neue Schlüssel ja, umbenennen,
///    entfernen oder umdeuten nie. Eine inkompatible Änderung erhöht
///    `protocol`.
/// 3. Eine Extension, die `protocol` nicht kennt, gibt den Namen frei.
public enum TrayPopoverInterface {

    public static let interfaceName = "org.claudemonitor.Tray.Popover1"
    public static let objectPath = "/Popover"
    /// Der Well-Known-Name der Extension. Sein Eigentümer ist das Zeichen,
    /// dass sie lebt.
    public static let extensionBusName = "org.claudemonitor.Popover"

    /// Die eigene `Introspect`-Antwort des Objekts unter ``objectPath``.
    public static let introspectionXML = """
        <!DOCTYPE node PUBLIC "-//freedesktop//DTD D-BUS Object Introspection 1.0//EN" \
        "http://www.freedesktop.org/standards/dbus/1.0/introspect.dtd">
        <node>
          <interface name="org.freedesktop.DBus.Introspectable">
            <method name="Introspect"><arg name="xml" type="s" direction="out"/></method>
          </interface>
          <interface name="org.claudemonitor.Tray.Popover1">
            <method name="GetState"><arg name="state" type="s" direction="out"/></method>
            <method name="Invoke">
              <arg name="key" type="s" direction="in"/>
              <arg name="accepted" type="b" direction="out"/>
            </method>
            <method name="Opened"/>
            <signal name="StateChanged"><arg name="state" type="s"/></signal>
          </interface>
        </node>
        """
}

/// Der Zustand des Popovers als JSON-Vertrag (Protokoll 1).
///
/// Jeder Schlüssel ist immer da, ein fehlender Wert ist `null`. Deshalb
/// schreibt jede Struktur mit Optional-Feldern ihr `encode(to:)` selbst: Die
/// synthetisierte Fassung ließe den Schlüssel bei `nil` weg
/// (`encodeIfPresent`), und eine Gegenstelle in GJS läse `undefined` statt
/// `null`.
///
/// Alle Texte sind fertig, die Extension rechnet nichts. Die einzige Zahl, die
/// sie weiterverarbeiten darf, ist ``Window/fraction`` (Balkenbreite).
/// Schlüssel sind sortiert. Das Diagnose-Detail des Hinweisbalkens steht
/// bewusst nicht darin — wie im Menü gehen nur Titel und Erklärung hinaus.
///
/// Gebaut wird aus **denselben** Shared-Typen wie ``TrayPresentation/menu(for:now:autostart:autoUpdate:updateCheck:)``;
/// eine Textregel steht an einem Ort.
public struct TrayPopoverState: Codable, Equatable, Sendable {

    public static let protocolVersion = 1

    /// Titel und Erklärung des Hinweisbalkens.
    public struct Issue: Codable, Equatable, Sendable {
        public let title: String
        public let explanation: String
    }

    /// Eine Fensterzeile eines Accounts.
    public struct Window: Codable, Equatable, Sendable {
        public let id: String
        public let name: String
        /// `compact` („42%"), `null` bei nicht darstellbarem Wert.
        public let percentText: String?
        /// Balkenbreite 0…1, `null` bei nicht darstellbarem Wert.
        public let fraction: Double?
        /// Stufe des Fensters: `green`, `yellow` oder `red`.
        public let status: String
        /// `"2h04"`, `"due"` oder `null` (Reset unbekannt).
        public let resetText: String?

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(id, forKey: .id)
            try container.encode(name, forKey: .name)
            try container.encode(percentText, forKey: .percentText)
            try container.encode(fraction, forKey: .fraction)
            try container.encode(status, forKey: .status)
            try container.encode(resetText, forKey: .resetText)
        }
    }

    /// Ein Account-Kärtchen.
    public struct Account: Codable, Equatable, Sendable {
        public let id: String
        public let name: String
        public let isActive: Bool
        /// `"▸"` beim aktiven Account, sonst `null`.
        public let marker: String?
        /// `"#<id>"`.
        public let number: String
        /// Text der bindenden Auslastung oder `"–"`.
        public let binding: String
        /// Gesamtstufe (`overallStatus`) oder `null` ohne Aussage.
        public let status: String?
        /// Statuszeile, nur bei Warnung.
        public let statusText: String?
        /// „No usable data", wenn der Account keine Fenster zeigt.
        public let noDataText: String?
        /// „Updated … ago", wenn die Statuszeile das Alter nicht schon nennt.
        public let updatedText: String?
        public let windows: [Window]

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(id, forKey: .id)
            try container.encode(name, forKey: .name)
            try container.encode(isActive, forKey: .isActive)
            try container.encode(marker, forKey: .marker)
            try container.encode(number, forKey: .number)
            try container.encode(binding, forKey: .binding)
            try container.encode(status, forKey: .status)
            try container.encode(statusText, forKey: .statusText)
            try container.encode(noDataText, forKey: .noDataText)
            try container.encode(updatedText, forKey: .updatedText)
            try container.encode(windows, forKey: .windows)
        }
    }

    /// Ein Segment der Leiste.
    public struct Segment: Codable, Equatable, Sendable {
        public let id: String
        public let marker: String?
        public let status: String?
        public let numbersText: String
        public let resetText: String?

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(id, forKey: .id)
            try container.encode(marker, forKey: .marker)
            try container.encode(status, forKey: .status)
            try container.encode(numbersText, forKey: .numbersText)
            try container.encode(resetText, forKey: .resetText)
        }
    }

    /// Die Leiste in einem der beiden Modi.
    public struct PanelMode: Codable, Equatable, Sendable {
        public let segments: [Segment]
        /// `green`, `yellow`, `red`, `neutral` oder `noData`.
        public let icon: String
        public let accessibleText: String
    }

    /// Beide Modi sind **immer** vorhanden — der Umschalter gehört der
    /// Extension, der Tray speichert nichts.
    public struct Panel: Codable, Equatable, Sendable {
        public let activeAccount: PanelMode
        public let overview: PanelMode
    }

    public struct Footer: Codable, Equatable, Sendable {
        public let checkedText: String
    }

    /// Ein Eintrag aus Einstellungen, „Refresh" und „Quit" — mit dem
    /// Schlüssel, den `Invoke` annimmt.
    public struct Control: Codable, Equatable, Sendable {
        public let key: String
        public let role: String
        public let label: String
        public let enabled: Bool
        /// Häkchen, `null` bei einem Eintrag ohne Häkchen.
        public let checked: Bool?

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(key, forKey: .key)
            try container.encode(role, forKey: .role)
            try container.encode(label, forKey: .label)
            try container.encode(enabled, forKey: .enabled)
            try container.encode(checked, forKey: .checked)
        }
    }

    public let `protocol`: Int
    public let header: String
    public let issue: Issue?
    /// `loading`, `empty`, `issueOnly` oder `accounts`.
    public let content: String
    /// In Menüreihenfolge (nach Account-Nummer).
    public let accounts: [Account]
    public let panel: Panel
    public let footer: Footer?
    public let controls: [Control]

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(`protocol`, forKey: .protocol)
        try container.encode(header, forKey: .header)
        try container.encode(issue, forKey: .issue)
        try container.encode(content, forKey: .content)
        try container.encode(accounts, forKey: .accounts)
        try container.encode(panel, forKey: .panel)
        try container.encode(footer, forKey: .footer)
        try container.encode(controls, forKey: .controls)
    }

    /// Der JSON-String mit sortierten Schlüsseln. Nie leer: Scheitert das
    /// Codieren, kommt der Rückfall `{"protocol":1}`.
    public func json() -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(self),
              let text = String(data: data, encoding: .utf8),
              !text.isEmpty
        else { return "{\"protocol\":\(Self.protocolVersion)}" }
        return text
    }

    // MARK: - Abbildung

    /// Baut den Zustand aus denselben Typen wie das Menü.
    public static func make(
        for state: MonitorViewState,
        now: Date,
        autostart: TrayAutostartDisplay?,
        autoUpdate: TrayAutoUpdateDisplay?,
        updateCheck: TrayUpdateCheck?
    ) -> TrayPopoverState {
        let content: String
        var accounts: [Account] = []
        switch PopoverContent.make(for: state, now: now) {
        case .loading: content = "loading"
        case .empty: content = "empty"
        case .issueOnly: content = "issueOnly"
        case .accounts(let sorted):
            content = "accounts"
            accounts = sorted.map { account(for: $0, now: now) }
        }

        let issue = state.issue.map {
            Issue(title: TrayTexts.issueTitle(for: $0), explanation: TrayTexts.issueExplanation(for: $0))
        }
        let controls = TrayPresentation.settingsItems(autostart: autostart, autoUpdate: autoUpdate, updateCheck: updateCheck)
            + [TrayPresentation.refreshItem, TrayPresentation.quitItem]

        return TrayPopoverState(
            protocol: protocolVersion,
            header: TrayTexts.header,
            issue: issue,
            content: content,
            accounts: accounts,
            panel: Panel(
                activeAccount: panelMode(for: state, mode: .activeAccount, now: now),
                overview: panelMode(for: state, mode: .overview, now: now)
            ),
            footer: TrayPresentation.checkedText(for: state, now: now).map(Footer.init(checkedText:)),
            controls: controls.map(control(for:))
        )
    }

    private static func account(for account: MonitoredAccount, now: Date) -> Account {
        let parts = TrayPresentation.headerParts(for: account)
        let windows: [Window]
        let noDataText: String?
        switch AccountWindowsDisplay.make(for: account) {
        case .noUsableData:
            windows = []
            noDataText = TrayTexts.noUsableData
        case .windows(let shown):
            windows = shown.map { window(for: $0, now: now) }
            noDataText = nil
        }
        return Account(
            id: account.id,
            name: parts.name,
            isActive: account.isActive,
            marker: parts.marker,
            number: parts.number,
            binding: parts.binding,
            status: account.overallStatus?.rawValue,
            statusText: TrayPresentation.statusText(for: account, now: now),
            noDataText: noDataText,
            updatedText: TrayPresentation.updatedText(for: account, now: now),
            windows: windows
        )
    }

    private static func window(for window: LimitWindow, now: Date) -> Window {
        Window(
            id: window.id,
            name: WindowKindNaming.name(for: window.kind),
            percentText: PercentFormatting.compact(window.percent),
            fraction: PercentFormatting.fraction(window.percent),
            status: window.status.rawValue,
            resetText: TrayPresentation.resetText(for: window, now: now)
        )
    }

    private static func panelMode(for state: MonitorViewState, mode: MenuBarMode, now: Date) -> PanelMode {
        let display = MenuBarDisplay.make(for: state, mode: mode, now: now)
        let spoken = TrayPresentation.labelText(for: display, withMarkers: false)
        return PanelMode(
            segments: display.segments.map { segment in
                Segment(
                    id: segment.id,
                    marker: segment.markerText,
                    status: segment.status?.rawValue,
                    numbersText: segment.numbersText,
                    resetText: segment.resetText
                )
            },
            icon: iconName(TrayIconAggregation.icon(for: display)),
            accessibleText: TraySNIProperties.accessibleDescription(spokenLabelText: spoken)
        )
    }

    private static func iconName(_ icon: TrayIconStatus) -> String {
        switch icon {
        case .level(let level): return level.rawValue
        case .neutral: return "neutral"
        case .noData: return "noData"
        }
    }

    private static func control(for item: TrayMenuItem) -> Control {
        Control(
            key: item.key,
            role: item.role.rawValue,
            label: item.label,
            enabled: item.isEnabled,
            checked: item.checkmark?.isOn
        )
    }
}
