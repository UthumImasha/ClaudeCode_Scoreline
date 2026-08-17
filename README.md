# 🏏 Claude Code Cricket Scoreline

Live cricket scores, right inside your [Claude Code](https://claude.com/claude-code) status line. Follow your team's matches ball-by-ball while you code — score, batsmen, bowler, and a live run-chase tracker with CRR/RRR — all without leaving the terminal.

```
📁 my-project  |  🌿 main  |  🤖 Fable 5  |  📅 Sun 17 Aug  |  🕐 21:43
🏏 SL v IND, 2nd ODI - SL 187/4 (38.2)  ·  IND 261  ·  Nissanka 72*(84), Asalanka 31(40)  ·  Bumrah 2/38 (7.2)
🎯 SL need 75 runs in 70 balls  ·  CRR 4.88  ·  RRR 6.42

🟢 ctx ██░░░░░░░░ 23%          🟢 5h ███░░░░░░░ 31%          🟡 7d █████░░░░░ 54%          ⏱ 1h12m
```

No API keys, no accounts — scores come from Cricbuzz's public live-scores page.

## Features

- **Live score in the status line** — updates every ~15 seconds during a live match
- **Follows your team by default** — every live match of your team (national side, Women, A team, U19) shows at once, each in its own colour
- **Run-chase tracker** — a second line with runs needed, balls remaining, current and required run rate
- **Batsmen + bowler detail** — the two batters at the crease (striker starred) and the current bowler's figures
- **Test-match aware** — multi-innings scores (`438 & 23/2 (6.5)`), lead/trail headlines, all-out handling
- **`/live-score` command** — watch any match on demand: replace, stack, hide, list, reset (details below)
- **Smart refresh** — 15s while a match is live, 60s around typical start times (xx:01–:05, xx:31–:35), 5 min otherwise; the fetch runs detached in the background so your status line never blocks on the network
- **Plus the useful basics** — folder, git branch, model, date/clock, context-window and rate-limit meters, session uptime

## Requirements

- Windows 10/11 with Windows PowerShell 5.1+ (preinstalled on Windows)
- [Claude Code](https://claude.com/claude-code)
- Internet access (scores are fetched from cricbuzz.com)

## Install

### Quick install

```powershell
git clone https://github.com/UthumImasha/ClaudeCode_Scoreline.git
cd ClaudeCode_Scoreline
powershell -ExecutionPolicy Bypass -File .\install.ps1
```

The installer asks which team to follow (default: Sri Lanka), copies the scripts into `~/.claude`, installs the `/live-score` command, and wires up the `statusLine` setting — backing up your existing `settings.json` first, and asking before replacing a status line you already have. Then restart Claude Code.

Non-interactive: `.\install.ps1 -Team "India" -Silent`

### Manual install

1. Copy the files into your Claude Code home:
   - `statusline.ps1` → `%USERPROFILE%\.claude\cricket_statusline.ps1`
   - `cricket_fetch.ps1` → `%USERPROFILE%\.claude\cricket_fetch.ps1`
   - `cricket_pref.ps1` → `%USERPROFILE%\.claude\cricket_pref.ps1`
   - `skills\live-score\SKILL.md` → `%USERPROFILE%\.claude\skills\live-score\SKILL.md`
2. Save your team name (one line) to `%USERPROFILE%\.claude\cricket_team.txt`, e.g. `India`
3. Add this to `%USERPROFILE%\.claude\settings.json` (replace `<you>` with your username):

   ```json
   {
     "statusLine": {
       "type": "command",
       "command": "powershell -NoProfile -File C:/Users/<you>/.claude/cricket_statusline.ps1",
       "refreshInterval": 15
     }
   }
   ```

4. Restart Claude Code.

## The `/live-score` command

By default the scoreline shows **all live matches of your followed team**. `/live-score` lets you steer it from inside Claude Code:

| Command | What it does |
|---|---|
| `/live-score list` (or just `/live-score`) | List every live match right now, flagging which are tracked/added/hidden |
| `/live-score India` | **Replace** the scoreline with the top live India match |
| `/live-score Australia vs England` | Replace with that specific fixture |
| `/live-score add Pakistan` | **Stack** the Pakistan match's line on top of what's already showing |
| `/live-score remove women` | **Hide** the matching line (only while that match is live) |
| `/live-score reset` | Back to the default — all your team's live matches |

Picks, adds, and hides are all **one-shot**: they expire automatically the moment their match leaves the live feed, so the scoreline always returns to your team's matches on its own.

## Configuration

| What | How |
|---|---|
| Followed team | Edit `%USERPROFILE%\.claude\cricket_team.txt` (one line, e.g. `New Zealand`). Matched as a substring of full team names, so `India` also matches `India Women` and `India A`. |
| Temporary override | Set the `CC_CRICKET_TEAM` environment variable (takes precedence over the file — handy for testing). |
| Status line refresh | `refreshInterval` in `settings.json` (15s recommended). |

## How it works

```
Claude Code status line (every ~15s)
        │  reads (instant, never blocks)
        ▼
%TEMP%\cc_cricket.txt  ◄── writes ──  cricket_fetch.ps1 (detached background process)
                                              │  scrapes
                                              ▼
                                      cricbuzz.com live scores
        ▲
        │  writes picks/adds/hides + forces a refresh
/live-score skill ──► cricket_pref.ps1
```

- `cricket_statusline.ps1` renders the status line. For the cricket part it only **reads a cache file**, then (if the cache is stale) launches the fetcher as a detached hidden process and returns immediately — so the status line never waits on the network.
- `cricket_fetch.ps1` scrapes Cricbuzz's live-scores page, picks the matches to show (your team by default, or your `/live-score` selections), fetches each match page for batsmen/bowler/run-rates, and writes 1–2 display lines per match to `%TEMP%\cc_cricket.txt`.
- `cricket_pref.ps1` backs the `/live-score` command: it resolves your query against the live matches and writes one-shot preference files (`cricket_pref.txt`, `cricket_removed.txt`) that the fetcher honours until each match ends.

## Use with your own statusline

Already have a custom status line? You don't need to replace it — just keep `cricket_fetch.ps1` installed and have your own script print the cached lines:

```powershell
$cc = Join-Path $env:TEMP 'cc_cricket.txt'
if ((Test-Path $cc) -and ((Get-Date) - (Get-Item $cc).LastWriteTime).TotalMinutes -lt 15) {
    Get-Content $cc -Encoding UTF8 | Where-Object { $_.Trim() } | ForEach-Object { Write-Output $_ }
}
```

(See `statusline.ps1` for the refresh-trigger snippet that keeps the cache warm, and for the per-match colour cycling.)

## Uninstall

```powershell
powershell -ExecutionPolicy Bypass -File .\uninstall.ps1
```

Removes the scripts, the skill, the preference/cache files, and the `statusLine` setting (only if it still points at the cricket statusline; `settings.json` is backed up first).

## Notes & disclaimer

- Scores are scraped from Cricbuzz's public web pages for **personal, non-commercial use**. This project is not affiliated with or endorsed by Cricbuzz; if their page format changes, the scoreline may stop showing until the parser is updated.
- Windows-only for now (the scripts are Windows PowerShell). Ports to macOS/Linux (`pwsh` or bash) are welcome — PRs open!

## License

[MIT](LICENSE) © Uthum Balasooriya
