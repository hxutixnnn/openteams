# Release notes

## 0.3.0

The self-healing product loop is complete: OpenTeams recovers from problems in place, files what it can't fix, and takes feedback from the menu.

- **Send feedback** (#42): a Send feedback menu item and shortcut file an issue labeled `feedback`, with an optional local screenshot.
- **Healing actions** (#43): incidents are healed in place first (retry with backoff, refresh auth, reconnect sync, reset the broken view, restart the subsystem), and each outcome is recorded in the local incident log.
- **Automatic issue filing** (#44): incidents that healing can't fix, or that keep repeating, are filed in hxutixnnn/openteams labeled `auto` and `bug`. Reports are redacted and never include tokens, message bodies or personal data. Repeats comment on the open issue instead of opening a duplicate, at most every six hours.

Also since 0.2.0: cross-chat message search from ⌥⌘F, native window search, the unread divider, opening the message a notification points to, and performance work on caching, text normalization and timestamp formatting.
