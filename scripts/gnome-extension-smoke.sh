#!/usr/bin/env bash
# CM-42: Gate der GNOME-Extension — nur auf dem Wirt (nicht im Container), rc 0 = grün.
#   1. gjs-Tests der Shell-freien Regeln (Linux/Extension/tests/*.test.js, je Datei `gjs -m`).
#   2. Rauchtest: gnome-shell --headless in Wegwerf-HOME mit privatem Bus, installierte Extension,
#      Ersatz-Gegenstelle Linux/Extension/tests/smoke.sh (bekommt EXT_UUID, EXT_WORK, EXT_SHELL_LOG).
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
    WORK="$(mktemp -d)"
    mkdir -p "$WORK/home" "$WORK/runtime" "$WORK/pack"
    chmod 700 "$WORK/runtime"
    gnome-extensions pack "$EXT" --force \
        --extra-source=popoverState.js \
        --extra-source=stylesheet-dark.css \
        --extra-source=stylesheet-light.css \
        --schema=schemas/org.gnome.shell.extensions.claudemonitor.gschema.xml \
        -o "$WORK/pack" >/dev/null || fail=1
    echo "== Rauchtest (Wegwerf-HOME $WORK)"
    (
        export HOME="$WORK/home" XDG_RUNTIME_DIR="$WORK/runtime" \
            XDG_CONFIG_HOME="$WORK/home/.config" XDG_DATA_HOME="$WORK/home/.local/share" \
            XDG_CACHE_HOME="$WORK/home/.cache" XDG_STATE_HOME="$WORK/home/.local/state"
        export EXT_UUID="$UUID" EXT_WORK="$WORK" EXT_ZIP="$WORK/pack/$UUID.shell-extension.zip" EXT_DIR="$EXT"
        dbus-run-session -- bash "$EXT/tests/smoke.sh"
    ) || fail=1
fi

[ "$fail" -eq 0 ] && echo "gnome-extension-smoke: grün" || echo "gnome-extension-smoke: ROT" >&2
exit "$fail"
