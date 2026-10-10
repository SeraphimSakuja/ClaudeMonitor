# Installing `claude-monitor-tray` on Linux

`claude-monitor-tray` is a single self-contained binary. It shows the same account numbers in the
GNOME panel that the macOS build shows in the menu bar, and it reads only `claude-swap`'s local
cache — it never writes to it. Its only use of the network is the update check: about once a day —
15 minutes after the tray starts, then every 24 hours — it fetches one small signed file from this
project's GitHub Pages. It sends no account data and no identifiers, and it downloads or installs
nothing unless you tell it to (see *Updates*).

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

Starting it with your session (see below) additionally needs a **systemd user session** — without
`systemctl --user` the tray still runs, but "Start at login" stays greyed out with "Autostart state
unknown".

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

The output must end in `OK`. The tarball itself carries no signature. What is signed (Ed25519, with
the same key as the macOS update feed) is the update manifest, and that names the tarball's size and
sha256 — so every update the program fetches itself is covered by the signature, and a first
download by hand by the checksum published next to it.

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

When it is `enabled`, `--autostart-status` also names the binary the unit starts and warns if that
is not the binary you ran the command with, or if the file is gone (the check compares the unit
file with the binary you run the command with; it runs no `systemctl` beyond `is-enabled`).

If the answer is `masked`, systemd is blocking the unit — `enable` cannot undo that, only you can:

```sh
systemctl --user unmask claude-monitor-tray.service
claude-monitor-tray --install-autostart
```

The same is one click away in the tray menu: **Start at login** carries a checkmark that mirrors
`systemctl --user is-enabled`. Ticking it sets the service up, unticking it removes it; the state is
read again after every attempt and whenever you open the menu, so a change made in a terminal shows
up there too. Ticking it sets the unit up for the binary of the tray that is **running right now** —
put the binary where it should stay first, then tick. Ticking starts nothing right away, and
unticking does not end the tray that is running. If the unit is masked, the entry is greyed out and
the line below it names the `systemctl --user unmask` command; if an attempt fails, the line below
names the command that prints the details. If the unit file points at another or a missing binary
than the tray that is running, the checkmark stays ticked and a line below it says so — untick and
tick again to point it at this binary, or run `claude-monitor-tray --autostart-status` for the path.

Remove it again:

```sh
claude-monitor-tray --uninstall-autostart
```

That removes the unit file and the `.wants` link. A mask stays as it is: it is your systemd
setting, not the program's. A tray process that is running right now keeps running until you log
out.

Two things these commands refuse to do, by design: they never follow a symbolic link at the target
path, and they never overwrite **or remove** a unit file this program did not write itself — the
same holds for unticking "Start at login". In both cases they say so, leave the file alone and exit
with 10. The same applies when systemd uses another unit file for `claude-monitor-tray.service`
than the one at the target path, in whatever directory it lies (for example a hand-written one under
`~/.config/systemd/user/`): nothing is written, enabled, disabled or removed, and the message names
that file.

## Updates

The tray **looks for a newer version about once a day** — 15 minutes after it starts, then every
24 hours. That reads the signed manifest and nothing else; if a newer version exists, one line in
the menu says so. If it could not check anything (no network, neither `curl` nor `wget`), it tries
once more 15 minutes later and otherwise stays silent until the next day. **Nothing is downloaded or
installed until you say so:** click **Check for updates now**, run `--update`, or turn on
**Automatic updates**. If the binary lies in a directory you cannot write to (for example
`/usr/local/bin`), the line says so and points to the download by hand instead (see *Download and
verify*).

To switch the daily look-up off, give the tray `CLAUDE_MONITOR_NO_UPDATE_CHECK=1` in its
environment — exactly `1`; any other value leaves it on. It is the only switch; there is no menu
entry and no file for it, and it affects nothing but the look-up. When the tray runs from a
terminal:

```sh
CLAUDE_MONITOR_NO_UPDATE_CHECK=1 claude-monitor-tray
```

When it runs as the autostart unit, add the variable with a systemd drop-in instead of editing the
unit this program writes:

```sh
printf '[Service]\nEnvironment=CLAUDE_MONITOR_NO_UPDATE_CHECK=1\n' \
  | systemctl --user edit --stdin claude-monitor-tray.service
systemctl --user show claude-monitor-tray.service -p Environment   # "Environment=CLAUDE_MONITOR_NO_UPDATE_CHECK=1"
```

(`systemctl --user edit claude-monitor-tray.service` without `--stdin` opens an editor for the same
two lines.) The drop-in lies next to the unit, under
`~/.config/systemd/user/claude-monitor-tray.service.d/`, so `--install-autostart`, ticking **Start
at login** and updates leave it alone, and the program does not take it for a foreign unit file.
It takes effect when the tray starts next. `systemctl --user revert claude-monitor-tray.service`
removes it again. The tray says it in its log when the look-up is off.

Check once by hand:

```sh
~/.local/bin/claude-monitor-tray --update
```

That installs a newer version at once. To only look, without installing anything:

```sh
~/.local/bin/claude-monitor-tray --check-update
```

It reads the manifest, checks its signature and compares the build number: exit 0 means up to date,
14 means a newer version is available and nothing was downloaded. It needs no write access and
runs alongside an update.

Or let it install updates by itself once a day:

```sh
~/.local/bin/claude-monitor-tray --install-auto-update
claude-monitor-tray --auto-update-status      # "enabled", plus the last failed run if there was one
claude-monitor-tray --uninstall-auto-update   # turn it off again; takes effect at once
```

`--install-auto-update` writes two systemd **user** units next to the autostart unit —
`~/.local/share/systemd/user/claude-monitor-tray-update.timer` and
`claude-monitor-tray-update.service` — and enables the timer for `timers.target`. Nothing is
started right away: the first update run comes 15 minutes after your next login, then once a day,
and installs what it finds. The same safety rules as for the autostart unit apply to both files
(symbolic link, foreign file, mask, another unit file of the same name). `--uninstall-auto-update`
disables and stops the timer and removes both files, so no further update run comes in this
session. The daily look-up of the tray is independent of the timer and runs either way.

What an update does, in this order: it reads the manifest `linux-latest.json` from this project's
GitHub Pages, checks its Ed25519 signature before reading any field (missing or wrong: refused with
13, no fallback to the checksum alone), compares its build number with the running one (never a
downgrade), checks the
compatibility floor of this machine, downloads the tarball from this project's GitHub Releases —
the address is fixed in the program, not taken from the manifest —, checks its size and its sha256
from the manifest, unpacks only the binary, starts it once with `--version` as a load test and
then puts it in place of the old one with a single `rename`. If the autostart unit is set up for
exactly this binary, the tray service is restarted; otherwise you are told to restart the tray.

It needs `curl` or, failing that, `wget` — the daily look-up and `--check-update` too; without
either, the look-up stays silent. For installing, the directory the binary lies in must be writable
for you — `~/.local/bin` is, `/usr/local/bin` is not. Otherwise `--install-auto-update` refuses
with 10 and `--update` with 13, before anything is downloaded. While it runs, `--update` locks that
directory, so a second update at the same time stops with 13.

There is no way back: after the `rename` the previous binary is gone. To return to an older
version, download it by hand as described above.

An update replaces the binary only. It does not rewrite the unit files — they stay as they were
written when you set them up.

In the tray menu, **Automatic updates** carries a checkmark that mirrors
`systemctl --user is-enabled claude-monitor-tray-update.timer`. Ticking it runs
`--install-auto-update`, unticking it runs `--uninstall-auto-update`; the state is read again after
every attempt and whenever you open the menu. Ticking starts nothing right away: the first update
run comes 15 minutes after your next login, and it installs what it finds. Unticking takes effect at
once and leaves the daily look-up as it is. If the timer is masked or its
state cannot be read, the entry is greyed out and the line below it names the command that helps; if
an attempt fails, that line names the command that prints the details.

**Check for updates now** runs `claude-monitor-tray --update` as a child process of the tray, whether
or not Automatic updates is ticked. While it runs the entry reads "Checking for updates…" and is
greyed out; afterwards one line below it says how the last check ended ("up to date", "nothing could
be checked", "update refused", "could not run", or that a newer version is installed). The details
are what the same command prints in a terminal. ⚠️ It does not only check: **a newer version found is
installed at once**, replacing the binary. If the tray runs as the autostart unit set up for exactly
this binary, it then **restarts itself** (the icon disappears briefly and comes back as the new
version, without a result line); otherwise the line asks you to restart the tray. If the tray runs as
the autostart unit, quitting it ends a running check; in a terminal, Ctrl-C does — Quit from the
menu lets the check finish on its own.

The daily look-up runs `claude-monitor-tray --check-update` the same way, as a child of the tray.
While it runs, the entry reads "Checking for updates…" and is greyed out for those few seconds.
Afterwards the line below it says "up to date", "update refused", that a newer version is
installed, or "a newer version is available" — with "Check for updates now installs it" when the
binary's directory is writable for you, otherwise with a pointer to the download by hand. When
the look-up could not check anything, the menu stays as it was; the reason is in the log. The
look-up never installs anything.

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
| 10 | autostart and auto-update commands: the request could not be carried out — unknown option, something at the target path stands in the way (foreign file, symbolic link, mask), systemd uses another unit file of the same name, or (auto-update) the binary's directory is not writable. Nothing was overwritten or removed |
| 11 | autostart and auto-update commands: **nothing could be measured** — no systemd user manager reachable, no home directory, an unusable answer from `systemctl`, or which unit file systemd uses could not be determined. Explicitly not "not set up" |
| 12 | `--update` and `--check-update`: **nothing could be checked** — neither `curl` nor `wget`, a network or HTTP error, a timeout, or no manifest at all. Explicitly not "up to date" |
| 13 | `--update` and `--check-update`: the update was **refused** — the manifest's signature is missing or does not match, the manifest is invalid or in another format, the machine is below the floor; for `--update` also: size or checksum do not match, the load test failed, the directory is not writable, or another update is running. The installed binary is unchanged |
| 14 | `--check-update` only: a **newer version is available** and fits this machine; nothing was downloaded. Whether `--update` can install it here (writable directory) is in the message |

Exit 5 over SSH or in a container is normal and correct: there is no session bus to talk to. So is
exit 11 for the autostart and auto-update commands there — without a session there is no user
manager to ask.

## If it does not start

```sh
~/.local/bin/claude-monitor-tray ; echo "exit=$?"
ldd ~/.local/bin/claude-monitor-tray            # six entries, none "not found"
```

A `version 'GLIBC_2.38' not found` message means the machine is below the floor at the top of this
page. That is not fixable from this side — the binary is built against that floor on purpose, so it
stays one file with nothing to install alongside it.

## Removing it

First turn off automatic updates, if you set them up:

```sh
~/.local/bin/claude-monitor-tray --uninstall-auto-update
```

Then remove the autostart — untick **Start at login** in the tray menu, or run:

```sh
~/.local/bin/claude-monitor-tray --uninstall-autostart
```

Then delete the binary:

```sh
rm ~/.local/bin/claude-monitor-tray
```

Deleting the binary alone would leave an enabled service behind that points at a missing file and
fails at every login — and, with automatic updates on, a timer whose service fails once a day.
If you switched the daily look-up off with a drop-in, remove it with
`systemctl --user revert claude-monitor-tray.service`.

Apart from those units nothing is left behind: no configuration file, no cache, no log file. The
tray process writes to stderr and nowhere else; only `--update` and `--check-update` write.
`--update` writes the binary itself, and both write a temporary directory they remove again —
unless the process is killed from outside, for example by `TimeoutStartSec` or by quitting the
tray while its look-up runs; then `claude-monitor-tray-update.*` can stay in `$TMPDIR`.
