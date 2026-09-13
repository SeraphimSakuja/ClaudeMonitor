import Foundation
import ClaudeMonitorCore
import ClaudeMonitorShared

// Rauchprobe für den Linux-Bau (CM-19). Strikt lesend: kein Schreiben, kein
// Lock, kein `SnapshotStore.write` (Leitplanke L1).
//
// ⚠️ **Druckvertrag.** Dieses Werkzeug schreibt NIE eine personenbezogene oder
// fremdbestimmte Zeichenkette nach stdout/stderr. Verboten sind namentlich:
// `displayName`, `email`, `organizationUuid`, `organizationName`, jeder Alias,
// `lastError`, `window.label`, `window.id`, der Rohschlüssel des Falls
// `.other` — und zusätzlich JEDE Reflexionsausgabe eines Modell- oder
// Anzeigetyps: String-Interpolation eines Modelltyps (`"\(account)"`),
// `print(<Modelltyp>)`, `dump(...)`, `String(describing: <Modelltyp>)`,
// `debugPrint`. Grund: keiner dieser Typen ist `CustomStringConvertible`, die
// Standard-Reflexion gäbe daher ALLE gespeicherten Felder aus, `displayName`
// inklusive. Jede Ausgabezeile wird deshalb aus benannten Skalaren gebaut
// (String, Int, Double, Bool, Fallname) und läuft durch `redact(_:)`.

// MARK: - Home-Bezugsquelle

/// Das Home-Verzeichnis wird **einmal** ermittelt. Genau dieser Wert geht an
/// `UsageStoreReader.read(homeDirectory:)` UND dient als Redaktionspräfix.
///
/// Grund: Im Container mit `--user` ohne passenden `passwd`-Eintrag kann
/// `homeDirectoryForCurrentUser` etwas anderes liefern als das, womit gesucht
/// wurde — dann redigierte der Filter ein Präfix, das in den gedruckten Pfaden
/// gar nicht vorkommt, und die Pfade gingen unredigiert hinaus.
let homeDirectory = FileManager.default.homeDirectoryForCurrentUser
let homePrefix = homeDirectory.path

/// `true`, wenn kein brauchbares Präfix vorliegt. Dann wird **kein** Pfad
/// gedruckt — statt eines unredigierten.
let homePrefixIsUnusable = homePrefix.isEmpty || homePrefix == "/"

// MARK: - Redaktionsfilter

/// Der EINE Filter, durch den jede Ausgabezeile aller vier Fälle läuft —
/// zentral, damit die Regel an genau einer Stelle brechbar ist und nicht an
/// fünf.
func redact(_ text: String) -> String {
    guard !homePrefixIsUnusable else { return text }
    return text.replacingOccurrences(of: homePrefix, with: "~")
}

func emitOut(_ line: String) { print(redact(line)) }

func emitErr(_ line: String) { FileHandle.standardError.write(Data((redact(line) + "\n").utf8)) }

// MARK: - Namensfreie Abbildungen

/// Fenstertyp als namensfreier Text.
///
/// `rawKey` ist NUR für die vier festen Fälle namensfrei; `.other` gibt den
/// rohen Schlüssel aus der Fremddatei zurück und wird deshalb auf den festen
/// Text `other` abgebildet.
func kindText(_ kind: LimitWindow.Kind) -> String {
    if case .other = kind { return "other" }
    return kind.rawKey
}

/// Zustand als Fallname mit ausschließlich **numerischen** Nutzlasten.
/// Die `message`-Nutzlast von `.failing` wird NIE gedruckt.
func stateText(_ state: AccountState) -> String {
    switch state {
    case .ok: return "ok"
    case .noData: return "noData"
    case .authDead(let strikes): return "authDead(strikes: \(strikes))"
    case .backoff: return "backoff"
    case .failing: return "failing"
    }
}

/// Ziffern-Schranke für jede gedruckte Kennung (Fachentscheid 7).
///
/// `MonitoredAccount.id` stammt ungefiltert aus dem Slot-Schlüssel der
/// Fremddatei (`usage.json`) — das kann alles sein, auch eine E-Mail-Adresse.
/// Gedruckt wird die Kennung deshalb NUR, wenn sie aus reinen Ziffern besteht;
/// sonst der feste Ersatztext `nonNumeric`. Damit ist die Invariante
/// „nachgemessen reine Zahlen" mechanisch durchgesetzt und nicht bloß durch
/// den fail-open-Vorfilter der Nebenquelle erhofft.
func idText(_ identifier: String) -> String {
    !identifier.isEmpty && identifier.allSatisfy(\.isNumber) ? identifier : "nonNumeric"
}

func percentText(_ percent: Double) -> String {
    percent.isFinite ? String(format: "%.1f", percent) : "n/a"
}

/// Fallname des Popover-Inhalts — nie sein Inhalt.
func popoverText(_ content: PopoverContent) -> String {
    switch content {
    case .loading: return "loading"
    case .empty: return "empty"
    case .issueOnly: return "issueOnly"
    case .accounts(let list): return "accounts(\(list.count))"
    }
}

// MARK: - Lauf

let now = Date()
let result = UsageStoreReader().read(homeDirectory: homeDirectory, now: now)

switch result {
case .success(let snapshot):
    emitOut("store=ok accounts=\(snapshot.accounts.count) schemaVersion=\(snapshot.sourceSchemaVersion)")

    for account in snapshot.accounts {
        var parts: [String] = ["#\(idText(account.id))"]
        for window in account.windows {
            parts.append("\(kindText(window.kind))=\(percentText(window.percent))")
        }
        parts.append("state=\(stateText(account.state))")
        parts.append("isActive=\(account.isActive ? "yes" : "no")")
        emitOut(parts.joined(separator: " "))
    }

    // Der Shared-Anzeigeweg wird wirklich durchlaufen — ein Lauf deckt Core
    // UND Shared ab.
    let state = MonitorViewState().reduced(with: result)
    let display = MenuBarDisplay.make(for: state, mode: .overview, now: now)

    // Kopfzeile: ohne sie wären 0 Segmentzeilen nicht von „Werkzeug defekt"
    // zu unterscheiden.
    if display.segments.isEmpty {
        emitOut("display=unavailable")
    } else {
        emitOut("display=segments(\(display.segments.count))")
    }

    for segment in display.segments {
        // Wörtlich aus benannten Eigenschaften — `displayName` ist verboten.
        var parts: [String] = []
        if let marker = segment.markerText { parts.append(marker) }
        parts.append("#\(idText(segment.id))")
        parts.append(segment.numbersText)
        if let reset = segment.resetText { parts.append(reset) }
        emitOut(parts.joined(separator: " "))
    }

    emitOut("popover=\(popoverText(PopoverContent.make(for: state, now: now)))")
    exit(0)

case .storeNotFound(let searchedPaths):
    emitErr("store=notFound searched=\(searchedPaths.count)")
    if homePrefixIsUnusable {
        emitErr("(Pfade nicht gedruckt: kein brauchbares Home-Präfix zum Redigieren)")
    } else {
        for path in searchedPaths { emitErr("searched: \(path)") }
    }
    exit(2)

case .unsupportedSchemaVersion(let found, let expected):
    emitErr("store=unsupportedSchemaVersion found=\(found.map(String.init) ?? "none") expected=\(expected)")
    exit(3)

case .unreadable(let reason):
    // ⚠️ `reason` ist im Decoder-Zweig `error.localizedDescription` und damit
    // **plattformabhängig** (`UsageStoreReader.swift:118`) — Wortlaut und
    // Sprache dürfen NICHT als stabil gelesen werden. Er läuft wie jede andere
    // Zeile durch `redact(_:)`; ein fremdbestimmter Dateiinhalt wird dadurch
    // nicht garantiert entfernt, weshalb diese Zeile bewusst der einzige
    // unsichere Zweig des Druckvertrags ist.
    emitErr("store=unreadable reason=\(reason)")
    exit(4)
}
