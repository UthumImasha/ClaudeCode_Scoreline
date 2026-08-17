# Installer for the Claude Code cricket scoreline.
# Usage:
#   .\install.ps1                          # interactive (asks for your team)
#   .\install.ps1 -Team "India"            # non-interactive team choice
#   .\install.ps1 -Team "India" -Silent    # no prompts at all (overwrites an existing statusLine setting)
#
# What it does:
#   1. Copies the scripts into ~/.claude  (statusline.ps1 is installed as cricket_statusline.ps1
#      so it never clobbers a statusline.ps1 you already have)
#   2. Saves your followed team to ~/.claude/cricket_team.txt
#   3. Installs the /live-score skill to ~/.claude/skills/live-score
#   4. Points Claude Code's statusLine setting at the new script (settings.json is backed up first)
#   5. Primes the score cache once
param(
    [string]$Team,
    [switch]$Silent
)

$ErrorActionPreference = 'Stop'
$src    = $PSScriptRoot
$claude = Join-Path $env:USERPROFILE '.claude'

Write-Host ""
Write-Host "Claude Code Cricket Scoreline - installer" -ForegroundColor Cyan
Write-Host "-----------------------------------------"

# 0. Sanity: the source files must sit next to this script.
foreach ($f in @('statusline.ps1', 'cricket_fetch.ps1', 'cricket_pref.ps1', 'skills\live-score\SKILL.md')) {
    if (-not (Test-Path (Join-Path $src $f))) {
        Write-Host "ERROR: '$f' not found next to install.ps1. Run this from a full clone of the repo." -ForegroundColor Red
        exit 1
    }
}
if (-not (Test-Path $claude)) { New-Item -ItemType Directory -Path $claude -Force | Out-Null }

# 1. Followed team
if (-not $Team) {
    if ($Silent) { $Team = 'Sri Lanka' }
    else {
        $answer = Read-Host "Which team do you want to follow by default? [Sri Lanka]"
        if ([string]::IsNullOrWhiteSpace($answer)) { $Team = 'Sri Lanka' } else { $Team = $answer.Trim() }
    }
}
Set-Content -Path (Join-Path $claude 'cricket_team.txt') -Value $Team -Encoding UTF8
Write-Host "  [ok] Followed team: $Team"

# 2. Copy scripts (statusline gets a distinct name so an existing statusline.ps1 is untouched)
Copy-Item (Join-Path $src 'statusline.ps1')    (Join-Path $claude 'cricket_statusline.ps1') -Force
Copy-Item (Join-Path $src 'cricket_fetch.ps1') (Join-Path $claude 'cricket_fetch.ps1')      -Force
Copy-Item (Join-Path $src 'cricket_pref.ps1')  (Join-Path $claude 'cricket_pref.ps1')       -Force
Write-Host "  [ok] Scripts copied to $claude"

# 3. /live-score skill
$skillDir = Join-Path $claude 'skills\live-score'
New-Item -ItemType Directory -Path $skillDir -Force | Out-Null
Copy-Item (Join-Path $src 'skills\live-score\SKILL.md') (Join-Path $skillDir 'SKILL.md') -Force
Write-Host "  [ok] /live-score skill installed"

# 4. Wire up settings.json (backed up first; asks before replacing a different statusLine)
$settingsPath = Join-Path $claude 'settings.json'
$slPath  = (Join-Path $claude 'cricket_statusline.ps1') -replace '\\', '/'
$slValue = [pscustomobject]@{
    type            = 'command'
    command         = "powershell -NoProfile -File $slPath"
    refreshInterval = 15
}
$settings = $null
if (Test-Path $settingsPath) {
    $stamp  = Get-Date -Format 'yyyyMMdd-HHmmss'
    $backup = "$settingsPath.bak-$stamp"
    Copy-Item $settingsPath $backup -Force
    Write-Host "  [ok] settings.json backed up to $backup"
    try { $settings = Get-Content $settingsPath -Raw -Encoding UTF8 | ConvertFrom-Json } catch {
        Write-Host "ERROR: could not parse $settingsPath as JSON. Fix or remove it, then re-run." -ForegroundColor Red
        exit 1
    }
}
if ($null -eq $settings) { $settings = [pscustomobject]@{} }

$existing = $null
try { $existing = $settings.statusLine } catch {}
$writeStatusLine = $true
if ($existing -and $existing.command -and ($existing.command -notmatch 'cricket_statusline')) {
    Write-Host ""
    Write-Host "  You already have a statusLine configured:" -ForegroundColor Yellow
    Write-Host "    $($existing.command)" -ForegroundColor Yellow
    if ($Silent) {
        Write-Host "  -Silent: replacing it (your old settings.json is in the backup above)." -ForegroundColor Yellow
    }
    else {
        $r = Read-Host "  Replace it with the cricket statusline? [y/N]"
        if ($r -notmatch '^(y|yes)$') {
            $writeStatusLine = $false
            Write-Host "  [skip] Kept your existing statusLine. See README 'Use with your own statusline'" -ForegroundColor Yellow
            Write-Host "         for how to read the score cache from your own script." -ForegroundColor Yellow
        }
    }
}
if ($writeStatusLine) {
    $settings | Add-Member -MemberType NoteProperty -Name statusLine -Value $slValue -Force
    $json = $settings | ConvertTo-Json -Depth 50
    Set-Content -Path $settingsPath -Value $json -Encoding UTF8
    Write-Host "  [ok] statusLine wired into settings.json"
}

# 5. Prime the score cache once so a live match shows up immediately
try {
    & (Join-Path $claude 'cricket_fetch.ps1')
    Write-Host "  [ok] Score cache primed"
} catch {
    Write-Host "  [warn] Could not prime the score cache (offline?). It will refresh on its own." -ForegroundColor Yellow
}

Write-Host ""
Write-Host "Done! Restart Claude Code to see the new status line." -ForegroundColor Green
Write-Host "When a $Team match is live, the score appears automatically."
Write-Host "Try '/live-score list' inside Claude Code to see all live matches."
Write-Host ""
