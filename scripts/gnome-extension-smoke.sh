#!/usr/bin/env bash
# CM-42: Gate der GNOME-Extension — nur auf dem Wirt (nicht im Container), rc 0 = grün.
#   1. gjs-Tests der Shell-freien Regeln (Linux/Extension/tests/*.test.js, je Datei `gjs -m`).
#   2. Rauchtest: gnome-shell --headless in Wegwerf-HOME mit privatem Bus, installierte Extension,
#      Ersatz-Gegenstelle Linux/Extension/tests/smoke.sh (bekommt EXT_UUID, EXT_WORK, EXT_ZIP, EXT_DIR,
#      EXT_INSTALLER). Zwei Läufe, je eigenes Wegwerf-HOME:
#      a) Zip aus dem Quellbaum (`gnome-extensions pack`/`install`),
#      b) Installer des Binaries (`claude-monitor-tray --install-gnome-extension`, CM-AUF-15) —
#         prüft die Ordnerstruktur, die der Installer anlegt, gegen die echte Shell.
#      Binary: $CM_TRAY_BIN, sonst das statische Release-Binary aus scripts/release-linux.sh
#      (das Debug-Binary startet auf dem Wirt nicht: Swift-Bibliotheken fehlen).
# Nie gegen die laufende Sitzung: eigener Bus, eigenes HOME/XDG_*.
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
EXT="$ROOT/Linux/Extension"
UUID="claudemonitor@markusfricke.at"
fail=0

for tool in gjs gnome-extensions gnome-shell dbus-run-session; do
    command -v "$tool" >/dev/null || { echo "gnome-extension-smoke: $tool fehlt (Wirt, nicht Container)" >&2; exit 2; }
done

tests=("$EXT"/tests/*.test.js)
if [ ! -e "${tests[0]}" ]; then
    echo "gnome-extension-smoke: keine gjs-Tests unter Linux/Extension/tests/" >&2
    fail=1
else
    for t in "${tests[@]}"; do
        echo "== gjs -m ${t#"$ROOT"/}"
        gjs -m "$t" || fail=1
    done
fi

if [ ! -f "$EXT/tests/smoke.sh" ]; then
    echo "gnome-extension-smoke: Linux/Extension/tests/smoke.sh fehlt" >&2
    fail=1
else
    # rauchtest <Modus> <Installer-Binary oder leer>
    rauchtest() {
        local WORK
        WORK="$(mktemp -d)"
        mkdir -p "$WORK/home" "$WORK/runtime" "$WORK/pack"
        chmod 700 "$WORK/runtime"
        if [ -z "$2" ]; then
            gnome-extensions pack "$EXT" --force \
                --extra-source=popoverState.js \
                --extra-source=stylesheet-dark.css \
                --extra-source=stylesheet-light.css \
                --schema=schemas/org.gnome.shell.extensions.claudemonitor.gschema.xml \
                -o "$WORK/pack" >/dev/null || return 1
        fi
        echo "== Rauchtest $1 (Wegwerf-HOME $WORK)"
        (
            export HOME="$WORK/home" XDG_RUNTIME_DIR="$WORK/runtime" \
                XDG_CONFIG_HOME="$WORK/home/.config" XDG_DATA_HOME="$WORK/home/.local/share" \
                XDG_CACHE_HOME="$WORK/home/.cache" XDG_STATE_HOME="$WORK/home/.local/state"
            export EXT_UUID="$UUID" EXT_WORK="$WORK" EXT_ZIP="$WORK/pack/$UUID.shell-extension.zip" EXT_DIR="$EXT" \
                EXT_INSTALLER="$2"
            dbus-run-session -- bash "$EXT/tests/smoke.sh"
        )
    }
    rauchtest "Zip aus dem Quellbaum" "" || fail=1

    TRAY_BIN="${CM_TRAY_BIN:-$ROOT/build/linux/scratch/x86_64-unknown-linux-gnu/release/claude-monitor-tray}"
    if [ ! -x "$TRAY_BIN" ]; then
        echo "gnome-extension-smoke: Installer-Binary fehlt: $TRAY_BIN" >&2
        echo "  statisch bauen (swift:6.3.3, Aufruf im Kopf von scripts/release-linux.sh) oder CM_TRAY_BIN setzen" >&2
        fail=1
    else
        rauchtest "Installer $TRAY_BIN" "$TRAY_BIN" || fail=1
    fi
fi

[ "$fail" -eq 0 ] && echo "gnome-extension-smoke: grün" || echo "gnome-extension-smoke: ROT" >&2
exit "$fail"
