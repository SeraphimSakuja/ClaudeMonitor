#!/bin/bash
#
# Signiert das Linux-Update-Manifest und veröffentlicht es erst nach zwei
# Gegenproben nach docs/linux-latest.json (CM-36 · FE-14).
#
# Zwei Schritte, getrennt nach dem, was sie brauchen:
#
#   sign    braucht den privaten Schlüssel — läuft dort, wo er liegt (heute der
#           Mac), nie in einem Container. Ergebnis: build/linux/linux-latest.signed.json
#           (Gegenprobe a eingeschlossen). docs/ bleibt unberührt.
#   verify  braucht KEINEN Schlüssel, nur den Kandidaten und das gebaute Binary
#           (Gegenprobe b). Auf Linux nativ, auf macOS im Bauimage swift:6.3.3.
#           Erst nach Exit 0 schreibt es docs/linux-latest.json.
#
# Aufruf je Rechner — Bau auf dem Linux-Wirt, Schlüssel auf dem Mac:
#
#   Linux-Wirt:  docker run … ./scripts/release-linux.sh          (Kopf dort)
#                → build/linux/linux-latest.unsigned.json
#   Mac:         build/linux/linux-latest.unsigned.json vom Linux-Wirt holen
#                (z. B. scp), dann
#                  ./scripts/sign-linux-manifest.sh sign
#                → build/linux/linux-latest.signed.json zurück auf den Linux-Wirt
#   Linux-Wirt:  ./scripts/sign-linux-manifest.sh verify
#                → docs/linux-latest.json, danach Schlussmeldung von
#                  release-linux.sh ab „Veröffentlichen" abarbeiten.
#
# Liegt der Schlüssel auf einem Linux-Rechner, laufen beide Schritte dort
# nacheinander. Auf dem Mac geht `verify` ebenfalls, wenn Docker das Bauimage
# swift:6.3.3 (linux/amd64) und das gebaute Binary dort vorhanden sind:
#   ./scripts/sign-linux-manifest.sh verify --binary <Pfad zum Linux-Binary>
#
# Parameter (alle mit Vorgabe):
#   sign    --unsigned <Datei>   build/linux/linux-latest.unsigned.json
#           --out <Datei>        build/linux/linux-latest.signed.json
#           Schlüssel: $CLAUDEMONITOR_SPARKLE_KEY, sonst
#           ~/MF-Projects/.secrets/ClaudeMonitor/sparkle_ed25519.key — dieselbe
#           Datei wie in scripts/release.sh (Base64 des 32-Byte-Seeds).
#           OpenSSL ≥ 3: $OPENSSL, sonst `openssl` im PATH, sonst Homebrew
#           `openssl@3`. macOS bringt LibreSSL mit; das signiert kein Ed25519
#           über rohe Bytes (`brew install openssl@3`).
#   verify  --candidate <Datei>  build/linux/linux-latest.signed.json
#           --binary <Datei>     build/linux/scratch/release/claude-monitor-tray
#           --out <Datei>        docs/linux-latest.json
#
# FORMAT (eingefrorener Client-Vertrag, `UpdateSignature` im Ziel `Update`):
# Signiert werden die Bytes der unsignierten Datei D, die auf "\n}\n" endet.
# Ausgeliefert wird F = D ohne die letzten 3 Byte + Trailer
#   ,\n  "signature": "<88 Zeichen Base64 von 64 Byte>"\n}\n      (110 Byte)
# Der Client misst den Trailer vom Dateiende und prüft D.
#
# Jeder Abbruch lässt docs/linux-latest.json unberührt. Der private Schlüssel
# verlässt diesen Prozess nur als 0600-Datei in einem privaten Temp-Verzeichnis,
# das beim Ende entfernt wird; er landet nie im Repo und nie in einem Container.

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="$PROJECT_DIR/build/linux"
UPDATE_ENDPOINTS="$PROJECT_DIR/Linux/Sources/Update/UpdateEndpoints.swift"
RELEASE_SH="$PROJECT_DIR/scripts/release.sh"
REF_IMAGE="swift:6.3.3"

# DER-Köpfe für Ed25519 (RFC 8410): PKCS#8-Privatschlüssel und SPKI-Public-Key,
# jeweils gefolgt von den 32 Rohbytes. Oktal statt \x — das printf der
# macOS-Bash 3.2 kennt kein \x.
PKCS8_PREFIX='\060\056\002\001\000\060\005\006\003\053\145\160\004\042\004\040'
SPKI_PREFIX='\060\052\060\005\006\003\053\145\160\003\041\000'
TRAILER_LENGTH=110

fail() { printf '\n\033[31m✘ %s\033[0m\n' "$1" >&2; exit 1; }
ok() { echo "  ✓ $1"; }

usage() {
  sed -n '3,40p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
  exit 2
}

file_size() { wc -c < "$1" | tr -d ' '; }

# Die letzten drei Bytes als Hex, z. B. "0a7d0a".
tail_hex() { tail -c 3 "$1" | od -An -tx1 | tr -d ' \n'; }

# Der Public Key des Clients — gelesen wie im Zwillingswächter von
# release-linux.sh, nie zweitkopiert.
client_key() {
  sed -n 's/^[[:space:]]*public static let manifestPublicKey = "\(.*\)"$/\1/p' "$UPDATE_ENDPOINTS" | head -n 1
}
anchor_key() {
  sed -n 's/^SPARKLE_PUBLIC_KEY="\(.*\)"$/\1/p' "$RELEASE_SH" | head -n 1
}

# ---------------------------------------------------------------------------
# sign
# ---------------------------------------------------------------------------
cmd_sign() {
  local unsigned="$BUILD_DIR/linux-latest.unsigned.json" out="$BUILD_DIR/linux-latest.signed.json"
  while [ $# -gt 0 ]; do
    case "$1" in
      --unsigned) unsigned="$2"; shift 2 ;;
      --out) out="$2"; shift 2 ;;
      *) fail "Unbekanntes Argument für sign: $1" ;;
    esac
  done
  local key_file="${CLAUDEMONITOR_SPARKLE_KEY:-$HOME/MF-Projects/.secrets/ClaudeMonitor/sparkle_ed25519.key}"

  echo "▸ sign"
  # Nie im Container: dort hat der Schlüssel nichts zu suchen (Kopf von
  # release-linux.sh). Gilt nur für diesen Schritt, nicht für verify.
  [ ! -e /.dockerenv ] || fail "sign läuft in einem Container (/.dockerenv) — abgebrochen.
  Der private Schlüssel betritt nie einen Container. Auf dem Rechner mit dem Schlüssel aufrufen."

  # (1) OpenSSL ≥ 3.
  local openssl="" candidate
  for candidate in "${OPENSSL:-}" "$(command -v openssl || true)" \
                   /opt/homebrew/opt/openssl@3/bin/openssl /usr/local/opt/openssl@3/bin/openssl; do
    [ -n "$candidate" ] && [ -x "$candidate" ] || continue
    if "$candidate" version 2>/dev/null | grep -qE '^OpenSSL ([3-9]|[1-9][0-9])\.'; then
      openssl="$candidate"; break
    fi
  done
  [ -n "$openssl" ] || fail "Kein OpenSSL ≥ 3 gefunden (LibreSSL zählt nicht).
  Abhilfe: OpenSSL 3 installieren (macOS: brew install openssl@3) oder OPENSSL=<Pfad> setzen."
  ok "$("$openssl" version) ($openssl)"

  # (2) Schlüssel und Anker.
  [ -r "$key_file" ] || fail "Schlüsseldatei nicht lesbar: $key_file
  Erwartet wird Base64 des 32-Byte-Seeds (generate_keys -x), wie in scripts/release.sh."
  local client anchor
  client="$(client_key)"; anchor="$(anchor_key)"
  [ -n "$client" ] || fail "In $UPDATE_ENDPOINTS ließ sich manifestPublicKey nicht lesen."
  [ -n "$anchor" ] || fail "In $RELEASE_SH ließ sich SPARKLE_PUBLIC_KEY nicht lesen."
  [ "$client" = "$anchor" ] || fail "UpdateEndpoints.manifestPublicKey ($client) ist nicht der Vertrauensanker
  SPARKLE_PUBLIC_KEY aus scripts/release.sh ($anchor). Der Linux-Client prüft mit dem Sparkle-Schlüssel."

  [ -r "$unsigned" ] || fail "Unsigniertes Manifest fehlt: $unsigned
  Es entsteht in Schritt 7/7 von scripts/release-linux.sh."
  local size
  size="$(file_size "$unsigned")"
  [ "$size" -gt 3 ] && [ "$(tail_hex "$unsigned")" = "0a7d0a" ] \
    || fail "$unsigned endet nicht auf \"\\n}\\n\".
  Genau dieses Ende ersetzt der Trailer; mit einem anderen Ende lehnt jeder Client ab.
  Das Manifest neu mit scripts/release-linux.sh erzeugen — nicht von Hand bearbeiten."

  # Global, nicht `local`: der EXIT-Trap läuft nach dem Ende dieser Funktion.
  work="$(umask 077 && mktemp -d "${XDG_RUNTIME_DIR:-${TMPDIR:-/tmp}}/cm-sign.XXXXXX")"
  # Bekannte Dateien einzeln, dann das leere Verzeichnis — kein rekursives Löschen.
  trap 'rm -f "$work/key.der" "$work/pub.der" "$work/sig.bin" "$work/check.sig" "$work/document" "$work/candidate"; rmdir "$work" 2>/dev/null || true' EXIT

  ( umask 077
    printf "$PKCS8_PREFIX" > "$work/key.der"
    tr -d '[:space:]' < "$key_file" | "$openssl" base64 -d -A >> "$work/key.der" ) \
    || fail "Die Schlüsseldatei ist kein Base64."
  [ "$(file_size "$work/key.der")" -eq 48 ] \
    || fail "Die Schlüsseldatei ergibt keinen 32-Byte-Seed — falsches Format oder abgeschnitten."

  local derived
  derived="$("$openssl" pkey -inform DER -in "$work/key.der" -pubout -outform DER | tail -c 32 | "$openssl" base64 -A)" \
    || fail "Aus der Schlüsseldatei ließ sich kein Ed25519-Schlüssel bilden."
  [ "$derived" = "$client" ] || fail "Der Schlüssel gehört NICHT zum Vertrauensanker.
  Schlüsseldatei:      $key_file
  daraus abgeleitet:   $derived
  im Client erwartet:  $client
  Ein so signiertes Manifest lehnt jeder Client mit 13 ab. Den Anker zu ändern ist keine Abhilfe."
  ok "Schlüssel passt zu UpdateEndpoints.manifestPublicKey und SPARKLE_PUBLIC_KEY"

  # (3) Signieren — über die Bytes der unsignierten Datei.
  "$openssl" pkeyutl -sign -inkey "$work/key.der" -keyform DER -rawin -in "$unsigned" -out "$work/sig.bin" \
    || fail "openssl pkeyutl -sign ist gescheitert."
  rm -f "$work/key.der"
  [ "$(file_size "$work/sig.bin")" -eq 64 ] || fail "Die Signatur hat nicht 64 Byte."
  local signature
  signature="$("$openssl" base64 -A -in "$work/sig.bin")"
  [ "${#signature}" -eq 88 ] || fail "Die Base64-Signatur hat nicht 88 Zeichen."

  # (4) Kandidat = Datei ohne die letzten 3 Byte + Trailer.
  head -c "$((size - 3))" "$unsigned" > "$work/candidate"
  printf ',\n  "signature": "%s"\n}\n' "$signature" >> "$work/candidate"
  [ "$(file_size "$work/candidate")" -eq "$((size - 3 + TRAILER_LENGTH))" ] \
    || fail "Der Kandidat hat nicht die erwartete Länge — Trailer-Format verletzt."

  # (5) Gegenprobe a — aus dem KANDIDATEN zurückgelesen, wie der Client es tut:
  # Trailer vom Ende abmessen, Dokument rekonstruieren, mit dem Client-Schlüssel prüfen.
  local csize
  csize="$(file_size "$work/candidate")"
  head -c "$((csize - TRAILER_LENGTH))" "$work/candidate" > "$work/document"
  printf '\n}\n' >> "$work/document"
  cmp -s "$work/document" "$unsigned" || fail "Gegenprobe a: Das rekonstruierte Dokument ist nicht die unsignierte Datei."
  tail -c "$((TRAILER_LENGTH - 18))" "$work/candidate" | head -c 88 | "$openssl" base64 -d -A > "$work/check.sig"
  printf "$SPKI_PREFIX" > "$work/pub.der"
  printf '%s' "$client" | "$openssl" base64 -d -A >> "$work/pub.der"
  "$openssl" pkeyutl -verify -pubin -inkey "$work/pub.der" -keyform DER -rawin \
      -in "$work/document" -sigfile "$work/check.sig" >/dev/null \
    || fail "Gegenprobe a: Die Signatur im Kandidaten passt nicht zum Client-Schlüssel."
  ok "Gegenprobe a: Signatur im Kandidaten gültig für UpdateEndpoints.manifestPublicKey"

  mkdir -p "$(dirname "$out")"
  cp "$work/candidate" "$out.tmp.$$" && mv "$out.tmp.$$" "$out"
  ok "$out"
  echo
  echo "  Weiter: $(basename "$out") auf den Linux-Wirt bringen (falls dies nicht er ist) und dort"
  echo "    ./scripts/sign-linux-manifest.sh verify"
  echo "  ausführen — erst das schreibt docs/linux-latest.json."
}

# ---------------------------------------------------------------------------
# verify
# ---------------------------------------------------------------------------

# Attrappe für `curl`: kopiert den Kandidaten an das Ziel von `-o`. Der Client
# ruft sonst niemanden; ein zweiter Abruf (Tarball) fände hier nichts und
# endete nicht mit 0.
CURL_STUB='#!/bin/sh
out=""
while [ $# -gt 0 ]; do
  if [ "$1" = "-o" ]; then out="$2"; shift; fi
  shift
done
[ -n "$out" ] || exit 2
cp "$CM_CANDIDATE" "$out"'

cmd_verify() {
  local candidate="$BUILD_DIR/linux-latest.signed.json"
  local binary="$BUILD_DIR/scratch/release/claude-monitor-tray"
  local out="$PROJECT_DIR/docs/linux-latest.json"
  while [ $# -gt 0 ]; do
    case "$1" in
      --candidate) candidate="$2"; shift 2 ;;
      --binary) binary="$2"; shift 2 ;;
      --out) out="$2"; shift 2 ;;
      *) fail "Unbekanntes Argument für verify: $1" ;;
    esac
  done

  echo "▸ verify"
  [ -r "$candidate" ] || fail "Signierter Kandidat fehlt: $candidate (entsteht mit: sign)"
  [ -f "$binary" ] && [ -x "$binary" ] || fail "Gebautes Binary fehlt oder ist nicht ausführbar: $binary
  Es entsteht in Schritt 2/7 von scripts/release-linux.sh."

  # Gegenprobe b — mit dem AUSGELIEFERTEN Binary: Es holt den Kandidaten über
  # die curl-Attrappe, prüft Signatur und Felder und vergleicht die
  # Build-Nummer. Manifest-Build = Binary-Build ⇒ „up to date" ⇒ Exit 0. Jeder
  # andere Code heißt: Ein installierter Client nähme dieses Manifest nicht an.
  local code=0 output
  if [ "$(uname -s)" = "Linux" ]; then
    # Global, nicht `local`: der EXIT-Trap läuft nach dem Ende dieser Funktion.
    work="$(umask 077 && mktemp -d "${TMPDIR:-/tmp}/cm-verify.XXXXXX")"
    trap 'rm -f "$work/bin/curl"; rmdir "$work/bin" "$work/tmp" "$work" 2>/dev/null || true' EXIT
    mkdir "$work/bin" "$work/tmp"
    printf '%s\n' "$CURL_STUB" > "$work/bin/curl"
    chmod 755 "$work/bin/curl"
    output="$(env -i PATH="$work/bin:/usr/bin:/bin" HOME="$work" TMPDIR="$work/tmp" \
      CM_CANDIDATE="$(cd "$(dirname "$candidate")" && pwd)/$(basename "$candidate")" \
      "$binary" --check-update 2>&1)" || code=$?
  else
    command -v docker >/dev/null || fail "verify braucht auf $(uname -s) Docker mit dem Bauimage $REF_IMAGE.
  Alternative: den Kandidaten auf den Linux-Wirt bringen und verify dort ausführen."
    # Eingebunden werden nur Kandidat und Binary, beide schreibgeschützt.
    output="$(docker run --rm --platform linux/amd64 \
      -v "$(cd "$(dirname "$candidate")" && pwd)/$(basename "$candidate"):/in/candidate.json:ro" \
      -v "$(cd "$(dirname "$binary")" && pwd)/$(basename "$binary"):/in/claude-monitor-tray:ro" \
      -e CURL_STUB="$CURL_STUB" \
      "$REF_IMAGE" bash -c 'mkdir -p /tmp/stub /tmp/t && printf "%s\n" "$CURL_STUB" > /tmp/stub/curl \
        && chmod 755 /tmp/stub/curl \
        && env -i PATH=/tmp/stub:/usr/bin:/bin HOME=/tmp TMPDIR=/tmp/t CM_CANDIDATE=/in/candidate.json \
           /in/claude-monitor-tray --check-update' 2>&1)" || code=$?
  fi
  printf '%s\n' "$output" | sed 's/^/    /'
  [ "$code" -eq 0 ] || fail "Gegenprobe b: Das gebaute Binary nimmt den Kandidaten nicht an (Exit $code).
  0 wäre „up to date\" (Manifest-Build = Binary-Build). docs/linux-latest.json bleibt unverändert."
  ok "Gegenprobe b: $(basename "$binary") --check-update nimmt den Kandidaten an (Exit 0)"

  mkdir -p "$(dirname "$out")"
  cp "$candidate" "$out.tmp.$$" && mv "$out.tmp.$$" "$out"
  ok "$out"
}

case "${1:-}" in
  sign) shift; cmd_sign "$@" ;;
  verify) shift; cmd_verify "$@" ;;
  -h|--help|"") usage ;;
  *) fail "Unbekannter Schritt: $1 (sign | verify)" ;;
esac
