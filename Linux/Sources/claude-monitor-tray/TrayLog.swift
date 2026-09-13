import Foundation
#if canImport(Glibc)
import Glibc
#endif

/// Das Protokoll des Tray-Prozesses — der Ersatz für `OSLog`, das es auf Linux
/// nicht gibt.
///
/// ⚠️ **Druckvertrag.** Auf macOS redigiert `os_log` dynamische Zeichenketten
/// von sich aus; `UsageMonitor.swift:182-199` beruht ausdrücklich darauf. Ein
/// handgeschriebener Protokollierer tut das **nicht** — er muss es selbst tun
/// (Auflage 10). Es gilt derselbe Vertrag wie für die Rauchprobe
/// (`Linux/Sources/claude-monitor/main.swift:5-20`, `Linux/README.md`):
///
/// * Keine personenbezogene oder fremdbestimmte Zeichenkette: kein
///   `displayName`, keine E-Mail, keine Organisations-UUID, kein Alias, kein
///   `lastError`, kein `window.label`/`window.id`, nicht der Rohschlüssel des
///   Falls `.other`.
/// * **Keine Reflexionsausgabe** eines Modell-, Anzeige- oder Menütyps:
///   keine String-Interpolation eines Modellwerts, kein `dump`, kein
///   `debugPrint`, kein `String(describing:)`. Keiner dieser Typen ist
///   `CustomStringConvertible`, die Standard-Reflexion gäbe daher **alle**
///   Felder aus, `displayName` inklusive.
/// * **Kein Wire-Dump** von D-Bus-Nachrichten. Ein Rumpf kann jeden dieser
///   Werte enthalten — auch den Menütext mit allen Account-Namen.
/// * Jede Zeile wird aus benannten Skalaren gebaut und läuft durch
///   ``redact(_:)``.
///
/// Der Gegenvertrag steht in Fachentscheid 5.5: Die **Oberfläche** zeigt
/// `displayName` sehr wohl — sie muss es, sonst ließen sich die Accounts nicht
/// unterscheiden. Redigiert wird das Protokoll, nicht das Menü.
///
/// **Ziel ist ausschließlich stderr** (Auflage 15). Keine eigene Logdatei:
/// Unter `CM-21` läuft der Prozess als systemd-Nutzerdienst, und das Journal
/// übernimmt Auffangen, Rotation und Aufbewahrung. Eine zweite Datei daneben
/// wäre eine zweite Halde, die niemand aufräumt.
final class TrayLog {

    /// Das Home-Verzeichnis wird **einmal** ermittelt und dient sowohl der
    /// Store-Suche als auch als Redaktionspräfix. Zwei getrennt ermittelte
    /// Werte gingen im Container auseinander — dann redigierte der Filter ein
    /// Präfix, das in den gedruckten Pfaden gar nicht vorkommt.
    private let homePrefix: String
    /// Kein brauchbares Präfix ⇒ es wird **kein** Pfad gedruckt, statt eines
    /// unredigierten.
    private let prefixIsUnusable: Bool
    /// Zuletzt gedruckte Zeile je Rubrik — Grundlage der Entprellung.
    private var lastLines: [String: String] = [:]

    init(homeDirectory: URL) {
        homePrefix = homeDirectory.path
        prefixIsUnusable = homePrefix.isEmpty || homePrefix == "/"
    }

    /// Der EINE Filter, durch den jede Zeile läuft.
    func redact(_ text: String) -> String {
        guard !prefixIsUnusable else { return text }
        return text.replacingOccurrences(of: homePrefix, with: "~")
    }

    /// `true`, wenn Pfade überhaupt gedruckt werden dürfen.
    var canPrintPaths: Bool { !prefixIsUnusable }

    /// Druckt eine Zeile — **entprellt**.
    ///
    /// Wiederholt sich die Zeile einer Rubrik, bleibt sie aus. Ohne das flutete
    /// der 30-s-Takt das Journal mit derselben Aussage; dieselbe Überlegung
    /// steht hinter `UsageMonitor.logIfChanged` (`UsageMonitor.swift:156-157`).
    func note(_ category: String, _ line: String) {
        guard lastLines[category] != line else { return }
        lastLines[category] = line
        write(line)
    }

    /// Druckt eine Zeile ohne Entprellung — für einmalige Ereignisse (Start,
    /// Abbau, Abbruchgründe).
    func always(_ line: String) {
        write(line)
    }

    /// Schreibt eine Zeile auf stderr — **ohne** zu trappen (CM-27).
    ///
    /// `FileHandle.standardError.write(_:)` ist die alte ObjC-Brücke: Sie wirft
    /// nicht, sondern beendet den Prozess mit einem Trap (Exit 132), sobald der
    /// Schreibversuch scheitert. Unter systemd ist genau das erreichbar — reißt
    /// die Journal-Pipe zusammen mit der Sitzung ab, träfe es ausgerechnet die
    /// Zeile direkt vor `return .connectionFailed`, und der Prozess endete mit
    /// dem falschen Code, den `CM-21` auswertet.
    ///
    /// Deshalb eine geprüfte `Glibc.write(2)`-Schleife im Stil von
    /// `DBusConnection.writeAll`: `EINTR` wird wiederholt, alles andere
    /// (insbesondere `EPIPE`) bricht still ab. Ein Protokollierer darf nie der
    /// Grund sein, warum ein Prozess stirbt. `Glibc.write` ist qualifiziert,
    /// sonst träfe der Name die Methode `TrayLog.write` selbst.
    private func write(_ line: String) {
        let bytes = Array((redact(line) + "\n").utf8)
        #if canImport(Glibc)
        var offset = 0
        bytes.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            while offset < bytes.count {
                let written = Glibc.write(2, base + offset, bytes.count - offset)
                if written > 0 {
                    offset += written
                    continue
                }
                if written < 0 && errno == EINTR { continue }
                return
            }
        }
        #else
        try? FileHandle.standardError.write(contentsOf: Data(bytes))
        #endif
    }
}
