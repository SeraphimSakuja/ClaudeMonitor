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
# Das Skript ist der ZWILLING von `scripts/release.sh` (macOS/DMG/Sparkle) und
# fasst jenes bewusst nicht an: `release.sh` bleibt Null-Diff. Gemeinsame
# Identitätswerte — Download-Basis, Feed-Adresse, Projektadresse — werden
# deshalb weiter unten AUS `release.sh` GELESEN und hier nie zweitkopiert. Eine
# zweite Handkopie derselben URL ist genau die Sorte Fundstelle, die beim
# nächsten Umzug übersehen wird.
#
# Es lädt NICHTS hoch, legt kein Tag an und veröffentlicht nichts. Ergebnis sind
# drei Dateien: der Tarball und die Prüfsummendatei unter build/linux/ sowie das
# Manifest docs/linux-latest.json im Repo. Die Veröffentlichung ist ein eigener,
# von Hand ausgeführter Schritt; die Reihenfolge steht in der Schlussmeldung.
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
# SIGNATUR: BEWUSST NOCH KEINE
#
# Das Manifest führt `"signature": null`. Die macOS-Linie signiert ihren Feed
# per EdDSA, weil Sparkle einen Client mitbringt, der prüft. Auf Linux gibt es
# diesen Client noch nicht — er entsteht mit `CM-21`. Eine Signatur-Identität
# hier schon festzulegen hieße, sie einzufrieren, bevor der prüfende Teil
# existiert; `CM-21` friert sie ein, nicht diese Karte. Bis dahin ist die
# sha256-Summe neben dem Download die Zusage, und der Netzverkehr eines
# künftigen Update-Clients bleibt auf zwei Anfragen beschränkt: Manifest holen,
# Datei holen.

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
MANIFEST="$PROJECT_DIR/docs/linux-latest.json"
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
BASELINE_LINUX=23

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

# Die vier Wächter über ein Binary — einmal für das gebaute, einmal für das
# wieder ausgepackte (Schritt 6). Ohne den zweiten Lauf belegt die Gegenprobe
# nur, dass sich das Archiv öffnen lässt, nicht dass sein Inhalt derselbe ist.
# $1 = Binary, $2 = Bezeichnung für Meldungen
check_binary() {
  local bin="$1" label="$2" glibc glibcxx sonames size

  glibc="$(max_symbol_version "$bin" GLIBC)"
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

  glibcxx="$(max_symbol_version "$bin" GLIBCXX)"
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
  CXXABI_MAX="$(max_symbol_version "$bin" CXXABI)"
  GCC_MAX="$(max_symbol_version "$bin" GCC)"

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
for pair in "DOWNLOAD_URL_BASE=$DOWNLOAD_URL_BASE" "PROJECT_URL=$PROJECT_URL" "FEED_URL=$FEED_URL"; do
  [ -n "${pair#*=}" ] \
    || fail "Aus $RELEASE_SH ließ sich ${pair%%=*} nicht lesen.
  Dort wurde die Zuweisung umbenannt oder umformatiert. Bitte die Ableitung in
  read_identity nachziehen — NICHT den Wert hier hartcodieren: eine zweite Kopie
  derselben Adresse ist die Fundstelle, die beim nächsten Umzug übersehen wird."
done
FEED_BASE="$(dirname "$FEED_URL")"
echo "  ✓ Identitätswerte aus scripts/release.sh abgeleitet (keine Zweitkopie)"

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
  (beide Konfigurationen, Debug und Release). Ändert sich dabei auch die
  Marketing-Version, MARKETING_VERSION und TrayTexts.version gemeinsam nachziehen —
  der Zwillingswächter oben prüft das."
  fi
  if [ "$BUILD_VERSION" -lt "$PREV_BUILD" ]; then
    fail "Build-Nummer $BUILD_VERSION ist KLEINER als die veröffentlichte ($PREV_BUILD).
  Ein Update-Client böte das Artefakt nie an. Abhilfe: CURRENT_PROJECT_VERSION in
  $PBXPROJ auf mindestens $((PREV_BUILD + 1)) setzen."
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
  out="$( ( cd "$dir" && swift test 2>&1 ) )" \
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
( cd "$LINUX_DIR" && swift build -c release --static-swift-stdlib \
    --product "$PRODUCT" --scratch-path "$SCRATCH_DIR" ) \
  || fail "Release-Build fehlgeschlagen."

BIN="$SCRATCH_DIR/release/$PRODUCT"
[ -x "$BIN" ] || fail "Der Release-Build hat kein ausführbares $PRODUCT erzeugt: $BIN"
echo "  ✓ $BIN"

# ---------------------------------------------------------------------------
step "3/7  Wächter über das gebaute Binary"
check_binary "$BIN" "gebautes Binary"
load_probe "$BIN" "gebautes Binary"

# ---------------------------------------------------------------------------
# Der Tarball packt ein VERZEICHNIS, keine nackte Datei: Wer ihn im
# Downloadordner auspackt, soll dort nicht drei lose Dateien vorfinden.
step "4/7  Tarball (reproduzierbar verpackt)"
TAR_NAME="$PRODUCT-$SHORT_VERSION-$PLATFORM.tar.gz"
TARBALL="$BUILD_DIR/$TAR_NAME"
PAYLOAD="$STAGE_DIR/$PRODUCT-$SHORT_VERSION"
mkdir -p "$PAYLOAD"
cp "$BIN" "$PAYLOAD/$PRODUCT"
cp "$INSTALL_DOC" "$PAYLOAD/INSTALL.md"
cp "$LICENSE_FILE" "$PAYLOAD/LICENSE"
chmod 755 "$PAYLOAD/$PRODUCT"
chmod 644 "$PAYLOAD/INSTALL.md" "$PAYLOAD/LICENSE"

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
( cd "$BUILD_DIR" && sha256sum -c "$(basename "$SHA_FILE")" ) >/dev/null \
  || fail "Die Prüfsummendatei passt nicht zum Tarball."
echo "  ✓ Prüfsummendatei bestätigt, ausgepackt nach $VERIFY_DIR"

# ---------------------------------------------------------------------------
# Manifest. Ein EIGENES neben docs/appcast.xml, nicht darin: Der Appcast ist
# Sparkles Format mit Sparkles Signaturregeln — ein Linux-Eintrag darin wäre
# ein Fremdkörper, den Sparkle mitliest und ein Linux-Client erst herausfiltern
# müsste. Zwei kleine Dateien sind billiger als ein Format, das zwei Herren dient.
step "7/7  Manifest docs/linux-latest.json"
DOWNLOAD_URL="$DOWNLOAD_URL_BASE/v$SHORT_VERSION/$TAR_NAME"
mkdir -p "$(dirname "$MANIFEST")"
cat > "$MANIFEST" <<JSON
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
  "projectUrl": "$PROJECT_URL",
  "signature": null
}
JSON
echo "  ✓ $MANIFEST"

printf '\n\033[32m✔ Fertig: %s\033[0m\n' "$TARBALL"
echo "  Prüfsumme: $SHA_FILE"
echo "  Manifest:  $MANIFEST"
echo "  Tests:     Core $COUNT_CORE · Shared $COUNT_SHARED · Linux $COUNT_LINUX"
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
