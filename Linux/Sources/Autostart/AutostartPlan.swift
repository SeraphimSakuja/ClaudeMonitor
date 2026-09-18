import Foundation
import ClaudeMonitorShared

/// Was am Zielpfad vorgefunden wurde — das Ergebnis der Messung, nicht die
/// Messung selbst. Gefüllt wird sie im Programm-Ziel.
public struct AutostartTargetProbe: Equatable, Sendable {

    /// Ob am Zielpfad überhaupt etwas liegt (auch ein toter Symlink zählt).
    public let exists: Bool
    /// Ob der Zielpfad **selbst** ein Symlink ist (`lstat`, nicht `stat`).
    public let isSymlink: Bool
    /// Ob die vorgefundene Datei den Marker dieser Einrichtung trägt.
    public let carriesMarker: Bool
    /// Gesetzt, wenn das Lesen der vorgefundenen Datei fehlschlug (EACCES,
    /// kaputtes UTF-8, ...) — dann ist `carriesMarker == false` KEINE Aussage
    /// über den Inhalt, sondern nur „konnte nicht gelesen werden".
    public let unreadableReason: String?

    public init(exists: Bool, isSymlink: Bool, carriesMarker: Bool, unreadableReason: String? = nil) {
        self.exists = exists
        self.isSymlink = isSymlink
        self.carriesMarker = carriesMarker
        self.unreadableReason = unreadableReason
    }
}

/// Die Entscheidung vor dem Schreiben — reine Tabelle, ohne Dateizugriff.
public enum AutostartPlan: Equatable, Sendable {

    /// Schreiben und einschalten.
    case install
    /// Am Zielpfad liegt eine Datei, die diese Einrichtung nicht geschrieben
    /// hat. Sie wird nicht angefasst.
    case refuseForeignFile
    /// Die vorgefundene Datei ließ sich nicht lesen (EACCES, kaputtes UTF-8,
    /// ...) — ob sie den Marker trägt, ist unbekannt, nicht „nein".
    case refuseUnreadable(reason: String)
    /// Der Zielpfad ist ein **Symlink**.
    ///
    /// ⚠️ Das ist ausdrücklich **nicht** dasselbe wie ``alreadyMaskedInform``
    /// (Auflage 8): Eine systemd-Maske ist ein Symlink nach `/dev/null` im
    /// **Konfig**baum, den der Nutzer bewusst gesetzt hat. Ein Symlink am
    /// Zielpfad im **Daten**baum ist eine fremde oder kaputte Datei am
    /// Zielort. „Autostart ist maskiert" wäre hier eine Falschauskunft.
    case refuseSymlink
    /// Der Nutzer hat die Unit maskiert; `enable` bliebe wirkungslos.
    case alreadyMaskedInform

    /// Die Entscheidungstabelle.
    ///
    /// Reihenfolge der Prüfungen, und warum:
    /// 1. **Symlink am Ziel** zuerst — dorthin lässt sich ohnehin nicht
    ///    schreiben (`O_NOFOLLOW`), egal was der Zustand sagt.
    /// 2. **Maske** vor „fremde Datei" — eine maskierte Unit kann nebenbei
    ///    eine reguläre Datei am Zielpfad haben; der Grund, warum nichts
    ///    wirkt, ist dann die Maske.
    /// 3. **Fremde Datei** — vorhanden, aber ohne Marker.
    /// 4. Sonst einrichten; eine eigene Datei wird dabei aufgefrischt.
    public static func plan(target: AutostartTargetProbe, status: AutostartStatus.Reading) -> AutostartPlan {
        if target.isSymlink { return .refuseSymlink }
        if status == .known(.requiresApproval) { return .alreadyMaskedInform }
        if let reason = target.unreadableReason { return .refuseUnreadable(reason: reason) }
        if target.exists && !target.carriesMarker { return .refuseForeignFile }
        return .install
    }
}
