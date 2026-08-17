# Uninstaller for the Claude Code cricket scoreline.
# Removes everything install.ps1 put in place. settings.json is backed up before editing,
# and the statusLine setting is only removed if it still points at the cricket statusline.
$ErrorActionPreference = 'SilentlyContinue'
$claude = Join-Path $env:USERPROFILE '.claude'

Write-Host ""
Write-Host "Claude Code Cricket Scoreline - uninstaller" -ForegroundColor Cyan
Write-Host "-------------------------------------------"

# 1. Detach from settings.json (only if it is still our statusline)
$settingsPath = Join-Path $claude 'settings.json'
if (Test-Path $settingsPath) {
    try {
        $settings = Get-Content $settingsPath -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($settings.statusLine -and $settings.statusLine.command -match 'cricket_statusline') {
            $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
            Copy-Item $settingsPath "$settingsPath.bak-$stamp" -Force
            $settings.PSObject.Properties.Remove('statusLine')
            Set-Content -Path $settingsPath -Value ($settings | ConvertTo-Json -Depth 50) -Encoding UTF8
            Write-Host "  [ok] statusLine removed from settings.json (backup: settings.json.bak-$stamp)"
        }
        else {
            Write-Host "  [skip] settings.json statusLine is not the cricket statusline - left untouched"
        }
    } catch {
        Write-Host "  [warn] Could not edit settings.json - remove the statusLine block manually if needed" -ForegroundColor Yellow
    }
}

# 2. Remove installed files
$files = @(
    (Join-Path $claude 'cricket_statusline.ps1'),
    (Join-Path $claude 'cricket_fetch.ps1'),
    (Join-Path $claude 'cricket_pref.ps1'),
    (Join-Path $claude 'cricket_team.txt'),
    (Join-Path $claude 'cricket_pref.txt'),
    (Join-Path $claude 'cricket_removed.txt')
)
foreach ($f in $files) { if (Test-Path $f) { Remove-Item $f -Force; Write-Host "  [ok] Removed $f" } }

$skillDir = Join-Path $claude 'skills\live-score'
if (Test-Path $skillDir) { Remove-Item $skillDir -Recurse -Force; Write-Host "  [ok] Removed /live-score skill" }

# 3. Temp caches
Remove-Item (Join-Path $env:TEMP 'cc_cricket.txt') -Force
Remove-Item (Join-Path $env:TEMP 'cc_cricket_attempt.txt') -Force

Write-Host ""
Write-Host "Done. Restart Claude Code to go back to the default status line." -ForegroundColor Green
Write-Host ""
