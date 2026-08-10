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

# Die Teil-Plist der Arbeitskopie mit den Sparkle-Keys. Xcode MERGT sie beim
# Bauen mit den generierten Keys ins Bundle — dass das passiert, prüft der
# Vertrauensanker-Wächter in Schritt 4 nach.
SOURCE_INFO_PLIST="$PROJECT_DIR/App/Info.plist"

# EINGEFRORENER VERTRAUENSANKER (Leitplanke L9). Bewusst als Konstante HIER und
# nicht aus App/Info.plist gelesen: Das ist der zweite, UNABHÄNGIGE Anker.
# Verändert jemand App/Info.plist — versehentlich oder absichtlich —, schlägt
# genau dieser Vergleich an, während ein Vergleich Bundle-gegen-Arbeitskopie
# allein die Änderung anstandslos durchwinken würde.
SPARKLE_PUBLIC_KEY="xe1+/8jYc45qORKi4EzxgBfxsOk0K5NWRS79mjuJQj0="

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
# Aufräumen ersatzlos verschwindet.
#
# REIHENFOLGE: erst das SPM-Artefakt, DANN der PATH. Sie war früher andersherum
# und das war die falsche Wahl: Dem gefundenen Binary wird `--ed-key-file`
# gereicht, also der PFAD ZUM PRIVATEN SIGNATURSCHLÜSSEL. Ein untergeschobenes
# `generate_appcast` (manipulierter PATH, kompromittiertes Homebrew-Cask) könnte
# ihn damit ausleiten. Ein gestohlener EdDSA-Schlüssel ist bei dieser
# Architektur der Totalverlust: Leitplanke L9 friert den Public Key im Bundle
# ein, es gibt also keinen schmerzfreien Rotationspfad — jede ausgelieferte
# Kopie müsste von Hand ersetzt werden. Das SPM-Artefakt stammt dagegen aus der
# committeten, prüfsummengesicherten Package.resolved und ist damit die
# vertrauenswürdigere Quelle. Der PATH bleibt nur als Rückfallebene.
#
# Fehlt beides: hart abbrechen. Der Appcast-Schritt wird NIE stillschweigend
# übersprungen — ein fehlender Appcast fällt sonst erst auf, wenn die Nutzer
# kein Update bekommen.
#
# $1 = BUILD_DIR-Buildsetting (…/DerivedData/<Projekt>/Build/Products)
# Ergebnis in der globalen Variablen SPARKLE_BIN.
resolve_sparkle_tools() {
  local derived_products="$1" derived_root candidate
  SPARKLE_BIN=""

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

  if command -v generate_appcast >/dev/null 2>&1; then
    SPARKLE_BIN="$(dirname "$(command -v generate_appcast)")"
    return 0
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
else
  # Ein still übersprungener Wächter ist schlimmer als gar keiner: Zeigt
  # CLAUDEMONITOR_RELEASES_DIR versehentlich auf ein leeres Verzeichnis, entfiele
  # dieser Vergleich WORTLOS — und zugleich träte der Schaden ein, den der Kopf
  # dieser Datei beschreibt (generate_appcast hielte alle Einträge für neu und
  # schriebe --download-url-prefix mit dem AKTUELLEN Tag auf ALLE). Deshalb wird
  # das Überspringen hier ausdrücklich gemeldet. Die Gegenprobe nach Schritt 11
  # fängt den zweiten Teil des Schadens.
  echo "  ⚠ Kein vorhandener Appcast in $RELEASES_DIR — Monotonieprüfung entfällt (nur beim Erstrelease korrekt)."
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

# Der Modus allein genügt nicht: 0600 sagt „nur der Eigentümer darf lesen" —
# nicht, dass der Eigentümer auch ICH bin. Und ein weit offenes Elternverzeichnis
# lässt Fremde die Datei umbenennen oder ersetzen, ohne sie je zu lesen.
KEY_OWNER="$(stat -f '%u' "$SPARKLE_KEY_FILE")"
[ "$KEY_OWNER" = "$(id -u)" ] \
  || fail "Sparkle-Signaturschlüssel gehört UID $KEY_OWNER, nicht dem laufenden Benutzer (UID $(id -u)): $SPARKLE_KEY_FILE
  0600 schützt nur den Eigentümer — ist das ein anderer, ist der Schlüssel für ihn offen und für dich fremdbestimmt.
  Abhilfe: sudo chown $(id -u) \"$SPARKLE_KEY_FILE\""

KEY_DIR="$(dirname "$SPARKLE_KEY_FILE")"
KEY_DIR_MODE="$(stat -f '%OLp' "$KEY_DIR")"
[ "$KEY_DIR_MODE" = "700" ] \
  || fail "Verzeichnis des Signaturschlüssels hat Rechte $KEY_DIR_MODE statt 700: $KEY_DIR
  Bei offenerem Verzeichnis kann ein fremder Prozess die Schlüsseldatei ersetzen oder verschieben, ohne sie lesen zu müssen.
  Abhilfe: chmod 700 \"$KEY_DIR\""

# WÄCHTER: Der private Schlüssel gehört zum eingebetteten Public Key.
#
# Bisher wurde nur geprüft, dass die Datei EXISTIERT und 0600 ist — nicht, dass
# sie zu SPARKLE_PUBLIC_KEY passt. Ein falscher, aber technisch gültiger
# Schlüssel (versehentliche Rotation, zweiter Rechner, gesetztes
# CLAUDEMONITOR_SPARKLE_KEY) erzeugt einen fehlerfrei signierten Appcast, den
# ABER KEIN EINZIGER CLIENT AKZEPTIERT. Der Lauf meldet Erfolg, das Release geht
# raus, und auffallen würde es erst Wochen später — daran, dass niemand ein
# Update bekommt.
#
# Die Datei enthält Base64 des 32-Byte-Seeds; daraus lässt sich der Public Key
# ableiten. Bewusst NICHT über `generate_keys -p`: Das ginge über den
# Schlüsselbund und könnte mitten im Release einen GUI-Dialog aufwerfen — genau
# das, was die Entscheidung im Kopf dieser Datei vermeiden will.
#
# Das Hilfsprogramm ist ein Wegwerf-Artefakt unter build/ und gehört nicht ins
# Repo. Es gibt ausschließlich den PUBLIC Key aus; der private verlässt weder
# die Datei noch diesen Prozess.
mkdir -p "$BUILD_DIR"
KEYCHECK_SWIFT="$BUILD_DIR/sparkle_pubkey_from_seed.swift"
cat >"$KEYCHECK_SWIFT" <<'SWIFT'
import Foundation
import CryptoKit
let raw = try String(contentsOfFile: CommandLine.arguments[1], encoding: .utf8)
guard let seed = Data(base64Encoded: raw.trimmingCharacters(in: .whitespacesAndNewlines)),
      let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: seed) else { exit(1) }
print(key.publicKey.rawRepresentation.base64EncodedString())
SWIFT

DERIVED_PUBLIC_KEY="$(swift "$KEYCHECK_SWIFT" "$SPARKLE_KEY_FILE" 2>/dev/null | tail -n 1 || true)"
rm -f "$KEYCHECK_SWIFT"

[ -n "$DERIVED_PUBLIC_KEY" ] \
  || fail "Aus $SPARKLE_KEY_FILE ließ sich kein Ed25519-Public-Key ableiten.
  Erwartet wird Base64 eines 32-Byte-Seeds — genau das, was „generate_keys -x\" schreibt.
  Ist die Datei leer, abgeschnitten oder ein anderes Format, wäre der erzeugte Appcast wertlos."

[ "$DERIVED_PUBLIC_KEY" = "$SPARKLE_PUBLIC_KEY" ] \
  || fail "Der Signaturschlüssel gehört NICHT zum Vertrauensanker der App.
  Schlüsseldatei:   $SPARKLE_KEY_FILE
  daraus abgeleitet: $DERIVED_PUBLIC_KEY
  im Bundle erwartet: $SPARKLE_PUBLIC_KEY
  Der Appcast entstünde fehlerfrei und wäre sauber signiert — und würde von JEDEM
  Client abgelehnt. Niemand bekäme je ein Update, und auffallen würde es erst Wochen später.
  Abhilfe: den richtigen Schlüssel exportieren bzw. CLAUDEMONITOR_SPARKLE_KEY korrigieren.
  Den Vertrauensanker zu ändern ist KEINE Abhilfe — er ist per Leitplanke L9 eingefroren."

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
echo "  ✓ Signaturschlüssel gehört zum Vertrauensanker $SPARKLE_PUBLIC_KEY"
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

# ---------------------------------------------------------------------------
# WÄCHTER: Vertrauensanker im exportierten Bundle.
#
# Dass SUPublicEDKey und SUFeedURL überhaupt im Bundle landen, hängt an
# undokumentiertem Xcode-Verhalten: GENERATE_INFOPLIST_FILE = YES MERGT die
# zusätzlich gesetzte INFOPLIST_FILE, statt sie zu ersetzen. Kippt dieses
# Verhalten mit einer künftigen Xcode-Version, fehlen die Keys — und Sparkle
# BRICHT NICHT AB: Es loggt eine Deprecation-Zeile und validiert Updates
# fortan ALLEIN über Apple Code Signing (SPUUpdater.m:340-355). Ein solcher
# Build besteht jeden anderen Wächter dieses Skripts, wird notarisiert und geht
# raus. Genau deshalb steht der Wächter hier.
#
# Geprüft werden ZWEI Dinge, und das ist Absicht:
#   1. MERGE   — Bundle-Werte == Werte in App/Info.plist der Arbeitskopie.
#                Fängt das Kippen des Xcode-Verhaltens.
#   2. L9      — SUPublicEDKey im Bundle == eingefrorene Konstante oben.
#                Zweiter, unabhängiger Anker: Verändert jemand App/Info.plist,
#                bestünde Prüfung 1 anstandslos — Prüfung 2 nicht.
#
# Bewusst OHNE eigene Schrittnummer, wie die Versions-Gegenprobe darüber: Die
# Nummerierung 0/11…11/11 bleibt dadurch lückenlos.
plist_value() { plutil -extract "$2" raw -o - "$1" 2>/dev/null || true; }

SOURCE_ED_KEY="$(plist_value "$SOURCE_INFO_PLIST" SUPublicEDKey)"
SOURCE_FEED_URL="$(plist_value "$SOURCE_INFO_PLIST" SUFeedURL)"
[ -n "$SOURCE_ED_KEY" ] && [ -n "$SOURCE_FEED_URL" ] \
  || fail "SUPublicEDKey oder SUFeedURL fehlt bereits in der Arbeitskopie: $SOURCE_INFO_PLIST
  Ohne diese beiden Keys hat die App keinen Vertrauensanker."

BUNDLE_ED_KEY="$(defaults read "$APP/Contents/Info.plist" SUPublicEDKey 2>/dev/null || true)"
BUNDLE_FEED_URL="$(defaults read "$APP/Contents/Info.plist" SUFeedURL 2>/dev/null || true)"

[ "$BUNDLE_ED_KEY" = "$SOURCE_ED_KEY" ] && [ "$BUNDLE_FEED_URL" = "$SOURCE_FEED_URL" ] \
  || fail "Der Vertrauensanker im exportierten Bundle weicht von $SOURCE_INFO_PLIST ab.
  im Bundle:      SUPublicEDKey=\"$BUNDLE_ED_KEY\"  SUFeedURL=\"$BUNDLE_FEED_URL\"
  in der Quelle:  SUPublicEDKey=\"$SOURCE_ED_KEY\"  SUFeedURL=\"$SOURCE_FEED_URL\"
  Sind die Werte LEER, hat der Info.plist-Merge nicht stattgefunden
  (GENERATE_INFOPLIST_FILE + INFOPLIST_FILE, siehe Kopf von App/Info.plist).
  BEDEUTUNG: Sparkle bricht deswegen NICHT ab — es validiert Updates dann
  stillschweigend allein über Apple Code Signing (SPUUpdater.m:340-355), und die
  EdDSA-Prüfung von Feed und Archiv entfällt ersatzlos. Dieses Bundle darf nicht
  ausgeliefert werden."

[ "$BUNDLE_ED_KEY" = "$SPARKLE_PUBLIC_KEY" ] \
  || fail "SUPublicEDKey im Bundle ist nicht der eingefrorene Vertrauensanker.
  im Bundle:   $BUNDLE_ED_KEY
  eingefroren: $SPARKLE_PUBLIC_KEY
  Der Anker ist per Leitplanke L9 festgeschrieben: Jede bereits ausgelieferte Kopie
  prüft gegen den ALTEN Schlüssel. Ein Bundle mit anderem Anker bekäme von diesen
  Clients nie ein Update — und Updates dieses Bundles wären mit dem bisherigen
  Schlüssel nicht mehr signierbar.
  Abhilfe ist NICHT, die Konstante in diesem Skript anzupassen, sondern
  App/Info.plist zurückzusetzen."

echo "  ✓ SUPublicEDKey und SUFeedURL im Bundle == Arbeitskopie"
echo "  ✓ SUPublicEDKey == eingefrorener Anker $SPARKLE_PUBLIC_KEY"

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

# Das DMG bekommt bewusst KEIN eigenes Ticket angeheftet.
#
# Hier stand ein `xcrun stapler staple "$DMG" >/dev/null 2>&1 || true`. Der
# Aufruf MUSSTE fehlschlagen — eingereicht wird in Schritt 7 ein ZIP der .app,
# nie das DMG; für das DMG existiert also gar kein Ticket, das sich abholen
# ließe. Mit unterdrückter Ausgabe und `|| true` tarnte er sich trotzdem als
# geglückter Schritt und behauptete etwas, das nie stattgefunden hat.
#
# Ein Ticket am DMG braucht es auch nicht: Die .app IM DMG trägt ihres aus
# Schritt 8, und geprüft wird die App — von Gatekeeper beim ersten Start
# (Schritt 10 belegt das mit `spctl -t install`) und von Sparkle beim Update.
# Das DMG ist nur die Hülle für den Transport.

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

# ⚠️ NUR das Archiv der AKTUELLEN Version darf im Wurzelverzeichnis liegen.
#
# `generate_appcast` erzeugt für JEDES dort gefundene Archiv einen Eintrag NEU
# und wendet dabei `--download-url-prefix` mit dem AKTUELLEN Tag an. Ein altes
# DMG im Wurzelverzeichnis bekommt dadurch eine Enclosure-URL unter dem neuen
# Tag — wo diese Datei nie liegen wird. Ergebnis: 404 für jeden Nutzer, der
# eine Version übersprungen hat, und zwar erst Monate später bemerkbar.
#
# Ein persistentes Archiv allein genügt also NICHT; das war beim ersten
# 1.0.1-Lauf am 10.08.2026 die falsche Annahme, und die Verlust-Gegenprobe
# weiter unten hat sie gestoppt, bevor docs/ Schaden nahm.
#
# GEMESSEN (10.08.2026, an einer Kopie des Archivs): Liegt das alte Archiv in
# `old_updates/`, meldet das Werkzeug „Wrote 1 new update, updated 0 existing
# updates" und übernimmt den alten Eintrag unverändert aus dem vorhandenen
# Appcast — die alte URL bleibt korrekt erhalten.
#
# Preis: keine Delta-Updates mehr (die bräuchten das Vorgängerarchiv am selben
# Ort). Bei rund 2 MB Gesamtgröße ist das kein Verlust.
mkdir -p "$RELEASES_DIR/old_updates"
STALE=0
while IFS= read -r stale; do
  [ -n "$stale" ] || continue
  mv "$stale" "$RELEASES_DIR/old_updates/"
  STALE=$((STALE + 1))
done < <(find "$RELEASES_DIR" -maxdepth 1 -type f \( -name '*.dmg' -o -name '*.delta' \) \
           ! -name "$(basename "$DMG")")
[ "$STALE" -eq 0 ] \
  && echo "  ✓ nur das aktuelle Archiv im Wurzelverzeichnis" \
  || echo "  ✓ $STALE ältere(s) Archiv(e) nach old_updates/ verschoben"
"$SPARKLE_BIN/generate_appcast" \
  --account ClaudeMonitor \
  --ed-key-file "$SPARKLE_KEY_FILE" \
  --download-url-prefix "$DOWNLOAD_URL_BASE/v$SHORT_VERSION/" \
  --link "$PROJECT_URL" \
  "$RELEASES_DIR" \
  || fail "generate_appcast fehlgeschlagen."
[ -f "$APPCAST" ] || fail "generate_appcast hat keinen appcast.xml erzeugt: $APPCAST"

# WÄCHTER: kein Eintrag darf verloren gehen (Gegenprobe zum Monotonie-Wächter).
#
# Der committete docs/appcast.xml ist der Stand, den die Nutzer heute sehen.
# Jede Enclosure-URL daraus MUSS im neu erzeugten Appcast wieder auftauchen.
# Fehlt eine, war das Release-Archiv unvollständig — dann hat generate_appcast
# die älteren Einträge nicht fortgeschrieben, sondern neu erfunden und ihnen
# --download-url-prefix mit dem AKTUELLEN Tag verpasst. Für jeden Nutzer, der
# eine Version übersprungen hat, endet das in einem 404 (siehe Kopf dieser
# Datei). Beim Erstrelease gibt es noch keinen committeten Appcast — dann
# entfällt der Vergleich naturgemäß.
if git -C "$PROJECT_DIR" cat-file -e HEAD:docs/appcast.xml 2>/dev/null; then
  while IFS= read -r url; do
    [ -n "$url" ] || continue
    grep -qF "$url" "$APPCAST" \
      || fail "Der neue Appcast hat einen Eintrag verloren, der im committeten docs/appcast.xml steht:
  $url
  Das Release-Archiv $RELEASES_DIR war also unvollständig. generate_appcast hat die
  älteren Einträge nicht fortgeschrieben, sondern neu erzeugt — mit dem Tag v$SHORT_VERSION
  in der Enclosure-URL. Jeder Nutzer, der eine Version übersprungen hat, liefe damit in ein 404.
  Abhilfe: alle bisherigen DMGs (und deren Release Notes) nach $RELEASES_DIR zurückholen
  und das Skript erneut laufen lassen. docs/appcast.xml NICHT von Hand reparieren —
  das bricht die Feed-Signatur (SURequireSignedFeed)."
  done < <(git -C "$PROJECT_DIR" show HEAD:docs/appcast.xml \
             | grep -oE 'url="[^"]+"' | sed 's/^url="//; s/"$//' | sort -u)
  echo "  ✓ alle Enclosure-URLs des committeten Appcasts sind erhalten"
else
  echo "  ⚠ Kein committeter docs/appcast.xml — Verlust-Gegenprobe entfällt (nur beim Erstrelease korrekt)."
fi

mkdir -p "$(dirname "$DOCS_APPCAST")"
cp -f "$APPCAST" "$DOCS_APPCAST"

# Die Release Notes müssen MIT nach docs/. `generate_appcast` legt den
# <sparkle:releaseNotesLink> neben den Feed — es leitet die Adresse aus der
# SUFeedURL des Bundles ab. Läge die Datei nur im Archivverzeichnis, zeigte der
# Link ins Leere und der Update-Dialog bliebe mit leerem Notizfeld stehen.
# Beim ersten echten Lauf am 10.08.2026 genau so passiert.
#
# ⚠️ Kopiert wird die Datei AUS DEM ARCHIVVERZEICHNIS, nicht das Original von
# vorher: `generate_appcast` schreibt ihr eine Signaturwarnung in den Kopf und
# signiert danach GENAU diesen Inhalt. Eine andere Fassung — und sei es nur
# ohne den Kopf — bricht `sparkle:edSignature` am releaseNotesLink.
DOCS_NOTES="$(dirname "$DOCS_APPCAST")/$(basename "$RELEASE_NOTES")"
cp -f "$RELEASE_NOTES" "$DOCS_NOTES"

# Gegenprobe: Jede Adresse unter der Feed-Domain muss auch als Datei in docs/
# liegen. Sonst verspricht der Appcast etwas, das die Seite nicht ausliefert.
FEED_BASE="$(dirname "$FEED_URL")"
while IFS= read -r link; do
  [ -n "$link" ] || continue
  candidate="$(dirname "$DOCS_APPCAST")/${link#"$FEED_BASE/"}"
  [ -f "$candidate" ] \
    || fail "Der Appcast verweist auf $link, aber $candidate fehlt.
  GitHub Pages liefert die Adresse dann nicht aus, und der Update-Dialog bleibt leer."
done < <(grep -oE "$FEED_BASE/[^<\"[:space:]]+" "$DOCS_APPCAST" | grep -v "$(basename "$DOCS_APPCAST")\$" | sort -u)
echo "  ✓ alle Feed-Adressen sind in docs/ vorhanden"

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
