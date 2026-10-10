#!/bin/bash
#
# Baut aus dem Tray-Prozess `claude-monitor-tray` (CM-20) einen verteilbaren
# Linux-Tarball samt Prüfsumme und Manifest.
#
#   docker run --rm --user "$(id -u):$(id -g)" \
#     -v "$PWD:/work" -w /work \
#     --tmpfs /hometmp:exec,mode=0777 --tmpfs /worktmp:exec,mode=0777 \
#     -e HOME=/hometmp -e TMPDIR=/worktmp \
#     swift:6.3.3 bash -lc './scripts/release-linux.sh'
#
# Der Lauf braucht Netz zu github.com (CM-36): SwiftPM klont `swift-crypto` in
# das tmpfs-HOME, gepinnt über Linux/Package.resolved.
#
# Das Skript ist der ZWILLING von `scripts/release.sh` (macOS/DMG/Sparkle) und
# fasst jenes bewusst nicht an: `release.sh` bleibt Null-Diff. Gemeinsame
# Identitätswerte — Download-Basis, Feed-Adresse, Projektadresse — werden
# deshalb weiter unten AUS `release.sh` GELESEN und hier nie zweitkopiert. Eine
# zweite Handkopie derselben URL ist genau die Sorte Fundstelle, die beim
# nächsten Umzug übersehen wird.
#
# Es lädt NICHTS hoch, legt kein Tag an und veröffentlicht nichts. Ergebnis sind
# drei Dateien unter build/linux/: der Tarball, die Prüfsummendatei und das
# UNSIGNIERTE Manifest linux-latest.unsigned.json. docs/linux-latest.json
# schreibt dieses Skript NICHT mehr (CM-36) — das tut erst
# `scripts/sign-linux-manifest.sh`, nach Signatur und beiden Gegenproben. Die
# Veröffentlichung ist ein eigener, von Hand ausgeführter Schritt; die
# Reihenfolge steht in der Schlussmeldung.
#
# ---------------------------------------------------------------------------
# WARUM TARBALL UND NICHT .deb, PPA ODER APPIMAGE
#
# Nicht, weil die Werkzeuge fehlten — `dpkg-deb`, `strip` und `objcopy` liegen
# im Bauimage und ein .deb wäre in einer halben Stunde gebaut. Der Grund ist
# der Bezugs- und Update-WEG dahinter: Ein Paket, das sich lohnt, will in ein
# Repository (PPA, OBS, Distributionsarchiv). Das bedeutet ein fremdes Konto,
# eine fremde Pflegepflicht und eine Zusage an die Nutzer, die sich kaum wieder
# einfangen lässt — „liegt im Repo" heißt „bleibt im Repo, auch in zwei
# Jahren". Ein Tarball zum Herunterladen und selbst Ablegen ist der Weg, der
# mit dem heutigen Stand ehrlich ist: eine Datei, eine Prüfsumme, kein
# Versprechen über die eigene Reichweite hinaus (Entscheid Markus, 14.09.2026).
#
# AppImage scheidet zusätzlich mechanisch aus: `appimagetool`, `zsync`, `curl`
# und `wget` fehlen im Bauimage und sind ohne Administratorrechte und ohne Netz
# dort nicht zu beschaffen.
#
# ---------------------------------------------------------------------------
# WAS HIER REPRODUZIERBAR IST — UND WAS NICHT
#
# Reproduzierbar ist die HÜLLE: `tar --sort=name --owner=0 --group=0
# --numeric-owner --mtime=@$SOURCE_DATE_EPOCH` und `gzip -9n` erzeugen aus
# denselben Eingabedateien byteweise denselben Tarball. Das BINARY selbst ist
# es nicht — der Swift-Compiler bettet Pfade und Zeitstempel ein, und diese
# Karte stellt den Compiler nicht darauf um. Wer zwei Läufe vergleicht, darf
# also gleiche Tarball-Prüfsummen nur bei identischem Binary erwarten, nicht
# aus der Verpackung allein ableiten.
#
# `SOURCE_DATE_EPOCH` ist im Repo nirgends gesetzt; es wird hier aus dem
# Zeitstempel des letzten Commits hergeleitet (Schritt 0).
#
# ---------------------------------------------------------------------------
# SIGNATUR (CM-36)
#
# Das Manifest ist Ed25519-signiert, mit demselben Schlüssel wie der
# Sparkle-Feed der macOS-Linie (`SPARKLE_PUBLIC_KEY` in scripts/release.sh).
# Jeder Client prüft die Signatur über die Bytes, BEVOR er ein Feld liest
# (`UpdateSignature`, `UpdateManifest.validate`); fehlt sie oder passt sie
# nicht, lehnt er mit 13 ab — einen Rückfall auf die Prüfsumme allein gibt es
# nicht. Der private Schlüssel betritt diesen Bau-Container NIE: Dieses Skript
# schreibt das Manifest unsigniert nach build/linux/, signiert wird danach
# außerhalb des Containers mit `scripts/sign-linux-manifest.sh` — auf dem
# Rechner, auf dem der Schlüssel liegt. Erst jenes Skript schreibt
# docs/linux-latest.json. Der Netzverkehr des Clients bleibt bei zwei
# Anfragen: Manifest holen, Datei holen.

set -euo pipefail

# ---------------------------------------------------------------------------
# Pfade. ALLE absolut aus PROJECT_DIR abgeleitet.
#
# Ein relativer Pfad wäre hier nicht Geschmackssache: Weiter unten steht ein
# `rm -rf`, und `scripts/release.sh` benutzt dasselbe `build/` für das DMG.
# Deshalb liegt dieses Skript in einem EIGENEN Unterverzeichnis build/linux und
# räumt auch nur dieses — mit einer Leerprüfung unmittelbar davor.
PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="$PROJECT_DIR/build/linux"
SCRATCH_DIR="$BUILD_DIR/scratch"
STAGE_DIR="$BUILD_DIR/stage"
VERIFY_DIR="$BUILD_DIR/verify"
LINUX_DIR="$PROJECT_DIR/Linux"
CORE_DIR="$PROJECT_DIR/Core"
SHARED_DIR="$PROJECT_DIR/Shared"
RELEASE_SH="$PROJECT_DIR/scripts/release.sh"
PBXPROJ="$PROJECT_DIR/App/ClaudeMonitor.xcodeproj/project.pbxproj"
TRAY_TEXTS="$PROJECT_DIR/Linux/Sources/TrayPresentation/TrayTexts.swift"
UPDATE_ENDPOINTS="$PROJECT_DIR/Linux/Sources/Update/UpdateEndpoints.swift"
# Das veröffentlichte, signierte Manifest — hier nur noch GELESEN (Wächter über
# die Build-Nummer, Adresse in der Schlussmeldung). Geschrieben wird es von
# scripts/sign-linux-manifest.sh (CM-36).
MANIFEST="$PROJECT_DIR/docs/linux-latest.json"
# Das Ergebnis von Schritt 7/7: unsigniert, Eingabe des Signierskripts.
UNSIGNED_MANIFEST="$BUILD_DIR/linux-latest.unsigned.json"
INSTALL_DOC="$PROJECT_DIR/Linux/INSTALL.md"
LINUX_README="$PROJECT_DIR/Linux/README.md"
ROOT_README="$PROJECT_DIR/README.md"
LICENSE_FILE="$PROJECT_DIR/LICENSE"

PRODUCT="claude-monitor-tray"
PLATFORM="linux-x86_64"

# ---------------------------------------------------------------------------
# KOMPATIBILITÄTSBODEN — EINZIGE QUELLE.
#
# Das sind die HÖCHSTEN Symbolversionen, die das gebaute Binary verlangt, im
# Bauimage gemessen (nicht geschätzt). Ein Zielsystem mit mindestens diesen
# Versionen kann es laden.
#
# Sie stehen NUR HIER. README.md, Linux/README.md und Linux/INSTALL.md nennen
# dieselben Zahlen im Klartext — Schritt 0 vergleicht die drei Dokumente gegen
# diese Konstanten und bricht bei Abweichung ab. Sonst driften vier Stellen
# auseinander und drei davon fallen niemandem auf.
GLIBC_FLOOR="2.38"
GLIBCXX_FLOOR="3.4.32"

# Genau dieser Wortlaut muss in den drei Dokumenten stehen.
FLOOR_TEXT_GLIBC="glibc ≥ $GLIBC_FLOOR"
FLOOR_TEXT_GLIBCXX="GLIBCXX ≥ $GLIBCXX_FLOOR"

# ---------------------------------------------------------------------------
# HERKUNFT DER BAUUMGEBUNG — festgeschrieben, nicht geraten.
#
# Der Kompatibilitätsboden oben ist keine Eigenschaft des Quelltexts, sondern
# der Bauumgebung: Gegen welche glibc gebunden wird, entscheidet allein, welche
# Symbolversionen im Binary landen. Baut jemand auf einem neueren Wirt — dieser
# Entwicklungsrechner ist Ubuntu 26.04 mit glibc 2.43 —, steigt der Boden still
# um mehrere Versionen, und das Artefakt lädt auf genau den Systemen nicht
# mehr, für die es gedacht war. Der Lauf MUSS deshalb im Bauimage stattfinden.
#
# Unterschieden werden zwei Zahlen, die leicht verwechselt werden:
#   REF_BUILDER_GLIBC  = die glibc DES BAUIMAGES (2.39 in Ubuntu 24.04)
#   GLIBC_FLOOR        = die höchste vom Binary VERLANGTE Symbolversion (2.38)
# Die zweite ist kleiner, weil das Binary nicht jedes Symbol der neuesten
# Version benutzt. Beides gemessen am 17.09.2026 in swift:6.3.3.
REF_IMAGE="swift:6.3.3"
REF_OS_ID="ubuntu"
REF_OS_VERSION_ID="24.04"
REF_BUILDER_GLIBC="2.39"
REF_SWIFT_VERSION="6.3.3"

# ---------------------------------------------------------------------------
# ldd-SOLLMENGE — nur Sonamen, keine Adressen.
#
# Ein roher `ldd`-Vergleich ist wegen ASLR bei jedem Lauf anders: die
# Ladeadressen hinter den Sonamen wechseln. Verglichen wird deshalb
# ausschließlich die MENGE der Sonamen. Sechs Einträge, und `linux-vdso.so.1`
# gehört dazu — es ist kein Bibliotheksfund auf der Platte, sondern das vom
# Kernel eingeblendete virtuelle Objekt, taucht in der ldd-Ausgabe aber als
# vollwertige Zeile auf und wurde beim Zählen bisher übersehen.
EXPECTED_SONAMES="$(printf '%s\n' \
  '/lib64/ld-linux-x86-64.so.2' \
  'libc.so.6' \
  'libgcc_s.so.1' \
  'libm.so.6' \
  'libstdc++.so.6' \
  'linux-vdso.so.1' | sort)"

# ---------------------------------------------------------------------------
# Testbestand — zuletzt bekannter Stand, gemessen am 17.09.2026 (Anker 9eb7ef6).
# Der Lauf misst frisch; diese Zahlen sind die UNTERGRENZE. Ein Rückgang heißt,
# dass Tests verschwunden sind — ein grüner Lauf mit weniger Tests ist kein
# Beleg, sondern ein Befund.
BASELINE_CORE=153
BASELINE_SHARED=125
BASELINE_LINUX=34

# Größenfenster des fertigen Binarys. `--static-swift-stdlib` bindet die
# Swift-Laufzeit ein; gemessen rund 70 MB. Deutlich darunter heißt, dass statisch
# nicht gegriffen hat (dann fehlt die Laufzeit auf dem Zielsystem), deutlich
# darüber heißt, dass etwas Fremdes mit hineingeraten ist.
SIZE_MIN_BYTES=$((30 * 1024 * 1024))
SIZE_MAX_BYTES=$((150 * 1024 * 1024))

# Exit 5 des Tray-Prozesses: „DBUS_SESSION_BUS_ADDRESS fehlt — es gab keine
# Sitzung" (Linux/README.md, Exit-Vertrag). Als LADEPROBE ist genau das der
# Sollwert: Der Prozess ist gestartet, hat seine Laufzeit gefunden, seinen
# Vertrag gelesen und sich geordnet verabschiedet. Als Selbsttest wäre exit 5
# wertlos („lief nicht"), als Ladeprobe ist er die Aussage, auf die es hier
# ankommt.
EXPECTED_LOAD_EXIT=5

step() { printf '\n\033[1m▸ %s\033[0m\n' "$1"; }
fail() { printf '\n\033[31m✘ %s\033[0m\n' "$1" >&2; exit 1; }

# Höchste Symbolversion einer Familie im Binary.
#
# ⚠️ `sort -u` ALLEIN IST HIER FALSCH und war es. Lexikographisch steht
# „GLIBC_2.9" hinter „GLIBC_2.38", der Wächter meldete also 2.9 als Maximum und
# hätte einen angehobenen Boden anstandslos durchgewinkt — am echten Binary
# nachgestellt. Es braucht `sort -V` (Versionssortierung).
#
# $1 = Binary, $2 = Familienpräfix (GLIBC, GLIBCXX, CXXABI, GCC)
max_symbol_version() {
  readelf -V "$1" 2>/dev/null \
    | grep -oE "(^|[^A-Za-z_])$2_[0-9]+(\.[0-9]+)*" \
    | grep -oE "$2_[0-9]+(\.[0-9]+)*" \
    | sed "s/^${2}_//" \
    | sort -uV | tail -n 1
}

# „$1 ist größer als $2" mit echtem Versionsvergleich.
version_gt() {
  [ "$1" != "$2" ] && [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -n 1)" = "$1" ]
}

# Versionsprobe (CM-29): `--version` muss mit Exit 0 genau die Zeile ausgeben,
# die jeder installierte Update-Client vor dem Austausch erwartet.
#
# ⚠️ EINGEFRORENER CLIENT-VERTRAG. Der Client liest stdout und vergleicht
# zeichengleich mit „claude-monitor-tray <version> (build <n>)"
# (`UpdateDecision.versionLine`, Kanal `UpdateDecision.versionOutputDescriptor`).
# Ein Binary, das hier abweicht, würde von JEDEM installierten Client mit 13
# abgelehnt — still und dauerhaft. Deshalb bricht schon der Bau ab.
version_probe() {
  local bin="$1" label="$2" rc=0 out expected
  expected="$PRODUCT $SHORT_VERSION (build $BUILD_VERSION)"
  out="$(timeout 30 env -u DBUS_SESSION_BUS_ADDRESS "$bin" --version 2>/dev/null)" || rc=$?
  [ "$rc" -eq 0 ] && [ "$out" = "$expected" ] \
    || fail "$label: --version endete mit Exit $rc und „$out\", erwartet war Exit 0 und „$expected\".
  Installierte Update-Clients vergleichen genau diese Zeile (stdout) mit dem Manifest und lehnen
  jedes Binary ab, das abweicht. Ursache ist fast immer TrayTexts.version/buildVersion oder ein
  geänderter Wortlaut bzw. Kanal von --version — beides ist ein eingefrorener Vertrag."
  echo "  ✓ $label: --version → „$out\""
}

# Die vier Wächter über ein Binary — einmal für das gebaute, einmal für das
# wieder ausgepackte (Schritt 6). Ohne den zweiten Lauf belegt die Gegenprobe
# nur, dass sich das Archiv öffnen lässt, nicht dass sein Inhalt derselbe ist.
# $1 = Binary, $2 = Bezeichnung für Meldungen
check_binary() {
  local bin="$1" label="$2" glibc glibcxx sonames size

  glibc="$(max_symbol_version "$bin" GLIBC)" || true
  [ -n "$glibc" ] \
    || fail "$label: aus dem Binary ließ sich keine einzige GLIBC_-Symbolversion lesen.
  Entweder ist readelf stumm geblieben oder die Datei ist kein dynamisch gebundenes ELF.
  Ein leeres Ergebnis darf NIE als „Boden eingehalten\" durchgehen — deshalb Abbruch."
  if version_gt "$glibc" "$GLIBC_FLOOR"; then
    fail "$label: verlangt GLIBC_$glibc, der zugesagte Boden ist $GLIBC_FLOOR.
  Auf jedem Zielsystem zwischen beiden Versionen startet das Binary nicht mehr.
  Fast immer heißt das: Es wurde nicht im Bauimage $REF_IMAGE gebaut.
  Wird der höhere Boden bewusst gewollt, ist GLIBC_FLOOR in diesem Skript zu
  erhöhen UND die drei Dokumente sind nachzuziehen — Schritt 0 erzwingt das."
  fi

  glibcxx="$(max_symbol_version "$bin" GLIBCXX)" || true
  [ -n "$glibcxx" ] \
    || fail "$label: keine einzige GLIBCXX_-Symbolversion gefunden.
  Das Binary bindet libstdc++ (siehe ldd-Sollmenge), also MUSS es welche geben.
  Ein leeres Ergebnis ist ein Messfehler, kein bestandener Wächter — Abbruch."
  if version_gt "$glibcxx" "$GLIBCXX_FLOOR"; then
    fail "$label: verlangt GLIBCXX_$glibcxx, zugesagt ist $GLIBCXX_FLOOR.
  Dieselbe Ursache und dieselbe Abhilfe wie beim GLIBC-Boden darüber."
  fi

  # CXXABI_* und GCC_* werden gemessen und ausgewiesen, aber nicht als eigener
  # Boden zugesagt — und das ist begründet, nicht vergessen:
  #
  #   CXXABI_*  steckt in DERSELBEN libstdc++.so.6 wie GLIBCXX_* und wird mit
  #             ihr im Gleichschritt je GCC-Fassung veröffentlicht (GCC 13.x →
  #             GLIBCXX_3.4.32 zusammen mit CXXABI_1.3.15). Ein System, das
  #             GLIBCXX_3.4.32 hat, hat damit zwangsläufig auch dieses CXXABI —
  #             es ist dieselbe Datei. Gemessen verlangt das Binary CXXABI_1.3.11
  #             (GCC 7, 2017) und liegt damit noch deutlich darunter: Der
  #             GLIBCXX-Boden deckt es mit Abstand ab.
  #   GCC_*     liegt dagegen in libgcc_s.so.1, also NICHT in libstdc++ — die
  #             Subsumtion über GLIBCXX gilt dafür ausdrücklich nicht. Gemessen
  #             verlangt das Binary GCC_3.3.1 (2003), während der glibc-Boden
  #             2.38 von 2023 ist. Jedes System, das den glibc-Boden erfüllt,
  #             übertrifft diesen Knoten um zwei Jahrzehnte.
  #
  # Ausgewiesen werden beide trotzdem: Wer später einen Boden dafür braucht,
  # findet die gemessene Zahl im Manifest und muss nicht raten.
  CXXABI_MAX="$(max_symbol_version "$bin" CXXABI)" || true
  GCC_MAX="$(max_symbol_version "$bin" GCC)" || true

  sonames="$(ldd "$bin" | awk '{print $1}' | sort)"
  [ "$sonames" = "$EXPECTED_SONAMES" ] \
    || fail "$label: die Menge der gebundenen Bibliotheken weicht ab.
  erwartet:
$(printf '%s\n' "$EXPECTED_SONAMES" | sed 's/^/    /')
  gemessen:
$(printf '%s\n' "$sonames" | sed 's/^/    /')
  Ein zusätzlicher Eintrag heißt, dass eine fremde Laufzeit mit ausgeliefert
  werden müsste — genau das, was das eigenständige Binary vermeiden soll.
  Ein fehlender Eintrag heißt meist, dass --static-swift-stdlib nicht griff."

  size="$(stat -c '%s' "$bin")"
  [ "$size" -ge "$SIZE_MIN_BYTES" ] \
    || fail "$label ist mit $size Byte zu klein (Untergrenze $SIZE_MIN_BYTES).
  Bei dieser Größe ist die Swift-Laufzeit nicht eingebunden — das Binary liefe
  nur auf einem Rechner mit installierter Toolchain."
  [ "$size" -le "$SIZE_MAX_BYTES" ] \
    || fail "$label ist mit $size Byte zu groß (Obergrenze $SIZE_MAX_BYTES).
  Da ist etwas mit hineingeraten, das nicht dazugehört."

  echo "  ✓ $label: GLIBC_$glibc ≤ $GLIBC_FLOOR, GLIBCXX_$glibcxx ≤ $GLIBCXX_FLOOR"
  echo "  ✓ $label: 6 Sonamen wie zugesagt, $size Byte"
  echo "    (nur gemessen, kein eigener Boden: CXXABI_${CXXABI_MAX:-—}, GCC_${GCC_MAX:-—})"

  MEASURED_GLIBC="$glibc"
  MEASURED_GLIBCXX="$glibcxx"
  MEASURED_SIZE="$size"
}

# Ladeprobe: startet das Binary wirklich? Bewusst OHNE Sitzungsbus, damit die
# Probe auch im Bauimage und auf einem Server ohne Desktop dasselbe Ergebnis
# hat. Jeder andere Ausgang als der vereinbarte ist ein Abbruchgrund — ein
# Binary, das nicht einmal geladen wird, darf nicht in den Tarball.
load_probe() {
  local bin="$1" label="$2" rc=0
  timeout 30 env -u DBUS_SESSION_BUS_ADDRESS "$bin" >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq "$EXPECTED_LOAD_EXIT" ] \
    || fail "$label: Ladeprobe endete mit Exit $rc, erwartet war $EXPECTED_LOAD_EXIT.
  Erwartet ist genau $EXPECTED_LOAD_EXIT (DBUS_SESSION_BUS_ADDRESS fehlt) — der Beleg, dass
  der Prozess geladen hat, seine Laufzeit fand und den Exit-Vertrag einhält.
  Exit 127 oder 1 deutet auf eine fehlende Bibliothek, ein Signalabbruch (>128)
  auf ein beschädigtes Binary, Exit 124 auf einen Hänger (30-Sekunden-Schranke)."
  echo "  ✓ $label: geladen und mit dem vereinbarten Exit $rc beendet"
}

# ---------------------------------------------------------------------------
step "0/7  Werkzeuge, Bauumgebung, Versionen"

for tool in swift readelf ldd tar gzip sha256sum git awk sed sort stat env timeout cmp; do
  command -v "$tool" >/dev/null 2>&1 \
    || fail "Werkzeug fehlt: $tool
  Der Lauf gehört ins Bauimage $REF_IMAGE, dort sind alle vorhanden."
done

# HERKUNFTSWÄCHTER. Ohne ihn wäre ein Lauf auf dem Entwicklungsrechner der
# gefährlichste Fall dieses Skripts: Er liefe durch, wäre grün, und das
# Artefakt hätte still einen um mehrere Versionen höheren Boden.
[ -r /etc/os-release ] || fail "/etc/os-release nicht lesbar — Bauumgebung nicht bestimmbar."
# shellcheck disable=SC1091
HOST_OS_ID="$(. /etc/os-release && printf '%s' "${ID:-}")"
HOST_OS_VERSION="$(. /etc/os-release && printf '%s' "${VERSION_ID:-}")"
HOST_GLIBC="$(ldd --version | head -n 1 | grep -oE '[0-9]+\.[0-9]+$' || true)"

[ "$HOST_OS_ID" = "$REF_OS_ID" ] && [ "$HOST_OS_VERSION" = "$REF_OS_VERSION_ID" ] \
  || fail "Falsche Bauumgebung: $HOST_OS_ID $HOST_OS_VERSION, festgeschrieben ist $REF_OS_ID $REF_OS_VERSION_ID.
  Der Kompatibilitätsboden ($FLOOR_TEXT_GLIBC) ist eine Eigenschaft DIESER Umgebung,
  nicht des Quelltextes. Auf einem neueren Wirt entstünde ein Binary, das auf den
  Zielsystemen nicht mehr lädt — und der Lauf wäre trotzdem grün.
  Abhilfe — im Bauimage starten:
    docker run --rm --user \"\$(id -u):\$(id -g)\" \\
      -v \"\$PWD:/work\" -w /work \\
      --tmpfs /hometmp:exec,mode=0777 --tmpfs /worktmp:exec,mode=0777 \\
      -e HOME=/hometmp -e TMPDIR=/worktmp \\
      $REF_IMAGE bash -lc './scripts/release-linux.sh'"

[ "$HOST_GLIBC" = "$REF_BUILDER_GLIBC" ] \
  || fail "Die glibc der Bauumgebung ist $HOST_GLIBC, festgeschrieben ist $REF_BUILDER_GLIBC.
  Das ist NICHT dieselbe Zahl wie der Kompatibilitätsboden $GLIBC_FLOOR: Gebunden wird gegen
  $REF_BUILDER_GLIBC, verlangt werden davon höchstens Symbole der Version $GLIBC_FLOOR.
  Weicht die erste Zahl ab, ist das Image ein anderes als das festgeschriebene."

HOST_SWIFT="$(swift --version 2>&1 | grep -oE 'Swift version [0-9.]+' | grep -oE '[0-9.]+' | head -n 1 || true)"
[ "$HOST_SWIFT" = "$REF_SWIFT_VERSION" ] \
  || fail "Swift $HOST_SWIFT statt der festgeschriebenen $REF_SWIFT_VERSION.
  Die Laufzeit wird statisch eingebunden — eine andere Fassung ändert Größe und Symbolbedarf."

echo "  ✓ Bauumgebung: $HOST_OS_ID $HOST_OS_VERSION, glibc $HOST_GLIBC, Swift $HOST_SWIFT"

# UMGEBUNGSVORBEDINGUNGEN der Testläufe (Linux/README.md, Route c).
# Fehlen sie, wird ein Zeitzonentest rot — und sieht dann wie ein Codefehler
# aus, obwohl er keiner ist. Deshalb VOR den Tests und mit klarer Ansage.
[ -e /usr/share/zoneinfo/Pacific/Kiritimati ] \
  || fail "Zeitzonendatenbank unvollständig: /usr/share/zoneinfo/Pacific/Kiritimati fehlt.
  Das ist ein Mangel der UMGEBUNG, NICHT des Codes. Die Zurücksetzungs-Tests würden rot
  und die Ursache läge nicht im Quelltext. Abhilfe: tzdata installieren, Lauf wiederholen —
  den Test dafür einzuklammern wäre die falsche Abhilfe."
ldconfig -p 2>/dev/null | grep -q libicu \
  || fail "ICU-Bibliotheken nicht auffindbar (ldconfig -p | grep libicu ist leer).
  Das ist ein Mangel der UMGEBUNG, NICHT des Codes: Foundation braucht ICU für
  Datums- und Zahlenformate. Abhilfe: ICU bereitstellen, Lauf wiederholen."
echo "  ✓ Umgebung: tzdata (Pacific/Kiritimati) und ICU vorhanden"

# IDENTITÄTSWERTE AUS release.sh — abgeleitet, nie zweitkopiert.
[ -r "$RELEASE_SH" ] || fail "scripts/release.sh nicht lesbar: $RELEASE_SH
  Von dort stammen Download-Basis, Feed- und Projektadresse. Eine eigene Kopie
  dieser Werte legt dieses Skript bewusst NICHT an."
read_identity() {
  sed -n "s/^$1=\"\\(.*\\)\"\$/\\1/p" "$RELEASE_SH" | head -n 1
}
DOWNLOAD_URL_BASE="$(read_identity DOWNLOAD_URL_BASE)"
PROJECT_URL="$(read_identity PROJECT_URL)"
FEED_URL="$(read_identity FEED_URL)"
# CM-36: der eingefrorene Vertrauensanker (Leitplanke L9) — derselbe Schlüssel
# prüft das Linux-Manifest. Aus release.sh gelesen, nicht aus App/Info.plist:
# dort steht der von der Plist UNABHÄNGIGE Anker.
SPARKLE_PUBLIC_KEY="$(read_identity SPARKLE_PUBLIC_KEY)"
for pair in "DOWNLOAD_URL_BASE=$DOWNLOAD_URL_BASE" "PROJECT_URL=$PROJECT_URL" "FEED_URL=$FEED_URL" \
  "SPARKLE_PUBLIC_KEY=$SPARKLE_PUBLIC_KEY"; do
  [ -n "${pair#*=}" ] \
    || fail "Aus $RELEASE_SH ließ sich ${pair%%=*} nicht lesen.
  Dort wurde die Zuweisung umbenannt oder umformatiert. Bitte die Ableitung in
  read_identity nachziehen — NICHT den Wert hier hartcodieren: eine zweite Kopie
  derselben Adresse ist die Fundstelle, die beim nächsten Umzug übersehen wird."
done
FEED_BASE="$(dirname "$FEED_URL")"
echo "  ✓ Identitätswerte aus scripts/release.sh abgeleitet (keine Zweitkopie, Schlüssel eingeschlossen)"

# VERSIONSQUELLE: das Xcode-Projekt. Es gibt keine zweite.
[ -r "$PBXPROJ" ] || fail "project.pbxproj nicht lesbar: $PBXPROJ"
SHORT_VERSION="$(sed -n 's/^[[:space:]]*MARKETING_VERSION = \(.*\);$/\1/p' "$PBXPROJ" | sort -u)"
BUILD_VERSION="$(sed -n 's/^[[:space:]]*CURRENT_PROJECT_VERSION = \(.*\);$/\1/p' "$PBXPROJ" | sort -u)"
[ "$(printf '%s\n' "$SHORT_VERSION" | wc -l)" -eq 1 ] && [ -n "$SHORT_VERSION" ] \
  || fail "MARKETING_VERSION ist im Projekt nicht eindeutig oder leer: „$SHORT_VERSION\"
  Debug- und Release-Konfiguration müssen denselben Wert tragen."
[ "$(printf '%s\n' "$BUILD_VERSION" | wc -l)" -eq 1 ] && [ -n "$BUILD_VERSION" ] \
  || fail "CURRENT_PROJECT_VERSION ist im Projekt nicht eindeutig oder leer: „$BUILD_VERSION\""
[[ "$BUILD_VERSION" =~ ^[0-9]+$ ]] \
  || fail "CURRENT_PROJECT_VERSION ist „$BUILD_VERSION\", muss aber eine ganze Zahl sein."

# ZWILLINGSWÄCHTER: die von Hand geführte Version im Tray-Menü.
#
# `TrayTexts.version` ist eine Konstante im Quelltext — auf Linux gibt es kein
# Bundle, aus dem sie zu lesen wäre. Sie ist zugleich die EINZIGE Stelle, an der
# ein Nutzer oder der Support sieht, welche Fassung läuft. Läuft die
# Marketing-Version im Xcode-Projekt weiter, ohne dass jemand diese Zeile
# nachzieht, zeigt das Panel dauerhaft eine falsche Zahl — und niemand merkt es,
# weil alles andere stimmt.
TRAY_VERSION="$(sed -n 's/^[[:space:]]*public static let version = "\(.*\)"$/\1/p' "$TRAY_TEXTS" | head -n 1)"
[ -n "$TRAY_VERSION" ] \
  || fail "In $TRAY_TEXTS ließ sich „public static let version\" nicht lesen.
  Wurde die Zeile umbenannt, prüft dieser Wächter nichts mehr — deshalb Abbruch statt Warnung."
[ "$TRAY_VERSION" = "$SHORT_VERSION" ] \
  || fail "Versionen laufen auseinander: TrayTexts.version=$TRAY_VERSION, MARKETING_VERSION=$SHORT_VERSION.
  Das Tray-Menü zeigt seine Fassung aus TrayTexts.version; der Tarball trägt MARKETING_VERSION
  im Namen. Auseinander bedeutet: Der Nutzer liest im Panel eine andere Zahl, als er geladen hat.
  Abhilfe: in $TRAY_TEXTS
    public static let version = \"$SHORT_VERSION\""
echo "  ✓ Version $SHORT_VERSION (Build $BUILD_VERSION), TrayTexts.version stimmt überein"

# ZWILLINGSWÄCHTER: die von Hand geführte Build-Nummer (CM-29).
#
# `TrayTexts.buildVersion` ist die EINZIGE Vergleichsgröße des Linux-Update-
# Clients. Bleibt sie hinter CURRENT_PROJECT_VERSION zurück, böte jeder Client
# dasselbe Release bei jedem Lauf erneut an und die Ladeprobe lehnte es ab;
# läuft sie voraus, nähme kein Client das Release je an.
TRAY_BUILD="$(sed -n 's/^[[:space:]]*public static let buildVersion = \([0-9]*\)$/\1/p' "$TRAY_TEXTS" | head -n 1)"
[ -n "$TRAY_BUILD" ] \
  || fail "In $TRAY_TEXTS ließ sich „public static let buildVersion\" nicht lesen.
  Wurde die Zeile umbenannt, prüft dieser Wächter nichts mehr — deshalb Abbruch statt Warnung."
[ "$TRAY_BUILD" = "$BUILD_VERSION" ] \
  || fail "Build-Nummern laufen auseinander: TrayTexts.buildVersion=$TRAY_BUILD, CURRENT_PROJECT_VERSION=$BUILD_VERSION.
  Der Linux-Update-Client vergleicht nur diese Zahl. Abhilfe: in $TRAY_TEXTS
    public static let buildVersion = $BUILD_VERSION"
echo "  ✓ TrayTexts.buildVersion = $TRAY_BUILD stimmt überein"

# ZWILLINGSWÄCHTER: die Adressen und der Schlüssel des Update-Clients (CM-29,
# CM-36).
#
# Der Client trägt Manifest-Adresse, Download-Basis, Produkt, Plattform und den
# Public Key des Manifests als Konstanten im Binary (`UpdateEndpoints`) — eine
# Umgebungsvariable dafür gibt es bewusst nicht. Diese Zweitkopie muss gleich
# dem sein, was dieses Skript erzeugt bzw. womit signiert wird; sonst holte
# jeder Client ein Manifest, das es nicht gibt, lehnte jede Download-Adresse ab
# oder jede Signatur.
read_endpoint() {
  sed -n "s/^[[:space:]]*public static let $1 = \"\(.*\)\"\$/\1/p" "$UPDATE_ENDPOINTS" | head -n 1
}
[ -r "$UPDATE_ENDPOINTS" ] || fail "$UPDATE_ENDPOINTS nicht lesbar — der Wächter über die Client-Adressen prüft sonst nichts."
for pair in \
  "manifestURL=$FEED_BASE/$(basename "$MANIFEST")" \
  "downloadURLBase=$DOWNLOAD_URL_BASE" \
  "product=$PRODUCT" \
  "platform=$PLATFORM" \
  "manifestPublicKey=$SPARKLE_PUBLIC_KEY"; do
  name="${pair%%=*}"; want="${pair#*=}"; have="$(read_endpoint "$name")"
  [ -n "$have" ] \
    || fail "In $UPDATE_ENDPOINTS ließ sich „public static let $name\" nicht lesen.
  Wurde die Zeile umformatiert, prüft dieser Wächter nichts mehr — deshalb Abbruch."
  [ "$have" = "$want" ] \
    || fail "UpdateEndpoints.$name=$have, dieses Skript erzeugt $want.
  Installierte Clients suchen dort, wo das Binary es sagt. Abhilfe: in $UPDATE_ENDPOINTS
    public static let $name = \"$want\""
done
echo "  ✓ UpdateEndpoints stimmt mit Feed-, Download-Adresse, Produkt, Plattform und Schlüssel überein"

# WÄCHTER: Build-Nummer gegen das vorhandene Manifest.
#
# Beide Richtungen, und die zweite ist der Grund für den Wächter:
#   - Die Zahl wurde erhöht, ohne dass sich auf der Linux-Seite etwas änderte:
#     KEIN Fehler. Die Versionsquelle ist gemeinsam, ein macOS-Release hebt sie
#     mit. Der Tarball bekommt dann eben eine neue Nummer.
#   - Die Zahl ist gleich geblieben, obwohl ein neuer Tarball entsteht: Fehler.
#     Zwei verschiedene Dateien trügen dieselbe Kennung, ein Update-Client
#     könnte sie nie unterscheiden. Das ist der Fall „Linux-Fix ohne
#     macOS-Bump" — legitim und häufig, aber er braucht eine eigene Zahl.
if [ -f "$MANIFEST" ]; then
  PREV_BUILD="$(sed -n 's/.*"buildVersion"[[:space:]]*:[[:space:]]*\([0-9]\+\).*/\1/p' "$MANIFEST" | head -n 1)"
  PREV_VERSION="$(sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$MANIFEST" | head -n 1)"
  [ -n "$PREV_BUILD" ] \
    || fail "$MANIFEST ist vorhanden, trägt aber keine lesbare \"buildVersion\".
  Dann kann der Wächter nicht vergleichen. Bitte die Datei prüfen."
  if [ "$BUILD_VERSION" -eq "$PREV_BUILD" ]; then
    fail "Build-Nummer $BUILD_VERSION steht bereits im veröffentlichten Manifest (Version $PREV_VERSION).
  Ein zweiter Tarball unter derselben Kennung ist für jeden Update-Client nicht von
  seinem Vorgänger zu unterscheiden.
  Das ist der übliche Fall „Linux-Fix, aber kein macOS-Release\" — er ist legitim und
  braucht nur eine eigene Zahl. Zu tun, GENAU diese Zeile:
    $PBXPROJ
      CURRENT_PROJECT_VERSION = $((PREV_BUILD + 1));
  (beide Konfigurationen, Debug und Release), und in
    $TRAY_TEXTS
      public static let buildVersion = $((PREV_BUILD + 1))
  Ändert sich dabei auch die Marketing-Version, MARKETING_VERSION und TrayTexts.version
  gemeinsam nachziehen — die Zwillingswächter oben prüfen beides."
  fi
  if [ "$BUILD_VERSION" -lt "$PREV_BUILD" ]; then
    fail "Build-Nummer $BUILD_VERSION ist KLEINER als die veröffentlichte ($PREV_BUILD).
  Ein Update-Client böte das Artefakt nie an. Abhilfe: CURRENT_PROJECT_VERSION in
  $PBXPROJ auf mindestens $((PREV_BUILD + 1)) setzen, und in $TRAY_TEXTS
    public static let buildVersion = <dieselbe Zahl>"
  fi
  echo "  ✓ Build-Nummer $BUILD_VERSION ist neu (veröffentlicht: $PREV_BUILD)"
else
  echo "  ⚠ Noch kein $MANIFEST — Vergleich der Build-Nummer entfällt (nur beim ersten Linux-Release korrekt)."
fi

# WÄCHTER: Die drei Dokumente nennen denselben Kompatibilitätsboden wie dieses
# Skript. Ohne ihn stünde dieselbe Zusage an vier Stellen und hielte sich an
# dreien nicht mehr.
for doc in "$ROOT_README" "$LINUX_README" "$INSTALL_DOC"; do
  [ -f "$doc" ] || fail "Dokument fehlt: $doc
  Es soll den Kompatibilitätsboden im Klartext nennen; fehlt es, ist die Zusage nur im Skript."
  grep -qF "$FLOOR_TEXT_GLIBC" "$doc" \
    || fail "In $doc steht nicht „$FLOOR_TEXT_GLIBC\".
  Der Boden wird in diesem Skript geführt, die Dokumente nennen ihn im Klartext.
  Weichen sie ab, liest der Nutzer eine Zusage, die das Artefakt nicht einhält."
  grep -qF "$FLOOR_TEXT_GLIBCXX" "$doc" \
    || fail "In $doc steht nicht „$FLOOR_TEXT_GLIBCXX\"."
done
echo "  ✓ README.md, Linux/README.md, Linux/INSTALL.md nennen $FLOOR_TEXT_GLIBC / $FLOOR_TEXT_GLIBCXX"

# SOURCE_DATE_EPOCH. Im Repo ist der Wert nirgends gesetzt; würde er ungeprüft
# übernommen, datierte der Tarball auf 1970 — und zwei Läufe wären trotzdem
# „reproduzierbar", nur eben falsch. Deshalb aus dem letzten Commit herleiten.
SOURCE_DATE_EPOCH="${SOURCE_DATE_EPOCH:-$(git -C "$PROJECT_DIR" log -1 --format=%ct 2>/dev/null || true)}"
[ -n "$SOURCE_DATE_EPOCH" ] \
  || fail "SOURCE_DATE_EPOCH ließ sich nicht bestimmen.
  Weder gesetzt noch aus „git log -1 --format=%ct\" ableitbar — ist das hier ein
  Git-Arbeitsbaum? Ohne den Wert wäre der Tarball auf 1970 datiert."
[[ "$SOURCE_DATE_EPOCH" =~ ^[0-9]+$ ]] \
  || fail "SOURCE_DATE_EPOCH ist „$SOURCE_DATE_EPOCH\" und damit keine Sekundenzahl."
export SOURCE_DATE_EPOCH
echo "  ✓ SOURCE_DATE_EPOCH=$SOURCE_DATE_EPOCH (aus dem letzten Commit; verpackt wird reproduzierbar, das Binary selbst nicht)"

# ---------------------------------------------------------------------------
# Das eigene Arbeitsverzeichnis leeren — und NUR dieses.
#
# Die Leerprüfung davor ist kein Zierrat: Wäre BUILD_DIR durch eine Umbenennung
# leer, machte `rm -rf "$BUILD_DIR"/` aus dem Befehl etwas ganz anderes. Und
# build/ selbst bleibt unangetastet — dort liegt das DMG von release.sh.
[ -n "$BUILD_DIR" ] || fail "BUILD_DIR ist leer — rm -rf wird nicht ausgeführt."
[ "$BUILD_DIR" != "/" ] || fail "BUILD_DIR ist / — rm -rf wird nicht ausgeführt."
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR" "$STAGE_DIR" "$VERIFY_DIR"

# ---------------------------------------------------------------------------
# Der Testbeleg dieses Projekts stammt ausschließlich aus `swift test` — drei
# Aufrufe, nicht einer: Core, Shared und die Linux-Seite sind eigene Pakete.
step "1/7  Bestandstests (Core, Shared, Linux)"

# $1 = Verzeichnis, $2 = Name, $3 = Untergrenze; Ergebnis in TEST_COUNT.
run_suite() {
  local dir="$1" name="$2" floor="$3" out count
  # `--force-resolved-versions` (CM-36): Linux/Package.resolved ist der Pin
  # von `swift-crypto` samt transitiver `swift-asn1`. Ohne den Schalter löste
  # SwiftPM bei Abweichung still neu auf; mit ihm bricht der Lauf ab. Core und
  # Shared haben keine Abhängigkeit — dort wirkt er nicht (gemessen).
  out="$( ( cd "$dir" && swift test --force-resolved-versions 2>&1 ) )" \
    || fail "$name-Tests rot. Letzte Zeilen:
$(printf '%s\n' "$out" | tail -n 20 | sed 's/^/    /')"
  count="$(printf '%s\n' "$out" | grep -oE 'Test run with [0-9]+ tests' | grep -oE '[0-9]+' | tail -n 1)"
  [ -n "$count" ] \
    || fail "$name: Aus der Testausgabe ließ sich keine Testzahl lesen.
  Ein grüner Lauf ohne ablesbare Zahl belegt nicht, dass Tests gelaufen sind."
  [ "$count" -ge "$floor" ] \
    || fail "$name: nur $count Tests, zuletzt bekannt waren $floor.
  Grün mit weniger Tests ist kein Beleg, sondern ein Befund: Es sind welche verschwunden.
  Abhilfe: Ursache klären. Ist der Rückgang gewollt, die Untergrenze in diesem Skript
  bewusst nachziehen — nicht beiläufig."
  echo "  ✓ $name: $count Tests grün (Untergrenze $floor)"
  TEST_COUNT="$count"
}

run_suite "$CORE_DIR"   "Core"   "$BASELINE_CORE";   COUNT_CORE="$TEST_COUNT"
run_suite "$SHARED_DIR" "Shared" "$BASELINE_SHARED"; COUNT_SHARED="$TEST_COUNT"
run_suite "$LINUX_DIR"  "Linux"  "$BASELINE_LINUX";  COUNT_LINUX="$TEST_COUNT"

# ---------------------------------------------------------------------------
# Eigener Baupfad. `--scratch-path` absolut aus PROJECT_DIR abgeleitet, damit
# der Release-Build das Entwickler-`.build` unter Linux/ nicht überschreibt:
# Release- und Debug-Bau teilen sich sonst einen Modulcache, und der nächste
# `swift test` baut ohne erkennbaren Grund alles neu.
step "2/7  Release-Build (statisch gebundene Swift-Laufzeit)"
( cd "$LINUX_DIR" && swift build -c release --static-swift-stdlib --force-resolved-versions \
    --product "$PRODUCT" --scratch-path "$SCRATCH_DIR" ) \
  || fail "Release-Build fehlgeschlagen."

BIN="$SCRATCH_DIR/release/$PRODUCT"
[ -x "$BIN" ] || fail "Der Release-Build hat kein ausführbares $PRODUCT erzeugt: $BIN"
echo "  ✓ $BIN"

# ---------------------------------------------------------------------------
step "3/7  Wächter über das gebaute Binary"
check_binary "$BIN" "gebautes Binary"
load_probe "$BIN" "gebautes Binary"
version_probe "$BIN" "gebautes Binary"

# ---------------------------------------------------------------------------
# Der Tarball packt ein VERZEICHNIS, keine nackte Datei: Wer ihn im
# Downloadordner auspackt, soll dort nicht drei lose Dateien vorfinden.
step "4/7  Tarball (reproduzierbar verpackt)"
TAR_NAME="$PRODUCT-$SHORT_VERSION-$PLATFORM.tar.gz"
TARBALL="$BUILD_DIR/$TAR_NAME"
# ⚠️ EINGEFRORENER CLIENT-VERTRAG (CM-29): Jeder installierte Update-Client packt
# genau das Mitglied `$PRODUCT-$SHORT_VERSION/$PRODUCT` aus
# (`UpdateDecision.memberPath`) und bildet die Adresse aus `TAR_NAME`
# (`UpdateDecision.expectedURL`). Ein anderer Aufbau hier hieße: Alle
# installierten Clients lehnen jedes Update mit 13 ab.
PAYLOAD="$STAGE_DIR/$PRODUCT-$SHORT_VERSION"
mkdir -p "$PAYLOAD"
cp "$BIN" "$PAYLOAD/$PRODUCT"
cp "$INSTALL_DOC" "$PAYLOAD/INSTALL.md"
cp "$LICENSE_FILE" "$PAYLOAD/LICENSE"

# THIRD-PARTY-NOTICES (CM-36): `swift-crypto` samt dem mitgebauten BoringSSL ist
# statisch ins Binary gebunden und steht unter Apache-2.0. §4 (a)/(d) verlangt
# bei Weitergabe in Objektform eine Kopie der Lizenz und der NOTICE-Hinweise.
# Quelle ist der Checkout DIESES Release-Builds — fehlt eine der beiden Dateien,
# bricht der Lauf ab, statt ein Paket ohne Hinweise zu schnüren.
CRYPTO_CHECKOUT="$SCRATCH_DIR/checkouts/swift-crypto"
NOTICES="$PAYLOAD/THIRD-PARTY-NOTICES"
for source in "$CRYPTO_CHECKOUT/LICENSE.txt" "$CRYPTO_CHECKOUT/NOTICE.txt"; do
  [ -r "$source" ] || fail "Lizenzquelle fehlt: $source
  Das Binary bindet swift-crypto statisch; ohne Lizenz- und NOTICE-Text darf es nicht
  ausgeliefert werden (Apache-2.0 §4). Liegt der Checkout woanders, den Pfad
  CRYPTO_CHECKOUT nachziehen — nicht den Wächter entfernen."
done
{
  echo "claude-monitor-tray statically links swift-crypto (https://github.com/apple/swift-crypto),"
  echo "which includes BoringSSL. Its license and notices follow."
  echo
  echo "==> swift-crypto: NOTICE.txt <=="
  echo
  cat "$CRYPTO_CHECKOUT/NOTICE.txt"
  echo
  echo "==> swift-crypto: LICENSE.txt <=="
  echo
  cat "$CRYPTO_CHECKOUT/LICENSE.txt"
} > "$NOTICES"

chmod 755 "$PAYLOAD/$PRODUCT"
chmod 644 "$PAYLOAD/INSTALL.md" "$PAYLOAD/LICENSE" "$NOTICES"

# --sort=name friert die Reihenfolge ein, --owner/--group/--numeric-owner die
# Eigentümer, --mtime die Zeitstempel. `gzip -9n` lässt den Dateinamen und den
# Zeitstempel aus dem gzip-Kopf weg — ohne -n stünde dort die aktuelle Uhrzeit
# und jeder Lauf ergäbe eine andere Prüfsumme.
#
# `xz` wäre kleiner, fehlt aber im Bauimage. Die Ersparnis rechtfertigt keine
# Paketinstallation mit Administratorrechten in einem Bauimage.
tar --sort=name --owner=0 --group=0 --numeric-owner \
    --mtime="@$SOURCE_DATE_EPOCH" \
    -C "$STAGE_DIR" -cf - "$PRODUCT-$SHORT_VERSION" \
  | gzip -9n > "$TARBALL"
echo "  ✓ $TARBALL ($(stat -c '%s' "$TARBALL") Byte)"

# ---------------------------------------------------------------------------
step "5/7  Prüfsumme"
SHA_FILE="$TARBALL.sha256"
( cd "$BUILD_DIR" && sha256sum "$TAR_NAME" > "$(basename "$SHA_FILE")" )
TAR_SHA="$(awk '{print $1}' "$SHA_FILE")"
TAR_SIZE="$(stat -c '%s' "$TARBALL")"
echo "  ✓ $TAR_SHA"

# ---------------------------------------------------------------------------
# Gegenprobe am AUSGEPACKTEN Stand, nicht am Bauergebnis.
#
# Sonst belegt dieser Schritt nur, dass sich das Archiv öffnen lässt. Geprüft
# wird das, was der Nutzer wirklich startet — deshalb dieselben Wächter und
# dieselbe Ladeprobe noch einmal, ausdrücklich in einem eigenen, leeren
# Verzeichnis unter build/linux/verify.
step "6/7  Gegenprobe am ausgepackten Tarball"
tar -xzf "$TARBALL" -C "$VERIFY_DIR"
UNPACKED="$VERIFY_DIR/$PRODUCT-$SHORT_VERSION/$PRODUCT"
[ -x "$UNPACKED" ] || fail "Im Tarball fehlt das ausführbare $PRODUCT: $UNPACKED"
cmp -s "$BIN" "$UNPACKED" \
  || fail "Das Binary im Tarball ist nicht dasselbe wie das gebaute.
  gebaut:      $BIN
  ausgepackt:  $UNPACKED"
check_binary "$UNPACKED" "ausgepacktes Binary"
load_probe "$UNPACKED" "ausgepacktes Binary"
version_probe "$UNPACKED" "ausgepacktes Binary"
[ -s "$VERIFY_DIR/$PRODUCT-$SHORT_VERSION/THIRD-PARTY-NOTICES" ] \
  || fail "Im Tarball fehlt THIRD-PARTY-NOTICES (Lizenz und NOTICE von swift-crypto)."
( cd "$BUILD_DIR" && sha256sum -c "$(basename "$SHA_FILE")" ) >/dev/null \
  || fail "Die Prüfsummendatei passt nicht zum Tarball."
echo "  ✓ Prüfsummendatei bestätigt, ausgepackt nach $VERIFY_DIR"

# ---------------------------------------------------------------------------
# Manifest. Ein EIGENES neben docs/appcast.xml, nicht darin: Der Appcast ist
# Sparkles Format mit Sparkles Signaturregeln — ein Linux-Eintrag darin wäre
# ein Fremdkörper, den Sparkle mitliest und ein Linux-Client erst herausfiltern
# müsste. Zwei kleine Dateien sind billiger als ein Format, das zwei Herren dient.
#
# ⚠️ EINGEFRORENER CLIENT-VERTRAG (CM-29): Installierte Update-Clients holen
# GENAU diese Datei am festen Pfad und lesen nur `schemaVersion: 1`
# (`UpdateManifest.supportedSchemaVersion`); jedes andere Schema lehnen sie mit
# 13 ab. Ein Schemawechsel braucht deshalb ein PARALLELES v1-Manifest an diesem
# alten Pfad, solange es Clients gibt, die nur v1 lesen.
#
# ⚠️ EBENSO EINGEFROREN (CM-36): das Dateiende. Diese Datei endet auf
# `"projectUrl": "…"\n}\n` — kein Feld `signature`, kein Komma dahinter. Genau
# diese Bytes signiert `scripts/sign-linux-manifest.sh`; es ersetzt die letzten
# drei Bytes durch den Trailer `,\n  "signature": "<Base64>"\n}\n`
# (`UpdateSignature`), und jeder Client misst ihn vom Dateiende. Ein anderes
# Ende hier lässt das Signierskript abbrechen.
step "7/7  Manifest (unsigniert) $UNSIGNED_MANIFEST"
DOWNLOAD_URL="$DOWNLOAD_URL_BASE/v$SHORT_VERSION/$TAR_NAME"
cat > "$UNSIGNED_MANIFEST" <<JSON
{
  "schemaVersion": 1,
  "product": "$PRODUCT",
  "platform": "$PLATFORM",
  "version": "$SHORT_VERSION",
  "buildVersion": $BUILD_VERSION,
  "url": "$DOWNLOAD_URL",
  "sha256": "$TAR_SHA",
  "size": $TAR_SIZE,
  "minimum": {
    "glibc": "$GLIBC_FLOOR",
    "glibcxx": "$GLIBCXX_FLOOR"
  },
  "measured": {
    "glibc": "$MEASURED_GLIBC",
    "glibcxx": "$MEASURED_GLIBCXX",
    "cxxabi": "${CXXABI_MAX:-}",
    "gcc": "${GCC_MAX:-}",
    "binarySize": $MEASURED_SIZE,
    "builtOn": "$HOST_OS_ID $HOST_OS_VERSION, glibc $HOST_GLIBC, Swift $HOST_SWIFT"
  },
  "projectUrl": "$PROJECT_URL"
}
JSON
echo "  ✓ $UNSIGNED_MANIFEST"

printf '\n\033[32m✔ Fertig: %s\033[0m\n' "$TARBALL"
echo "  Prüfsumme: $SHA_FILE"
echo "  Manifest:  $UNSIGNED_MANIFEST (unsigniert)"
echo "  Tests:     Core $COUNT_CORE · Shared $COUNT_SHARED · Linux $COUNT_LINUX"
echo
echo "  Vorher signieren: scripts/sign-linux-manifest.sh — erst dieses Skript schreibt"
echo "  docs/linux-latest.json (signieren dort, wo der Schlüssel liegt; Gegenprobe mit"
echo "  dem gebauten Binary; Aufruf je Rechner im Kopf des Skripts)."
echo
echo "  Veröffentlichen — die Reihenfolge ist bindend:"
echo "    1. GitHub-Release v$SHORT_VERSION anlegen (oder das vorhandene öffnen) und"
echo "       $TAR_NAME sowie $(basename "$SHA_FILE") als Assets hochladen."
echo "    2. docs/linux-latest.json committen und pushen."
echo "    3. Gegenprobe AUF DEM WIRT (im Bauimage fehlen curl und wget):"
echo "         curl -sI $FEED_BASE/$(basename "$MANIFEST")"
echo "         curl -sI $DOWNLOAD_URL"
echo "       Beide müssen 200 liefern — das Manifest von GitHub Pages, die Datei"
echo "       nach der Umleitung vom Release-Asset-Wirt."
echo "    4. Erst DANACH den Tarball weitergeben."
echo
echo "  Warum bindend: Das Manifest nennt die Adresse des Tarballs. Steht es vor dem"
echo "  Asset online, zeigt es auf eine Datei, die es noch nicht gibt — und jeder"
echo "  Abruf dazwischen sieht ein kaputtes Angebot statt gar keines."
echo
echo "  Hochladen und Tag bleiben bewusst manuelle, eigene Schritte."
