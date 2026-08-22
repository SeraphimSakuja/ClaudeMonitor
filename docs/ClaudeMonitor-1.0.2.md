<!-- sparkle-sign-warning:
IMPORTANT: This file was signed by Sparkle. Any modifications to this file requires updating signatures in appcasts that reference this file! This will involve re-running generate_appcast or sign_update.
-->
# ClaudeMonitor 1.0.2

Bug fix release.

## Fixed: removed accounts stayed visible — and were recommended

After removing an account with `cswap --remove-account`, ClaudeMonitor kept showing it. Worse than
a leftover row: because the stale entry still carried its last known usage numbers, it usually
looked like the *least* used account and was ranked **first** — presented as the best account to
switch to, with figures that had stopped updating hours earlier. In the "best account only" menu
bar mode it could be the only account shown.

The cause was a wrong assumption about how claude-swap stores its data. ClaudeMonitor built the
account list from `cache/usage.json`, but that file is only a number cache — `remove_account`
never touches it, and claude-swap has no pruning for it at all. The authority over *which accounts
exist* is `sequence.json`, which is exactly what claude-swap itself consults. ClaudeMonitor now
does the same, using claude-swap's own notion of identity (e-mail plus organization, since the
same address may legitimately appear in two slots under different organizations).

This also fixes a rarer but more serious case: when every account is removed, claude-swap reuses
slot number 1 for the next one. The old cache row would then have been displayed under the new
account's name — wrong numbers, not just a stale row.

If `sequence.json` is missing or unreadable, nothing is filtered and all figures keep showing as
before. A problem with that file must never hide usage data.

## Requirements

macOS 14 or later, and a running `claude-swap` installation. Verified against claude-swap 0.22.0
(cache `schemaVersion` 2).
