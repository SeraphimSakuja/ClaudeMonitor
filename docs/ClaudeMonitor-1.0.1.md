<!-- sparkle-sign-warning:
IMPORTANT: This file was signed by Sparkle. Any modifications to this file requires updating signatures in appcasts that reference this file! This will involve re-running generate_appcast or sign_update.
-->
# ClaudeMonitor 1.0.1

Bug fix release.

## Fixed: "Start at login" could not be switched on

In 1.0 the switch was permanently disabled, with a note claiming ClaudeMonitor had to be moved to
the Applications folder — even when it already was there. There was no way out of that state from
inside the app.

The cause was a wrong assumption about macOS rather than a slip: the app treated the system status
`notFound` as "this app is in the wrong place". It actually means "this app has never been
registered as a login item" — which is exactly the state of every fresh install, and the location
on disk has nothing to do with it. Registration works from any folder; measured, not assumed.

`/Applications` remains a sensible place to keep the app — an app left in `~/Downloads` tends to
disappear during the next tidy-up — but it was never a requirement, and the app no longer claims
it is.

## Fixed: disabled controls now explain themselves

The same class of problem affected the update button: if Sparkle failed to start, the button
stayed greyed out with no explanation and no way forward. Both controls now follow one rule — a
control that cannot be used always says why, and never suggests an action that would not help.

## Requirements

macOS 14 or later, and a running `claude-swap` installation. Verified against claude-swap 0.22.0
(cache `schemaVersion` 2).
