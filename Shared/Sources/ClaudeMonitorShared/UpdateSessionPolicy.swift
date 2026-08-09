import Foundation

/// Steuert Aktivierungsrichtlinie und Dock-Abzeichen während einer
/// Sparkle-Update-Session — als Ereignis→Wirkung-Automat mit
/// **Zielzustands-Semantik**: Jedes Ereignis liefert die vollständige
/// gewünschte Wirkung, niemals ein Delta. Der Aufrufer wendet sie
/// bedingungslos an.
///
/// **Warum Zielzustand statt Delta:** ClaudeMonitor ist eine reine
/// Menüleisten-App (`LSUIElement`, Aktivierungsrichtlinie `.accessory`, kein
/// Dock-Symbol). Während einer Sparkle-Session muss sie vorübergehend nach
/// `.regular` wechseln, sonst öffnen sich Sparkles Fenster hinter fremden
/// Fenstern und sind über kein Dock-Symbol erreichbar. Mit Delta-Semantik
/// gäbe es Ereignisfolgen, nach denen die App in `.regular` hängen bleibt —
/// genau das klebt dauerhaft ein Dock-Symbol an eine Menüleisten-App, das
/// der Nutzer nur per Neustart wieder loswird. Mit Zielzustands-Semantik ist
/// jedes Ereignis für sich genommen korrekt und die Regel von Natur aus
/// idempotent.
///
/// Liegt in `Shared/`, weil das App-Target kein Testziel hat (SSOT-Punkt
/// CM-06) — wie ``LoginItemState`` wird diese Regel ausschließlich über
/// `swift test` geprüft. Exportiert absichtlich keinen AppKit-Typ: `Shared/`
/// soll später auch iOS tragen, die Übersetzung nach
/// `NSApplication.ActivationPolicy` gehört ins App-Target.
public struct UpdateSessionPolicy: Sendable {

    /// Ereignisse, die Sparkle bzw. der App-Lebenszyklus während einer
    /// Update-Session auslösen.
    public enum Event: Equatable, Sendable {
        /// Der Nutzer hat die Prüfung selbst angestoßen (Menüpunkt „Nach
        /// Updates suchen"). Wechselt schon beim Klick nach `.regular`, nicht
        /// erst wenn ein Update gefunden wurde: Sparkle meldet
        /// ``willShowUpdate(userInitiated:)`` nur, wenn es tatsächlich ein
        /// Update **zeigt**. Der häufigste Fall — geklickt, alles aktuell —
        /// käme sonst nie nach vorn, und dasselbe gilt für den Fehlerdialog
        /// bei nicht erreichbarem Feed.
        case userInitiatedCheckStarted
        /// Sparkle zeigt ein gefundenes Update.
        case willShowUpdate(userInitiated: Bool)
        /// Sparkle zeigt einen modalen Alert (z. B. „alles aktuell" oder
        /// einen Fehlerdialog).
        case willShowModalAlert
        /// Der Nutzer hat auf ein sichtbares Sparkle-Fenster reagiert.
        case userAttentionReceived
        /// Die Update-Session ist beendet — mit oder ohne Update.
        case sessionFinished
        /// Die App wird beendet.
        case appWillTerminate
    }

    /// Gewünschte Aktivierungsrichtlinie der App. Eigener Typ statt
    /// `NSApplication.ActivationPolicy`, damit `Shared/` AppKit-frei bleibt.
    public enum Activation: Equatable, Sendable {
        case regular
        case accessory
    }

    /// Gewünschter Sichtbarkeitszustand des Dock-Abzeichens.
    public enum DockBadge: Equatable, Sendable {
        case visible
        case hidden
    }

    /// Vollständige Wirkung eines Ereignisses. Der Aufrufer wendet beide
    /// Felder bedingungslos an — nie nur eines, nie bedingt.
    public struct Effect: Equatable, Sendable {
        public let activation: Activation
        public let dockBadge: DockBadge

        public init(activation: Activation, dockBadge: DockBadge) {
            self.activation = activation
            self.dockBadge = dockBadge
        }
    }

    private var sessionActive = false
    private var badgeVisible = false

    public init() {}

    /// Verarbeitet ein Ereignis und liefert die vollständige Ziel-Wirkung.
    public mutating func handle(_ event: Event) -> Effect {
        switch event {
        case .userInitiatedCheckStarted:
            sessionActive = true
            return currentEffect()

        case .willShowUpdate(let userInitiated):
            sessionActive = true
            // Das Abzeichen erscheint nur bei einer *geplanten* Prüfung: Wer
            // selbst geklickt hat, schaut ohnehin hin — ein Abzeichen wäre
            // dort Lärm.
            if !userInitiated {
                badgeVisible = true
            }
            return currentEffect()

        case .willShowModalAlert:
            sessionActive = true
            return currentEffect()

        case .userAttentionReceived:
            badgeVisible = false
            return currentEffect()

        case .sessionFinished:
            // Ohne vorangegangenen Start ist das ein definierter Fall und
            // kein Programmfehler: Sparkles Rückrufe sind nicht garantiert
            // paarweise, und ein Fehlerpfad darf die App nicht in `.regular`
            // zurücklassen.
            sessionActive = false
            badgeVisible = false
            return currentEffect()

        case .appWillTerminate:
            // Räumt auf, weil eine Session offen sein kann, wenn der Nutzer
            // die App über das Menü beendet.
            sessionActive = false
            badgeVisible = false
            return currentEffect()
        }
    }

    private func currentEffect() -> Effect {
        Effect(
            activation: sessionActive ? .regular : .accessory,
            dockBadge: badgeVisible ? .visible : .hidden
        )
    }
}
