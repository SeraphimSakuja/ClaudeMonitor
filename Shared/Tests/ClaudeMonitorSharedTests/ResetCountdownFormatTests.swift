import Foundation
import Testing
import ClaudeMonitorCore
import ClaudeMonitorShared

/// Das grobe Zeitformat der Menüleiste.
///
/// Es ist bewusst sprachneutral und minutengenau — die Leiste ist ein alle 30 s
/// neu gezeichnetes Bild, kein tickender Text. Ein sekundengenaues Format
/// spränge sichtbar.
@Suite("Restzeit-Format der Menüleiste")
struct ResetCountdownFormatTests {

    @Test("Stunden werden zweistellig ergänzt, damit die Leiste nicht zappelt")
    func hoursPadMinutes() {
        #expect(ResetCountdownFormat.text(for: .remaining(2 * 3600 + 14 * 60)) == "2h14")
        // Ohne Auffüllen stünde hier „2h4" — die Zeichenkette wäre je nach
        // Minute unterschiedlich lang und die Leiste bewegte sich ständig.
        #expect(ResetCountdownFormat.text(for: .remaining(2 * 3600 + 4 * 60)) == "2h04")
        #expect(ResetCountdownFormat.text(for: .remaining(3600)) == "1h00")
    }

    @Test("Unter einer Stunde stehen nur Minuten")
    func minutesOnlyBelowAnHour() {
        #expect(ResetCountdownFormat.text(for: .remaining(47 * 60)) == "47m")
        #expect(ResetCountdownFormat.text(for: .remaining(60)) == "1m")
        // Abgerundet: 59 s sind noch keine Minute.
        #expect(ResetCountdownFormat.text(for: .remaining(119)) == "1m")
    }

    @Test("Unter einer Minute steht „<1m“ statt einer Null")
    func subMinuteIsImminentNotZero() {
        // „0m" hier wäre eine Lüge: Der Reset ist noch nicht fällig.
        #expect(ResetCountdownFormat.text(for: .remaining(59)) == "<1m")
        #expect(ResetCountdownFormat.text(for: .remaining(1)) == "<1m")
    }

    @Test("Ab einem Tag wird in Tagen gerechnet")
    func daysAboveTwentyFourHours() {
        // Ein 7-Tage-Fenster liefe sonst als „167h30" durch die Leiste.
        #expect(ResetCountdownFormat.text(for: .remaining(24 * 3600)) == "1d0")
        #expect(ResetCountdownFormat.text(for: .remaining(6 * 24 * 3600 + 23 * 3600)) == "6d23")
    }

    @Test("Ein fälliger Reset ist 0, ein unbekannter ist nichts")
    func dueIsZeroAndUnknownIsNil() {
        #expect(ResetCountdownFormat.text(for: .due) == "0m")
        // Der Unterschied, auf den es ankommt: „fällig" ist eine Aussage,
        // „unbekannt" ist keine. Ein Platzhalter wie „–" behauptete hier etwas.
        #expect(ResetCountdownFormat.text(for: .unknown) == nil)
        #expect(ResetCountdownFormat.text(for: .remaining(1800)) == "30m")
    }

    @Test("Nicht-endliche und negative Werte ergeben keinen Unsinn")
    func nonFiniteValuesStayHarmless() {
        // Aus einer kaputten Quelle darf kein „nanhinf" in der Leiste stehen.
        #expect(ResetCountdownFormat.text(for: .remaining(.nan)) == "0m")
        #expect(ResetCountdownFormat.text(for: .remaining(.infinity)) == "0m")
        #expect(ResetCountdownFormat.text(for: .remaining(-60)) == "0m")
    }
}
