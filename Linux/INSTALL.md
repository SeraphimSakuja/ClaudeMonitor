# Installing `claude-monitor-tray` on Linux

`claude-monitor-tray` is a single self-contained binary. It shows the same account numbers in the
GNOME panel that the macOS build shows in the menu bar, and it reads only `claude-swap`'s local
cache — it never writes to it and makes no network requests of its own.

It ships as a **tarball you download and put somewhere yourself**. There is no package repository
and no `.deb`: a package wants a repository behind it, and a repository is a foreign account, a
maintenance duty and a promise that is hard to take back. A file with a checksum next to it is the
honest form for where this project stands.

## Requirements

Two numbers, both checkable on your own machine — no distribution names, because a name says
nothing: two releases of the same distribution can sit on either side of the line.

| Requirement | Check it with |
|---|---|
| glibc ≥ 2.38 | `ldd --version \| head -1` |
| GLIBCXX ≥ 3.4.32 | `strings -a $(ldconfig -p \| awk '/libstdc\+\+\.so\.6/ {print $NF; exit}') \| grep -oE 'GLIBCXX_[0-9.]+' \| sort -uV \| tail -1` |

Plus a desktop that shows `org.kde.StatusNotifierItem` items. On GNOME that means the
`ubuntu-appindicators` (or `appindicatorsupport`) extension; KDE Plasma shows them out of the box.

```sh
busctl --user list | grep StatusNotifierWatcher     # must print a line
```

Nothing else. The binary carries its own Swift runtime and links against six entries only —
`libm`, `libstdc++`, `libgcc_s`, `libc`, `ld-linux` and the kernel's vDSO.

## Download and verify

Take `claude-monitor-tray-<version>-linux-x86_64.tar.gz` and the matching `.sha256` file from
[Releases](../../releases), then check the archive **before** unpacking it:

```sh
sha256sum -c claude-monitor-tray-<version>-linux-x86_64.tar.gz.sha256
```

The output must end in `OK`. There is no cryptographic signature yet — the update client that would
verify one does not exist, and pinning a signing identity before anything checks it would freeze the
wrong thing. Until then the checksum published next to the download is the promise.

## Install

```sh
tar -xzf claude-monitor-tray-<version>-linux-x86_64.tar.gz
mkdir -p ~/.local/bin
install -m 755 claude-monitor-tray-<version>/claude-monitor-tray ~/.local/bin/
```

## First run — use the absolute path

```sh
~/.local/bin/claude-monitor-tray
```

Deliberately the full path. `~/.local/bin` is added to `PATH` by the login shell profile, so on a
session where the directory did not exist before, the short name `claude-monitor-tray` answers with
`command not found` until you log out and back in. That looks like a broken install and is not one.

Once you have logged in again, the short form works:

```sh
claude-monitor-tray
```

The process stays in the **foreground**, does not fork and does not daemonise. `Ctrl-C` ends it
cleanly and the panel drops the entry. Running it from a terminal is the intended way to try it out;
starting it with every session is one command away — see the next section.

## Start it with your session

```sh
~/.local/bin/claude-monitor-tray --install-autostart
```

That writes a systemd **user** service to
`~/.local/share/systemd/user/claude-monitor-tray.service` and enables it for
`graphical-session.target`. The unit points at the binary you ran the command with, so install the
binary where it should stay **before** you run it. Nothing is started right away: it takes effect at
your next login.

Check it:

```sh
systemctl --user is-enabled claude-monitor-tray.service     # "enabled"
claude-monitor-tray --autostart-status                      # the same answer in plain words
```

If the answer is `masked`, systemd is blocking the unit — `enable` cannot undo that, only you can:

```sh
systemctl --user unmask claude-monitor-tray.service
claude-monitor-tray --install-autostart
```

Remove it again:

```sh
claude-monitor-tray --uninstall-autostart
```

That removes the unit file and the `.wants` link. A mask stays as it is: it is your systemd
setting, not the program's. A tray process that is running right now keeps running until you log
out.

Two things the command refuses to do, by design: it never follows a symbolic link at the target
path, and it never overwrites a unit file it did not write itself. In both cases it says so, leaves
the file alone and exits with 10.

## Exit codes

The process is judged by its exit code, not by "it printed nothing".

| Exit | Meaning |
|---|---|
| 0 | ended normally |
| 5 | `DBUS_SESSION_BUS_ADDRESS` is not set — you are not in a graphical session |
| 6 | connection or authentication failed, or the bus disappeared while running |
| 7 | `--selftest` only: registered, but the query sequence never arrived |
| 8 | another instance already owns `org.claudemonitor.Tray` |
| 9 | `--selftest` only: no `org.kde.StatusNotifierWatcher` on the bus |
| 10 | autostart only: the request could not be carried out — unknown option, or something at the target path stands in the way (foreign file, symbolic link, mask). Nothing was overwritten |
| 11 | autostart only: **nothing could be measured** — no systemd user manager reachable, no home directory, or an unusable answer from `systemctl`. Explicitly not "not set up" |

Exit 5 over SSH or in a container is normal and correct: there is no session bus to talk to. So is
exit 11 for the autostart commands there — without a session there is no user manager to ask.

## If it does not start

```sh
~/.local/bin/claude-monitor-tray ; echo "exit=$?"
ldd ~/.local/bin/claude-monitor-tray            # six entries, none "not found"
```

A `version 'GLIBC_2.38' not found` message means the machine is below the floor at the top of this
page. That is not fixable from this side — the binary is built against that floor on purpose, so it
stays one file with nothing to install alongside it.

## Removing it

```sh
rm ~/.local/bin/claude-monitor-tray
```

Nothing else is left behind: no configuration file, no cache, no service unit, no log file. The
process writes to stderr and nowhere else.
