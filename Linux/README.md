# `Linux/` — headless smoke tool

`claude-monitor` is a **development aid**, not a release artefact. It runs the real chain
`ClaudeMonitorCore` → `ClaudeMonitorShared` on Linux and prints a defined state. It is strictly
read-only: it never writes, never takes a lock and never calls `SnapshotStore.write`.

The package is invisible to Xcode (no `PBXFileSystemSynchronizedRootGroup` entry) and
`scripts/release.sh` does not touch it.

## Toolchain

Minimum: **Swift 6.0**. Put the full `swift --version` output into any report that claims a
platform difference — a compile error only counts as a platform finding if it is attributable to
the *platform*, not to the *compiler version*.

Three routes, in this order.

### a) swiftly

```sh
curl -O https://download.swift.org/swiftly/linux/swiftly-x86_64.tar.gz
tar zxf swiftly-x86_64.tar.gz
./swiftly init --platform ubuntu24.04
swiftly install latest
```

`--platform` is needed on distributions without an official Swift tarball; verify the flag name
with `swiftly init --help` before using it. A flag that is missing or named differently is a
naming finding, not a failure of this route.

A toolchain installed this way still needs a working C toolchain and the runtime libraries of the
distribution it was built for. If `swift build` fails to link with messages like
`crtbeginS.o not found`, `-lgcc not found` or `libxml2.so.2 / libicuuc.so.74: cannot open shared
object file`, the host distribution is too new for the tarball. Installing those system packages
requires administrator rights — if that is not desirable, go to route (c) instead.

### b) Tarball for the nearest supported release

Download the official tarball built for the closest supported Ubuntu release and unpack it into a
user-owned directory. glibc is backwards compatible, so an older build runs on a newer glibc.

Abandon this route **only** if all three hold: `ldd` reports unresolvable dependencies **and** the
toolchain tree contains no `libFoundation*` / `libswiftCore*` **and** a real `swift build` fails
with a *toolchain* error rather than a source error.

### c) Official Swift container image (no administrator rights needed)

```sh
docker run --rm \
  --user "$(id -u):$(id -g)" \
  -v "$PWD:/work" -w /work \
  --tmpfs /hometmp:exec,mode=0777 \
  --tmpfs /worktmp:exec,mode=0777 \
  -e HOME=/hometmp \
  -e TMPDIR=/worktmp \
  swift:6.3.3 bash -lc '( cd Core && swift build && swift test )'
```

Binding obligations:

1. **`--user "$(id -u):$(id -g)"` is mandatory.** Without it `Core/.build`, `Shared/.build` and
   `Linux/.build` are created as `root` inside the working tree.
2. **Bind-mount to a fixed path, and build and test in the SAME container run**
   (`-v "$PWD:/work" -w /work`). Both the source scan of the ordering guard and the fixture lookup
   resolve through `#filePath`; a host build combined with a container run makes both look in the
   wrong place.
3. **Set `HOME` explicitly, to a writable directory.** SwiftPM writes caches there.
4. **Set `TMPDIR` explicitly and mount that exact path.** Mounting a literal `/tmp` misses the
   target whenever `TMPDIR` points somewhere else — the oversized-file fixture needs a filesystem
   that supports `ftruncate`, so the mounted path must be the one actually used.
5. **Check tzdata and ICU before the first test run:** `/usr/share/zoneinfo/Pacific/Kiritimati`
   must exist, and `ldconfig -p | grep libicu` must return entries. If the time zone database is
   missing, a red reset-timing test is an *environment* finding, not a code finding — install
   tzdata and repeat the run instead of bracketing the test.
6. **On switching lanes** between a host toolchain (a/b) and the container (c), delete
   `Core/.build`, `Shared/.build` and `Linux/.build` first. Two toolchains must not share a module
   cache.

## Running the smoke tool

```sh
( cd Linux && swift build )
( cd Linux && swift run claude-monitor ) ; echo "smoke exit=$?"
```

The run is deliberately **not** chained with `&&`: it is judged by the case it prints and its exit
code, not by exit 0.

| Exit | Case | Channel |
|---|---|---|
| 0 | `success` — account count, one line per account, one line per menu bar segment, popover case | stdout |
| 2 | `storeNotFound` — all searched paths, each redacted | stderr |
| 3 | `unsupportedSchemaVersion` — both numbers | stderr |
| 4 | `unreadable` — the reason, redacted | stderr |

**All four are a pass.** The tool proves that the chain builds, loads and yields a defined state —
not that data exists on the machine. Without a store, exit 2 is the normal outcome. A crash, a hang
or **exit 1** is a failure; exit 1 is reserved for unexpected errors and is claimed by none of the
four cases.

To reach `success` in a container, mount an existing store **read-only**. Note that
`homeDirectoryForCurrentUser` resolves through the password database on Linux, not through `$HOME`,
so the mount target is the home directory recorded for the container user:

```sh
-v "$HOME/.local/share/claude-swap:/home/<container-user>/.local/share/claude-swap:ro"
```

The `:ro` binding enforces the read-only promise mechanically.

## What the tool never prints

No personal and no externally supplied string: no display name, e-mail address, organisation UUID
or name, no alias, no `lastError`, no window label or window id, and not the raw key of the `other`
window kind — that one is mapped to the fixed text `other`. Reflection output of a model or display
type is likewise forbidden (string interpolation of a model value, `print` of a model value,
`dump`, `debugPrint`, `String(describing:)`), because none of these types is
`CustomStringConvertible` and the default reflection would print every stored field, display name
included. Every line is assembled from named scalars and passes through a single `redact(_:)`
function.

The home directory is determined **once** and the same value is used both for the store lookup and
as the redaction prefix, so a path can never be printed against a prefix that does not occur in it.
If that value is empty or `/`, no path is printed at all.

One line is knowingly less safe than the rest: the reason of the `unreadable` case can be a decoder
error text, which is platform dependent in wording and language. It is redacted like everything
else, but its content is not under this project's control.

---

# `claude-monitor-tray` — the resident tray process (CM-20)

Unlike the smoke tool above, this **is** a user-facing artefact: a resident process that shows the
same numbers in the GNOME panel that the macOS build shows in the menu bar. It speaks
`org.kde.StatusNotifierItem` and `com.canonical.dbusmenu` directly, over a D-Bus client written in
plain Swift (Foundation + Glibc sockets). No GTK, no libayatana-appindicator, no libdbus, no
GObject introspection, no pkg-config, no `-dev` headers, no SwiftPM dependency.

The reason for that route is not purity, it is the **self-contained single binary** that `CM-22`
packages. A release binary links against `libm`, `libstdc++`, `libgcc_s`, `libc`, `ld-linux` and the
kernel's vDSO — **six entries in `ldd`, counting `linux-vdso.so.1`** — and nothing else; any foreign
runtime in the shipped artefact would be a step back from that goal.

The vDSO is easy to miss when counting: it is not a file on disk but an object the kernel maps into
every process, and it still shows up as a full line in `ldd` output. `scripts/release-linux.sh`
compares the set of **sonames** (a raw `ldd` diff is never stable — the load addresses move with
every run because of ASLR) against exactly those six.

## Packaging (CM-22)

`scripts/release-linux.sh` turns this binary into a downloadable tarball with a checksum and the
manifest `docs/linux-latest.json`. It is the twin of `scripts/release.sh` and, like it, uploads
nothing.

The compatibility floor it promises is **`glibc ≥ 2.38`** and **`GLIBCXX ≥ 3.4.32`** — the highest
symbol versions the release binary actually requires, measured, not estimated. That floor is a
property of the build environment rather than of the source, so the script refuses to run outside
the pinned image (`swift:6.3.3`, Ubuntu 24.04): building on a newer host would silently raise the
floor and the run would still be green. The floor is held as a single constant in the script, which
checks this file, `README.md` and `Linux/INSTALL.md` against it.

`Linux/INSTALL.md` is the document that ships **inside** the tarball; it is written for the person
who downloaded it, not for this repository.

## Targets

| Target | Kind | Contains |
|---|---|---|
| `DBusWire` | library | values, marshalling, message framing, socket + SASL EXTERNAL + `Hello` + `poll()` dispatch, object protocol |
| `TrayPresentation` | library | the **one** translation point `MonitorViewState` → (label, icon, menu), plus the layout/property mapping and the `ItemsPropertiesUpdated` diff |
| `claude-monitor-tray` | executable | socket, registration, event loop, signals, exit contract, `--selftest` |
| `TrayTests` | test | the proof slot for the two libraries |

The split is deliberate. Everything that can be judged without a live session lives in a library, so
that it is reachable from the test slot; the executable keeps only what needs a real bus.

## Building and running

```sh
( cd Linux && swift build )
( cd Linux && swift build -c release --static-swift-stdlib )   # the shippable binary, ~70 MB
./Linux/.build/release/claude-monitor-tray
```

The process runs in the **foreground**, does not fork and does not daemonise — `--install-autostart`
wraps it in a systemd user service (see below). `SIGTERM`/`SIGINT` tear it down cleanly; the watcher notices and drops the
item from the panel. It re-registers by itself when `gnome-shell` restarts (`NameOwnerChanged`).

`SIGPIPE` is ignored process-wide (`signal(SIGPIPE, SIG_IGN)`, first statement of `runTray`). The
D-Bus socket is written with `write(2)`, which has no `MSG_NOSIGNAL` flag, so without that switch a
bus teardown during a write would kill the process by signal (exit 141) instead of honouring the
exit contract below. With it, `write` returns `EPIPE`, the teardown surfaces on the next `pump()`
and the loop leaves with exit 6. The switch covers the tray process only — the `claude-monitor`
smoke tool keeps dying on `SIGPIPE` when piped, as a CLI should.

It is strictly read-only, like the smoke tool: it never writes, never locks and never calls
`SnapshotStore.write` — the tray targets do not even link `SnapshotStore`, so the promise cannot be
broken by accident. That holds for `--selftest` too.

## Exit contract

| Exit | Meaning |
|---|---|
| 0 | ended normally, or `--selftest` passed |
| 5 | `DBUS_SESSION_BUS_ADDRESS` is not set — **there was no session** |
| 6 | connection or SASL failed, or the bus disappeared while running |
| 7 | `--selftest` only: registered, but the query sequence never arrived |
| 8 | another instance already owns `org.claudemonitor.Tray` |
| 9 | `--selftest` only: no `org.kde.StatusNotifierWatcher` on the bus |
| 10 | autostart only: the request could not be carried out (unknown option, foreign file or symlink at the target path, masked unit). Nothing was overwritten |
| 11 | autostart only: nothing could be **measured** — no user manager reachable, no home directory, unusable `systemctl` answer |

Exit 8 is the single-instance guard. Without it, an autostart instance plus a hand start — the
normal case once autostart is set up — would put **two** entries in the panel, because the watcher
keys items by `busName@objectPath`.

## Autostart (`--install-autostart`)

Three front-door subcommands, all of them evaluated **before** the bus is touched, because none of
them needs a bus: `--install-autostart`, `--uninstall-autostart`, `--autostart-status`. Any other
`--` argument is refused with exit 10 instead of silently falling through into the resident tray —
a typo must not look like a successful setup.

The unit is generated at install time, not shipped:

```ini
# generated by claude-monitor-tray --install-autostart
[Unit]
Description=ClaudeMonitor tray icon
After=graphical-session.target
PartOf=graphical-session.target

[Service]
Type=simple
ExecStart=/absolute/path/to/claude-monitor-tray
Restart=on-failure
RestartSec=5
RestartPreventExitStatus=5 8 9

[Install]
WantedBy=graphical-session.target
```

Why it looks like that:

* **`WantedBy=graphical-session.target`, not `default.target`** — measured: only the graphical
  target actually becomes an active target group in a GNOME session.
* **`ExecStart` comes from `readlink("/proc/self/exe")`**, never from `argv[0]`. Started over `PATH`
  — the normal way in `INSTALL.md` — `argv[0]` is just `claude-monitor-tray`, and systemd would fail
  with `203/EXEC` at the next login, long after "set up" was printed. The path is checked (absolute,
  regular file, executable) before anything is written, and quoted if it contains spaces.
* **`RestartPreventExitStatus=5 8 9`** — no session, another instance, no watcher: conditions a
  restart cannot fix. **7 is deliberately absent** (it can only come from `--selftest`, which the
  service never runs), and so is **6**: a bus teardown is the one failure that does pass, and
  restarting after it is exactly right.
* **No `Environment=` line** — `systemd --user` already carries `DBUS_SESSION_BUS_ADDRESS`, `HOME`
  and `XDG_RUNTIME_DIR` (measured via `systemctl --user show-environment`). A copy here would be a
  second source of truth that goes stale.

The unit is written with `open(O_WRONLY|O_CREAT|O_NOFOLLOW|O_TRUNC)`, not `Data.write`: at a symlink
the former stops with `ELOOP`, the latter replaces the link with a regular file (measured) or writes
straight through it to, say, `/dev/null`. After `enable`, the state is **asked again** and that
answer is reported — never derived from the return code of `enable`.

Removal checks the state **before** `disable`: for a masked unit `systemctl --user disable` returns
0, says "is masked, ignoring" and leaves the `.wants` link behind. The link is therefore removed
directly, and "removed" is only printed once no link points at the deleted unit any more. A mask is
never lifted by this program — that is your systemd setting.

Exit 9 is only an abort in `--selftest`. In normal operation a missing watcher is not a reason to
stop: the process says so once and registers as soon as the watcher appears.

## `--selftest` runs on the host, never in the container

⚠️ **The container (`swift:6.3.3`) has no session bus.** `--selftest` there yields exit 5, and
**exit 5 is "did not run", never a pass.** The self-test is only meaningful on a host with a live
session, that is where `busctl --user list` shows `org.kde.StatusNotifierWatcher`:

```sh
busctl --user list | grep StatusNotifierWatcher     # precondition
./Linux/.build/release/claude-monitor-tray --selftest ; echo "selftest exit=$?"
```

It passes when the shell asks for the item's properties **and** fetches the menu layout. Both are
required: an item whose menu is never queried is never visible either, which is the whole reason the
menu is mandatory rather than optional.

Useful counter-checks while an instance is running:

```sh
busctl --user get-property org.claudemonitor.Tray /StatusNotifierItem \
  org.kde.StatusNotifierItem XAyatanaLabel Status IconPixmap
busctl --user get-property org.claudemonitor.Tray /StatusNotifierItem \
  org.kde.StatusNotifierItem AnythingUnknown          # must NOT be an Unknown* error
busctl --user call org.claudemonitor.Tray /StatusNotifierItem/Menu \
  com.canonical.dbusmenu GetLayout iias 0 -- -1 0
```

The second one matters more than it looks: the `ubuntu-appindicators` extension **destroys** an item
that answers its 10-second liveness question with `org.freedesktop.DBus.Error.Unknown*` — even while
`Status` is `Active`. The dispatcher therefore answers every property, unknown ones with a
type-appropriate empty value. It cannot do otherwise: the result type of an object handler has no
error case at all.

What the panel shows is the one thing no machine check here covers. That `XAyatanaLabel` really
appears as text in the panel, and changes within 30 s of a change in `usage.json`, is a **manual**
acceptance point and is recorded as one.

## What the tray process never prints

The same print contract as the smoke tool, with one addition and one tightening.

The addition: on macOS `os_log` redacts dynamic strings by itself, and `UsageMonitor` relies on
that. A hand-written logger does not, so `TrayLog` does it — every line is assembled from named
scalars and passes through a single `redact(_:)`. No reflection of a model, display or menu type, and
no wire dump of D-Bus messages: a message body can carry every name in the store.

The tightening: the `reason` of the `unreadable` case is **not** printed at all. The smoke tool still
prints it, knowingly, because it is a one-shot developer aid. This process is resident and its lines
stay in the journal.

The target is **stderr only** — no log file of its own. Under `CM-21` the journal handles capture and
rotation; a second pile next to it is one nobody clears out. Repeated lines are debounced, the same
way `UsageMonitor.logIfChanged` does it.

The **surface** is the opposite case and deliberately so: the menu shows `displayName`, because
without it the accounts cannot be told apart. Redaction applies to the log, not to the menu.

## Colours

The three levels use Linux-specific sRGB values: green (52, 199, 89), yellow (255, 149, 0), red
(255, 59, 48). The yellow one has a twin on macOS — `StatusAppearance.swift:19-25` maps the same
level to `systemOrange`, for the same reason: yellow on a light background is effectively invisible.
The level keeps the name `yellow` on both sides; the name belongs to the model, the colour to the
presentation.

Two further icons exist beside the three levels: a neutral dot for an account without a verdict, and
an open ring for "no usable data". Neither may ever be sent empty — an empty pixmap makes the
extension raise `Empty Icon found` and the panel falls back to `image-loading-symbolic`, the error
placeholder.

## Test baseline

The Linux baseline is **three** numbers now:

```sh
( cd Core && swift test )     # 153 tests
( cd Shared && swift test )   # 125 tests
( cd Linux && swift test )    # 23 tests — TrayTests, the CM-20/CM-26/CM-27 slot
```

`scripts/release-linux.sh` runs all three and treats these numbers as a **lower bound**: a green run
with fewer tests than last time is a finding, not a pass.

The third suite was built from the real diff after the verify gate, not by the implementer
(Auflage 17, CM-20 Phase 4): `TrayPresentationContractTests.swift` (panel label, menu identifier
stability, icon-never-empty, property dispatcher) and `DBusWireCodecTests.swift` (wire round-trip
and 8-byte alignment).
