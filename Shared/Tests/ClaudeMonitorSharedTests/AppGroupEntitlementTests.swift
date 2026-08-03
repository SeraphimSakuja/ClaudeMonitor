import Foundation
import Testing
import ClaudeMonitorCore
import ClaudeMonitorShared

/// Die Wache vor dem App-Group-Container.
///
/// Diese Tests fassen **keinen** App-Group-Container an — genau das ist ihr
/// Sinn: Ohne Deklaration darf der Pfad nicht einmal gebildet werden.
@Suite("App-Group-Wache")
struct AppGroupEntitlementTests {

    private let group = "group.example.test"

    @Test("Deklarierte Gruppe wird erkannt, eine fremde nicht")
    func declaredGroupIsRecognised() {
        let entitlement = AppGroupEntitlement.declaring([group, "group.example.other"])
        #expect(entitlement.isDeclared(group))
        #expect(entitlement.isDeclared("group.example.other"))
        #expect(entitlement.isDeclared("group.example.missing") == false)
    }

    @Test("Ohne Deklaration gibt es kein Container-Verzeichnis")
    func undeclaredYieldsNoDirectory() {
        let store = SnapshotStore(groupIdentifier: group, entitlement: .none)
        #expect(store.containerDirectory == nil)
    }

    @Test("Ohne Deklaration meldet der Schreibversuch containerUnavailable, statt den Container anzufassen")
    func writeIsBlockedWithoutEntitlement() {
        let store = SnapshotStore(groupIdentifier: group, entitlement: .none)
        let snapshot = Fixture.snapshot([Fixture.account()])

        #expect(store.write(snapshot) == .containerUnavailable(groupIdentifier: group))
    }

    @Test("Ohne Deklaration liefert das Lesen einen Fehler, statt zu blockieren")
    func readIsBlockedWithoutEntitlement() {
        let store = SnapshotStore(groupIdentifier: group, entitlement: .none)
        #expect(throws: (any Error).self) { try store.read() }
    }

    @Test("Die Wache sitzt im Store selbst und ist nicht am Aufrufer vorbei zu umgehen")
    func guardLivesInsideTheStore() throws {
        // Belegt die eigentliche Zusage von Fund 2: Der Container-Lookup ist die
        // einzige Stelle, an der ein App-Group-Pfad entsteht, und sie fragt die
        // Wache. Ein Aufrufer (etwa die Widget-Extension) kann sie deshalb nicht
        // „vergessen" — es gibt keinen zweiten Weg in den Container.
        //
        // Geprüft wird das an dem Verzeichnis-Weg, den die Extension nimmt: Er
        // funktioniert weiterhin (Vertrag prüfbar ohne Entitlement), er führt
        // aber nachweislich nicht in den App-Group-Bereich.
        let directory = try Fixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = SnapshotStore(groupIdentifier: group, entitlement: .none)
        let snapshot = Fixture.snapshot([Fixture.account()])

        guard case .written(let url) = store.write(snapshot, into: directory) else {
            Issue.record("Der Verzeichnis-Weg muss ohne Entitlement funktionieren.")
            return
        }
        #expect(url.path.hasPrefix(directory.path))
        #expect(url.path.contains("Group Containers") == false)
        let readBack = try store.read(from: directory)
        #expect(readBack == snapshot)
    }

    @Test("Die echte Wache liest die Signatur — und der Testprozess trägt die Gruppe nicht")
    func codeSignatureGuardIsWiredUp() {
        // Gegenprobe zur Attrappe: `codeSignature` fragt wirklich die Signatur
        // dieses Prozesses. Der Testrunner ist nicht mit der App Group signiert,
        // also darf die Wache nichts freigeben — sonst liefe genau dieser Lauf
        // in den blockierenden Systemdialog.
        #expect(AppGroupEntitlement.codeSignature.isDeclared(AppGroup.identifier) == false)
        #expect(AppGroupEntitlement.groupsFromCodeSignature().contains(AppGroup.identifier) == false)
    }
}
