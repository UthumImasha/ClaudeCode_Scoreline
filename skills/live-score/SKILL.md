---
name: live-score
description: Control which live cricket matches the status-line score shows. Use ONLY when the user types /live-score (with a team like "India" to replace the scoreline, "add <match>" to stack another match's line, "remove <match>" to hide one line, "list", "reset", or nothing). Default shows all live matches of the user's followed team; picks, adds and hides are one-shot and auto-expire when the match ends.
argument-hint: <team> | "Team A vs Team B" | add <match> | remove <match> | list | reset
disable-model-invocation: true
---

The user invoked `/live-score` to control the live cricket score in the status line. Their argument: $ARGUMENTS

Run this one command and relay its output to the user verbatim — it is already concise and user-facing:

```
powershell -NoProfile -File "$USERPROFILE/.claude/cricket_pref.ps1" $ARGUMENTS
```

The script does everything (resolves teams against Cricbuzz's live matches, writes the one-shot pick/add/hide, and refreshes the score cache). The argument may be a team or "A vs B" fixture (replaces the scoreline), `add <match>` (stack another match's line on top, any number), `remove <match>` (hide one match's line until it ends), `list`, `reset`, or empty (treated as `list`). Do not add commentary unless the user asks a follow-up.
