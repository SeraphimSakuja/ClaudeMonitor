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

/// Die Unit-Datei, die systemd für `claude-monitor-tray.service` tatsächlich
/// lädt, gemessen gegen den eigenen Zielpfad (CM-32).
///
/// `enable`, `disable` und `is-enabled` wirken über den **Namen**. Lädt
/// systemd dafür eine andere Datei als `unitPath` — gleich in welchem
/// Verzeichnis, auch wenn am Zielpfad gar keine liegt —, schaltete Einrichten
/// die fremde Unit ein und Entfernen sie ab.
public enum AutostartEffectiveUnit: Equatable, Sendable {
    /// systemd lädt dieselbe Datei wie `unitPath`, oder gar keine.
    case notShadowed
    /// systemd lädt eine andere Datei.
    case shadowed(path: String)
    /// Nicht erhoben — bei einer Maske ist FragmentPath der Masken-Link selbst.
    case notMeasured

    /// Gerät und Inode einer Datei.
    public struct FileIdentity: Equatable, Sendable {
        public let device: UInt64
        public let inode: UInt64

        public init(device: UInt64, inode: UInt64) {
            self.device = device
            self.inode = inode
        }
    }

    /// Die Identitätsregel: dieselbe Datei heißt gleicher Pfad **oder**
    /// gleiches Gerät + Inode.
    ///
    /// - Parameters:
    ///   - fragmentIdentity: `stat` des FragmentPath (folgt Links); `nil`, wenn
    ///     `stat` scheiterte — dann gilt die Unit als fremd.
    ///   - unitIdentity: `lstat` des Zielpfads, nur gesetzt für eine
    ///     **reguläre** Datei.
    public static func compare(
        fragmentPath: String,
        unitPath: String,
        fragmentIdentity: FileIdentity?,
        unitIdentity: FileIdentity?
    ) -> AutostartEffectiveUnit {
        if fragmentPath == unitPath { return .notShadowed }
        if let fragmentIdentity, let unitIdentity, fragmentIdentity == unitIdentity { return .notShadowed }
        return .shadowed(path: fragmentPath)
    }
}

/// Zeigt die eigene Autostart-Unit auf das laufende Binary? (CM-34)
///
/// Maßstab ist die Datei auf der Platte; gleich heißt gleiche Datei
/// (Gerät + Inode), nicht gleicher Pfadtext.
public enum AutostartBinaryMatch: Equatable, Sendable {
    case matches
    case differs(unitExecutable: String, running: String)
    case missing(unitExecutable: String)
    /// Keine eigene Unit am Zielpfad, nicht lesbar, nicht auswertbar oder das
    /// laufende Binary nicht auflösbar — keine Behauptung ohne Messung.
    case notMeasured

    /// - Parameters:
    ///   - unitExecutable: Pfad aus der Unit; `nil`, wenn keiner auswertbar war.
    ///   - unitTarget: Identität des Ziels, nur für eine reguläre ausführbare Datei.
    ///   - running: Pfad des laufenden Binarys; `nil`, wenn nicht auflösbar.
    ///   - runningIdentity: Identität des laufenden Binarys.
    public static func compare(
        unitExecutable: String?,
        unitTarget: AutostartEffectiveUnit.FileIdentity?,
        running: String?,
        runningIdentity: AutostartEffectiveUnit.FileIdentity?
    ) -> AutostartBinaryMatch {
        guard let unitExecutable else { return .notMeasured }
        guard let unitTarget else { return .missing(unitExecutable: unitExecutable) }
        guard let running, let runningIdentity else { return .notMeasured }
        return unitTarget == runningIdentity
            ? .matches
            : .differs(unitExecutable: unitExecutable, running: running)
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
    /// systemd lädt für den Namen eine andere Datei als den Zielpfad (CM-32);
    /// `enable` schaltete sie ein.
    case refuseShadowed(fragmentPath: String)

    /// Die Entscheidungstabelle.
    ///
    /// Reihenfolge der Prüfungen, und warum:
    /// 1. **Symlink am Ziel** zuerst — dorthin lässt sich ohnehin nicht
    ///    schreiben (`O_NOFOLLOW`), egal was der Zustand sagt.
    /// 2. **Maske** vor „fremde Datei" — eine maskierte Unit kann nebenbei
    ///    eine reguläre Datei am Zielpfad haben; der Grund, warum nichts
    ///    wirkt, ist dann die Maske.
    /// 3. **Verschattet** — systemd lädt eine andere Datei; was am Zielpfad
    ///    liegt, ist dann wirkungslos.
    /// 4. **Unlesbar** bzw. **fremde Datei** — vorhanden, aber ohne Marker.
    /// 5. Sonst einrichten; eine eigene Datei wird dabei aufgefrischt.
    public static func plan(
        target: AutostartTargetProbe,
        status: AutostartStatus.Reading,
        effectiveUnit: AutostartEffectiveUnit
    ) -> AutostartPlan {
        if target.isSymlink { return .refuseSymlink }
        if status == .known(.requiresApproval) { return .alreadyMaskedInform }
        if case .shadowed(let path) = effectiveUnit { return .refuseShadowed(fragmentPath: path) }
        if let reason = target.unreadableReason { return .refuseUnreadable(reason: reason) }
        if target.exists && !target.carriesMarker { return .refuseForeignFile }
        return .install
    }
}

/// Die Entscheidung vor dem Entfernen — Gegenstück zu ``AutostartPlan``
/// (CM-30, 2b-Auflage 3).
///
/// Entfernt wird nur, was diese Einrichtung selbst geschrieben hat. Ohne
/// diese Prüfung löschte `--uninstall-autostart` — und seit CM-30 ein
/// Menüklick — eine von Hand geschriebene Unit am selben Pfad, die das
/// Einrichten ausdrücklich unangetastet lässt.
public enum AutostartRemovalPlan: Equatable, Sendable {

    /// Abschalten und löschen. Auch, wenn am Zielpfad gar nichts liegt: Dann
    /// werden nur noch verbliebene `.wants`-Verweise aufgeräumt.
    case remove
    /// Am Zielpfad liegt eine Datei ohne Marker.
    case refuseForeignFile
    /// Die vorgefundene Datei ließ sich nicht lesen — ob sie den Marker
    /// trägt, ist unbekannt.
    case refuseUnreadable(reason: String)
    /// Der Zielpfad ist ein Symlink; diese Einrichtung legt dort nie einen an.
    case refuseSymlink
    /// systemd lädt für den Namen eine andere Datei (CM-32). Weder `disable`
    /// noch ein Löschen — auch die eigene, wirkungslose Datei bleibt liegen.
    case refuseShadowed(fragmentPath: String)

    /// Dieselbe Reihenfolge wie
    /// ``AutostartPlan/plan(target:status:effectiveUnit:)``, ohne die
    /// Masken-Stufe: Beim Entfernen ist die Maske kein Hindernis, sie bleibt
    /// nur stehen. Bei einer Maske ist `effectiveUnit` ``AutostartEffectiveUnit/notMeasured``.
    public static func plan(
        target: AutostartTargetProbe,
        effectiveUnit: AutostartEffectiveUnit
    ) -> AutostartRemovalPlan {
        if target.isSymlink { return .refuseSymlink }
        if case .shadowed(let path) = effectiveUnit { return .refuseShadowed(fragmentPath: path) }
        if let reason = target.unreadableReason { return .refuseUnreadable(reason: reason) }
        if target.exists && !target.carriesMarker { return .refuseForeignFile }
        return .remove
    }

    /// Ob ein `.wants`-Verweis bei maskierter Unit auf eine **fremde** Datei
    /// zeigt (CM-32, 2b-Auflage 5).
    ///
    /// Bei einer Maske wird die wirksame Unit nicht erhoben; die Verweise
    /// würden rein über den Namen gelöscht. Zeigt einer auf eine vorhandene
    /// Datei, die nicht die eigene ist, gehört er zu einer fremden Unit.
    ///
    /// - Parameters:
    ///   - linkTarget: `stat` des Verweises (folgt dem Link); `nil` bei totem
    ///     Verweis — der wird wie bisher aufgeräumt.
    ///   - unitIdentity: `lstat` des Zielpfads, nur für eine reguläre Datei.
    public static func isForeignWantsLink(
        linkTarget: AutostartEffectiveUnit.FileIdentity?,
        unitIdentity: AutostartEffectiveUnit.FileIdentity?
    ) -> Bool {
        guard let linkTarget else { return false }
        return linkTarget != unitIdentity
    }
}
