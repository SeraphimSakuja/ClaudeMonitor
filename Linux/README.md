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
