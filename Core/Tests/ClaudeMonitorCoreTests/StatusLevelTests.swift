import Foundation
import Testing
@testable import ClaudeMonitorCore

@Suite("StatusLevel — Ampelstufen und Grenzwerte")
struct StatusLevelTests {

    @Test("Stufen im Normalbereich")
    func levels() {
        #expect(StatusLevel(percent: 0) == .green)
        #expect(StatusLevel(percent: 25) == .green)
        #expect(StatusLevel(percent: 60) == .yellow)
        #expect(StatusLevel(percent: 90) == .red)
        #expect(StatusLevel(percent: 100) == .red)
    }

    @Test("Grenzwert gelb: 50 gehört zur höheren Stufe")
    func yellowBoundary() {
        #expect(StatusLevel(percent: StatusLevel.yellowThreshold - 0.0001) == .green)
        #expect(StatusLevel(percent: StatusLevel.yellowThreshold) == .yellow)
        #expect(StatusLevel(percent: StatusLevel.yellowThreshold + 0.0001) == .yellow)
    }

    @Test("Grenzwert rot: 85 gehört zur höheren Stufe")
    func redBoundary() {
        #expect(StatusLevel(percent: StatusLevel.redThreshold - 0.0001) == .yellow)
        #expect(StatusLevel(percent: StatusLevel.redThreshold) == .red)
        #expect(StatusLevel(percent: StatusLevel.redThreshold + 0.0001) == .red)
    }

    @Test("Schwellen sind benannte Konstanten mit den erwarteten Werten")
    func thresholdConstants() {
        #expect(StatusLevel.yellowThreshold == 50)
        #expect(StatusLevel.redThreshold == 85)
        #expect(StatusLevel.yellowThreshold < StatusLevel.redThreshold)
    }

    @Test("Ausreißer: negativ ist grün, über 100 und nicht-endlich sind rot")
    func outliers() {
        #expect(StatusLevel(percent: -5) == .green)
        #expect(StatusLevel(percent: 140) == .red)
        #expect(StatusLevel(percent: .nan) == .red)
        #expect(StatusLevel(percent: .infinity) == .red)
    }
}
