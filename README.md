# ClaudeMonitor

A macOS menu bar companion for [claude-swap](https://github.com/realiti4/claude-swap).

If you juggle several Claude accounts, you want to see at a glance which one still has capacity.
`claude-swap` already knows — ClaudeMonitor puts it in your menu bar.

> **Not affiliated with Anthropic.** This is an independent, unofficial tool. It uses no official
> Anthropic API — there isn't one for Pro/Max subscription limits (see below).

Requires **macOS 14** or later and a working `claude-swap` installation.

## What it shows

For each account: the usage of every limit window, when it resets, and how long that takes —
ordered so the account with the most headroom comes first.

The menu bar itself has two modes. **Active account** (the default) shows exactly the account
`claude-swap` currently has selected. **Overview** shows up to three accounts picked by *role* —
active, best, and next to reset:

```
▸●92/30  ●12/28  ●100/89 47m
```

Roles rather than "the first N accounts", because that answers the three questions you actually
have: *What am I working with? Where could I switch? When does capacity come back?* An account
holding several roles appears once, and the order is fixed — so the positions stay learnable.

## Where the data comes from

**There is no official Anthropic API for subscription limits.** The Admin Usage & Cost API covers
token spend for API organizations, which is a different thing from the rolling windows of a
Pro/Max plan, and there is no third-party OAuth flow. The only source is the undocumented
`api.anthropic.com/api/oauth/usage` endpoint.

ClaudeMonitor does **not** talk to it. It reads the local cache that `claude-swap` already
maintains.

**Why not fetch directly?** Only the active account holds a fresh token in the keychain; the other
accounts' tokens live in claude-swap's backup store and go stale. Multi-account monitoring would
therefore need its own token refresh — and two processes independently rotating the same refresh
tokens destroy each other's sessions. `claude-swap` solves this with file locking. The dependency
is the price of being multi-account, not convenience.

## Relationship to claude-swap

ClaudeMonitor is **not a fork and not a patch**. It only ever *reads* claude-swap's local cache and
never writes to it — claude-swap serialises its writes read-modify-write under a file lock, and an
outside writer could corrupt the store. OAuth tokens are never touched either: claude-swap remains
their sole owner and sole refresher. That way claude-swap stays independently updatable.

If claude-swap isn't running, the data ages. ClaudeMonitor then shows **how old** the last known
value is instead of presenting stale numbers as current. A dead token is called out as such rather
than frozen at its last percentage.

## Installing

Download the notarised `.dmg` from [Releases](../../releases) and drag the app into
`/Applications`. That's a recommendation, not a requirement — everything, including "Start at
login", works from any location. It's just that an app left in `~/Downloads` tends to disappear
during the next tidy-up.

## Updates

ClaudeMonitor updates itself via [Sparkle](https://sparkle-project.org). It checks once a day,
and **both the update feed and the app archive are signed** — an EdDSA signature over the feed
plus Apple Developer ID code signing on the app itself.

Updates are **downloaded and installed only after you confirm**. The update dialog offers a
checkbox to make future updates automatic; that's opt-in, and it starts off. Automatic *checking*
can be turned off entirely in the app's window.

Because a menu bar app has no Dock icon, ClaudeMonitor briefly becomes a regular app while an
update dialog is on screen, so the window can be brought to the front — and returns to the
background as soon as the dialog is gone.

## Network and privacy

The app makes **no network requests except for updates**. It reads only local files below your
home directory and sends nothing anywhere: no telemetry, no system profiling, no account
identifiers. Account e-mail addresses read from claude-swap stay on the machine and are kept out
of the logs.

Updating contacts two hosts: the appcast on `seraphimsakuja.github.io`, and GitHub's release asset
host for the download itself.

## Project layout

| Path | Contents |
|---|---|
| `Core/` | Framework-free core logic (parsing, ranking, status, remaining time) as a SwiftPM package — testable with `swift test`, no Xcode needed |
| `Shared/` | The layer shared by app and widget: snapshot transport plus all display rules — also SwiftPM, also testable without Xcode |
| `App/` | The menu bar app (Xcode project) |
| `scripts/` | `release.sh` builds the notarised DMG and the appcast, then verifies both |
| `Linux/` | Headless smoke tool that runs `Core/` + `Shared/` on Linux — a development aid, not part of any release |

Display rules deliberately live in `Shared/` rather than the app target: the widget extension needs
exactly the same formatting, and two copies are guaranteed to drift. It also means the rules are
covered by tests — the app target has no test target of its own.

The WidgetKit extension is on hold; the menu bar covers the use case. The App Group transport in
`Shared/` is kept for its return, but the entitlement is deliberately **not** declared.

## Building and testing

```sh
( cd Core   && swift test )    # core logic
( cd Shared && swift test )    # transport + display rules
xcodebuild -project App/ClaudeMonitor.xcodeproj -scheme ClaudeMonitor -destination 'platform=macOS' build
( cd Linux  && swift build )         # Linux smoke tool
( cd Linux  && swift run claude-monitor )
```

Each command runs in its own subshell, so every line starts from the repository root again — the
same form `scripts/release.sh` uses. `swift run claude-monitor` deliberately does **not** belong in
a `&&` chain: it ends with a non-zero exit code whenever no store is present, and that is a valid
outcome, not a failure. See `Linux/README.md` for the toolchain runbook and the exit codes.

> `xcodebuild test` is **not** a valid proof of anything in this project: the scheme carries a test
> action with an empty `<Testables>` list, so it reports `TEST SUCCEEDED` without running a single
> test — and Xcode restores that action if you remove it. Use `swift test` in `Core/` and `Shared/`.

Signing uses **Developer ID** with the hardened runtime; releases are notarised. The app needs no
provisioning profile because it declares no restricted entitlement — the reasoning, and the way
back to widgets, is commented in `App/Signing.xcconfig`.

## Releasing

```sh
./scripts/release.sh          # tests → archive → export → guards → notarise → DMG → appcast
```

The script builds locally into `build/` and **uploads nothing**. Publishing to GitHub Releases is a
deliberate, separate step. One-time setup — notarisation credentials in the keychain and a Sparkle
signing key — is documented at the top of the script; every guard that fails tells you the command
that fixes it.

The app icon is generated by `scripts/makeicon.swift`; run it and regenerate the asset catalog if
you want to change it.

## Status

**v1.0** — macOS 14+. Verified against claude-swap 0.22.0 (cache `schemaVersion` 2).

## License

MIT — see [LICENSE](LICENSE). The same licence as claude-swap, so the two can be reused together
without friction.
