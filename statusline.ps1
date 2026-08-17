# Claude Code statusline with a live cricket scoreline.
# Line 1: folder | git branch | model | date | clock
# Then:   one coloured score line per live match (plus a chase line during a run chase)
# Then:   context / rate-limit meters + session uptime
#
# The cricket lines are read from a cache file only (instant); the network fetch runs
# detached in the background (cricket_fetch.ps1), so the status line never blocks.
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding $false

$data = $input | Out-String | ConvertFrom-Json

$e       = [char]27
$bold    = "$e[1m"
$cyan    = "$e[36m"
$yellow  = "$e[33m"
$green   = "$e[32m"
$magenta = "$e[35m"
$reset   = "$e[0m"
$dim     = "$e[2m"

$model  = $data.model.display_name
$dir    = Split-Path $data.cwd -Leaf
$branch = ""
try { $branch = (git -C $data.cwd --no-optional-locks branch --show-current 2>$null) } catch {}

$now = Get-Date

# Date + clock
$date  = $now.ToString("ddd dd MMM")
$clock = $now.ToString("HH:mm")

# Session uptime: stash first-seen time per session_id in a temp file, then elapse it
$uptime = $null
$sid = $data.session_id
if ($sid) {
    $sf = Join-Path $env:TEMP ("cc_session_" + ($sid -replace '[^A-Za-z0-9_-]', '') + ".txt")
    $start = $now
    try {
        if (Test-Path $sf) {
            $start = [datetime][long]((Get-Content $sf -Raw).Trim())
        } else {
            Set-Content -Path $sf -Value ([string]$now.Ticks) -Encoding ascii
        }
    } catch { $start = $now }
    $span = $now - $start
    $hh = [int][math]::Floor($span.TotalHours)
    if ($hh -gt 0) { $uptime = "${hh}h$($span.Minutes)m" }
    else           { $uptime = "$($span.Minutes)m" }
}

# --- Live cricket score (Cricbuzz, keyless) ---
# This render only READS a cache file (instant); the network fetch runs detached in
# the background, so the status line never blocks on the network.
$ccLines = @()   # all cached cricket lines: one score line per displayed match, plus a chase line under any match in a run chase
$ccFile    = Join-Path $env:TEMP 'cc_cricket.txt'
$ccAttempt = Join-Path $env:TEMP 'cc_cricket_attempt.txt'
$fetcher   = Join-Path $env:USERPROFILE '.claude\cricket_fetch.ps1'
try {
    if (Test-Path $ccFile) {
        $age = ($now - (Get-Item $ccFile).LastWriteTime).TotalMinutes
        if ($age -lt 15) {
            $ccLines = @(Get-Content $ccFile -Encoding UTF8 | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' })
        }
    }
    # Trigger a background refresh; this call returns immediately. Cadence:
    #   - live match (cache non-empty): every 15s, so the score stays current ball-to-ball.
    #   - "start window" xx:01-xx:05 and xx:31-xx:35 (matches usually start at xx:00 / xx:30,
    #     but Cricbuzz needs a moment to publish, so we begin checking at :01, not :00): every 60s,
    #     so a starting match is picked up within ~a minute of going live.
    #   - otherwise idle: every 5 minutes, to avoid pointless fetches.
    $m = $now.Minute
    $startWindow = (($m -ge 1) -and ($m -le 5)) -or (($m -ge 31) -and ($m -le 35))
    if     ($ccLines.Count -gt 0) { $refreshEvery = 15 }
    elseif ($startWindow)         { $refreshEvery = 60 }
    else                          { $refreshEvery = 300 }
    $stale = $true
    if (Test-Path $ccAttempt) { $stale = ((($now - (Get-Item $ccAttempt).LastWriteTime).TotalSeconds) -ge $refreshEvery) }
    if ($stale -and (Test-Path $fetcher)) {
        Set-Content -Path $ccAttempt -Value ([string]$now.Ticks) -Encoding ascii
        Start-Process -FilePath "powershell" -WindowStyle Hidden -ArgumentList @("-NoProfile", "-WindowStyle", "Hidden", "-File", "`"$fetcher`"") | Out-Null
    }
} catch {}

# Emoji icons (universal — no Nerd Font required)
$icoDir    = [char]::ConvertFromUtf32(0x1F4C1)  # folder
$icoBranch = [char]::ConvertFromUtf32(0x1F33F)  # branch/leaf
$icoModel  = [char]::ConvertFromUtf32(0x1F916)  # robot
$icoDate   = [char]::ConvertFromUtf32(0x1F4C5)  # calendar
$icoClock  = [char]::ConvertFromUtf32(0x1F550)  # clock

# Line 1: dir | branch | model | date | clock
$sep = "  $dim|$reset  "
$parts = @("${bold}${cyan}${icoDir} ${dir}${reset}")
if ($branch) { $parts += "${yellow}${icoBranch} ${branch}${reset}" }
$parts += "${green}${icoModel} ${model}${reset}"
$parts += "${dim}${icoDate} ${date}${reset}"
$parts += "${magenta}${icoClock} ${clock}${reset}"
$line1 = $parts -join $sep

# Meters: context bar + optional rate limits
function Bar($pct) {
    if ($null -eq $pct) { return $null }
    $pct = [int]$pct
    $w = 10
    $filled = [math]::Floor($pct * $w / 100)
    if    ($pct -ge 80) { $c = "$e[31m" }
    elseif ($pct -ge 50) { $c = "$e[33m" }
    else                 { $c = "$e[32m" }
    $full  = [string][char]0x2588
    $empty = [string][char]0x2591
    $bar = ($full * $filled) + ($empty * ($w - $filled))
    return "$c$bar$reset ${pct}%"
}

# Traffic-light emoji for meter fill (green/yellow/red)
function CtxEmoji($pct) {
    if ($null -eq $pct) { return "" }
    $pct = [int]$pct
    if    ($pct -ge 80) { return [char]::ConvertFromUtf32(0x1F534) }  # red
    elseif ($pct -ge 50) { return [char]::ConvertFromUtf32(0x1F7E1) }  # yellow
    else                 { return [char]::ConvertFromUtf32(0x1F7E2) }  # green
}

$ctx = $data.context_window.used_percentage
$h5  = $data.rate_limits.five_hour.used_percentage
$d7  = $data.rate_limits.seven_day.used_percentage

$meters = @()
$ctxBar = Bar $ctx
if ($ctxBar) { $meters += "$(CtxEmoji $ctx) ctx $ctxBar" }
$h5Bar  = Bar $h5
if ($h5Bar)  { $meters += "$(CtxEmoji $h5) 5h $h5Bar" }
$d7Bar  = Bar $d7
if ($d7Bar)  { $meters += "$(CtxEmoji $d7) 7d $d7Bar" }

# Session uptime meter
if ($uptime) { $meters += "${dim}$([char]::ConvertFromUtf32(0x23F1)) ${uptime}${reset}" }

Write-Output $line1
# Cricket: one colour per match so stacked matches are easy to tell apart. A match = one score
# line (bat emoji) plus an optional chase line (target emoji) under it; both lines share the
# match's colour at full brightness, so each match reads as one solid coloured block. The
# palette cycles if there are more matches than colours (rarely more than 3-4 live at once).
$batEmo = [char]::ConvertFromUtf32(0x1F3CF)   # score line = start of a new match
$ccPalette = @("$e[96m", "$e[93m", "$e[95m", "$e[92m", "$e[94m")   # bright: cyan, yellow, magenta, green, blue
$ccIdx = -1
foreach ($ccl in $ccLines) {
    if ($ccl.StartsWith($batEmo)) { $ccIdx++ }   # new match -> advance to the next colour
    $ccCol = $ccPalette[[Math]::Max($ccIdx, 0) % $ccPalette.Count]
    Write-Output "${bold}${ccCol}${ccl}${reset}"
}
if ($meters.Count -gt 0) {
    Write-Output ""
    Write-Output ($meters -join "          ")
}
