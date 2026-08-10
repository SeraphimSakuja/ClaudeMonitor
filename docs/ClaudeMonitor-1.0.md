<!-- sparkle-sign-warning:
IMPORTANT: This file was signed by Sparkle. Any modifications to this file requires updating signatures in appcasts that reference this file! This will involve re-running generate_appcast or sign_update.
-->
# ClaudeMonitor 1.0

First public release. A macOS menu bar companion for
[claude-swap](https://github.com/realiti4/claude-swap): see at a glance which of your Claude
accounts still has capacity.

## What's in it

**Menu bar.** One traffic-light dot per account and both limit windows as `5h/7d`. Two modes:
*Active account* shows exactly the account claude-swap has selected; *Overview* shows up to three
accounts by role — active, best, and next to reset. The remaining time appears only when an
account is actually blocked, so the number means something when it's there.

**Detail window.** Every account with every limit window, one row each, sorted by account number
so positions stay where you left them. Exact reset times in the tooltip. Stale data is labelled
with its age rather than presented as current, and an account whose token has died is called out
instead of being frozen at its last percentage.

**Open at login**, including the two system states where the switch alone doesn't help — blocked
in System Settings, or the app not yet in the Applications folder.

**Automatic updates** via Sparkle, with a signed update feed. Checks once a day; nothing is
downloaded or installed without your confirmation, and automatic checking can be switched off in
the app.

## Requirements

macOS 14 or later, and a running `claude-swap` installation that fetches usage data. Verified
against claude-swap 0.22.0 (cache `schemaVersion` 2).

## Notes

ClaudeMonitor only ever reads claude-swap's local cache and never writes to it; OAuth tokens are
never touched. It makes no network requests other than checking for its own updates — no
telemetry, no account identifiers, nothing leaves the machine.

Not affiliated with Anthropic. There is no official API for Pro/Max subscription limits, which is
why this tool builds on claude-swap rather than talking to Anthropic itself.
