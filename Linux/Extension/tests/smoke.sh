#!/usr/bin/env bash
# Die Extension übernimmt das Popover erst nach dem Zeichnen und gibt es bei einem kaputten Tray-Zustand frei, sodass das Tray-Menü zurückkommt.
# Läuft unter scripts/gnome-extension-smoke.sh (dbus-run-session, Wegwerf-HOME). Nutzt EXT_UUID, EXT_WORK, EXT_ZIP, EXT_DIR, EXT_INSTALLER.
# EXT_INSTALLER gesetzt ⇒ Einrichten über `<Binary> --install-gnome-extension` statt über das Zip.
set -u
LOG="$EXT_WORK/shell.log"
PEER="$EXT_WORK/peer.py"
: > "$LOG"

cat > "$PEER" <<'PY'
import json, os, sys
from gi.repository import Gio, GLib
XML = '''<node><interface name="org.claudemonitor.Tray.Popover1">
<method name="GetState"><arg name="state" type="s" direction="out"/></method>
<method name="Invoke"><arg name="key" type="s" direction="in"/><arg name="accepted" type="b" direction="out"/></method>
<method name="Opened"/><signal name="StateChanged"><arg name="state" type="s"/></signal></interface></node>'''
seg = {"id": "a", "marker": "▸", "status": "green", "numbersText": "42%", "resetText": "2h04"}
st = {"protocol": 1, "header": "ClaudeMonitor", "issue": None, "content": "accounts", "contentText": None,
      "accounts": [], "footer": None, "controls": [],
      "panel": {"title": "Panel",
                "activeAccount": {"label": "Active account", "icon": "green", "accessibleText": "a", "segments": [seg]},
                "overview": {"label": "Overview", "icon": "green", "accessibleText": "o", "segments": [seg]}}}
node = Gio.DBusNodeInfo.new_for_xml(XML)
def call(conn, sender, path, iface, method, params, inv):
    if method == 'GetState':
        inv.return_value(GLib.Variant('(s)', (json.dumps(st),)))
    elif method == 'Invoke':
        inv.return_value(GLib.Variant('(b)', (False,)))
    else:
        inv.return_value(None)
def acq(conn, name):
    conn.register_object('/Popover', node.interfaces[0], call, None, None)
    def pruefen():
        if os.path.exists(sys.argv[1]):
            conn.emit_signal(None, '/Popover', 'org.claudemonitor.Tray.Popover1', 'StateChanged',
                             GLib.Variant('(s)', ('{"protocol":1}',)))
            return False
        return True
    # Auslöser: Datei sys.argv[1] ⇒ kaputten Zustand senden
    GLib.timeout_add(200, pruefen)
Gio.bus_own_name(Gio.BusType.SESSION, 'org.claudemonitor.Tray', Gio.BusNameOwnerFlags.NONE, acq, None, None)
GLib.timeout_add_seconds(120, lambda: sys.exit(0))
GLib.MainLoop().run()
PY

haelt_name() {
    gdbus call --session --dest org.freedesktop.DBus --object-path /org/freedesktop/DBus \
        --method org.freedesktop.DBus.NameHasOwner org.claudemonitor.Popover 2>/dev/null
}
# warte_auf_log <Kennmarke> <Sekunden>: rc≠0 nach Ablauf der Frist
warte_auf_log() {
    local i
    for ((i = 0; i < $2 * 2; i++)); do
        grep -q -- "$1" "$LOG" && return 0
        sleep 0.5
    done
    echo "smoke: Frist ($2 s) abgelaufen, Kennmarke '$1' fehlt im Log" >&2
    return 1
}

gsettings set org.gnome.shell disable-user-extensions false
if [ -n "${EXT_INSTALLER:-}" ]; then
    "$EXT_INSTALLER" --install-gnome-extension || { echo "ROT 0: --install-gnome-extension rc $?" >&2; exit 1; }
    ZIEL="$XDG_DATA_HOME/gnome-shell/extensions/$EXT_UUID"
    [ -f "$ZIEL/schemas/gschemas.compiled" ] || { echo "ROT 0: $ZIEL/schemas/gschemas.compiled fehlt" >&2; exit 1; }
    # Die Nutzlast des Binaries muss der Quellbaum sein — sonst prüft der Lauf ein veraltetes Binary.
    # Abgeglichen wird alles, was der Installer schreibt, außer dem beim Einrichten erzeugten Schema-Kompilat.
    while IFS= read -r -d '' p; do
        f="${p#"$ZIEL"/}"
        [ "$f" = "schemas/gschemas.compiled" ] && continue
        cmp -s "$EXT_DIR/$f" "$p" \
            || { echo "ROT 0: $f im Binary weicht vom Quellbaum ab (Binary neu bauen): $EXT_INSTALLER" >&2; exit 1; }
    done < <(find "$ZIEL" -type f -print0)
else
    gnome-extensions install --force "$EXT_ZIP" || exit 1
    gsettings set org.gnome.shell enabled-extensions "['$EXT_UUID']"
fi

python3 "$PEER" "$EXT_WORK/senden" > "$EXT_WORK/peer.log" 2>&1 &
PEER_PID=$!
gnome-shell --headless --virtual-monitor 1280x800 > "$LOG" 2>&1 &
SHELL_PID=$!
trap 'kill "$SHELL_PID" "$PEER_PID" 2>/dev/null' EXIT

fail=0
warte_auf_log 'popover=shown' 40 || { cat "$LOG" | tail -20 >&2; exit 1; }
# Der Name kann kurz nach der Kennmarke erst übernommen werden — Frist 5 s wie warte_auf_log.
for ((i = 0; i < 10; i++)); do
    [ "$(haelt_name)" = "(true,)" ] && break
    sleep 0.5
done
[ "$(haelt_name)" = "(true,)" ] || { echo "ROT 1: Popover-Name 5 s nach popover=shown nicht besessen: $(haelt_name)" >&2; fail=1; }

: > "$EXT_WORK/senden"
warte_auf_log 'reason=shape' 20 || fail=1
sleep 1
[ "$(haelt_name)" = "(false,)" ] || { echo "ROT 2: Popover-Name nach StateChanged {protocol:1} noch besessen: $(haelt_name)" >&2; fail=1; }

[ "$fail" -eq 0 ] && echo "smoke: grün"
exit "$fail"
