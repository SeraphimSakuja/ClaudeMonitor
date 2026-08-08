# ClaudeMonitor

Menüleisten- und Widget-Companion für [claude-swap](https://github.com/realiti4/claude-swap) auf macOS.

Wer mehrere Claude-Accounts parallel nutzt, will auf einen Blick sehen, welcher gerade
Kapazität hat. `claude-swap` kennt diese Daten bereits — ClaudeMonitor macht sie als
macOS-Widget und als eigene Menüleisten-Anzeige sichtbar.

## Was es anzeigt

Pro Account die Auslastung aller Limitfenster (5-Stunden, Woche und weitere), den
Zeitpunkt des nächsten Resets und die verbleibende Zeit — sortiert, sodass der aktuell
beste Account oben steht.

## Verhältnis zu claude-swap

ClaudeMonitor ist **kein Fork und kein Patch**. Es liest ausschließlich den lokalen Cache
von claude-swap und schreibt niemals hinein — claude-swap serialisiert seine Writes
read-modify-write unter einem File-Lock, ein Fremdzugriff könnte den Store beschädigen.
Auch OAuth-Tokens werden nie angefasst: claude-swap bleibt der alleinige Besitzer und
einzige Erneuerer. Damit bleibt claude-swap unabhängig aktualisierbar.

Voraussetzung ist deshalb eine laufende claude-swap-Installation, die ihre Nutzungsdaten
regelmäßig abruft. Ist sie nicht aktiv, altern die Daten — ClaudeMonitor zeigt in dem Fall
das Alter des letzten bekannten Werts an, statt veraltete Zahlen als aktuell auszugeben.

## Struktur

| Pfad | Inhalt |
|---|---|
| `Core/` | Framework-freie Kernlogik (Parsing, Ranking, Status, Restzeiten) als SwiftPM-Package — mit `swift test` ohne Xcode testbar |
| `Shared/` | Gemeinsame Schicht von App und Widget: Snapshot-Transport über den App-Group-Container und alle Anzeigeregeln — ebenfalls SwiftPM, ebenfalls ohne Xcode testbar |
| `App/` | Menüleisten-App (Xcode-Projekt) |
| `scripts/` | `release.sh` — baut das notarisierte DMG und prüft das Ergebnis nach |

Anzeigeregeln liegen bewusst in `Shared/` und nicht im App-Target: Die Widget-Extension
braucht exakt dieselbe Formatierung, und zwei Kopien laufen garantiert auseinander.

## Bauen und testen

```sh
cd Core   && swift test        # Kernlogik
cd Shared && swift test        # Transport + Anzeigeregeln
xcodebuild -project App/ClaudeMonitor.xcodeproj -scheme ClaudeMonitor -destination 'platform=macOS' build
```

Signiert wird mit **Developer ID** und Hardened Runtime, ausgeliefert wird notarisiert.
Ein Provisioning-Profil braucht die App nicht: Sie führt kein eingeschränktes Entitlement.
Begründung und der Weg zurück zu den Widgets stehen kommentiert in `App/Signing.xcconfig`.

## Ausliefern

```sh
./scripts/release.sh          # Tests → Archive → Export → Notarisierung → DMG
```

Das Skript baut nur lokal nach `build/` und lädt nichts hoch. Einmalig müssen die
Zugangsdaten für die Notarisierung im Schlüsselbund liegen — der Befehl dafür steht
im Kopf von `scripts/release.sh`.

## Status

v1.0 — macOS 14+. Verifiziert gegen claude-swap 0.22.0 (Cache-`schemaVersion` 2).

Die WidgetKit-Extension liegt auf Hold; die Menüleiste deckt den Anwendungsfall ab.
Der App-Group-Transport in `Shared/` bleibt dafür erhalten, das Entitlement ist
bewusst **nicht** gesetzt.

## Lizenz

MIT — siehe [LICENSE](LICENSE). Dieselbe Lizenz wie claude-swap, damit beides ohne
Reibung zusammen weiterverwendet werden kann.
