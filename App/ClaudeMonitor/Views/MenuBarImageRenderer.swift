import AppKit
import SwiftUI
import ClaudeMonitorCore
import ClaudeMonitorShared

/// Zeichnet die **gesamte** Menüleistenanzeige in ein einziges `NSImage`.
///
/// Warum überhaupt selbst zeichnen: Ein `NSStatusItem` hat genau **ein** Bild
/// und **einen** Titel. SwiftUI bildet das Label eines `MenuBarExtra` darauf
/// ab — mehrere `Image`/`Text` in einem `HStack` können dort nicht dargestellt
/// werden, es überlebte nur das erste Paar. Am Gerät verifiziert: Statt sechs
/// Werten stand nur `●74%` in der Leiste. ``MenuBarIcon`` benutzt dasselbe
/// Verfahren bereits für den einzelnen Ampelpunkt; hier ist es auf die ganze
/// Anzeige hochgezogen.
///
/// **Der Preis dieses Wegs ist die Textfarbe.** Ein Schablonenbild
/// (`isTemplate = true`) würde AppKit passend zum hellen bzw. dunklen
/// Erscheinungsbild einfärben — dann gingen aber die Ampelfarben verloren, und
/// die sind hier die halbe Information. Also `isTemplate = false`, und der Text
/// muss selbst in der richtigen Farbe gezeichnet werden: `NSColor.labelColor`,
/// aufgelöst im passenden ``NSAppearance``. Der Aufrufer liest dazu
/// `@Environment(\.colorScheme)` und reicht es herein — dadurch wertet SwiftUI
/// das Label bei einem Wechsel hell↔dunkel neu aus und das Bild entsteht neu.
///
/// Die **Anzeigeregeln** stehen nicht hier, sondern geprüft in `Shared/`
/// (``MenuBarDisplay``). Diese Datei zeichnet nur, was dort entschieden wurde.
@MainActor
enum MenuBarImageRenderer {

    // MARK: - Maße

    /// Durchmesser des Ampelpunktes.
    private static let dotDiameter: CGFloat = 8
    /// Abstand zwischen Punkt und Zahlen desselben Accounts.
    private static let dotTextGap: CGFloat = 3
    /// Abstand zwischen zwei Accounts. Bewusst deutlich größer als
    /// ``dotTextGap``, weil er das einzige Trennzeichen ist — ein `│` kostete
    /// Breite, die in der Menüleiste knapp ist.
    private static let segmentGap: CGFloat = 8
    /// Luft links und rechts, damit die Leiste nicht am Nachbarsymbol klebt.
    private static let horizontalInset: CGFloat = 2
    /// Abstand zwischen der Markierung des aktiven Accounts und seinem Punkt.
    private static let markerGap: CGFloat = 1

    /// Schrift der Leiste — mit **Ziffern fester Breite**: Ohne sie zappelte
    /// die Gesamtbreite bei jedem Prozentwechsel, und mit ihr die Position
    /// aller Nachbarsymbole in der Menüleiste.
    private static let font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)

    /// Schrift der Zahlen des **aktiven** Accounts. Gleiche Größe und ebenfalls
    /// Ziffern fester Breite — nur schwerer: So bleibt die Breite eines
    /// Segments von seinem Zustand unabhängig genug, und die Auszeichnung
    /// kommt ohne Farbe aus (die gehört der Ampel).
    private static let activeFont = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .bold)

    // MARK: - Zwischenspeicher

    /// Letzter Schlüssel und das dazu gezeichnete Bild.
    ///
    /// Ein Eintrag genügt: Zwischen zwei Auswertungen ändert sich der Zustand
    /// entweder gar nicht (dann trifft der Eintrag) oder er ist neu (dann wäre
    /// jeder ältere Eintrag ohnehin wertlos). Der Speicher ist **statisch**,
    /// weil SwiftUI die View-Struct bei jeder Auswertung neu erzeugt — an einer
    /// Instanz hinge er nur bis zum nächsten Rumpf. `@MainActor` isoliert ihn,
    /// wie bei ``MenuBarIcon``; AppKit-Zeichnen gehört ohnehin auf den
    /// Hauptthread.
    private static var cachedKey: (display: MenuBarDisplay, colorScheme: ColorScheme)?
    private static var cachedImage: NSImage?

    /// Das fertige Bild für die Leiste.
    ///
    /// Verworfen wird der Zwischenspeicher genau dann, wenn sich die Anzeige
    /// (``MenuBarDisplay`` ist `Equatable`) **oder** das Erscheinungsbild
    /// ändert — also bei jedem neuen Prozentwert, jedem Moduswechsel und jedem
    /// Wechsel hell↔dunkel. Bei gleichem Schlüssel kommt dasselbe Bild zurück,
    /// statt es bei jeder Rumpfauswertung neu zu zeichnen.
    static func image(for display: MenuBarDisplay, colorScheme: ColorScheme) -> NSImage? {
        // Leer heißt: nichts zu sagen. Dann das neutrale Schablonensymbol —
        // AppKit färbt es passend ein, und eine selbstgezeichnete Fassung
        // müsste diese Einfärbung nachbauen.
        guard !display.segments.isEmpty else { return MenuBarIcon.image(for: nil) }

        if let cachedKey, let cachedImage,
           cachedKey.display == display, cachedKey.colorScheme == colorScheme {
            return cachedImage
        }

        let image = draw(display, colorScheme: colorScheme)
        cachedKey = (display, colorScheme)
        cachedImage = image
        return image
    }

    // MARK: - Zeichnen

    private static func draw(_ display: MenuBarDisplay, colorScheme: ColorScheme) -> NSImage {
        let palette = Palette(colorScheme: colorScheme)
        // `numbersText` kommt aus `Shared/` — welche Zahlen mit welchem
        // Trennzeichen dastehen, ist eine geprüfte Anzeigeregel und keine
        // Entscheidung des Zeichners.
        //
        // Auch **welcher** Account ausgezeichnet wird und womit, steht in
        // `Shared/` (``MenuBarDisplay/AccountSegment/markerText``) — der
        // Zeichner setzt es nur in Pixel um.
        let texts = display.segments.map {
            attributed($0.numbersText, color: palette.label, font: $0.isActive ? activeFont : font)
        }
        let markers = display.segments.map { segment in
            segment.markerText.map { attributed($0, color: palette.label, font: activeFont) }
        }
        let overflow = display.hasMoreAccounts
            ? attributed(MenuBarDisplay.overflowText, color: palette.dimmedLabel, font: font)
            : nil

        // Breiten **einmal** messen: Der Zeichenblock unten läuft potenziell
        // mehrfach (Neuzeichnen durch AppKit), und eine dort neu gemessene
        // Breite müsste zwingend dieselbe sein wie die der Bildgröße — sonst
        // liefe die Anzeige aus dem Bild heraus.
        let widths = texts.map { $0.size().width }
        let markerWidths = markers.map { marker -> CGFloat in
            guard let marker else { return 0 }
            return marker.size().width + markerGap
        }
        let dotColors = display.segments.map { $0.status.map(palette.status) ?? palette.neutralDot }

        let height = NSStatusBar.system.thickness
        var width = horizontalInset * 2
        for (index, textWidth) in widths.enumerated() {
            if index > 0 { width += segmentGap }
            width += markerWidths[index] + dotDiameter + dotTextGap + textWidth
        }
        let overflowWidth = overflow.map { $0.size().width }
        if let overflowWidth { width += segmentGap + overflowWidth }

        let size = NSSize(width: ceil(width), height: height)
        let image = NSImage(size: size, flipped: false) { _ in
            var x = horizontalInset
            for (index, text) in texts.enumerated() {
                if index > 0 { x += segmentGap }

                if let marker = markers[index] {
                    draw(marker, at: x, height: height)
                    x += markerWidths[index]
                }

                dotColors[index].setFill()
                NSBezierPath(
                    ovalIn: NSRect(
                        x: x,
                        y: (height - dotDiameter) / 2,
                        width: dotDiameter,
                        height: dotDiameter
                    )
                ).fill()
                x += dotDiameter + dotTextGap

                draw(text, at: x, height: height)
                x += widths[index]
            }
            if let overflow {
                x += segmentGap
                draw(overflow, at: x, height: height)
            }
            return true
        }
        // Ampelfarben überleben ein Schablonenbild nicht (siehe ``MenuBarIcon``).
        image.isTemplate = false
        return image
    }

    /// Zeichnet eine Zeile senkrecht mittig — ausgerichtet an der
    /// **Versalhöhe**, nicht an der vollen Zeilenhöhe: Diese enthält Platz für
    /// Unterlängen, die in „74/28" gar nicht vorkommen, und die Zahlen säßen
    /// dadurch sichtbar zu tief.
    ///
    /// Der Ursprung von `draw(at:)` ist im ungedrehten Kontext die **untere**
    /// linke Ecke der Zeile, also `descender` (negativ) unterhalb der
    /// Grundlinie. Gesucht ist `grundlinie = (height - capHeight) / 2`; daraus
    /// folgt der Ursprung als `grundlinie + descender`.
    /// Die Maße kommen aus der Schrift **dieser** Zeile und nicht aus
    /// ``font``: Die Leiste setzt den aktiven Account fett, und eine hier fest
    /// angenommene Schrift setzte dessen Zahlen minimal versetzt gegen die
    /// übrigen.
    private static func draw(_ text: NSAttributedString, at x: CGFloat, height: CGFloat) {
        // `attribute(at:)` verlangt einen gültigen Index — bei leerem Text gäbe
        // es keinen.
        let lineFont = text.length > 0
            ? (text.attribute(.font, at: 0, effectiveRange: nil) as? NSFont ?? font)
            : font
        let origin = (height - lineFont.capHeight) / 2 + lineFont.descender
        text.draw(at: NSPoint(x: x, y: origin))
    }

    private static func attributed(_ string: String, color: NSColor, font: NSFont) -> NSAttributedString {
        NSAttributedString(string: string, attributes: [.font: font, .foregroundColor: color])
    }

    // MARK: - Farben

    /// Die im gewünschten Erscheinungsbild **aufgelösten** Farben.
    ///
    /// Aufgelöst wird einmal vorab: Der Zeichenblock von
    /// `NSImage(size:flipped:drawingHandler:)` läuft nicht zwingend sofort und
    /// nicht zwingend unter demselben Erscheinungsbild — dynamische Farben
    /// (`labelColor`, `systemGreen` …) würden dort erneut und womöglich falsch
    /// ausgewertet. `usingColorSpace` friert sie zum Zeitpunkt der Auflösung
    /// ein.
    private struct Palette {

        let label: NSColor
        let dimmedLabel: NSColor
        let neutralDot: NSColor
        private let statusColors: [StatusLevel: NSColor]

        init(colorScheme: ColorScheme) {
            let appearance = NSAppearance(named: colorScheme == .dark ? .darkAqua : .aqua)
                ?? NSAppearance.currentDrawing()

            var label = NSColor.labelColor
            var dimmed = NSColor.labelColor.withAlphaComponent(0.6)
            var neutral = NSColor.secondaryLabelColor
            var statuses: [StatusLevel: NSColor] = [:]

            appearance.performAsCurrentDrawingAppearance {
                label = Palette.frozen(.labelColor)
                dimmed = Palette.frozen(.labelColor).withAlphaComponent(0.6)
                neutral = Palette.frozen(.secondaryLabelColor)
                for status in StatusLevel.allCases {
                    statuses[status] = Palette.frozen(StatusAppearance.nsColor(for: status))
                }
            }

            self.label = label
            self.dimmedLabel = dimmed
            self.neutralDot = neutral
            self.statusColors = statuses
        }

        /// Ampelfarbe einer Stufe — aus ``StatusAppearance``, nicht nachgebaut.
        func status(_ level: StatusLevel) -> NSColor {
            statusColors[level] ?? neutralDot
        }

        private static func frozen(_ color: NSColor) -> NSColor {
            color.usingColorSpace(.sRGB) ?? color
        }
    }
}
