import Foundation
import AppKit
import Combine
import Sparkle
import ClaudeMonitorShared

/// Bindet Sparkle an die App an und übersetzt dessen Sitzungsereignisse mit
/// ``UpdateSessionPolicy`` nach AppKit.
///
/// **Warum ein prozesslanger Singleton und kein `@StateObject` in einer View**
/// (so macht es ``LoginItemController``, hier wäre es falsch): Der Updater
/// entstünde erst beim ersten Öffnen des Detailfensters und stürbe mit ihm.
/// Geplante Hintergrundprüfungen — der eigentliche Zweck von
/// `SUEnableAutomaticChecks` — fänden dann nie statt.
///
/// **Der Singleton ist zugleich sein eigener `userDriverDelegate`.**
/// ``SPUStandardUpdaterController`` hält `updaterDelegate` und
/// `userDriverDelegate` laut Header **schwach** („you are responsible for
/// keeping them alive"). Mit `self` als Delegat ist die Lebensdauer des
/// Delegaten die des Prozesses, die schwache Referenz kann also nicht ins Leere
/// zeigen. Ein eigenes kleines Delegat-Objekt müsste man von Hand am Leben
/// halten — und würde beim ersten Umbau still eingesammelt, wonach die
/// Aktivierungssteuerung wortlos ausbliebe.
///
/// **Bewusst ohne `UserNotifications`.** Sparkles „gentle reminders" lassen
/// sich zusätzlich als Systemmitteilung zeigen; das kostet einen
/// Berechtigungsdialog und eröffnet eine neue Datenschutzfläche für eine App,
/// die sonst ausschließlich lokal liest. Das Dock-Abzeichen genügt. Nicht als
/// Versehen nachrüsten.
@MainActor
final class UpdateController: NSObject, ObservableObject {

    static let shared = UpdateController()

    /// Spiegel von `SPUUpdater.canCheckForUpdates`.
    ///
    /// Der Spiegel ist nötig, weil die Sparkle-Eigenschaft zwar KVO-fähig, aber
    /// keine `ObservableObject`-Quelle ist: Ein `Binding` mit reinem `get`/`set`
    /// direkt darauf würde die View nie zum Neuzeichnen bringen — der Knopf
    /// bliebe nach der ersten Prüfung dauerhaft grau.
    ///
    /// **Kein `@Published`, sondern `objectWillChange` von Hand** — und das ist
    /// keine Geschmacksfrage: Mit `@Published` stürzte die App beim ersten
    /// KVO-Rückruf reproduzierbar in `Published.subscript.setter`
    /// (`EXC_BAD_ACCESS` in `swift_getAtKeyPath`, 13 gleichlautende
    /// Absturzberichte). Sichtbar wurde das als „der zweite Beobachter feuert
    /// nie" — in Wahrheit war der Prozess da schon tot. Der Stack zeigt den
    /// Value-Witness-Pfad der Swift-Runtime (`swift_cvw_initWithCopyImpl`) und
    /// deutet vermutlich auf die Kombination aus Eigenschafts-Wrapper und
    /// `NSObject`-Erbe hin, das der Sparkle-Delegat erzwingt — bewiesen ist das
    /// nicht, nur gestützt durch ``UsageMonitor`` und ``LoginItemController``,
    /// die `@Published` problemlos nutzen und beide nicht von `NSObject` erben.
    private(set) var canCheckForUpdates = false {
        willSet { if newValue != canCheckForUpdates { objectWillChange.send() } }
    }

    /// Ob ``canCheckForUpdates`` seit Prozessstart schon **einmal** `true` war.
    ///
    /// Wird nie zurückgesetzt, und das ist der ganze Zweck: Sparkle setzt
    /// `canCheckForUpdates` auch während einer laufenden Prüfung auf `false`.
    /// Ohne dieses Gedächtnis ließe sich „prüft gerade" nicht von „ist nie
    /// gestartet" unterscheiden — und der Knopf trüge in einem der beiden Fälle
    /// zwangsläufig eine Falschauskunft. Kein `objectWillChange`: Der Wert wird
    /// nur zusammen mit ``canCheckForUpdates`` gesetzt, das bereits meldet.
    private var hasEverBeenReady = false

    /// Was der Update-Knopf anzeigen darf — die geprüfte Regel aus `Shared/`.
    ///
    /// Berechnet statt gespeichert: Es gibt keinen zweiten Weg zu diesem
    /// Zustand, der irgendwann abweichen könnte.
    var buttonState: UpdateButtonState {
        UpdateAvailability.state(
            canCheckForUpdates: canCheckForUpdates,
            hasEverBeenReady: hasEverBeenReady
        )
    }

    /// Der Fehlertext des Systems, falls Sparkle einen liefert — nie ein
    /// geratener Text.
    ///
    /// ⚠️ **Der Startfehler erreicht diese Eigenschaft nicht.** Scheitert
    /// `startUpdater`, behandelt ``SPUStandardUpdaterController`` das
    /// vollständig selbst (`SPUStandardUpdaterController.m:78-101`: `SULog` plus
    /// ein eigener `runModal` nach einer Sekunde) und reicht den Fehler an
    /// **keinen** Delegaten weiter. Gefüllt wird der Text daher nur von
    /// `updater(_:didAbortWithError:)`, also von abgebrochenen Prüfläufen. Die
    /// Zustandsregel in ``UpdateAvailability`` trägt auch ohne ihn — dieser Text
    /// ist eine Zugabe, keine Voraussetzung.
    private(set) var lastUpdateError: String? {
        willSet { if newValue != lastUpdateError { objectWillChange.send() } }
    }

    /// Spiegel von `SPUUpdater.automaticallyChecksForUpdates`. Gleiche
    /// Begründung wie oben, warum hier kein Eigenschafts-Wrapper steht.
    ///
    /// Nur lesbar nach außen: Geschrieben wird ausschließlich über
    /// ``setAutomaticallyChecksForUpdates(_:)``, das in den Updater schreibt —
    /// der Spiegel folgt dann über KVO. Andersherum zeigte die Oberfläche einen
    /// Zustand, den Sparkle nicht teilt, sobald der Updater den Wert selbst
    /// ändert.
    private(set) var automaticallyChecksForUpdates = false {
        willSet { if newValue != automaticallyChecksForUpdates { objectWillChange.send() } }
    }

    /// `lazy` statt `Optional` + `start()`-Zuweisung: `self` muss als Delegat
    /// übergeben werden, das geht in einer Property-Initialisierung nicht. Ein
    /// `Optional` bräuchte an jeder Verwendungsstelle ein `!` oder ein `guard`
    /// für einen Fall, den es nie gibt.
    ///
    /// `self` steht in **beiden** Delegat-Feldern: Der `userDriverDelegate`
    /// steuert Aktivierung und Dock-Abzeichen, der `updaterDelegate` liefert
    /// den Fehlertext eines abgebrochenen Prüflaufs. Beide sind laut Header
    /// **schwach** gehalten — `self` ist prozesslang und damit der einzige
    /// Kandidat, der nicht still eingesammelt wird.
    private lazy var updaterController = SPUStandardUpdaterController(
        startingUpdater: true,
        updaterDelegate: self,
        userDriverDelegate: self
    )

    /// Die geprüfte Regel aus `Shared/`. Sie hält den gesamten Sitzungszustand;
    /// dieser Typ hält keinen eigenen.
    private var policy = UpdateSessionPolicy()

    private var cancellables = Set<AnyCancellable>()

    /// `NSObject`-Erbe ist keine Bequemlichkeit: `SPUStandardUserDriverDelegate`
    /// erweitert `NSObjectProtocol`, und dem lässt sich in Swift nur durch
    /// Erben von `NSObject` genügen.
    private override init() {
        super.init()
    }

    /// Startet den Updater und verbindet die beiden Spiegel.
    ///
    /// Wird vom `AppDelegate` aufgerufen. Der Zugriff auf `updaterController`
    /// ist hier kein Beiwerk: Er löst die `lazy`-Erzeugung aus und damit den
    /// Start des Updaters — ohne ihn liefe keine geplante Prüfung.
    func start() {
        // Nicht idempotent ohne diese Wache: Ein zweiter Aufruf legte ein
        // zweites Abonnement-Paar an und verdoppelte jedes `objectWillChange`.
        guard cancellables.isEmpty else { return }

        let updater = updaterController.updater

        // Feed auf den code-signierten Wert pinnen.
        //
        // `SUHost.m:395` gibt UserDefaults Vorrang vor dem Info.plist. Ein
        // `defaults write at.markusfricke.claudemonitor SUFeedURL http://…`
        // biegt den Update-Kanal also dauerhaft um — und HTTP wird von Sparkle
        // nur geloggt, nicht abgelehnt. Der Vertrauensanker selbst bleibt
        // unantastbar (`SUPublicEDKey` liest Sparkle NUR aus dem
        // Info-Dictionary, `SUHost.m:193`), aber ein fremdbestimmter Kanal ist
        // trotzdem nichts, was diese App hinnehmen muss: Der Feed ist
        // code-signiert im Bundle hinterlegt, und genau der soll gelten.
        //
        // Beseitigt zugleich Sparkles Deprecation-Warnung aus
        // `SPUUpdater.m:179`.
        //
        // Reihenfolge stimmt: `startingUpdater: true` oben hat `startUpdater`
        // bereits ausgelöst, das den Prüfzyklus aber per `dispatch_async` auf
        // den nächsten Runloop-Durchlauf plant — dieses Löschen läuft synchron
        // davor, also vor der ersten Feed-Anfrage.
        updater.clearFeedURLFromUserDefaults()

        // Synchron vorbelegen, bevor überhaupt abonniert wird: Die
        // KVO-Quelle für `canCheckForUpdates`/`automaticallyChecksForUpdates`
        // ist laut Sparkle-Quelltext (`SPUUpdater.m:1038`,
        // `SPUUpdaterSettings.m:65`, `SUHost.m:88`) `NSUserDefaults`, nicht
        // `SPUUpdater` selbst. Eine prozessfremde Änderung (`defaults write`,
        // MDM, zweite Instanz) kann also auf einem Nebenstrang zustellen.
        // Die Vorbelegung hier läuft synchron im Aufrufer von `start()`
        // (`applicationDidFinishLaunching`, garantiert Hauptstrang) und trägt
        // den korrekten Anfangswert, bevor der erste KVO-Rückruf überhaupt
        // eintreffen kann.
        setCanCheckForUpdates(updater.canCheckForUpdates)
        automaticallyChecksForUpdates = updater.automaticallyChecksForUpdates

        // `receive(on: DispatchQueue.main)` ist hier **Pflicht, nicht
        // Kosmetik**: Es garantiert, dass jeder folgende Rückruf auf dem
        // Hauptstrang zugestellt wird — nur dadurch ist `assumeIsolated`
        // unten belegt statt unterstellt. Wer dieses `receive(on:)` entfernt,
        // holt den `fatalError`-Absturzpfad zurück.
        updater.publisher(for: \.canCheckForUpdates)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] value in
                MainActor.assumeIsolated { self?.setCanCheckForUpdates(value) }
            }
            .store(in: &cancellables)

        updater.publisher(for: \.automaticallyChecksForUpdates)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] value in
                MainActor.assumeIsolated { self?.automaticallyChecksForUpdates = value }
            }
            .store(in: &cancellables)
    }

    /// Der **einzige** Schreibweg auf ``canCheckForUpdates``.
    ///
    /// Er hält ``hasEverBeenReady`` mit — an einer Stelle, damit die beiden
    /// Werte nicht auseinanderlaufen können. Die Vorbelegung in ``start()`` und
    /// der KVO-Rückruf gehen beide hier durch; ein zweiter, direkter Zuweisungsweg
    /// wäre genau der stille Weg, auf dem das Gedächtnis verloren ginge.
    private func setCanCheckForUpdates(_ value: Bool) {
        canCheckForUpdates = value
        if value { hasEverBeenReady = true }
    }

    /// Schaltet die automatische Suche um.
    ///
    /// Schreibt **nur** in den Updater; der Spiegel wird nicht von Hand
    /// nachgezogen, sondern folgt über den KVO-Beobachter oben. Sonst gäbe es
    /// zwei Wege zum selben Zustand, von denen einer irgendwann abweicht.
    func setAutomaticallyChecksForUpdates(_ enabled: Bool) {
        updaterController.updater.automaticallyChecksForUpdates = enabled
    }

    /// „Nach Updates suchen" aus dem Detailfenster.
    func checkForUpdates() {
        // Lehnt Sparkle die Sitzung ab (`SPUUpdater.m:708 !_startedUpdater`,
        // `:713 _sessionInProgress`), kommt nie ein
        // `standardUserDriverWillFinishUpdateSession` — hat `apply(...)`
        // darunter bereits `.regular` gesetzt, bliebe das Dock-Symbol
        // dauerhaft kleben. Heute nur durch `.disabled(...)` in einer View
        // verhindert; diese Wache schützt jeden weiteren Aufrufer mit.
        // Unschädlich für „gezeigtes Update nach vorn holen": Dort ist
        // `canCheckForUpdates == true`.
        guard canCheckForUpdates else { return }

        // Ein neuer Lauf darf nicht unter dem Fehlertext des vorigen starten —
        // sonst erklärt die Oberfläche den aktuellen Zustand mit einem
        // Ereignis, das vorbei ist.
        lastUpdateError = nil

        apply(policy.handle(.userInitiatedCheckStarted))
        // Das Aktivieren gehört **hierher** und nicht allein in die
        // Delegat-Rückrufe: `standardUserDriverWillHandleShowingUpdate` feuert
        // nur, wenn ein Update tatsächlich gezeigt wird. Der häufigste Fall —
        // geklickt, alles aktuell — und der Fehlerdialog bei nicht
        // erreichbarem Feed liefen sonst hinter fremden Fenstern auf. Was den
        // Fall rettet, in dem der Nutzer inzwischen in einer anderen App ist
        // und ein Update später erscheint, ist **nicht** dieser Aufruf —
        // `SPUStandardUserDriver.showAlert:` aktiviert nicht, es folgt direkt
        // `runModal` —, sondern das Dock-Symbol aus `apply(...)` (`.regular`
        // via `standardUserDriverWillHandleShowingUpdate`). Der Aufruf hier
        // bleibt trotzdem sinnvoll für die `MenuBarExtra`-Panels.
        NSApp.activate()
        updaterController.updater.checkForUpdates()
    }

    /// Meldet das Ende des App-Lebenszyklus an die Regel.
    ///
    /// Nötig, weil der Nutzer die App über den „Beenden"-Knopf im
    /// Detailfenster schließen kann, während eine Sitzung noch offen ist.
    func applicationWillTerminate() {
        apply(policy.handle(.appWillTerminate))
    }

    /// Der **einzige** Ort, an dem die Wirkung der Regel nach AppKit übersetzt
    /// wird. `Shared/` bleibt dadurch AppKit-frei und die Regel testbar.
    ///
    /// Beide Felder werden bedingungslos angewandt — ``UpdateSessionPolicy``
    /// liefert Zielzustände, keine Deltas. Ein „nur wenn geändert" hier wäre
    /// genau die Delta-Logik, die die Regel bewusst vermeidet.
    private func apply(_ effect: UpdateSessionPolicy.Effect) {
        switch effect.activation {
        case .regular:
            NSApp.setActivationPolicy(.regular)
        case .accessory:
            NSApp.setActivationPolicy(.accessory)
        }

        switch effect.dockBadge {
        case .visible:
            NSApp.dockTile.badgeLabel = "1"
        case .hidden:
            // Leerer String statt `nil`: Beides blendet das Abzeichen aus,
            // aber `badgeLabel` ist als `String?` deklariert und `nil` löst in
            // Swift die überflüssige Frage aus, ob „kein Abzeichen" und
            // „leeres Abzeichen" unterschiedliche Zustände sind.
            NSApp.dockTile.badgeLabel = ""
        }
    }
}

/// `@preconcurrency` ist **nicht** entbehrlich und darf nicht als überflüssig
/// entfernt werden: ``SPUStandardUpdaterController`` und ``SPUUpdater`` sind im
/// Sparkle-Header `NS_SWIFT_UI_ACTOR` (= `@MainActor`), das Protokoll
/// `SPUStandardUserDriverDelegate` dagegen ist **nicht** annotiert. Ohne
/// `@preconcurrency` verlangt Swift 6 nicht-isolierte Rümpfe, in denen sich
/// weder `policy` noch `NSApp` anfassen ließen.
///
/// Alle Mitglieder des Protokolls sind `@optional`. Ein vertippter Name
/// kompiliert deshalb anstandslos und feuert dann **nie** — die Signaturen
/// unten sind wörtlich aus `SPUStandardUserDriverDelegate.h` übernommen und
/// dürfen nicht „aufgeräumt" werden.
extension UpdateController: @preconcurrency SPUStandardUserDriverDelegate {

    /// Sagt Sparkle, dass geplante Fundmeldungen nicht sofort in den
    /// Vordergrund drängen müssen. Ohne das riss eine Hintergrundprüfung den
    /// Nutzer mitten aus der Arbeit.
    var supportsGentleScheduledUpdateReminders: Bool { true }

    /// `standardUserDriverShouldHandleShowingScheduledUpdate(_:andInImmediateFocus:)`
    /// bleibt **absichtlich** unimplementiert: Sparkle soll die Anzeige selbst
    /// übernehmen, wir ergänzen nur Aktivierung und Abzeichen. So macht es auch
    /// Sparkles eigenes Beispiel für Hintergrund-Apps.
    func standardUserDriverWillShowModalAlert() {
        apply(policy.handle(.willShowModalAlert))
    }

    func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool,
        forUpdate update: SUAppcastItem,
        state: SPUUserUpdateState
    ) {
        apply(policy.handle(.willShowUpdate(userInitiated: state.userInitiated)))
    }

    func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        apply(policy.handle(.userAttentionReceived))
    }

    func standardUserDriverWillFinishUpdateSession() {
        apply(policy.handle(.sessionFinished))
    }
}

/// Nur ein einziges Mitglied, und nur zu einem Zweck: den Fehlertext des
/// Systems zu bekommen, statt einen zu erfinden.
///
/// ⚠️ Wie beim User-Driver-Protokoll sind **alle** Mitglieder `@optional` — ein
/// vertippter Name kompiliert anstandslos und feuert nie. Die Signatur unten ist
/// wörtlich aus `SPUUpdaterDelegate.h:455` übernommen
/// (`- (void)updater:(SPUUpdater *)updater didAbortWithError:(NSError *)error;`)
/// und compilergeprüft (siehe Umsetzungsprotokoll zu CM-11). Nicht „aufräumen".
///
/// Anders als bei ``SPUStandardUserDriverDelegate`` steht hier **kein**
/// `@preconcurrency`: `SPUUpdaterDelegate` ist im Header bereits
/// `NS_SWIFT_UI_ACTOR`, der Rumpf ist also ohnehin `@MainActor`-isoliert. Der
/// Compiler weist die Annotation ausdrücklich zurück („has no effect") — sie
/// nachzurüsten holt nur eine Warnung.
extension UpdateController: SPUUpdaterDelegate {

    /// Der Prüflauf ist mit einem Fehler abgebrochen.
    ///
    /// Nicht gefiltert: Welcher Code „harmlos" ist, entscheidet hier niemand.
    /// Der Text wird ohnehin nur dort gezeigt, wo der Knopf gesperrt ist, und
    /// beim nächsten Prüflauf wieder gelöscht.
    func updater(_ updater: SPUUpdater, didAbortWithError error: any Error) {
        lastUpdateError = error.localizedDescription
    }
}

