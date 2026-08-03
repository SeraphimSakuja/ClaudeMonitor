import Foundation
import Testing
@testable import ClaudeMonitorCore

@Suite("ISO8601Parsing — Zeitstempel der Quelle")
struct ISO8601ParsingTests {

    /// Referenzzeitpunkt 2026-08-03T16:50:00Z.
    private static let reference: Date = {
        var components = DateComponents()
        components.year = 2026; components.month = 8; components.day = 3
        components.hour = 16; components.minute = 50; components.second = 0
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar.date(from: components)!
    }()

    // MARK: - Kürzung des Bruchteils

    @Test("Mikrosekunden werden auf drei Stellen gekürzt")
    func normalizesToThreeDigits() {
        #expect(
            ISO8601Parsing.normalizedFractionalSeconds(in: "2026-08-03T16:50:00.191164+00:00")
                == "2026-08-03T16:50:00.191+00:00"
        )
    }

    @Test("Drei oder weniger Stellen bleiben unverändert")
    func keepsShortFractions() {
        #expect(
            ISO8601Parsing.normalizedFractionalSeconds(in: "2026-08-03T16:50:00.19+00:00")
                == "2026-08-03T16:50:00.19+00:00"
        )
        #expect(
            ISO8601Parsing.normalizedFractionalSeconds(in: "2026-08-03T16:50:00+00:00")
                == "2026-08-03T16:50:00+00:00"
        )
    }

    // MARK: - Fallback ohne Bruchteil (F13)

    @Test("strippedFractionalSeconds entfernt den Bruchteil vollständig")
    func stripsFraction() {
        #expect(
            ISO8601Parsing.strippedFractionalSeconds(in: "2026-08-03T16:50:00.191164+00:00")
                == "2026-08-03T16:50:00+00:00"
        )
        #expect(
            ISO8601Parsing.strippedFractionalSeconds(in: "2026-08-03T16:50:00.5Z")
                == "2026-08-03T16:50:00Z"
        )
    }

    @Test("Ohne Punkt bleibt der Zeitstempel beim Strippen unangetastet")
    func stripsNothingWithoutDot() {
        #expect(
            ISO8601Parsing.strippedFractionalSeconds(in: "2026-08-03T16:50:00Z")
                == "2026-08-03T16:50:00Z"
        )
    }

    @Test("Der gestrippte Zeitstempel ist selbst parsbar — der Fallback trägt")
    func strippedResultIsParsable() throws {
        let stripped = ISO8601Parsing.strippedFractionalSeconds(in: "2026-08-03T16:50:00.191164+00:00")
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let parsed = try #require(formatter.date(from: stripped))
        #expect(parsed == Self.reference)
    }

    // MARK: - Parsen

    @Test("Mikrosekunden-Zeitstempel wird auf den erwarteten Instant geparst")
    func parsesMicroseconds() throws {
        let date = try #require(ISO8601Parsing.date(from: "2026-08-03T16:50:00.191164+00:00"))
        #expect(abs(date.timeIntervalSince(Self.reference.addingTimeInterval(0.191))) < 0.001)
    }

    @Test("Zeitstempel ohne Bruchteil wird ebenfalls geparst")
    func parsesWithoutFraction() throws {
        let date = try #require(ISO8601Parsing.date(from: "2026-08-03T16:50:00+00:00"))
        #expect(date == Self.reference)
    }

    @Test("Fehlender oder unbrauchbarer Zeitstempel ergibt nil")
    func rejectsGarbage() {
        #expect(ISO8601Parsing.date(from: nil) == nil)
        #expect(ISO8601Parsing.date(from: "") == nil)
        #expect(ISO8601Parsing.date(from: "morgen früh") == nil)
    }
}
