# Background fetcher for the status line. Default: shows EVERY live match of your followed team
# at once (national / Women / A / U19 -- any live match whose team name contains the team filter),
# national side first. A one-shot /live-score pick (tracked by match id) replaces the default
# and auto-expires when that match leaves the live feed. /live-score remove hides individual
# matches; hidden ids also auto-expire when their match ends. For each shown match it pulls the
# two batsmen + current bowler + chase rates from the match page and writes 1-2 lines per match
# to a cache file. Detached + best-effort; must never throw.
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding $false
$cacheFile   = Join-Path $env:TEMP 'cc_cricket.txt'
$prefFile    = Join-Path $env:USERPROFILE '.claude\cricket_pref.txt'      # one-shot pick: "<matchId> <focusShort>"; empty/missing = default
$removedFile = Join-Path $env:USERPROFILE '.claude\cricket_removed.txt'   # hidden match ids, one per line; pruned as matches end
$teamFile    = Join-Path $env:USERPROFILE '.claude\cricket_team.txt'      # followed team (written by install.ps1; edit anytime)
# Default team filter (regex, matched against full team names). Resolution order:
# CC_CRICKET_TEAM env var (testing/advanced) > cricket_team.txt > 'Sri Lanka'.
# (cricket_pref.ps1 mirrors this.)
$defaultFilter = 'Sri Lanka'
try {
    if (Test-Path $teamFile) {
        $t = @(Get-Content $teamFile -Encoding UTF8 | ForEach-Object { $_.Trim() } | Where-Object { $_ })
        if ($t.Count -gt 0) { $defaultFilter = $t[0] }
    }
} catch {}
if ($env:CC_CRICKET_TEAM) { $defaultFilter = $env:CC_CRICKET_TEAM }

function Emo($cp) { [char]::ConvertFromUtf32($cp) }
$bat = Emo 0x1F3CF
$tgt = Emo 0x1F3AF   # direct-hit / target, used for the chase line
$dot = [char]0x00B7   # middle dot separator

function Get-Side($block, $side, $liveInnId) {
    # Return the side's full score. A Test innings has up to two innings per side; show them all,
    # e.g. "438 & 23/2 (6.5)". Cricbuzz nests innings as inngs1/inngs2, each tagged with an
    # inningsId (1-4, chronological across the whole match), and OMITS "wickets" when it is 0
    # (common in Tests). Overs are shown only on the current (live) innings -- the one whose
    # inningsId equals the match-wide maximum -- and the redundant "/10" is dropped when all out.
    $start = $block.IndexOf('"' + $side + '"')
    if ($start -lt 0) { return $null }
    $seg = $block.Substring($start)
    $other = if ($side -eq 'team1Score') { 'team2Score' } else { 'team1Score' }
    $oi = $seg.IndexOf('"' + $other + '"')
    if ($oi -gt 0) { $seg = $seg.Substring(0, $oi) }
    $inns = [regex]::Matches($seg, '"inningsId":(\d+),"runs":(\d+)(?:,"wickets":(\d+))?(?:,"overs":([\d.]+))?')
    if ($inns.Count -eq 0) {
        # Fallback (no inningsId in payload): parse the last runs/wickets/overs as one innings.
        $runsAll = [regex]::Matches($seg, '"runs":(\d+)')
        if ($runsAll.Count -eq 0) { return $null }
        $tail = $seg.Substring($runsAll[$runsAll.Count - 1].Index)
        $r = [regex]::Match($tail, '"runs":(\d+)').Groups[1].Value
        $w = [regex]::Match($tail, '"wickets":(\d+)').Groups[1].Value
        $o = [regex]::Match($tail, '"overs":([\d.]+)').Groups[1].Value
        if (-not $w) { $w = '0' }
        $sc = "$r/$w"; if ($o) { $sc += " ($o)" }
        return $sc
    }
    $scores = @()
    foreach ($mm in $inns) {
        $id = [int]$mm.Groups[1].Value
        $r  = $mm.Groups[2].Value
        $w  = $mm.Groups[3].Value
        $o  = $mm.Groups[4].Value
        if (-not $w) { $w = '0' }
        $piece = if ($w -eq '10') { "$r" } else { "$r/$w" }    # all out -> drop the redundant /10
        if ($o -and $id -eq $liveInnId) { $piece += " ($o)" }  # overs only on the live innings
        $scores += $piece
    }
    return ($scores -join ' & ')
}
function Surname($n) { if ($n) { ($n -split ' ')[-1] } else { '' } }
function Get-Bat($page, $key, $star) {
    $m = [regex]::Match($page, '"' + $key + '":\{(.*?)\}')
    if (-not $m.Success) { return $null }
    $o = $m.Groups[1].Value
    $name = [regex]::Match($o, '"name":"([^"]+)"').Groups[1].Value
    if (-not $name) { return $null }
    $r = [regex]::Match($o, '"runs":(\d+)').Groups[1].Value
    $b = [regex]::Match($o, '"balls":(\d+)').Groups[1].Value
    return "$(Surname $name) $r$star($b)"
}

# Builds the 1-2 display lines (score line + chase line during a run chase) for one match.
function Build-MatchLines($best, $focus) {
    # Order the two team scores so the focus team is shown first.
    $first1 = $true
    if     ($best.s2 -eq $focus -or ($best.n2 -and $best.n2 -match [regex]::Escape($focus))) { $first1 = $false }
    elseif ($best.s1 -eq $focus -or ($best.n1 -and $best.n1 -match [regex]::Escape($focus))) { $first1 = $true }
    $parts = @()
    if ($first1) { if ($best.sc1) { $parts += "$($best.s1) $($best.sc1)" }; if ($best.sc2) { $parts += "$($best.s2) $($best.sc2)" } }
    else         { if ($best.sc2) { $parts += "$($best.s2) $($best.sc2)" }; if ($best.sc1) { $parts += "$($best.s1) $($best.sc1)" } }
    $hasScore = ($parts.Count -gt 0)
    $score = if ($hasScore) { $parts -join "  $dot  " } else { $best.state }

    $line = "$bat $($best.s1) v $($best.s2), $($best.desc) - $score"
    # Test/multi-innings context: surface "lead by N" / "trail by N" from the status text as a
    # headline right after the scores (e.g. "... ENG 354  .  NZ lead by 107").
    if ($best.status) {
        $lt = [regex]::Match($best.status, '(?i)(.*?)\b(lead|trail)s?\s+by\s+(\d+)\s+run')
        if ($lt.Success) {
            $code = ''
            $cands = @(); if ($best.n1) { $cands += , @($best.n1, $best.s1) }; if ($best.n2) { $cands += , @($best.n2, $best.s2) }
            foreach ($cd in ($cands | Sort-Object { - $_[0].Length })) { if ($lt.Groups[1].Value -match [regex]::Escape($cd[0])) { $code = $cd[1]; break } }
            $dir = $lt.Groups[2].Value.ToLower(); $byN = $lt.Groups[3].Value
            $line += "  $dot  " + $(if ($code) { "$code $dir by $byN" } else { "$dir by $byN" })
        }
    }
    $chaseLine = $null   # second line, only built during a run chase
    # Only fetch the match page (for batsmen/bowler/rates) once play is under way.
    if ($hasScore -and $best.mid) {
        try {
            $mt = ((Invoke-WebRequest -Uri "https://www.cricbuzz.com/live-cricket-scores/$($best.mid)" -Headers $H -TimeoutSec 12 -UseBasicParsing).Content) -replace '\\"', '"'
            $striker = Get-Bat $mt 'batsmanStriker' '*'
            $nonstr  = Get-Bat $mt 'batsmanNonStriker' ''
            $bats = @($striker, $nonstr) | Where-Object { $_ }
            if ($bats.Count -gt 0) { $line += "  $dot  " + ($bats -join ', ') }
            $bm = [regex]::Match($mt, '"bowlerStriker":\{(.*?)\}')
            if ($bm.Success) {
                $o  = $bm.Groups[1].Value
                $bn = Surname ([regex]::Match($o, '"name":"([^"]+)"').Groups[1].Value)
                if ($bn) {
                    $bw = [regex]::Match($o, '"wickets":(\d+)').Groups[1].Value
                    $br = [regex]::Match($o, '"runs":(\d+)').Groups[1].Value
                    $bo = [regex]::Match($o, '"overs":([\d.]+)').Groups[1].Value
                    $line += "  $dot  $bn $bw/$br ($bo)"
                }
            }
            # --- Chase line: only when the team batting second still "need"s runs ---
            # Runs/balls come from the per-match status text; CRR/RRR from the miniscore.
            if ($best.status -and $best.status -match '\bneed\b') {
                $rm = [regex]::Match($best.status, 'need (\d+) runs?(?: in (\d+) ball)?')
                if ($rm.Success) {
                    $needR = $rm.Groups[1].Value; $needB = $rm.Groups[2].Value
                    # Map the chasing team (named in the status) to its short code; longer full name first
                    # so "Sri Lanka A" is matched before "Sri Lanka". Falls back to no prefix if unresolved.
                    $chaseTeam = ''
                    $cands = @(); if ($best.n1) { $cands += , @($best.n1, $best.s1) }; if ($best.n2) { $cands += , @($best.n2, $best.s2) }
                    foreach ($cd in ($cands | Sort-Object { - $_[0].Length })) { if ($best.status -match [regex]::Escape($cd[0])) { $chaseTeam = $cd[1]; break } }
                    $rWord = if ($needR -eq '1') { 'run' } else { 'runs' }
                    $body = if ($chaseTeam) { "$chaseTeam need $needR $rWord" } else { "Need $needR $rWord" }
                    if ($needB) { $body += " in $needB ball$(if ($needB -ne '1') { 's' })" }   # balls omitted for timeless/Test chases
                    $crr = [regex]::Match($mt, '"currentRunRate":([\d.]+)').Groups[1].Value
                    $rrr = [regex]::Match($mt, '"requiredRunRate":([\d.]+)').Groups[1].Value
                    $rates = @(); if ($crr) { $rates += "CRR $crr" }; if ($rrr -and [double]$rrr -gt 0) { $rates += "RRR $rrr" }
                    if ($rates.Count) { $body += "  $dot  " + ($rates -join "  $dot  ") }
                    $chaseLine = "$tgt $body"
                }
            }
        } catch {}
    }
    $out = @($line); if ($chaseLine) { $out += $chaseLine }
    return $out
}

try {
    $H = @{ "User-Agent" = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0 Safari/537.36" }
    $raw = (Invoke-WebRequest -Uri "https://www.cricbuzz.com/cricket-match/live-scores" -Headers $H -TimeoutSec 12 -UseBasicParsing).Content
    $u = $raw -replace '\\"', '"'   # unescape the embedded payload

    # Only these states count as "live" -- Preview/Upcoming and finished/result states are hidden.
    $liveStates = @('In Progress', 'Innings Break', 'Stumps', 'Rain', 'Tea', 'Lunch', 'Drinks', 'Toss')
    # Lower number = more "live"; used to order/select when several matches qualify at once.
    $pri = @{ 'In Progress' = 0; 'Innings Break' = 1; 'Rain' = 1; 'Tea' = 1; 'Lunch' = 1; 'Drinks' = 1; 'Stumps' = 2; 'Toss' = 3 }

    # Parse every live match once into objects.
    $live = @(); $seen = @{}
    foreach ($c in ([regex]::Split($u, '"matchInfo":') | Select-Object -Skip 1)) {
        $t1 = [regex]::Match($c, '"team1":\{[^}]*?"teamName":"([^"]+)"[^}]*?"teamSName":"([^"]+)"')
        $t2 = [regex]::Match($c, '"team2":\{[^}]*?"teamName":"([^"]+)"[^}]*?"teamSName":"([^"]+)"')
        if (-not $t1.Success -or -not $t2.Success) { continue }
        $state = [regex]::Match($c, '"stateTitle":"([^"]*)"').Groups[1].Value.Trim()
        if ($liveStates -notcontains $state) { continue }   # live-only
        $n1 = $t1.Groups[1].Value; $s1 = $t1.Groups[2].Value
        $n2 = $t2.Groups[1].Value; $s2 = $t2.Groups[2].Value
        $desc = [regex]::Match($c, '"matchDesc":"([^"]+)"').Groups[1].Value
        $mid  = [regex]::Match($c, '"matchId":(\d+)').Groups[1].Value
        $cstatus = [regex]::Match($c, '"status":"([^"]*)"').Groups[1].Value   # per-match chase text, e.g. "Sri Lanka need 52 runs in 55 balls"
        $key = "$s1-$s2-$desc"
        if ($seen.ContainsKey($key)) { continue }
        $seen[$key] = $true
        $blk = [regex]::Match($c, '"matchScore":\{.*?\}\}\}').Value
        $allIds = @([regex]::Matches($blk, '"inningsId":(\d+)') | ForEach-Object { [int]$_.Groups[1].Value })
        $liveInnId = if ($allIds.Count) { ($allIds | Measure-Object -Maximum).Maximum } else { 0 }
        $sc1 = Get-Side $blk 'team1Score' $liveInnId
        $sc2 = Get-Side $blk 'team2Score' $liveInnId
        $pp = if ($pri.ContainsKey($state)) { $pri[$state] } else { 3 }
        $live += [pscustomobject]@{ s1 = $s1; s2 = $s2; n1 = $n1; n2 = $n2; desc = $desc; mid = $mid; status = $cstatus; state = $state; sc1 = $sc1; sc2 = $sc2; prio = $pp }
    }

    # Load /live-score-removed match ids and prune ones whose match has left the live feed --
    # a hide only lasts while its match is live ("in the moment", never permanent).
    $removed = @()
    if (Test-Path $removedFile) {
        $ids = @(Get-Content $removedFile -Encoding UTF8 | ForEach-Object { $_.Trim() } | Where-Object { $_ -match '^\d+$' })
        $liveIds = @($live | ForEach-Object { $_.mid })
        $removed = @($ids | Where-Object { $liveIds -contains $_ })
        if ($removed.Count -eq 0) { Remove-Item $removedFile -Force -ErrorAction SilentlyContinue }
        elseif ($removed.Count -ne $ids.Count) { Set-Content -Path $removedFile -Value $removed -Encoding UTF8 }
    }

    # Choose the matches to show. The pref file holds one entry per line:
    #   "pick <mid> <focus>" -- /live-score <team>: replaces the default with this match
    #   "add <mid> <focus>"  -- /live-score add <team>: stacked ON TOP of whatever else shows
    # (legacy bare "<mid> <focus>" is treated as a pick). Every entry is one-shot: it is pruned
    # the moment its match leaves the live feed; an empty file is deleted -> pure default again.
    # Display = (live picks if any, else ALL default-team matches, national side first) + adds.
    $picks = @(); $adds = @()
    if (Test-Path $prefFile) {
        $lines = @(Get-Content $prefFile -Encoding UTF8 | ForEach-Object { $_.Trim() } | Where-Object { $_ })
        $valid = @()
        foreach ($ln in $lines) {
            $pm = [regex]::Match($ln, '^(?:(pick|add)\s+)?(\d+)(?:\s+(\S+))?$')
            if (-not $pm.Success) { continue }
            $kind = $pm.Groups[1].Value; if (-not $kind) { $kind = 'pick' }
            $hit = $live | Where-Object { $_.mid -eq $pm.Groups[2].Value } | Select-Object -First 1
            if (-not $hit) { continue }   # one-shot expired: drop the entry
            $valid += $ln
            $foc = if ($pm.Groups[3].Value) { $pm.Groups[3].Value } else { $hit.s1 }
            $entry = [pscustomobject]@{ m = $hit; focus = $foc }
            if ($kind -eq 'add') { $adds += $entry } else { $picks += $entry }
        }
        if ($valid.Count -eq 0) { Remove-Item $prefFile -Force -ErrorAction SilentlyContinue }
        elseif ($valid.Count -ne $lines.Count) { Set-Content -Path $prefFile -Value $valid -Encoding UTF8 }
    }
    $entries = @($picks)
    if ($entries.Count -eq 0) {
        $entries = @($live | Where-Object { $_.n1 -match $defaultFilter -or $_.n2 -match $defaultFilter } |
                Sort-Object { if ($_.n1 -eq $defaultFilter -or $_.n2 -eq $defaultFilter) { 0 } else { 1 } }, { $_.prio }, { [long]$_.mid } |
                ForEach-Object { [pscustomobject]@{ m = $_; focus = $defaultFilter } })
    }
    $entries += $adds
    # Dedup by match id, then apply /live-score remove hides.
    $seenMid = @{}; $out = @()
    foreach ($e in $entries) {
        if ($seenMid.ContainsKey($e.m.mid)) { continue }
        $seenMid[$e.m.mid] = $true
        if ($removed -contains $e.m.mid) { continue }
        $out += Build-MatchLines $e.m $e.focus
    }
    if ($out.Count -gt 0) { Set-Content -Path $cacheFile -Value $out -Encoding UTF8 }
    else { Set-Content -Path $cacheFile -Value '' -Encoding UTF8 }
} catch {
    if (Test-Path $cacheFile) { (Get-Item $cacheFile).LastWriteTime = Get-Date }
}
