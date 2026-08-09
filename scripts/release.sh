#!/bin/bash
#
# Baut ClaudeMonitor als notarisiertes, verteilbares DMG und schreibt den
# Sparkle-Appcast fort.
#
#   ./scripts/release.sh
#
# Das Skript lädt NICHTS hoch, legt kein Tag an und veröffentlicht nichts — es
# legt das fertige DMG unter build/ ab, kopiert es ins persistente Release-
# Archiv und erneuert docs/appcast.xml im Repo. Der Weg zu GitHub Releases und
# GitHub Pages ist bewusst ein eigener, manueller Schritt; die verbindliche
# Reihenfolge steht in der Schlussmeldung.
#
# WARUM archive + exportArchive und nicht `xcodebuild build`:
#   Ein direkter Release-Build trägt weiterhin `com.apple.security.get-task-allow`
#   (das Debug-Entitlement). Damit lehnt die Notarisierung ab. Erst der Export
#   mit `method = developer-id` entfernt es. Schritt 5 prüft das nach, statt sich
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
#
# EINMALIGE VORBEREITUNG — Sparkle-Signaturschlüssel. Der private Schlüssel darf
# NIE ins Repository. Er liegt als Datei außerhalb des Repos (0600) und wird
# generate_appcast per --ed-key-file gereicht:
#
#   generate_keys --account ClaudeMonitor
#   generate_keys --account ClaudeMonitor -x ~/MF-Projects/.secrets/ClaudeMonitor/sparkle_ed25519.key
#   chmod 600 ~/MF-Projects/.secrets/ClaudeMonitor/sparkle_ed25519.key
#
# Bewusst die Datei und nicht der Schlüsselbund: Ein Keychain-Zugriff kann mitten
# im Release einen GUI-Dialog aufwerfen und den Lauf blockieren.

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="$PROJECT_DIR/build"
ARCHIVE="$BUILD_DIR/ClaudeMonitor.xcarchive"
EXPORT_DIR="$BUILD_DIR/export"
APP="$EXPORT_DIR/ClaudeMonitor.app"
XCODEPROJ="$PROJECT_DIR/App/ClaudeMonitor.xcodeproj"
NOTARY_PROFILE="${NOTARY_PROFILE:-ClaudeMonitor-Notary}"

# ---------------------------------------------------------------------------
# PERSISTENTES RELEASE-ARCHIV — der Kern der Appcast-Kette. Bitte vor jeder
# Änderung an diesem Block zu Ende lesen.
#
# generate_appcast arbeitet verzeichnisbasiert: Es liest einen bereits
# vorhandenen appcast.xml IM ARCHIVVERZEICHNIS und schreibt ihn fort. Nur für
# Archive, die noch nicht im Feed stehen, erzeugt es neue Einträge; bestehende
# Einträge bleiben unangetastet.
#
# Genau deshalb darf dieses Verzeichnis NICHT unter build/ liegen: build/ wird
# bei jedem Lauf mit `rm -rf` geleert. Läge der Appcast dort, wäre er bei jedem
# Lauf verschwunden, JEDER Eintrag gälte als neu — und --download-url-prefix,
# das den Tag der GERADE gebauten Version trägt, würde auf ALLE Einträge
# angewandt. Die Enclosure-URLs älterer Versionen zeigten dann auf ein Asset,
# das es unter diesem Tag nie gab. Folge: 404 beim Update für jeden Nutzer, der
# eine Version übersprungen hat — ein Fehler, der Monate später auftritt und
# aus dem Skript heraus nicht mehr erkennbar ist.
#
# Deshalb: außerhalb des Repos, wird nie gelöscht, das DMG wird dorthin KOPIERT
# (build/ bleibt das Arbeitsergebnis), generate_appcast läuft OHNE -o auf diesem
# Verzeichnis, und erst danach wird das Ergebnis nach docs/appcast.xml kopiert.
# ---------------------------------------------------------------------------
RELEASES_DIR="${CLAUDEMONITOR_RELEASES_DIR:-$HOME/MF-Projects/ClaudeMonitor-Releases}"
APPCAST="$RELEASES_DIR/appcast.xml"
DOCS_APPCAST="$PROJECT_DIR/docs/appcast.xml"

SPARKLE_KEY_FILE="${CLAUDEMONITOR_SPARKLE_KEY:-$HOME/MF-Projects/.secrets/ClaudeMonitor/sparkle_ed25519.key}"
TEAM_ID="94794Q4RW7"
DOWNLOAD_URL_BASE="https://github.com/SeraphimSakuja/ClaudeMonitor/releases/download"
PROJECT_URL="https://github.com/SeraphimSakuja/ClaudeMonitor"
FEED_URL="https://seraphimsakuja.github.io/ClaudeMonitor/appcast.xml"

step() { printf '\n\033[1m▸ %s\033[0m\n' "$1"; }
fail() { printf '\n\033[31m✘ %s\033[0m\n' "$1" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Werkzeugpfad deterministisch bestimmen.
#
# generate_appcast und sign_update liegen NICHT im PATH. Sie stecken im
# SPM-Artefakt unterhalb von DerivedData — einem Pfad, der beim nächsten
# Aufräumen ersatzlos verschwindet. Deshalb: erst PATH, dann gezielt unterhalb
# des tatsächlich konfigurierten DerivedData-Pfades suchen, sonst hart
# abbrechen. Der Appcast-Schritt wird NIE stillschweigend übersprungen — ein
# fehlender Appcast fällt sonst erst auf, wenn die Nutzer kein Update bekommen.
#
# $1 = BUILD_DIR-Buildsetting (…/DerivedData/<Projekt>/Build/Products)
# Ergebnis in der globalen Variablen SPARKLE_BIN.
resolve_sparkle_tools() {
  local derived_products="$1" derived_root candidate
  SPARKLE_BIN=""

  if command -v generate_appcast >/dev/null 2>&1; then
    SPARKLE_BIN="$(dirname "$(command -v generate_appcast)")"
    return 0
  fi

  derived_root="${derived_products%/Build/Products}"
  if [ -d "$derived_root/SourcePackages/artifacts" ]; then
    candidate="$(find "$derived_root/SourcePackages/artifacts" \
                   -type f -perm -111 -name generate_appcast \
                   -path '*/Sparkle/bin/*' 2>/dev/null | head -n 1 || true)"
    if [ -n "$candidate" ]; then
      SPARKLE_BIN="$(dirname "$candidate")"
      return 0
    fi
  fi

  fail "Sparkle-Werkzeuge (generate_appcast/sign_update) nicht gefunden.
  Weder im PATH noch unter $derived_root/SourcePackages/artifacts.
  Abhilfe — eine der beiden Varianten:
    a) brew install --cask sparkle
    b) Release-Tarball von https://github.com/sparkle-project/Sparkle/releases
       entpacken und dessen bin/ in den PATH legen:
       export PATH=\"/pfad/zu/Sparkle/bin:\$PATH\"
  Danach dieses Skript erneut starten."
}

# ---------------------------------------------------------------------------
# Alle verschachtelten Code-Objekte des Bundles auflisten (ein Pfad pro Zeile).
#
# Seit Sparkle im Bundle steckt, ist „die App" nicht mehr ein Binary, sondern
# ein Baum: Sparkle.framework, darin Versions/B/Updater.app, Autoupdate und
# XPCServices/{Downloader,Installer}.xpc. Jedes davon trägt eine EIGENE Signatur
# und EIGENE Entitlements. Wer nur das Hauptbinary prüft, prüft den kleineren
# Teil und behauptet den größeren.
nested_code_objects() {
  find "$1" -mindepth 1 \
    \( -name '*.app' -o -name '*.xpc' -o -name '*.framework' -o -name 'Autoupdate' \) \
    2>/dev/null | sort
}

# ---------------------------------------------------------------------------
# Entitlement-Wächter über ALLE Code-Objekte (Hauptbundle + verschachtelte).
#
# Geprüft wird ausschließlich auf zwei Schlüssel:
#   get-task-allow     — das Debug-Entitlement; ist es noch da, lehnt die
#                        Notarisierung ab, der Export hat also nicht gegriffen.
#   application-groups — muss fehlen, solange die Widgets auf Hold sind:
#                        deklariert-aber-nicht-autorisiert ist der Zustand, in
#                        dem die App im Systemdialog endlos hängt. Begründung
#                        in App/Signing.xcconfig.
#
# Fremde Entitlements von Sparkle selbst — etwa com.apple.application-identifier
# in Autoupdate — sind ausdrücklich KEIN Abbruchgrund. Sie gehören zu Sparkles
# eigener Signatur und sagen über diese App nichts aus.
check_entitlements() {
  local app="$1" obj ent
  local objects
  objects="$(printf '%s\n' "$app"; nested_code_objects "$app")"

  while IFS= read -r obj; do
    [ -n "$obj" ] || continue
    ent="$(codesign -d --entitlements - --xml "$obj" 2>/dev/null || true)"
    [ -n "$ent" ] || continue   # kein Entitlement-Blob → nichts zu prüfen
    if grep -q 'get-task-allow' <<<"$ent"; then
      fail "get-task-allow ist noch gesetzt in: ${obj#"$app"/} — der Export hat nicht gegriffen."
    fi
    if grep -q 'application-groups' <<<"$ent"; then
      fail "App-Group-Entitlement gesetzt in: ${obj#"$app"/}, obwohl die Widgets auf Hold sind."
    fi
  done <<<"$objects"
}

# ---------------------------------------------------------------------------
# Signaturwächter für den verschachtelten Code — VOR der Notarisierung.
#
# Sparkle wird ad-hoc signiert ausgeliefert. Am Original-Artefakt 2.9.5
# nachgemessen: Sparkle.framework, Versions/B/Updater.app, Versions/B/Autoupdate
# und XPCServices/{Downloader,Installer}.xpc tragen alle
# flags=0x10002(adhoc,runtime) und TeamIdentifier=not set.
#
# Ad-hoc signierter verschachtelter Code lässt die Notarisierung ablehnen — und
# `codesign --verify --deep --strict` fängt das NICHT, weil eine Ad-hoc-Signatur
# eine gültige Signatur ist. Ohne diesen Wächter fällt der Fehler erst nach
# Minuten Wartezeit am notarytool auf.
#
# Der genannte Fallback wird bewusst NICHT automatisch ausgeführt: Ob Xcode beim
# Export rekursiv nachsigniert, zeigt erst der erste echte Lauf. Automatisches
# Nachsignieren würde genau diesen Befund verdecken.
check_nested_signatures() {
  local app="$1" team="$2" obj info
  local objects
  objects="$(nested_code_objects "$app")"
  [ -n "$objects" ] || return 0

  while IFS= read -r obj; do
    [ -n "$obj" ] || continue
    info="$(codesign -dv --verbose=2 "$obj" 2>&1 || true)"

    if ! grep -q "TeamIdentifier=$team" <<<"$info"; then
      fail "Verschachtelter Code ohne Team-ID $team: ${obj#"$app"/}
  codesign meldet: $(grep -E 'TeamIdentifier|flags=' <<<"$info" | tr '\n' ' ')
  Das ist mit hoher Wahrscheinlichkeit Sparkles Ad-hoc-Signatur.
  Fallback — inside-out neu signieren, GENAU in dieser Reihenfolge:
    SIGN=\"Developer ID Application: <Name> ($team)\"
    F=\"$app/Contents/Frameworks/Sparkle.framework\"
    codesign -f -s \"\$SIGN\" --options runtime --timestamp \"\$F/Versions/B/XPCServices/Downloader.xpc\"
    codesign -f -s \"\$SIGN\" --options runtime --timestamp \"\$F/Versions/B/XPCServices/Installer.xpc\"
    codesign -f -s \"\$SIGN\" --options runtime --timestamp \"\$F/Versions/B/Updater.app\"
    codesign -f -s \"\$SIGN\" --options runtime --timestamp \"\$F/Versions/B/Autoupdate\"
    codesign -f -s \"\$SIGN\" --options runtime --timestamp \"\$F\"
    codesign -f -s \"\$SIGN\" --options runtime --timestamp \"$app\"
  Bitte NICHT automatisieren, bevor nicht geklärt ist, warum der Export nicht
  rekursiv nachsigniert hat."
    fi

    if ! grep -qE '^CodeDirectory .*flags=.*runtime' <<<"$info"; then
      fail "Verschachtelter Code ohne Hardened Runtime: ${obj#"$app"/}
  codesign meldet: $(grep -E 'flags=' <<<"$info" | tr '\n' ' ')
  Ohne --options runtime lehnt die Notarisierung ab. Fallback wie oben:
  inside-out neu signieren, jeweils mit --options runtime --timestamp."
    fi
  done <<<"$objects"
}

# ---------------------------------------------------------------------------
step "0/11  Vorbedingungen"

security find-identity -v -p codesigning \
  | grep -q "Developer ID Application" \
  || fail "Kein „Developer ID Application\"-Zertifikat im Schlüsselbund."

xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1 \
  || fail "Kein notarytool-Profil „$NOTARY_PROFILE\". Siehe Kopf dieser Datei."

# Versionen: ZWEI Größen, nicht eine.
#   SHORT_VERSION (CFBundleShortVersionString) → DMG-Name, Tag, Menschen.
#   BUILD_VERSION (CFBundleVersion)            → Sparkles Vergleichsgröße.
# Sparkle entscheidet ausschließlich anhand von CFBundleVersion, ob ein Update
# angeboten wird. Beide werden hier aus den Buildsettings gelesen, weil sie in
# Schritt 0 gebraucht werden — lange bevor es eine gebaute .app gibt. Nach dem
# Export wird gegen die tatsächliche Info.plist gegengeprüft.
BUILD_SETTINGS="$(xcodebuild -showBuildSettings -project "$XCODEPROJ" -scheme ClaudeMonitor 2>/dev/null)" \
  || fail "xcodebuild -showBuildSettings fehlgeschlagen — Projekt/Scheme nicht lesbar."
setting() { sed -n "s/^ *$1 = //p" <<<"$BUILD_SETTINGS" | head -n 1; }
SHORT_VERSION="$(setting MARKETING_VERSION)"
BUILD_VERSION="$(setting CURRENT_PROJECT_VERSION)"
DERIVED_PRODUCTS="$(setting BUILD_DIR)"
[ -n "$SHORT_VERSION" ] || fail "MARKETING_VERSION ist leer."
[ -n "$BUILD_VERSION" ] || fail "CURRENT_PROJECT_VERSION ist leer."

# Sparkle vergleicht CFBundleVersion numerisch. Ein nicht-numerischer Wert macht
# den Monotonie-Wächter unten wirkungslos, deshalb hier abfangen.
[[ "$BUILD_VERSION" =~ ^[0-9]+$ ]] \
  || fail "CURRENT_PROJECT_VERSION ist „$BUILD_VERSION\", muss aber eine ganze Zahl sein.
  Sparkle vergleicht CFBundleVersion numerisch."

mkdir -p "$RELEASES_DIR"

# WÄCHTER: Versions-Monotonie.
# BUILD_VERSION muss STRIKT GRÖSSER sein als das Maximum aller sparkle:version
# im vorhandenen Appcast. Ein bloßes „steht die Version schon drin?" genügt
# nicht: Eine KLEINERE Zahl bestünde diesen Test anstandslos, und Sparkle böte
# dann stumm nie wieder ein Update an. Deshalb numerischer Vergleich gegen das
# Maximum. Beim Erstrelease gibt es noch keinen Appcast — dann entfällt der
# Vergleich.
# Das grep deckt beide Schreibweisen ab, die generate_appcast je nach Version
# erzeugt: als Kindelement <sparkle:version>N</sparkle:version> und als Attribut
# sparkle:version="N" am <enclosure>.
if [ -f "$APPCAST" ]; then
  MAX_FEED_VERSION="$(grep -oE 'sparkle:version(>|=")[0-9]+' "$APPCAST" \
                        | grep -oE '[0-9]+$' | sort -n | tail -n 1 || true)"
  if [ -n "$MAX_FEED_VERSION" ] && [ "$BUILD_VERSION" -le "$MAX_FEED_VERSION" ]; then
    fail "CFBundleVersion $BUILD_VERSION ist nicht größer als die höchste Version im Feed ($MAX_FEED_VERSION).
  Sparkle würde dieses Release nie als Update anbieten.
  Abhilfe: CURRENT_PROJECT_VERSION in $XCODEPROJ auf mindestens $((MAX_FEED_VERSION + 1)) erhöhen
  (Xcode → Target ClaudeMonitor → Build Settings → „Current Project Version\")."
  fi
fi

# WÄCHTER: Sparkle-Signaturschlüssel vorhanden und nur für den Eigentümer lesbar.
[ -f "$SPARKLE_KEY_FILE" ] \
  || fail "Sparkle-Signaturschlüssel fehlt: $SPARKLE_KEY_FILE
  Ohne ihn kann der Appcast nicht signiert werden und kein Client akzeptiert das Update.
  Abhilfe (exportiert den vorhandenen Schlüssel aus dem Schlüsselbund):
    mkdir -p \"\$(dirname \"$SPARKLE_KEY_FILE\")\"
    generate_keys --account ClaudeMonitor -x \"$SPARKLE_KEY_FILE\"
    chmod 600 \"$SPARKLE_KEY_FILE\""
KEY_MODE="$(stat -f '%OLp' "$SPARKLE_KEY_FILE")"
[ "$KEY_MODE" = "600" ] \
  || fail "Sparkle-Signaturschlüssel hat Rechte $KEY_MODE statt 600: $SPARKLE_KEY_FILE
  Abhilfe: chmod 600 \"$SPARKLE_KEY_FILE\""

# WÄCHTER: Release Notes.
# generate_appcast zieht eine Notizdatei mit DEMSELBEN BASISNAMEN wie das
# Archiv (.md/.html/.txt). Fehlt sie, bleibt die Notizfläche in Sparkles
# Update-Dialog leer — ausgerechnet beim allerersten Update, das ein Nutzer je
# von dieser App sieht. Die Datei wird von Hand gepflegt, nicht generiert.
RELEASE_NOTES="$RELEASES_DIR/ClaudeMonitor-$SHORT_VERSION.md"
[ -f "$RELEASE_NOTES" ] \
  || fail "Release Notes fehlen: $RELEASE_NOTES
  Sparkle zeigt sonst ein leeres Notizfeld im Update-Dialog.
  Abhilfe: Datei anlegen (Markdown, Basisname identisch zum DMG) und den
  Abschnitt zu v$SHORT_VERSION aus
  MF-Docs/ClaudeMonitor/Changelog_Erledigt.md hineinkopieren."

# WÄCHTER: Sparkle-Werkzeuge auflösbar (setzt SPARKLE_BIN).
resolve_sparkle_tools "$DERIVED_PRODUCTS"

echo "  ✓ Zertifikat, notarytool-Profil, Signaturschlüssel, Release Notes"
echo "  ✓ Version $SHORT_VERSION (Build $BUILD_VERSION)"
echo "  ✓ Sparkle-Werkzeuge: $SPARKLE_BIN"
echo "  ✓ Release-Archiv:    $RELEASES_DIR"

# Die Testbelege dieses Projekts stammen ausschließlich aus `swift test`.
# `xcodebuild test` meldet hier TEST SUCCEEDED, OHNE einen Test auszuführen:
# Das Scheme trägt eine TestAction mit leerem <Testables>, und Xcode stellt sie
# selbsttätig wieder her. Siehe SSOT-Punkt CM-06.
step "1/11  Tests (Core + Shared)"
( cd "$PROJECT_DIR/Core"   && swift test ) || fail "Core-Tests rot."
( cd "$PROJECT_DIR/Shared" && swift test ) || fail "Shared-Tests rot."

rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

# Eigener, UNGEFILTERTER Vorschritt. Der archive-Aufruf unten filtert seine
# Ausgabe durch `grep -E 'error:|ARCHIVE'`; mit einer Remote-Abhängigkeit
# verschluckt dieser Filter Auflösungsfehler (kein Netz, Prüfsummen-Konflikt,
# GitHub nicht erreichbar). Sichtbar würde erst das fehlende Archiv — ohne
# Ursache. Deshalb hier ungefiltert und mit hartem Abbruch.
step "2/11  Paketabhängigkeiten auflösen"
xcodebuild -resolvePackageDependencies \
  -project "$XCODEPROJ" \
  -scheme ClaudeMonitor \
  || fail "Auflösung der SPM-Abhängigkeiten fehlgeschlagen (Netz? Prüfsumme? GitHub erreichbar?)."

# -onlyUsePackageVersionsFromResolvedFile: Der Release-Build benutzt exakt die
# committete Package.resolved. Ohne das könnte `upToNextMinorVersion` unbemerkt
# eine andere Sparkle-2.x-Version ziehen — ein fremdes Framework, das Code auf
# Nutzermaschinen installiert.
step "3/11  Archivieren"
xcodebuild archive \
  -project "$XCODEPROJ" \
  -scheme ClaudeMonitor \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  -archivePath "$ARCHIVE" \
  -onlyUsePackageVersionsFromResolvedFile \
  | grep -E 'error:|ARCHIVE' || true
[ -d "$ARCHIVE" ] || fail "Archiv wurde nicht erzeugt."

step "4/11  Exportieren (Developer ID)"
xcodebuild -exportArchive \
  -archivePath "$ARCHIVE" \
  -exportPath "$EXPORT_DIR" \
  -exportOptionsPlist "$PROJECT_DIR/scripts/ExportOptions.plist" \
  | grep -E 'error:|EXPORT' || true
[ -d "$APP" ] || fail "Export hat keine .app erzeugt."

# Gegenprobe der in Schritt 0 aus den Buildsettings gelesenen Versionen gegen
# das, was tatsächlich im Bundle steht. Weichen sie ab, hat der Monotonie-
# Wächter oben die falsche Zahl geprüft.
PLIST_SHORT="$(defaults read "$APP/Contents/Info.plist" CFBundleShortVersionString)"
PLIST_BUILD="$(defaults read "$APP/Contents/Info.plist" CFBundleVersion)"
[ "$PLIST_SHORT" = "$SHORT_VERSION" ] && [ "$PLIST_BUILD" = "$BUILD_VERSION" ] \
  || fail "Version im Bundle ($PLIST_SHORT/$PLIST_BUILD) weicht von den Buildsettings ($SHORT_VERSION/$BUILD_VERSION) ab.
  Der Versions-Wächter in Schritt 0 hat damit die falsche Zahl geprüft."

DMG="$BUILD_DIR/ClaudeMonitor-$SHORT_VERSION.dmg"

step "5/11  Entitlements prüfen (alle Code-Objekte)"
check_entitlements "$APP"
echo "  ✓ kein get-task-allow, keine App Group — im Hauptbundle und in allem Verschachtelten"

step "6/11  Signatur des verschachtelten Codes prüfen"
check_nested_signatures "$APP" "$TEAM_ID"
echo "  ✓ alle verschachtelten Objekte: TeamIdentifier=$TEAM_ID, Hardened Runtime"

step "7/11  Notarisieren (kann einige Minuten dauern)"
ZIP="$BUILD_DIR/ClaudeMonitor-notarize.zip"
ditto -c -k --keepParent "$APP" "$ZIP"
xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait \
  || fail "Notarisierung abgelehnt. Details: xcrun notarytool log <id> --keychain-profile $NOTARY_PROFILE"
rm -f "$ZIP"

# Erst stapeln, DANN verpacken. Andersherum enthielte das DMG eine .app ohne
# Ticket, und ein Rechner ohne Netz beim ersten Start würde sie abweisen.
step "8/11  Ticket anheften"
xcrun stapler staple "$APP" || fail "stapler staple fehlgeschlagen."

step "9/11  DMG bauen"
DMG_ROOT="$BUILD_DIR/dmg"
mkdir -p "$DMG_ROOT"
cp -R "$APP" "$DMG_ROOT/"
ln -s /Applications "$DMG_ROOT/Applications"
hdiutil create -volname "ClaudeMonitor $SHORT_VERSION" \
  -srcfolder "$DMG_ROOT" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$DMG_ROOT"

step "10/11  Gegenprobe"
codesign --verify --deep --strict --verbose=2 "$APP" 2>&1 | sed 's/^/  /'
# Der Gatekeeper-Test, der wirklich zählt: `-t install` bewertet die App so,
# wie ein fremder Mac sie beim ersten Öffnen bewertet.
spctl -a -vvv -t install "$APP" 2>&1 | sed 's/^/  /' \
  || fail "spctl weist die App ab."
xcrun stapler validate "$APP" 2>&1 | sed 's/^/  /'
xcrun stapler staple "$DMG" >/dev/null 2>&1 || true

# ---------------------------------------------------------------------------
# Appcast fortschreiben. Reihenfolge ist zwingend (siehe Kopf der Datei):
#   1. DMG ins persistente Archiv KOPIEREN (nicht verschieben — build/ bleibt
#      das Arbeitsergebnis dieses Laufs).
#   2. generate_appcast auf dem Archivverzeichnis laufen lassen, OHNE -o. Nur so
#      findet es den vorhandenen appcast.xml dort und schreibt ihn fort, statt
#      ihn neu zu erfinden.
#   3. Ergebnis nach docs/appcast.xml ins Repo kopieren — das ist die Datei, die
#      GitHub Pages ausliefert.
step "11/11  Appcast erzeugen"
cp -f "$DMG" "$RELEASES_DIR/"
"$SPARKLE_BIN/generate_appcast" \
  --account ClaudeMonitor \
  --ed-key-file "$SPARKLE_KEY_FILE" \
  --download-url-prefix "$DOWNLOAD_URL_BASE/v$SHORT_VERSION/" \
  --link "$PROJECT_URL" \
  "$RELEASES_DIR" \
  || fail "generate_appcast fehlgeschlagen."
[ -f "$APPCAST" ] || fail "generate_appcast hat keinen appcast.xml erzeugt: $APPCAST"
mkdir -p "$(dirname "$DOCS_APPCAST")"
cp -f "$APPCAST" "$DOCS_APPCAST"

printf '\n\033[32m✔ Fertig: %s\033[0m\n' "$DMG"
echo "  Release-Archiv: $RELEASES_DIR"
echo "  Appcast im Repo: $DOCS_APPCAST"
echo
echo "  Veröffentlichen — die Reihenfolge ist bindend:"
echo "    1. Repository öffentlich schalten (falls noch nicht) und GitHub Pages"
echo "       auf Branch main / Ordner /docs stellen."
echo "    2. GitHub-Release v$SHORT_VERSION anlegen und $(basename "$DMG") als Asset hochladen."
echo "    3. docs/appcast.xml committen und pushen."
echo "    4. Gegenprobe: curl -sI $FEED_URL"
echo "    5. Erst DANACH das DMG weitergeben."
echo
echo "  Warum bindend: Vor Schritt 4 ist der Feed nicht erreichbar — jede vorher"
echo "  weitergegebene Kopie kann nie ein Update finden, auch später nicht"
echo "  automatisch, weil sie vom ersten Suchlauf an ins Leere greift."
echo
echo "  Hochladen und Tag bleiben bewusst manuelle, eigene Schritte."
