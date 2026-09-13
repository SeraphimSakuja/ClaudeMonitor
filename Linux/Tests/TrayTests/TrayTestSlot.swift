import XCTest
@testable import DBusWire
@testable import TrayPresentation

// CM-20 · reservierter Nachweis-Platz (Auflage 17).
//
// Dieses Ziel existiert ab dem ersten Tag der Karte, obwohl es noch keinen
// Testfall trägt: Ein Testziel, das erst später angelegt wird, ist erfahrungs-
// gemäß eines, das nie angelegt wird — und die Zusage aus Auflage 12 („die
// inhaltsreiche Abbildung liegt in einem Bibliotheksziel, damit sie prüfbar
// ist") wäre ohne den Platz nur eine Behauptung. Dass die Importe hier stehen,
// beweist mechanisch, dass beide Ziele aus einem Testkontext heraus baubar und
// importierbar sind.
//
// Die Testfälle selbst schreibt `mf-test-builder` nach dem Verify-Gate aus dem
// echten Diff — nicht der Implementierende (Trennung von Bau und Nachweis).
