# Setter behind the /live-score command.
#   <team> / "A vs B"  -> REPLACE the scoreline with that live match (one-shot, until it ends)
#   add <match>        -> ADD that match's line on top of whatever is showing (stackable, n matches)
#   remove <match>     -> hide that match's line until the match ends
#   list               -> show all live matches (tracked/added/hidden flagged)
#   reset              -> clear picks, adds and hides; back to the default (all live matches of your followed team)
# Output is plain text meant to be relayed to the user by the skill. Best-effort; never throws.
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding $false
$prefFile    = Join-Path $env:USERPROFILE '.claude\cricket_pref.txt'      # entries: "pick <mid> <focus>" / "add <mid> <focus>"
$removedFile = Join-Path $env:USERPROFILE '.claude\cricket_removed.txt'   # hidden match ids, one per line
$fetcher     = Join-Path $env:USERPROFILE '.claude\cricket_fetch.ps1'
$teamFile    = Join-Path $env:USERPROFILE '.claude\cricket_team.txt'      # followed team (written by install.ps1; edit anytime)
$attempt     = Join-Path $env:TEMP 'cc_cricket_attempt.txt'
# Default team filter -- must mirror cricket_fetch.ps1:
# CC_CRICKET_TEAM env var (testing/advanced) > cricket_team.txt > 'Sri Lanka'.
$defaultFilter = 'Sri Lanka'
try {
    if (Test-Path $teamFile) {
        $t = @(Get-Content $teamFile -Encoding UTF8 | ForEach-Object { $_.Trim() } | Where-Object { $_ })
        if ($t.Count -gt 0) { $defaultFilter = $t[0] }
    }
} catch {}
if ($env:CC_CRICKET_TEAM) { $defaultFilter = $env:CC_CRICKET_TEAM }
$bat = [char]::ConvertFromUtf32(0x1F3CF)
$dot = [char]0x00B7

$query  = ($args -join ' ').Trim()
$qLower = $query.ToLower()
# Typing the followed team's own name also counts as "reset" -- it IS the default view.
$resetWords = @('reset', 'default', 'clear', 'none', 'off', $defaultFilter.ToLower(), ($defaultFilter -replace '\s', '').ToLower())

function Refresh-Now {
    # Update the cache immediately and clear the status-line throttle so the change shows at once.
    if (Test-Path $attempt) { Remove-Item $attempt -Force -ErrorAction SilentlyContinue }
    if (Test-Path $fetcher) { & $fetcher }
}

function Get-LiveMatches {
    $H = @{ "User-Agent" = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0 Safari/537.36" }
    $raw = (Invoke-WebRequest -Uri "https://www.cricbuzz.com/cricket-match/live-scores" -Headers $H -TimeoutSec 12 -UseBasicParsing).Content
    $u = $raw.Replace('\"', '"')
    $liveStates = @('In Progress', 'Innings Break', 'Stumps', 'Rain', 'Tea', 'Lunch', 'Drinks', 'Toss')
    $pri = @{ 'In Progress' = 0; 'Innings Break' = 1; 'Rain' = 1; 'Tea' = 1; 'Lunch' = 1; 'Drinks' = 1; 'Stumps' = 2; 'Toss' = 3 }
    $out = @(); $seen = @{}
    foreach ($c in ([regex]::Split($u, '"matchInfo":') | Select-Object -Skip 1)) {
        $t1 = [regex]::Match($c, '"team1":\{[^}]*?"teamName":"([^"]+)"[^}]*?"teamSName":"([^"]+)"')
        $t2 = [regex]::Match($c, '"team2":\{[^}]*?"teamName":"([^"]+)"[^}]*?"teamSName":"([^"]+)"')
        if (-not $t1.Success -or -not $t2.Success) { continue }
        $state = [regex]::Match($c, '"stateTitle":"([^"]*)"').Groups[1].Value.Trim()
        if ($liveStates -notcontains $state) { continue }
        $mid = [regex]::Match($c, '"matchId":(\d+)').Groups[1].Value
        if (-not $mid -or $seen.ContainsKey($mid)) { continue }
        $seen[$mid] = $true
        $desc   = [regex]::Match($c, '"matchDesc":"([^"]+)"').Groups[1].Value
        $series = [regex]::Match($c, '"seriesName":"([^"]+)"').Groups[1].Value
        $pp = if ($pri.ContainsKey($state)) { $pri[$state] } else { 3 }
        $out += [pscustomobject]@{ s1 = $t1.Groups[2].Value; n1 = $t1.Groups[1].Value; s2 = $t2.Groups[2].Value; n2 = $t2.Groups[1].Value; desc = $desc; series = $series; mid = $mid; state = $state; prio = $pp }
    }
    return , $out
}

# A term matches a match if it is a substring of either team (full or short), the description, or the series.
function Test-Term($obj, $term) {
    $t = $term.ToLower()
    foreach ($f in @($obj.n1, $obj.n2, $obj.s1, $obj.s2, $obj.desc, $obj.series)) {
        if ($f -and $f.ToLower().Contains($t)) { return $true }
    }
    return $false
}
# Splits "A vs B" queries; single terms pass through unchanged. Leading comma keeps a
# single-element result an array (PowerShell would otherwise unroll it to a bare string).
function Get-Terms($q) { return , @($q -split '(?i)\s+(?:vs?|versus)\s+' | ForEach-Object { $_.Trim() } | Where-Object { $_ }) }
# All live matches matching a free-text query, most-live first.
function Resolve-Query($m, $q) {
    $terms = Get-Terms $q
    return , @($m | Where-Object {
            $obj = $_; $ok = $true
            foreach ($term in $terms) { if (-not (Test-Term $obj $term)) { $ok = $false; break } }
            $ok
        } | Sort-Object { $_.prio }, { [long]$_.mid })
}
# Which of the two teams the first query term names -> shown first on the score line.
function Get-Focus($b, $q) {
    $ft = ((Get-Terms $q)[0]).ToLower()
    if (("$($b.n2) $($b.s2)").ToLower().Contains($ft)) { return $b.s2 }
    return $b.s1
}

function Get-RemovedIds {
    if (Test-Path $removedFile) { return , @(Get-Content $removedFile -Encoding UTF8 | ForEach-Object { $_.Trim() } | Where-Object { $_ -match '^\d+$' }) }
    return , @()
}
function Unhide($mid) {
    $ids = Get-RemovedIds
    if ($ids -contains $mid) {
        $keep = @($ids | Where-Object { $_ -ne $mid })
        if ($keep.Count -gt 0) { Set-Content -Path $removedFile -Value $keep -Encoding UTF8 }
        else { Remove-Item $removedFile -Force -ErrorAction SilentlyContinue }
    }
}
# Parsed pref entries: kind (pick/add), mid, focus, raw line. Legacy bare "<mid> <focus>" = pick.
function Get-PrefEntries {
    $out = @()
    if (Test-Path $prefFile) {
        foreach ($ln in @(Get-Content $prefFile -Encoding UTF8 | ForEach-Object { $_.Trim() } | Where-Object { $_ })) {
            $pm = [regex]::Match($ln, '^(?:(pick|add)\s+)?(\d+)(?:\s+(\S+))?$')
            if ($pm.Success) {
                $k = $pm.Groups[1].Value; if (-not $k) { $k = 'pick' }
                $out += [pscustomobject]@{ kind = $k; mid = $pm.Groups[2].Value; focus = $pm.Groups[3].Value; raw = $ln }
            }
        }
    }
    return , $out
}
# Mirrors the fetcher's selection: (live picks if any, else default-team matches) + adds, deduped.
function Get-DisplayedSet($m) {
    $entries = Get-PrefEntries
    $pickIds = @($entries | Where-Object { $_.kind -eq 'pick' } | ForEach-Object { $_.mid })
    $addIds  = @($entries | Where-Object { $_.kind -eq 'add' } | ForEach-Object { $_.mid })
    $disp = @($m | Where-Object { $pickIds -contains $_.mid })
    if ($disp.Count -eq 0) { $disp = @($m | Where-Object { $_.n1 -match $defaultFilter -or $_.n2 -match $defaultFilter }) }
    $disp += @($m | Where-Object { $addIds -contains $_.mid })
    $seen = @{}; $u = @()
    foreach ($x in $disp) { if (-not $seen.ContainsKey($x.mid)) { $seen[$x.mid] = $true; $u += $x } }
    return , $u
}

# ---------------- dispatch ----------------
if (@($resetWords) -contains $qLower) {
    if (Test-Path $prefFile)    { Remove-Item $prefFile -Force -ErrorAction SilentlyContinue }
    if (Test-Path $removedFile) { Remove-Item $removedFile -Force -ErrorAction SilentlyContinue }
    Refresh-Now
    Write-Output "$bat Reset - back to the default (all live $defaultFilter matches)."
}
elseif ($query -eq '' -or $qLower -eq 'list') {
    $m = Get-LiveMatches
    $removedIds = Get-RemovedIds
    $entries = Get-PrefEntries
    if ($m.Count -eq 0) { Write-Output "$bat No live matches right now (all $defaultFilter matches show by default when on)." }
    else {
        Write-Output "$bat Live matches right now:"
        foreach ($x in ($m | Sort-Object { $_.prio }, { [long]$_.mid })) {
            $sd = if ($x.series) { " - $($x.series)" } else { '' }
            $flags = ''
            $e = $entries | Where-Object { $_.mid -eq $x.mid } | Select-Object -First 1
            if ($e) { $flags += $(if ($e.kind -eq 'add') { '  [added]' } else { '  [tracking]' }) }
            if ($removedIds -contains $x.mid) { $flags += '  [hidden]' }
            Write-Output "  $dot $($x.s1) v $($x.s2), $($x.desc)$sd  [$($x.state)]$flags"
        }
        Write-Output "Use:  /live-score <team>   |   /live-score add <match>   |   /live-score remove <match>   |   /live-score reset"
    }
}
elseif ($qLower -eq 'remove' -or $qLower -eq 'hide' -or $qLower -match '^(remove|hide)\s') {
    $sub = ($query -replace '(?i)^(remove|hide)\s*', '').Trim()
    if (-not $sub) {
        Write-Output "$bat Tell me which match to remove, e.g. /live-score remove women"
    }
    else {
        $m = Get-LiveMatches
        $removedIds = Get-RemovedIds
        $visible = @((Get-DisplayedSet $m) | Where-Object { $removedIds -notcontains $_.mid })
        $hit = Resolve-Query $visible $sub
        if ($hit.Count -eq 0) {
            Write-Output "$bat No '$sub' match on the scoreline to remove (already hidden or not shown)."
        }
        else {
            $hitIds = @($hit | ForEach-Object { $_.mid })
            $newIds = @($removedIds + $hitIds) | Select-Object -Unique
            Set-Content -Path $removedFile -Value $newIds -Encoding UTF8
            # Removing a tracked/added match drops its pref entry too.
            $keep = @((Get-PrefEntries) | Where-Object { $hitIds -notcontains $_.mid } | ForEach-Object { $_.raw })
            if ($keep.Count -gt 0) { Set-Content -Path $prefFile -Value $keep -Encoding UTF8 }
            elseif (Test-Path $prefFile) { Remove-Item $prefFile -Force -ErrorAction SilentlyContinue }
            Refresh-Now
            foreach ($x in $hit) { Write-Output "$bat Hidden: $($x.s1) v $($x.s2), $($x.desc)  (only while it's live - back to normal once it ends)" }
        }
    }
}
elseif ($qLower -eq 'add' -or $qLower -match '^add\s') {
    $sub = ($query -replace '(?i)^add\s*', '').Trim()
    if (-not $sub) {
        Write-Output "$bat Tell me which match to add, e.g. /live-score add India"
    }
    else {
        $m = Get-LiveMatches
        $matched = Resolve-Query $m $sub
        if ($matched.Count -eq 0) {
            Write-Output "$bat No live $sub match."
        }
        else {
            $b = $matched[0]
            $removedIds = Get-RemovedIds
            $visibleIds = @((Get-DisplayedSet $m) | Where-Object { $removedIds -notcontains $_.mid } | ForEach-Object { $_.mid })
            if ($visibleIds -contains $b.mid) {
                Write-Output "$bat $($b.s1) v $($b.s2), $($b.desc) is already on the scoreline."
            }
            else {
                Add-Content -Path $prefFile -Value "add $($b.mid) $(Get-Focus $b $sub)" -Encoding UTF8
                Unhide $b.mid
                Refresh-Now
                Write-Output "$bat Added $($b.s1) v $($b.s2), $($b.desc)  [$($b.state)]"
            }
        }
    }
}
else {
    $m = Get-LiveMatches
    $matched = Resolve-Query $m $query
    if ($matched.Count -eq 0) {
        Write-Output "$bat No live $query match."
    }
    else {
        $b = $matched[0]
        # Replace: this pick becomes the whole scoreline (clears earlier picks AND adds).
        Set-Content -Path $prefFile -Value "pick $($b.mid) $(Get-Focus $b $query)" -Encoding UTF8
        Unhide $b.mid
        Refresh-Now
        Write-Output "$bat Now tracking $($b.s1) v $($b.s2), $($b.desc)  [$($b.state)]"
    }
}
