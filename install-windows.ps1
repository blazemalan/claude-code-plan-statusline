# Installs the plan-statusline (Windows PowerShell version) into Claude Code.
# Run via install-windows.bat (double-click) or:
#   powershell -NoProfile -ExecutionPolicy Bypass -File install-windows.ps1
#
# What it does:
#   1. Copies statusline.ps1 (next to this script) to %USERPROFILE%\.claude\hooks\plan-statusline.ps1
#   2. Adds/updates the "statusLine" entry in %USERPROFILE%\.claude\settings.json
#      (backs the file up first; every other setting is preserved)
# No network access, no admin rights needed.

$ErrorActionPreference = 'Stop'

$source = Join-Path $PSScriptRoot 'statusline.ps1'
if (-not (Test-Path $source)) {
    Write-Host "ERROR: statusline.ps1 not found next to this installer ($source)." -ForegroundColor Red
    exit 1
}

# 1. Copy the script into Claude Code's hooks folder.
$hooks = Join-Path $env:USERPROFILE '.claude\hooks'
New-Item -ItemType Directory -Force -Path $hooks | Out-Null
$dest = Join-Path $hooks 'plan-statusline.ps1'
Copy-Item -Path $source -Destination $dest -Force
Write-Host "Installed: $dest"

# 2. Merge the statusLine entry into settings.json, preserving everything else.
$settingsPath = Join-Path $env:USERPROFILE '.claude\settings.json'
$destForward = $dest -replace '\\', '/'
$command = "powershell -NoProfile -ExecutionPolicy Bypass -File `"$destForward`""

if (Test-Path $settingsPath) {
    $backup = "$settingsPath.bak-" + (Get-Date -Format 'yyyyMMdd-HHmmss')
    Copy-Item -Path $settingsPath -Destination $backup -Force
    Write-Host "Backed up settings to: $backup"
    $settings = Get-Content -Raw -Path $settingsPath | ConvertFrom-Json
} else {
    $settings = New-Object PSObject
}

$statusLine = [pscustomobject]@{ type = 'command'; command = $command }
$settings | Add-Member -NotePropertyName statusLine -NotePropertyValue $statusLine -Force

$jsonOut = $settings | ConvertTo-Json -Depth 32
# WriteAllText writes UTF-8 WITHOUT a BOM (a BOM can break JSON parsers).
[System.IO.File]::WriteAllText($settingsPath, $jsonOut)
Write-Host "Updated:   $settingsPath"

# 3. Smoke test: run the installed script on a sample payload and show the result.
$sample = '{"model":{"display_name":"Opus 4.8"},"rate_limits":{"five_hour":{"used_percentage":14,"resets_at":' + `
    [DateTimeOffset]::UtcNow.AddHours(2).ToUnixTimeSeconds() + '},"seven_day":{"used_percentage":47,"resets_at":' + `
    [DateTimeOffset]::UtcNow.AddDays(3).ToUnixTimeSeconds() + '}},"context_window":{"used_percentage":6,"context_window_size":1000000}}'
Write-Host ""
Write-Host "Preview of your statusline:"
$sample | powershell -NoProfile -ExecutionPolicy Bypass -File "$dest"
Write-Host ""
Write-Host ""
Write-Host "Done. Start a NEW Claude Code session and send any message - the statusline appears at the bottom." -ForegroundColor Green
Write-Host "To change themes later, ask Claude Code: `"switch my statusline theme to glow`" (or hearth / scrubs / default)."
