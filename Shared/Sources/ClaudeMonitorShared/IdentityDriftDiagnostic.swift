import Foundation

/// Unterscheidet zwei Zustände, die bisher gleich aussahen (CM-18): „claude-swap
/// verwaltet gerade keinen Account" (Normalfall, z. B. Erstlauf oder nach dem
/// letzten `remove_account`) und „claude-swap kennt Accounts, aber keiner davon
/// erschien in `usage.json`" (Identitäts-Drift — z. B. eine Feld-Umbenennung auf
/// Schreiberseite; `sequence.json` trägt keine `schemaVersion`, die das
/// abfangen könnte).
///
/// Reine Bedingung, framework-frei: der eigentliche `logger.debug`-Aufruf
/// bleibt in der App-Schicht (Core/Shared loggen nicht), aber die Regel selbst
/// ist ohne `OSLog` testbar.
public enum IdentityDriftDiagnostic {

    /// - Parameters:
    ///   - accountsIsEmpty: `true`, wenn der Lesedurchlauf keinen einzigen
    ///     Account ergab (`AccountsSnapshot.accounts.isEmpty`).
    ///   - knownAccountCount: Anzahl der Accounts, die `sequence.json` kennt
    ///     (`AccountSequenceInfo.knownAccounts?.count`) — `nil`, wenn die
    ///     Quelle nichts gesagt hat (Datei fehlt, kaputt); dieser Fall ist
    ///     **keine** Drift, sondern die bereits bekannte Fail-open-Lage.
    public static func isSuspected(accountsIsEmpty: Bool, knownAccountCount: Int?) -> Bool {
        accountsIsEmpty && (knownAccountCount ?? 0) > 0
    }
}
