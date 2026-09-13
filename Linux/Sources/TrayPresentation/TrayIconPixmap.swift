import Foundation
import ClaudeMonitorCore
import ClaudeMonitorShared
import DBusWire

/// Was das Symbol im Panel sagt.
///
/// Fünf Zustände und nicht drei: Neben den drei Ampelstufen gibt es
/// ausdrücklich einen Zustand für „Account ohne Aussage" und einen für „keine
/// Daten" (Auflage 2). Der Grund ist handfest: Ein **leeres** Pixmap wirft in
/// der `ubuntu-appindicators`-Extension `TypeError('Empty Icon found')`
/// (`pixmapsUtils.js:37-38`), gefangen in `appIndicator.js:1486-1496` — im
/// Panel steht dann `image-loading-symbolic`, der Fehler-Platzhalter. Das bräche
/// die Zusage aus §5.2, dass das Item sichtbar bleibt **und etwas sagt**.
public enum TrayIconStatus: Equatable, Sendable {
    /// Eine der drei Ampelstufen.
    case level(StatusLevel)
    /// Daten da, aber keine Aussage möglich (``MenuBarDisplay/AccountSegment/status``
    /// ist `nil`, etwa bei totem Token).
    case neutral
    /// Kein einziger Account mit verwertbaren Daten
    /// (``MenuBarDisplay/segments`` leer). Ein gültiger Zustand, kein Fehler
    /// (Fachentscheid 5.6).
    case noData
}

/// Wählt das Symbol zu einer Leistenanzeige.
public enum TrayIconAggregation {

    /// ⚠️ **VORLÄUFIG — CM-25 entscheidet.**
    ///
    /// Ein `StatusNotifierItem` hat genau **ein** Symbol (Fachentscheid 5.15);
    /// die Leiste auf macOS zeichnet dagegen einen Punkt je Account. Wie sich
    /// mehrere Ampeln auf eine zusammenziehen — schlechteste Stufe, Stufe des
    /// aktiven Accounts, Stufe des erstgereihten — ist eine Frage an den
    /// Kunden und ausdrücklich **nicht** Teil dieser Karte. Sie ist an `CM-25`
    /// ausgelagert und sperrt dort die Auslieferung, nicht den Bau.
    ///
    /// Bis dahin gilt Weg (a) der Spezifikation: die Stufe des **erstgereihten**
    /// Segments. Das ist auf macOS der Account, den die Rollenauswahl als
    /// „besten" vorne einsortiert — die Auskunft, auf die man in der Leiste
    /// zuerst schaut.
    ///
    /// Diese Funktion ist die einzige Stelle, an der die Regel steht. `CM-25`
    /// tauscht ihren Rumpf aus; die Signatur bleibt, kein Aufrufer ändert sich.
    public static func provisionalIcon(for display: MenuBarDisplay) -> TrayIconStatus {
        guard let first = display.segments.first else { return .noData }
        guard let status = first.status else { return .neutral }
        return .level(status)
    }
}

/// Das Symbol als ARGB32-Pixmap für `org.kde.StatusNotifierItem`.
///
/// Format gemessen gegen `pixmapsUtils.js:17,58-61,65` (Fachentscheid 5.14):
/// ARGB32 in **Netzwerk-Byte-Reihenfolge** (big-endian, also A,R,G,B in dieser
/// Reihenfolge im Speicher) und `rowStride = width * 4`. Das ist ausdrücklich
/// nicht die Byte-Reihenfolge des übrigen Protokolls — der Draht ist
/// little-endian, das Bild nicht.
public enum TrayIconPixmap {

    /// Kantenlänge. 22 px ist die Größe, die GNOME für Panel-Symbole skaliert;
    /// größer gerendert und herunterskaliert sähe auf einem Nicht-HiDPI-Panel
    /// matschig aus.
    public static let size = 22

    /// Farben der drei Stufen — **Linux-eigen** (Fachentscheid 5.14).
    ///
    /// Der Zwilling dieser Regel steht auf macOS in `StatusAppearance.swift:19-25`
    /// (`yellow` → `systemOrange`). Beide bilden dieselbe Stufe auf einen
    /// Orangeton ab, und aus demselben Grund: Gelb auf hellem Grund ist
    /// praktisch unsichtbar. Die Stufe heißt trotzdem weiter `yellow` — der
    /// Name gehört zum Modell, der Farbwert zur Darstellung.
    static func color(for status: TrayIconStatus) -> (r: UInt8, g: UInt8, b: UInt8) {
        switch status {
        case .level(.green): return (52, 199, 89)
        case .level(.yellow): return (255, 149, 0)
        case .level(.red): return (255, 59, 48)
        case .neutral, .noData: return (142, 142, 147)
        }
    }

    /// Die Bytes des Symbols — **nie leer**.
    ///
    /// - `.level`/`.neutral`: gefüllter Punkt.
    /// - `.noData`: offener Ring. Sichtbar anders als ein gefüllter Punkt und
    ///   trotzdem ein Punkt — „ich bin da, ich habe nur nichts zu sagen".
    public static func argb32(for status: TrayIconStatus) -> [UInt8] {
        let (red, green, blue) = color(for: status)
        let side = Double(size)
        let center = (side - 1) / 2
        let outer = side / 2 - 2
        let inner = status == .noData ? outer - 3 : 0

        var pixels = [UInt8](repeating: 0, count: size * size * 4)
        for y in 0..<size {
            for x in 0..<size {
                let dx = Double(x) - center
                let dy = Double(y) - center
                let distance = (dx * dx + dy * dy).squareRoot()
                // Deckung statt harter Kante: Ohne diese halbe Pixelbreite
                // sieht ein 22-px-Kreis ausgefranst aus.
                var coverage = min(max(outer - distance + 0.5, 0), 1)
                if inner > 0 {
                    coverage = min(coverage, min(max(distance - inner + 0.5, 0), 1))
                }
                let alpha = UInt8(coverage * 255)
                let offset = (y * size + x) * 4
                // Netzwerk-Byte-Reihenfolge: A, R, G, B.
                pixels[offset] = alpha
                pixels[offset + 1] = red
                pixels[offset + 2] = green
                pixels[offset + 3] = blue
            }
        }
        return pixels
    }

    /// Das Pixmap als `a(iiay)`, so wie die Eigenschaft `IconPixmap` es
    /// verlangt: Breite, Höhe, Bytes.
    public static func dbusValue(for status: TrayIconStatus) -> DBusValue {
        let bytes = argb32(for: status).map { DBusValue.byte($0) }
        return .array(elementSignature: "(iiay)", elements: [
            .structure([
                .int32(Int32(size)),
                .int32(Int32(size)),
                .array(elementSignature: "y", elements: bytes)
            ])
        ])
    }

    /// Ein ausdrücklich **leeres** Pixmap-Feld — für die Eigenschaften, die es
    /// gar nicht gibt (`OverlayIconPixmap`, `AttentionIconPixmap`).
    ///
    /// Das ist kein Widerspruch zu Auflage 2: Leer sein darf nur, was die
    /// Extension gar nicht erst zu zeichnen versucht. `IconPixmap` gehört nicht
    /// dazu.
    public static let emptyPixmapArray = DBusValue.array(elementSignature: "(iiay)", elements: [])
}
