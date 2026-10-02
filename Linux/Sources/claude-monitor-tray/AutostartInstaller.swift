import Foundation
#if canImport(Glibc)
import Glibc
#endif
import Autostart
import ClaudeMonitorShared
import Update

/// Eine systemd-Nutzer-Unit, die dieses Programm schreibt und wieder entfernt
/// (CM-29).
///
/// Die Schutzregeln (Symlink, fremde Datei, Maske, Verschattung) sind eine
/// veröffentlichte Zusage und gelten für JEDE Unit dieses Programms. Deshalb
/// läuft jede Unit durch dieselbe Kette im ``AutostartInstaller`` — parametriert
/// über diesen Deskriptor statt über eine zweite Kopie der Kette.
struct ManagedUnit: Sendable {

    /// Wie die Unit eingeschaltet wird — und damit, wie ihr Zustand zu lesen ist.
    enum Kind: Sendable {
        /// Mit `[Install]`; `enable` hängt sie in die Zielgruppe.
        /// `is-enabled` antwortet `enabled`/`disabled`/`masked`/`not-found`.
        case enableable
        /// Ohne `[Install]`; wird nie eingeschaltet, nur von einer anderen
        /// Unit ausgelöst. `is-enabled` antwortet `static` (2b-Auflage 1) —
        /// diese Lesart läuft nie durch `usableState`.
        case staticUnit
    }

    let name: String
    let kind: Kind
    /// Die Zeile, an der die Einrichtung ihre eigene Datei wiedererkennt.
    let marker: String
    /// Rendert den Unit-Text für den Pfad des laufenden Binarys.
    let render: @Sendable (String) -> String
    /// Pfade aus der Umgebung.
    let layout: @Sendable ([String: String]) -> Result<AutostartPaths.Layout, AutostartPaths.ResolveError>
    /// Nach `enable` prüfen, ob die Zielgruppe aktiv ist (nur Autostart,
    /// Auflage 15b von CM-21).
    let warnsIfInstallTargetInactive: Bool
    /// Beim Entfernen nach `disable` auch `stop` (2b-Auflage 10): Abschalten
    /// wirkt sofort. Nicht für den Autostart — dort beendet Entfernen den
    /// laufenden Tray ausdrücklich NICHT (Auflage 16 von CM-21).
    let stopsOnRemoval: Bool

    /// Die Autostart-Unit (CM-21) — der bisherige Standardfall.
    static let autostart = ManagedUnit(
        name: AutostartPaths.unitName,
        kind: .enableable,
        marker: AutostartUnit.markerComment,
        render: { AutostartUnit.render(executablePath: $0) },
        layout: { AutostartPaths.layout(environment: $0) },
        warnsIfInstallTargetInactive: true,
        stopsOnRemoval: false
    )

    /// Der Timer des Auto-Updates — die einzige Unit, die eingeschaltet wird.
    static let updateTimer = ManagedUnit(
        name: UpdateUnits.timerName,
        kind: .enableable,
        marker: UpdateUnits.markerComment,
        render: { _ in UpdateUnits.renderTimer() },
        layout: {
            AutostartPaths.layout(
                environment: $0,
                unitName: UpdateUnits.timerName,
                installTarget: UpdateUnits.timerInstallTarget
            )
        },
        warnsIfInstallTargetInactive: false,
        stopsOnRemoval: true
    )

    /// Der statische Service des Auto-Updates.
    static let updateService = ManagedUnit(
        name: UpdateUnits.serviceName,
        kind: .staticUnit,
        marker: UpdateUnits.markerComment,
        render: { UpdateUnits.renderService(executablePath: $0) },
        layout: { AutostartPaths.layout(environment: $0, unitName: UpdateUnits.serviceName, installTarget: nil) },
        warnsIfInstallTargetInactive: false,
        stopsOnRemoval: false
    )
}

/// Eine Einrichtung: die Units, die zusammen geschrieben, eingeschaltet und
/// entfernt werden, plus ihr Textsatz.
struct ManagedUnitSet: Sendable {
    /// In Schreibreihenfolge. Statische Units zuerst: Scheitert das Schreiben
    /// einer späteren, ist noch nichts eingeschaltet.
    let units: [ManagedUnit]
    let messages: UnitMessages
    /// Vor dem Einrichten prüfen, ob das Verzeichnis des Binarys schreibbar
    /// ist (FE 12): Sonst könnte der Service das Binary nie ersetzen.
    let requiresWritableBinaryDirectory: Bool

    /// Die eine eingeschaltete Unit, deren Zustand gemeldet wird.
    var primary: ManagedUnit {
        units.first { if case .enableable = $0.kind { return true } else { return false } } ?? units[0]
    }

    static let autostart = ManagedUnitSet(
        units: [.autostart],
        messages: .autostart,
        requiresWritableBinaryDirectory: false
    )

    static let autoUpdate = ManagedUnitSet(
        units: [.updateService, .updateTimer],
        messages: .autoUpdate,
        requiresWritableBinaryDirectory: true
    )
}

/// Der Textsatz einer Einrichtung. Die Texte selbst stehen in den
/// Bibliothekszielen (`AutostartTexts`, `UpdateTexts`); hier wird nur
/// zugeordnet. Für den Autostart sind es exakt die bisherigen Texte — die
/// Ausgaben von install/uninstall/status bleiben bytegleich.
struct UnitMessages: Sendable {
    let managerUnavailable: String
    let systemctlUnavailable: @Sendable (_ reason: String) -> String
    let unexpectedState: @Sendable (_ unitName: String, _ word: String) -> String
    let unreadableState: @Sendable (_ unitName: String, _ word: String) -> String
    let effectiveUnitUndetermined: @Sendable (_ unitName: String, _ reason: String) -> String
    let effectiveUnitUnusableValue: @Sendable (_ unitName: String, _ value: String) -> String
    let directoryNotWritable: @Sendable (_ directory: String) -> String
    let masked: @Sendable (_ unitName: String) -> String
    let foreignFile: @Sendable (_ unitPath: String) -> String
    let foreignFileUnreadable: @Sendable (_ unitPath: String, _ reason: String) -> String
    let symlinkAtTarget: @Sendable (_ unitPath: String) -> String
    let shadowedNotInstalled: @Sendable (_ fragmentPath: String, _ unitName: String, _ unitPath: String) -> String
    let shadowedNotRemoved: @Sendable (_ fragmentPath: String, _ unitName: String, _ unitPath: String) -> String
    let foreignFileNotRemoved: @Sendable (_ unitPath: String) -> String
    let unreadableFileNotRemoved: @Sendable (_ unitPath: String, _ reason: String) -> String
    let symlinkNotRemoved: @Sendable (_ unitPath: String) -> String
    let foreignWantsLinkNotRemoved: @Sendable (_ linkPath: String, _ unitPath: String) -> String
    let writeFailed: @Sendable (_ path: String, _ reason: String) -> String
    let enableDidNotTake: @Sendable (_ unitName: String) -> String
    let staleWantsLink: @Sendable (_ path: String) -> String
    /// Erfolgsmeldungen erhalten die Unit-Pfade in Schreibreihenfolge.
    let installed: @Sendable (_ unitPaths: [String]) -> String
    let alreadyEnabled: @Sendable (_ unitPaths: [String]) -> String
    let removed: @Sendable (_ unitPaths: [String]) -> String
    let nothingToRemove: @Sendable (_ unitPaths: [String]) -> String
    /// Statusmeldungen erhalten den Pfad der eingeschalteten Unit.
    let statusEnabled: @Sendable (_ unitPath: String) -> String
    let statusDisabled: @Sendable (_ unitPath: String) -> String

    static let autostart = UnitMessages(
        managerUnavailable: AutostartTexts.managerUnavailable,
        systemctlUnavailable: { AutostartTexts.systemctlUnavailable(reason: $0) },
        unexpectedState: { _, word in AutostartTexts.unexpectedState(word: word) },
        unreadableState: { _, word in AutostartTexts.unreadableState(word: word) },
        effectiveUnitUndetermined: { _, reason in AutostartTexts.effectiveUnitUndetermined(reason: reason) },
        effectiveUnitUnusableValue: { _, value in AutostartTexts.effectiveUnitUnusableValue(value) },
        directoryNotWritable: { _ in "" },
        masked: { AutostartTexts.masked(unitName: $0) },
        foreignFile: { AutostartTexts.foreignFile(unitPath: $0) },
        foreignFileUnreadable: { AutostartTexts.foreignFileUnreadable(unitPath: $0, reason: $1) },
        symlinkAtTarget: { AutostartTexts.symlinkAtTarget(unitPath: $0) },
        shadowedNotInstalled: { fragment, _, unitPath in
            AutostartTexts.shadowedNotInstalled(fragmentPath: fragment, unitPath: unitPath)
        },
        shadowedNotRemoved: { fragment, _, unitPath in
            AutostartTexts.shadowedNotRemoved(fragmentPath: fragment, unitPath: unitPath)
        },
        foreignFileNotRemoved: { AutostartTexts.foreignFileNotRemoved(unitPath: $0) },
        unreadableFileNotRemoved: { AutostartTexts.unreadableFileNotRemoved(unitPath: $0, reason: $1) },
        symlinkNotRemoved: { AutostartTexts.symlinkNotRemoved(unitPath: $0) },
        foreignWantsLinkNotRemoved: { AutostartTexts.foreignWantsLinkNotRemoved(linkPath: $0, unitPath: $1) },
        writeFailed: { AutostartTexts.writeFailed(path: $0, reason: $1) },
        enableDidNotTake: { AutostartTexts.enableDidNotTake(unitName: $0) },
        staleWantsLink: { AutostartTexts.staleWantsLink(path: $0) },
        installed: { AutostartTexts.installed(unitPath: $0[0]) },
        alreadyEnabled: { AutostartTexts.alreadyEnabled(unitPath: $0[0]) },
        removed: { AutostartTexts.removed(unitPath: $0[0]) },
        nothingToRemove: { AutostartTexts.nothingToRemove(unitPath: $0[0]) },
        statusEnabled: { AutostartTexts.statusEnabled(unitPath: $0) },
        statusDisabled: { AutostartTexts.statusDisabled(unitPath: $0) }
    )

    /// Pfade in Schreibreihenfolge von ``ManagedUnitSet/autoUpdate``:
    /// `[Service, Timer]`.
    static let autoUpdate = UnitMessages(
        managerUnavailable: UpdateTexts.managerUnavailable,
        systemctlUnavailable: { UpdateTexts.systemctlUnavailable(reason: $0) },
        unexpectedState: { UpdateTexts.unexpectedState(unitName: $0, word: $1) },
        unreadableState: { UpdateTexts.unreadableState(unitName: $0, word: $1) },
        effectiveUnitUndetermined: { UpdateTexts.effectiveUnitUndetermined(unitName: $0, reason: $1) },
        effectiveUnitUnusableValue: { unitName, value in
            UpdateTexts.effectiveUnitUndetermined(unitName: unitName, reason: "unexpected FragmentPath value \"\(value)\"")
        },
        directoryNotWritable: { UpdateTexts.directoryNotWritableForSetup(directory: $0) },
        masked: { UpdateTexts.masked(unitName: $0) },
        foreignFile: { UpdateTexts.foreignFile(unitPath: $0) },
        foreignFileUnreadable: { UpdateTexts.foreignFileUnreadable(unitPath: $0, reason: $1) },
        symlinkAtTarget: { UpdateTexts.symlinkAtTarget(unitPath: $0) },
        shadowedNotInstalled: { UpdateTexts.shadowedNotInstalled(fragmentPath: $0, unitName: $1, unitPath: $2) },
        shadowedNotRemoved: { UpdateTexts.shadowedNotRemoved(fragmentPath: $0, unitName: $1, unitPath: $2) },
        foreignFileNotRemoved: { UpdateTexts.foreignFileNotRemoved(unitPath: $0) },
        unreadableFileNotRemoved: { UpdateTexts.unreadableFileNotRemoved(unitPath: $0, reason: $1) },
        symlinkNotRemoved: { UpdateTexts.symlinkNotRemoved(unitPath: $0) },
        foreignWantsLinkNotRemoved: { UpdateTexts.foreignWantsLinkNotRemoved(linkPath: $0, unitPath: $1) },
        writeFailed: { UpdateTexts.writeFailed(path: $0, reason: $1) },
        enableDidNotTake: { UpdateTexts.enableDidNotTake(unitName: $0) },
        staleWantsLink: { UpdateTexts.staleWantsLink(path: $0) },
        installed: { UpdateTexts.installed(timerPath: $0[1], servicePath: $0[0]) },
        alreadyEnabled: { UpdateTexts.alreadyEnabled(timerPath: $0[1], servicePath: $0[0]) },
        removed: { UpdateTexts.removed(timerPath: $0[1], servicePath: $0[0]) },
        nothingToRemove: { UpdateTexts.nothingToRemove(timerPath: $0[1]) },
        statusEnabled: { UpdateTexts.statusEnabled(timerPath: $0) },
        statusDisabled: { UpdateTexts.statusDisabled(timerPath: $0) }
    )
}

/// Die I/O-Seite der Unit-Einrichtung (CM-21, seit CM-29 für jede Unit dieses
/// Programms): Datei anlegen, `systemctl` rufen, Ergebnis melden.
///
/// Die **Regeln** stehen in den Zielen `Autostart` und `Update` — Pfadauflösung,
/// Unit-Texte, Auswertung der `is-enabled`- und der `show -p FragmentPath`-Antwort,
/// Identitätsregel der wirksamen Unit, Entscheidungstabellen und sämtliche
/// Texte. Hier steht nur, was ohne echtes Dateisystem und ohne echten
/// Nutzermanager nicht geht (CM-20-Schichtung).
struct AutostartInstaller {

    /// Die Umgebung, aus der **alle** Pfade abgeleitet werden.
    let environment: [String: String]
    /// Der Zugang zu `systemctl`.
    let runner: CommandRunner
    /// Der Ausgabekanal.
    let emit: (String) -> Void

    // MARK: - Unterbefehle

    /// `--install-autostart`
    func install() -> TrayExit { install(.autostart) }

    /// `--uninstall-autostart`
    func uninstall() -> TrayExit { uninstall(.autostart) }

    /// `--autostart-status`
    func status() -> TrayExit { status(.autostart) }

    /// `--install-auto-update`: Timer und statischen Service schreiben, nur den
    /// Timer einschalten — ohne `--now` (FE 1).
    func installAutoUpdate() -> TrayExit { install(.autoUpdate) }

    /// `--uninstall-auto-update`
    func uninstallAutoUpdate() -> TrayExit { uninstall(.autoUpdate) }

    /// `--auto-update-status`: Zustand des **Timers** (FE 13), dazu der letzte
    /// gescheiterte Lauf des Service (2b-Auflage 9). Exit bleibt 0.
    func autoUpdateStatus() -> TrayExit {
        let result = status(.autoUpdate)
        guard result == .ok else { return result }
        let show = systemctl([
            "show", "-p", "Result,ExecMainStatus,ExecMainExitTimestamp", UpdateUnits.serviceName
        ])
        if show.didRun, show.exitStatus == 0,
           let failed = UpdateUnits.failedRun(fromShowOutput: show.standardOutput) {
            emit(UpdateTexts.lastRunFailed(exitStatus: failed.exitStatus, timestamp: failed.timestamp))
        }
        return .ok
    }

    /// Stille Messung für den Menüeintrag (CM-30) — **ohne** `emit`.
    ///
    /// ``status()`` druckt bei jedem Aufruf; der Tray fragt bei jedem Öffnen
    /// des Menüs, und das gehört nicht ins Journal.
    func reading() -> AutostartStatus.Reading {
        guard AutostartPaths.managerCanBeReachable(environment: environment) else {
            return .managerUnavailable
        }
        return currentReading(unitName: AutostartPaths.unitName)
    }

    /// Ob ein `try-restart` des Tray-Dienstes genau das ersetzte Binary trifft
    /// (FE 11, 2b-Auflage 5).
    ///
    /// `try-restart` wirkt über den **Namen** — dieselbe Klasse wie CM-32.
    /// Deshalb dieselbe Messung wie beim Einrichten: `daemon-reload`, `show -p
    /// FragmentPath`, Identitätsregel. Neu gestartet werden darf nur, wenn
    /// systemd die eigene Datei lädt, sie den Marker trägt und ihr Text gleich
    /// ``AutostartUnit/render(executablePath:)`` für den ersetzten Pfad ist.
    func autostartServiceRuns(executablePath: String) -> Bool {
        guard AutostartPaths.managerCanBeReachable(environment: environment),
              case .success(let layout) = AutostartPaths.layout(environment: environment) else {
            return false
        }
        let target = probe(unitPath: layout.unitPath, marker: AutostartUnit.markerComment)
        guard target.exists, !target.isSymlink, target.carriesMarker,
              let contents = try? String(contentsOfFile: layout.unitPath, encoding: .utf8),
              contents == AutostartUnit.render(executablePath: executablePath) else {
            return false
        }
        return effectiveUnit(
            unitName: AutostartPaths.unitName,
            unitPath: layout.unitPath,
            state: .disabled,
            messages: .autostart
        ) == .notShadowed
    }

    // MARK: - Ablauf je Einrichtung

    private func install(_ set: ManagedUnitSet) -> TrayExit {
        guard let layouts = resolvedLayouts(set) else { return .autostartUnavailable }
        guard managerReachable(set.messages) else { return .autostartUnavailable }

        let executablePath: String
        switch AutostartExecutable.resolve() {
        case .usable(let path):
            executablePath = path
        case .unusable(let reason):
            emit(AutostartTexts.executableNotUsable(reason: reason))
            return .autostartBlocked
        }

        if set.requiresWritableBinaryDirectory {
            let directory = parentDirectory(of: executablePath)
            guard access(directory, W_OK) == 0 else {
                emit(set.messages.directoryNotWritable(directory))
                return .autostartBlocked
            }
        }

        // 2b-Auflage 1: Erst werden ALLE Units gemessen und geplant. Lehnt
        // eine ab, wird keine geschrieben.
        var primaryStateBefore: LoginItemState = .disabled
        for (unit, layout) in zip(set.units, layouts) {
            guard let state = measuredState(unit, messages: set.messages) else { return .autostartUnavailable }
            if unit.name == set.primary.name { primaryStateBefore = state }
            guard let effective = effectiveUnit(
                unitName: unit.name,
                unitPath: layout.unitPath,
                state: state,
                messages: set.messages
            ) else {
                return .autostartUnavailable
            }

            let target = probe(unitPath: layout.unitPath, marker: unit.marker)
            switch AutostartPlan.plan(target: target, status: .known(state), effectiveUnit: effective) {
            case .refuseShadowed(let fragmentPath):
                emit(set.messages.shadowedNotInstalled(fragmentPath, unit.name, layout.unitPath))
                return .autostartBlocked
            case .refuseSymlink:
                emit(set.messages.symlinkAtTarget(layout.unitPath))
                return .autostartBlocked
            case .refuseForeignFile:
                emit(set.messages.foreignFile(layout.unitPath))
                return .autostartBlocked
            case .refuseUnreadable(let reason):
                emit(set.messages.foreignFileUnreadable(layout.unitPath, reason))
                return .autostartBlocked
            case .alreadyMaskedInform:
                emit(set.messages.masked(unit.name))
                return .autostartBlocked
            case .install:
                break
            }
        }

        for (unit, layout) in zip(set.units, layouts) {
            // Auflage 17: Scheitert schon das Verzeichnis, wird nicht
            // weitergelaufen — sonst folgte ein `enable` auf eine Unit, die es
            // nicht gibt, und die Meldung wäre erfunden.
            if let reason = createDirectory(layout.unitDirectory) {
                emit(AutostartTexts.directoryNotCreated(path: layout.unitDirectory, reason: reason))
                return .autostartUnavailable
            }

            if let code = writeUnit(unit.render(executablePath), to: layout.unitPath) {
                // `O_NOFOLLOW` beantwortet einen Symlink am Zielpfad mit `ELOOP`.
                // Das ist der Abbruchgrund — niemals ein Überschreiben: Ein
                // `Data.write(to:options:.atomic)` ersetzte den Symlink still
                // durch eine reguläre Datei, ein nicht-atomares Schreiben schriebe
                // lautlos an sein Ziel (etwa `/dev/null`). Beides gemessen.
                if code == ELOOP {
                    emit(set.messages.symlinkAtTarget(layout.unitPath))
                    return .autostartBlocked
                }
                emit(set.messages.writeFailed(layout.unitPath, Self.errnoName(code)))
                return .autostartUnavailable
            }
        }

        _ = systemctl(["daemon-reload"])
        let primary = set.primary
        _ = systemctl(["enable", primary.name])

        // Auflage 15b: Eine fehlende grafische Zielgruppe bricht die
        // Einrichtung NICHT ab — die Unit ist geschrieben und eingeschaltet
        // und greift, sobald die Zielgruppe aktiv wird. Sie darf aber auch
        // nicht verschwiegen werden, sonst wartet der Nutzer auf etwas, das
        // auf seinem System nie kommt.
        if primary.warnsIfInstallTargetInactive {
            let activity = systemctl(["is-active", AutostartPaths.installTargetName])
            let activityWord = AutostartStatus.firstWordOfOutput(activity.standardOutput)
            if activityWord != "active" {
                emit(AutostartTexts.graphicalSessionInactive(word: activityWord.isEmpty ? "unknown" : activityWord))
            }
        }

        // Der Zustand wird NEU erfragt und genau er gemeldet — nie aus dem
        // Rückgabecode von `enable` abgeleitet. Das ist das Vorgehen des
        // macOS-Vorbilds (`LoginItemController.swift:47-58`): Der Zustand ist
        // das, was das System sagt, nicht das, was der letzte Aufruf vorhatte.
        let after = currentReading(unitName: primary.name)
        guard let stateAfter = usableState(after, unitName: primary.name, messages: set.messages) else {
            return .autostartUnavailable
        }
        let unitPaths = layouts.map(\.unitPath)
        switch stateAfter {
        case .enabled:
            emit(primaryStateBefore == .enabled
                ? set.messages.alreadyEnabled(unitPaths)
                : set.messages.installed(unitPaths))
            return .ok
        case .requiresApproval:
            emit(set.messages.masked(primary.name))
            return .autostartBlocked
        case .disabled:
            emit(set.messages.enableDidNotTake(primary.name))
            return .autostartBlocked
        }
    }

    private func uninstall(_ set: ManagedUnitSet) -> TrayExit {
        guard let layouts = resolvedLayouts(set) else { return .autostartUnavailable }
        guard managerReachable(set.messages) else { return .autostartUnavailable }

        // Auflage 3: Der Zustand wird VOR `disable` gemessen. Bei einer
        // maskierten Unit antwortet `systemctl --user disable` mit „is masked,
        // ignoring" und rc=0, entfernt den `.wants`-Verweis aber NICHT — nach
        // dem Löschen der Unit-Datei bliebe ein toter Link liegen, und
        // „entfernt" wäre eine Falschauskunft.
        //
        // CM-30 · 2b-Auflage 3 / CM-32: Entfernt wird nur die eigene Unit.
        // Geprüft VOR `disable` und `unlink` — die Datei am Zielpfad UND die
        // Datei, die systemd für den Namen wirklich lädt. Eine fremde Unit
        // bleibt samt Aktivierung, wie sie ist. CM-29: für ALLE Units der
        // Einrichtung, bevor irgendeine angefasst wird.
        var states: [LoginItemState] = []
        var targets: [AutostartTargetProbe] = []
        for (unit, layout) in zip(set.units, layouts) {
            guard let state = measuredState(unit, messages: set.messages) else { return .autostartUnavailable }
            guard let effective = effectiveUnit(
                unitName: unit.name,
                unitPath: layout.unitPath,
                state: state,
                messages: set.messages
            ) else {
                return .autostartUnavailable
            }
            let target = probe(unitPath: layout.unitPath, marker: unit.marker)
            switch AutostartRemovalPlan.plan(target: target, effectiveUnit: effective) {
            case .refuseShadowed(let fragmentPath):
                emit(set.messages.shadowedNotRemoved(fragmentPath, unit.name, layout.unitPath))
                return .autostartBlocked
            case .refuseSymlink:
                emit(set.messages.symlinkNotRemoved(layout.unitPath))
                return .autostartBlocked
            case .refuseForeignFile:
                emit(set.messages.foreignFileNotRemoved(layout.unitPath))
                return .autostartBlocked
            case .refuseUnreadable(let reason):
                emit(set.messages.unreadableFileNotRemoved(layout.unitPath, reason))
                return .autostartBlocked
            case .remove:
                break
            }
            states.append(state)
            targets.append(target)
        }

        let existedBefore = targets.contains { $0.exists }
            || layouts.contains { layout in layout.wantsLinkPaths.contains { pathExists($0) } }

        // CM-32 · 2b-Auflage 5: Bei einer Maske ist die wirksame Unit nicht
        // erhoben. Zeigt ein `.wants`-Verweis auf eine vorhandene andere
        // Datei, gehört er zu einer fremden Unit und bleibt — mit allem.
        for (layout, state) in zip(layouts, states) where state == .requiresApproval {
            let ownIdentity = regularFileIdentity(layout.unitPath)
            for link in layout.wantsLinkPaths where AutostartRemovalPlan.isForeignWantsLink(
                linkTarget: fileIdentity(followingLinks: link),
                unitIdentity: ownIdentity
            ) {
                emit(set.messages.foreignWantsLinkNotRemoved(link, layout.unitPath))
                return .autostartBlocked
            }
        }

        for index in set.units.indices {
            let unit = set.units[index]
            if states[index] == .requiresApproval {
                // Die Maske selbst bleibt stehen: Sie ist eine Entscheidung des
                // Nutzers über systemd, nicht über diese App. Aufgehoben wird sie
                // von Hand (`systemctl --user unmask …`).
                emit(AutostartTexts.maskKept(unitName: unit.name))
                continue
            }
            if states[index] == .enabled, case .enableable = unit.kind {
                _ = systemctl(["disable", unit.name])
            }
            // 2b-Auflage 10: Abschalten wirkt sofort — ohne `stop` bliebe der
            // Timer bis zur Abmeldung aktiv und löste gegen den gelöschten
            // Service aus.
            if unit.stopsOnRemoval && (states[index] == .enabled || targets[index].exists) {
                _ = systemctl(["stop", unit.name])
            }
        }

        for layout in layouts {
            if unlink(layout.unitPath) != 0 && errno != ENOENT {
                emit(set.messages.writeFailed(layout.unitPath, Self.errnoName(errno)))
                return .autostartBlocked
            }
        }

        for layout in layouts {
            for link in layout.wantsLinkPaths where pathExists(link) {
                if unlink(link) != 0 && errno != ENOENT {
                    emit(set.messages.staleWantsLink(link))
                    return .autostartBlocked
                }
            }
        }

        _ = systemctl(["daemon-reload"])

        // Gegenprobe statt Zusage: Erst wenn kein Verweis mehr auf die
        // gelöschte Unit zeigt, darf „entfernt" gemeldet werden.
        for layout in layouts {
            if let remaining = layout.wantsLinkPaths.first(where: { pathExists($0) }) {
                emit(set.messages.staleWantsLink(remaining))
                return .autostartBlocked
            }
        }

        let unitPaths = layouts.map(\.unitPath)
        emit(existedBefore ? set.messages.removed(unitPaths) : set.messages.nothingToRemove(unitPaths))
        return .ok
    }

    private func status(_ set: ManagedUnitSet) -> TrayExit {
        let primary = set.primary
        guard let layout = resolvedLayout(primary) else { return .autostartUnavailable }
        guard managerReachable(set.messages) else { return .autostartUnavailable }

        guard let state = usableState(
            currentReading(unitName: primary.name),
            unitName: primary.name,
            messages: set.messages
        ) else {
            return .autostartUnavailable
        }
        switch state {
        case .enabled:
            emit(set.messages.statusEnabled(layout.unitPath))
        case .disabled:
            emit(set.messages.statusDisabled(layout.unitPath))
        case .requiresApproval:
            emit(set.messages.masked(primary.name))
        }
        // Eine Auskunft ist gelungen — auch „maskiert" ist eine. Blockiert ist
        // hier nichts, weil nichts eingerichtet werden sollte.
        return .ok
    }

    // MARK: - Gemeinsame Schritte

    private func resolvedLayouts(_ set: ManagedUnitSet) -> [AutostartPaths.Layout]? {
        var layouts: [AutostartPaths.Layout] = []
        for unit in set.units {
            guard let layout = resolvedLayout(unit) else { return nil }
            layouts.append(layout)
        }
        return layouts
    }

    private func resolvedLayout(_ unit: ManagedUnit) -> AutostartPaths.Layout? {
        switch unit.layout(environment) {
        case .success(let layout):
            return layout
        case .failure(.noHomeDirectory):
            emit(AutostartTexts.noHomeDirectory)
            return nil
        }
    }

    /// Vorbedingung vor jedem `systemctl`-Aufruf.
    ///
    /// Ohne `XDG_RUNTIME_DIR`/Sitzungsbus gibt es keinen Nutzermanager; jede
    /// Antwort wäre dann eine Aussage über eine Messung, die nicht
    /// stattgefunden hat (Auflage 1).
    private func managerReachable(_ messages: UnitMessages) -> Bool {
        guard AutostartPaths.managerCanBeReachable(environment: environment) else {
            emit(messages.managerUnavailable)
            return false
        }
        return true
    }

    private func currentReading(unitName: String) -> AutostartStatus.Reading {
        let outcome = systemctl(["is-enabled", unitName])
        return AutostartStatus.reading(
            isEnabledOutput: outcome.standardOutput,
            exitStatus: outcome.exitStatus,
            standardError: outcome.standardError,
            didRun: outcome.didRun
        )
    }

    /// Der Zustand einer Unit vor dem Einrichten bzw. Entfernen — je nach
    /// Art gelesen (2b-Auflage 1). Eine statische Unit zählt als `.disabled`
    /// (vorhanden oder nicht; das entscheidet die Dateiprüfung), eine Maske
    /// als `.requiresApproval`.
    private func measuredState(_ unit: ManagedUnit, messages: UnitMessages) -> LoginItemState? {
        switch unit.kind {
        case .enableable:
            return usableState(currentReading(unitName: unit.name), unitName: unit.name, messages: messages)
        case .staticUnit:
            let outcome = systemctl(["is-enabled", unit.name])
            switch UpdateUnits.serviceReading(
                isEnabledOutput: outcome.standardOutput,
                exitStatus: outcome.exitStatus,
                standardError: outcome.standardError,
                didRun: outcome.didRun
            ) {
            case .present, .absent:
                return .disabled
            case .masked:
                return .requiresApproval
            case .unexpected(let word):
                emit(messages.unexpectedState(unit.name, word))
            case .unreadable(let word):
                emit(messages.unreadableState(unit.name, word))
            case .managerUnavailable:
                emit(messages.managerUnavailable)
            case .didNotRun(let reason):
                emit(messages.systemctlUnavailable(reason))
            }
            return nil
        }
    }

    /// Misst, welche Unit-Datei systemd für den Namen lädt (CM-32) — oder
    /// meldet, warum das nicht geht, und gibt `nil` zurück.
    ///
    /// Bei einer Maske wird nichts erhoben: FragmentPath ist dann der
    /// Masken-Link selbst und sähe wie eine fremde Unit aus. Sonst erst
    /// `daemon-reload` — ohne ihn meldet ein laufender Dienst den Pfad von vor
    /// der Änderung —, dann `show`.
    private func effectiveUnit(
        unitName: String,
        unitPath: String,
        state: LoginItemState,
        messages: UnitMessages
    ) -> AutostartEffectiveUnit? {
        guard state != .requiresApproval else { return .notMeasured }
        let reading = AutostartStatus.fragmentReading(
            reload: answer(systemctl(["daemon-reload"])),
            show: { answer(systemctl(["show", "-p", "FragmentPath", "--value", unitName])) }
        )
        switch reading {
        case .noUnitFile:
            return .notShadowed
        case .path(let fragmentPath):
            return AutostartEffectiveUnit.compare(
                fragmentPath: fragmentPath,
                unitPath: unitPath,
                fragmentIdentity: fileIdentity(followingLinks: fragmentPath),
                unitIdentity: regularFileIdentity(unitPath)
            )
        case .didNotRun(let reason):
            emit(messages.systemctlUnavailable(reason))
        case .managerUnavailable:
            emit(messages.managerUnavailable)
        case .failed(let reason):
            emit(messages.effectiveUnitUndetermined(unitName, reason))
        case .unusableValue(let value):
            emit(messages.effectiveUnitUnusableValue(unitName, value))
        }
        return nil
    }

    private func answer(_ outcome: CommandOutcome) -> AutostartStatus.Answer {
        AutostartStatus.Answer(
            exitStatus: outcome.exitStatus,
            standardOutput: outcome.standardOutput,
            standardError: outcome.standardError,
            didRun: outcome.didRun
        )
    }

    /// Wandelt eine Messung in einen Schalterzustand — oder meldet, warum das
    /// nicht geht, und gibt `nil` zurück.
    private func usableState(
        _ reading: AutostartStatus.Reading,
        unitName: String,
        messages: UnitMessages
    ) -> LoginItemState? {
        switch reading {
        case .known(let state):
            return state
        case .unexpected(let word):
            emit(messages.unexpectedState(unitName, word))
            return nil
        case .unreadable(let word):
            emit(messages.unreadableState(unitName, word))
            return nil
        case .managerUnavailable:
            emit(messages.managerUnavailable)
            return nil
        case .didNotRun(let reason):
            emit(messages.systemctlUnavailable(reason))
            return nil
        }
    }

    private func systemctl(_ arguments: [String]) -> CommandOutcome {
        runner.run(executable: "systemctl", arguments: ["--user"] + arguments)
    }

    // MARK: - Dateisystem

    private func parentDirectory(of path: String) -> String {
        guard let slash = path.lastIndex(of: "/") else { return "." }
        let parent = String(path[..<slash])
        return parent.isEmpty ? "/" : parent
    }

    private func probe(unitPath: String, marker: String) -> AutostartTargetProbe {
        var info = stat()
        // `lstat`, nicht `stat`: Gefragt ist der Zielpfad SELBST, nicht das,
        // worauf er zeigt.
        guard lstat(unitPath, &info) == 0 else {
            return AutostartTargetProbe(exists: false, isSymlink: false, carriesMarker: false)
        }
        if (info.st_mode & S_IFMT) == S_IFLNK {
            return AutostartTargetProbe(exists: true, isSymlink: true, carriesMarker: false)
        }
        do {
            let contents = try String(contentsOfFile: unitPath, encoding: .utf8)
            return AutostartTargetProbe(
                exists: true,
                isSymlink: false,
                carriesMarker: AutostartUnit.carriesMarker(contents, marker: marker)
            )
        } catch {
            // Ein Lesefehler (EACCES, kaputtes UTF-8, ...) einer vorhandenen
            // Datei ist KEIN „ohne Marker": Ohne Inhalt lässt sich über den
            // Marker nichts aussagen — die Meldung muss den Lesefehler
            // benennen, statt „not written by this program" zu behaupten.
            return AutostartTargetProbe(
                exists: true,
                isSymlink: false,
                carriesMarker: false,
                unreadableReason: Self.errnoName(errno)
            )
        }
    }

    /// Gerät + Inode der Datei, auf die `path` zeigt (`stat`, folgt Links);
    /// `nil`, wenn `stat` scheitert.
    private func fileIdentity(followingLinks path: String) -> AutostartEffectiveUnit.FileIdentity? {
        var info = stat()
        guard stat(path, &info) == 0 else { return nil }
        return AutostartEffectiveUnit.FileIdentity(device: UInt64(info.st_dev), inode: UInt64(info.st_ino))
    }

    /// Gerät + Inode des Pfads SELBST (`lstat`), nur für eine reguläre Datei.
    private func regularFileIdentity(_ path: String) -> AutostartEffectiveUnit.FileIdentity? {
        var info = stat()
        guard lstat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { return nil }
        return AutostartEffectiveUnit.FileIdentity(device: UInt64(info.st_dev), inode: UInt64(info.st_ino))
    }

    /// Ob am Pfad etwas liegt — auch ein toter Symlink zählt.
    private func pathExists(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0
    }

    /// Legt das Verzeichnis samt Elternteilen an.
    ///
    /// - Returns: `nil` bei Erfolg, sonst der benannte Grund.
    private func createDirectory(_ path: String) -> String? {
        var current = ""
        for component in path.split(separator: "/") {
            current += "/" + component
            if mkdir(current, 0o755) == 0 { continue }
            let code = errno
            if code == EEXIST {
                var info = stat()
                if stat(current, &info) == 0 && (info.st_mode & S_IFMT) == S_IFDIR { continue }
                return "\(current) exists and is not a directory"
            }
            return "\(current): \(Self.errnoName(code))"
        }
        return nil
    }

    /// Schreibt die Unit — **ohne** Symlink zu folgen.
    ///
    /// - Returns: `nil` bei Erfolg, sonst `errno`.
    private func writeUnit(_ text: String, to path: String) -> Int32? {
        let descriptor = open(path, O_WRONLY | O_CREAT | O_NOFOLLOW | O_TRUNC, mode_t(0o644))
        guard descriptor >= 0 else { return errno }
        defer { close(descriptor) }

        let bytes = Array(text.utf8)
        var offset = 0
        var failure: Int32?
        bytes.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            while offset < bytes.count {
                let written = write(descriptor, base + offset, bytes.count - offset)
                if written > 0 {
                    offset += written
                    continue
                }
                if written < 0 && errno == EINTR { continue }
                failure = errno
                return
            }
        }
        return failure
    }

    /// Ein **fester** Bezeichner je `errno` — kein `strerror`, dessen Text von
    /// der Spracheinstellung des Systems abhängt.
    ///
    /// Das ist kein Meldungstext, sondern ein benannter Grund, wie ihn
    /// `TrayExit.reason(for:)` liefert: Der Satz drumherum steht in
    /// ``AutostartTexts``, hier steht nur das Wort für die Ursache (Auflage 11).
    /// Seit CM-29 nutzt auch ``UpdateClient`` diese eine Abbildung.
    static func errnoName(_ code: Int32) -> String {
        switch code {
        case EACCES: return "EACCES (permission denied)"
        case EPERM: return "EPERM (operation not permitted)"
        case EEXIST: return "EEXIST (already exists)"
        case ELOOP: return "ELOOP (symbolic link)"
        case ENOENT: return "ENOENT (no such file or directory)"
        case ENOSPC: return "ENOSPC (no space left)"
        case ENOTDIR: return "ENOTDIR (not a directory)"
        case EROFS: return "EROFS (read-only file system)"
        case EDQUOT: return "EDQUOT (disk quota exceeded)"
        default: return "errno=\(code)"
        }
    }
}

/// Der Pfad des LAUFENDEN Binaries — die Grundlage von `ExecStart=`.
enum AutostartExecutable {

    /// ⚠️ **Nicht** `CommandLine.arguments[0]`: Beim Start über `PATH` — dem in
    /// `Linux/INSTALL.md` beschriebenen Normalweg — steht dort nur
    /// `claude-monitor-tray`. Ein `ExecStart=claude-monitor-tray` ließe
    /// systemd erst beim nächsten Anmelden mit `203/EXEC` scheitern, also
    /// lange nachdem „eingerichtet" gemeldet wurde.
    ///
    /// Geprüft wird vor dem Rendern: absolut, vorhanden, reguläre Datei,
    /// ausführbar. Scheitert eine dieser Prüfungen, wird keine Unit
    /// geschrieben.
    static func resolve() -> Resolution {
        var buffer = [CChar](repeating: 0, count: 4096)
        let count = buffer.withUnsafeMutableBufferPointer { pointer -> Int in
            guard let base = pointer.baseAddress else { return -1 }
            return readlink("/proc/self/exe", base, pointer.count - 1)
        }
        guard count > 0 else { return .unusable(reason: "readlink /proc/self/exe failed, errno=\(errno)") }
        var path = String(decoding: buffer[0..<count].map { UInt8(bitPattern: $0) }, as: UTF8.self)

        guard path.hasPrefix("/") else { return .unusable(reason: "the resolved path is not absolute") }
        // CM-29 · FE 14: Nach einem Update hat `rename` eine neue Datei über
        // den Pfad gelegt; der laufende Prozess sieht seinen alten Inode als
        // „… (deleted)". Liegt unter dem Pfad ohne den Zusatz eine reguläre
        // ausführbare Datei, ist DAS das Binary, das ein Dienst starten soll.
        // Liegt dort nichts, bleibt es bei „gelöscht".
        let deletedSuffix = " (deleted)"
        if path.hasSuffix(deletedSuffix) {
            let replacement = String(path.dropLast(deletedSuffix.count))
            var replacementInfo = stat()
            guard stat(replacement, &replacementInfo) == 0,
                  (replacementInfo.st_mode & S_IFMT) == S_IFREG,
                  access(replacement, X_OK) == 0 else {
                return .unusable(reason: "the running binary has been deleted")
            }
            path = replacement
        }
        var info = stat()
        guard stat(path, &info) == 0 else { return .unusable(reason: "cannot stat \(path), errno=\(errno)") }
        guard (info.st_mode & S_IFMT) == S_IFREG else {
            return .unusable(reason: "\(path) is not a regular file")
        }
        guard access(path, X_OK) == 0 else { return .unusable(reason: "\(path) is not executable") }
        return .usable(path)
    }

    /// Das Ergebnis der Auflösung.
    enum Resolution: Equatable {
        case usable(String)
        case unusable(reason: String)
    }
}
