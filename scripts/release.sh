#!/bin/bash
#
# Baut ClaudeMonitor als notarisiertes, verteilbares DMG.
#
#   ./scripts/release.sh
#
# Das Skript lädt NICHTS hoch und veröffentlicht nichts — es legt das fertige
# DMG unter build/ ab. Der Weg zu GitHub Releases ist bewusst ein eigener,
# manueller Schritt.
#
# WARUM archive + exportArchive und nicht `xcodebuild build`:
#   Ein direkter Release-Build trägt weiterhin `com.apple.security.get-task-allow`
#   (das Debug-Entitlement). Damit lehnt die Notarisierung ab. Erst der Export
#   mit `method = developer-id` entfernt es. Schritt 3 prüft das nach, statt sich
#   darauf zu verlassen.
#
# EINMALIGE VORBEREITUNG — Zugangsdaten für die Notarisierung im Schlüsselbund
# ablegen. Sie liegen danach dort und tauchen nie in diesem Repository auf:
#
#   xcrun notarytool store-credentials "ClaudeMonitor-Notary" \
#     --key      <Pfad zum App-Store-Connect-Schlüssel .p8> \
#     --key-id   <Key ID> \
#     --issuer   <Issuer ID>
#
# Notarisierung ist team-, nicht app-gebunden — ein vorhandener Schlüssel des
# Teams genügt, es braucht keinen eigenen für diese App. Alternativ geht
# `--apple-id` mit einem app-spezifischen Passwort.

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="$PROJECT_DIR/build"
ARCHIVE="$BUILD_DIR/ClaudeMonitor.xcarchive"
EXPORT_DIR="$BUILD_DIR/export"
APP="$EXPORT_DIR/ClaudeMonitor.app"
NOTARY_PROFILE="${NOTARY_PROFILE:-ClaudeMonitor-Notary}"

step() { printf '\n\033[1m▸ %s\033[0m\n' "$1"; }
fail() { printf '\n\033[31m✘ %s\033[0m\n' "$1" >&2; exit 1; }

# ---------------------------------------------------------------------------
step "0/8  Vorbedingungen"

security find-identity -v -p codesigning \
  | grep -q "Developer ID Application" \
  || fail "Kein „Developer ID Application\"-Zertifikat im Schlüsselbund."

xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1 \
  || fail "Kein notarytool-Profil „$NOTARY_PROFILE\". Siehe Kopf dieser Datei."

# Die Testbelege dieses Projekts stammen ausschließlich aus `swift test`.
# `xcodebuild test` meldet hier TEST SUCCEEDED, OHNE einen Test auszuführen:
# Das Scheme trägt eine TestAction mit leerem <Testables>, und Xcode stellt sie
# selbsttätig wieder her. Siehe SSOT-Punkt CM-06.
step "1/8  Tests (Core + Shared)"
( cd "$PROJECT_DIR/Core"   && swift test ) || fail "Core-Tests rot."
( cd "$PROJECT_DIR/Shared" && swift test ) || fail "Shared-Tests rot."

rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

step "2/8  Archivieren"
xcodebuild archive \
  -project "$PROJECT_DIR/App/ClaudeMonitor.xcodeproj" \
  -scheme ClaudeMonitor \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  -archivePath "$ARCHIVE" \
  | grep -E 'error:|ARCHIVE' || true
[ -d "$ARCHIVE" ] || fail "Archiv wurde nicht erzeugt."

step "3/8  Exportieren (Developer ID)"
xcodebuild -exportArchive \
  -archivePath "$ARCHIVE" \
  -exportPath "$EXPORT_DIR" \
  -exportOptionsPlist "$PROJECT_DIR/scripts/ExportOptions.plist" \
  | grep -E 'error:|EXPORT' || true
[ -d "$APP" ] || fail "Export hat keine .app erzeugt."

VERSION="$(defaults read "$APP/Contents/Info.plist" CFBundleShortVersionString)"
DMG="$BUILD_DIR/ClaudeMonitor-$VERSION.dmg"

step "4/8  Entitlements prüfen"
ENTITLEMENTS="$(codesign -d --entitlements - --xml "$APP" 2>/dev/null | plutil -convert xml1 -o - -)"
# Muss weg sein, sonst lehnt die Notarisierung ab.
grep -q 'get-task-allow' <<<"$ENTITLEMENTS" \
  && fail "get-task-allow ist noch gesetzt — der Export hat nicht gegriffen."
# Muss fehlen, solange die Widgets auf Hold sind: deklariert-aber-nicht-
# autorisiert ist der Zustand, in dem die App im Systemdialog endlos hängt.
# Begründung in App/Signing.xcconfig.
grep -q 'application-groups' <<<"$ENTITLEMENTS" \
  && fail "App-Group-Entitlement ist gesetzt, obwohl die Widgets auf Hold sind."
echo "  ✓ kein get-task-allow, keine App Group"

step "5/8  Notarisieren (kann einige Minuten dauern)"
ZIP="$BUILD_DIR/ClaudeMonitor-notarize.zip"
ditto -c -k --keepParent "$APP" "$ZIP"
xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait \
  || fail "Notarisierung abgelehnt. Details: xcrun notarytool log <id> --keychain-profile $NOTARY_PROFILE"
rm -f "$ZIP"

# Erst stapeln, DANN verpacken. Andersherum enthielte das DMG eine .app ohne
# Ticket, und ein Rechner ohne Netz beim ersten Start würde sie abweisen.
step "6/8  Ticket anheften"
xcrun stapler staple "$APP" || fail "stapler staple fehlgeschlagen."

step "7/8  DMG bauen"
DMG_ROOT="$BUILD_DIR/dmg"
mkdir -p "$DMG_ROOT"
cp -R "$APP" "$DMG_ROOT/"
ln -s /Applications "$DMG_ROOT/Applications"
hdiutil create -volname "ClaudeMonitor $VERSION" \
  -srcfolder "$DMG_ROOT" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$DMG_ROOT"

step "8/8  Gegenprobe"
codesign --verify --deep --strict --verbose=2 "$APP" 2>&1 | sed 's/^/  /'
# Der Gatekeeper-Test, der wirklich zählt: `-t install` bewertet die App so,
# wie ein fremder Mac sie beim ersten Öffnen bewertet.
spctl -a -vvv -t install "$APP" 2>&1 | sed 's/^/  /' \
  || fail "spctl weist die App ab."
xcrun stapler validate "$APP" 2>&1 | sed 's/^/  /'
xcrun stapler staple "$DMG" >/dev/null 2>&1 || true

printf '\n\033[32m✔ Fertig: %s\033[0m\n' "$DMG"
echo "  Hochladen nach GitHub Releases ist ein bewusster, eigener Schritt."
