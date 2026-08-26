import Testing
import ClaudeMonitorShared

/// CM-18: „kein Account mehr" von „Accounts bekannt, aber keiner traf zu"
/// unterscheiden.
@Suite("Identitäts-Drift-Diagnose")
struct IdentityDriftDiagnosticTests {

    @Test("Bekannte Accounts, aber keiner traf zu ⇒ Drift vermutet")
    func knownAccountsWithNoMatchIsDrift() {
        #expect(IdentityDriftDiagnostic.isSuspected(accountsIsEmpty: true, knownAccountCount: 2))
    }

    @Test("sequence.json kennt explizit keinen Account ⇒ Normalfall, keine Drift")
    func explicitlyZeroKnownAccountsIsNotDrift() {
        #expect(IdentityDriftDiagnostic.isSuspected(accountsIsEmpty: true, knownAccountCount: 0) == false)
    }

    @Test("sequence.json sagt nichts (nil) ⇒ Fail-open-Fall, keine Drift")
    func noInformationIsNotDrift() {
        #expect(IdentityDriftDiagnostic.isSuspected(accountsIsEmpty: true, knownAccountCount: nil) == false)
    }

    @Test("Accounts vorhanden ⇒ nie Drift, unabhängig von knownAccountCount")
    func nonEmptyAccountsIsNeverDrift() {
        #expect(IdentityDriftDiagnostic.isSuspected(accountsIsEmpty: false, knownAccountCount: 5) == false)
        #expect(IdentityDriftDiagnostic.isSuspected(accountsIsEmpty: false, knownAccountCount: nil) == false)
    }
}
