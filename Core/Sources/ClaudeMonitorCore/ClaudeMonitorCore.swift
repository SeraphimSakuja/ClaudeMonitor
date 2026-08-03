import Foundation

/// Kernlogik des ClaudeMonitor — Gerüst, Implementierung folgt.
///
/// Der Monitor liest ausschließlich den lokalen Cache von `claude-swap`
/// (`usage.json`) und schreibt niemals hinein: claude-swap serialisiert seine
/// Writes read-modify-write unter einem File-Lock, ein Fremdzugriff könnte den
/// Store beschädigen.
public enum ClaudeMonitorCore {
    /// Cache-Schemaversion von claude-swap, gegen die dieser Monitor gebaut ist.
    /// Weicht die gelesene Datei davon ab, zeigt der Monitor einen sichtbaren
    /// Hinweis statt möglicherweise falscher Zahlen.
    public static let supportedSchemaVersion = 2

    /// claude-swap-Version, gegen die zuletzt verifiziert wurde.
    public static let verifiedAgainstCswapVersion = "0.22.0"
}
