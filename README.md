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
| `App/` | Menüleisten-App und WidgetKit-Extension (Xcode-Projekt) |

## Status

v0.1 in Entwicklung — macOS. Verifiziert gegen claude-swap 0.22.0 (Cache-`schemaVersion` 2).

## Lizenz

Noch nicht festgelegt.
