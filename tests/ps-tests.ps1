#!/usr/bin/env pwsh

$ErrorActionPreference = "Stop"
$Failed = $false

function Pass($name) {
    Write-Host "`e[32mPASS`e[0m $name"
}

function Fail($name, $msg) {
    Write-Host "`e[31mFAIL`e[0m $name - $msg"
    $script:Failed = $true
}

# --- Test dot-sourcing ---
. ./statusline.ps1

if ($null -eq (Get-Command fmt_size -ErrorAction SilentlyContinue)) {
    Fail "dot-source" "Did not define fmt_size"
} else {
    Pass "dot-source"
}

# --- Test fmt helpers ---

$truncateTests = @(
    @{in='42.9'; out='42'}
    @{in='100'; out='100'}
    @{in='0.5'; out='0'}
    @{in='.5'; out=''}
    @{in=''; out=''}
    @{in=$null; out=''}
    @{in='no_dot'; out='no_dot'}
    @{in=42.9; out='42'}
)
foreach ($t in $truncateTests) {
    $res = truncate_pct $t.in
    if ($res -ne $t.out) { Fail "truncate_pct" "Expected '$($t.out)', got '$res' for $($t.in)" }
}
Pass "truncate_pct"

$costTests = @(
    @{in=1.009058; out='$1.01'}
    @{in=0; out='$0.00'}
    @{in=12.5; out='$12.50'}
    @{in=''; out=''}
)
foreach ($t in $costTests) {
    $res = fmt_cost $t.in
    if ($res -ne $t.out) { Fail "fmt_cost" "Expected '$($t.out)', got '$res'" }
}
Pass "fmt_cost"

$durTests = @(
    @{in=45000; out='45s'}
    @{in=136020; out='2m16s'}
    @{in=3780000; out='1h3m'}
    @{in=0; out='0s'}
    @{in=''; out=''}
)
foreach ($t in $durTests) {
    $res = fmt_duration $t.in
    if ($res -ne $t.out) { Fail "fmt_duration" "Expected '$($t.out)', got '$res'" }
}
Pass "fmt_duration"

$sizeTests = @(
    @{in=248; out='248'}
    @{in=63015; out='63k'}
    @{in=1000000; out='1M'}
    @{in=''; out=''}
)
foreach ($t in $sizeTests) {
    $res = fmt_size $t.in
    if ($res -ne $t.out) { Fail "fmt_size" "Expected '$($t.out)', got '$res'" }
}
Pass "fmt_size"

$circleTests = @(
    @{in=100; out=[char]0x25CF}
    @{in=88; out=[char]0x25CF}
    @{in=63; out=[char]0x25D5}
    @{in=38; out=[char]0x25D1}
    @{in=13; out=[char]0x25D4}
    @{in=12; out=[char]0x25CB}
    @{in=0; out=[char]0x25CB}
    @{in='42.7'; out=[char]0x25D1}
)
foreach ($t in $circleTests) {
    $res = ctx_circle $t.in
    if ($res -ne $t.out) { Fail "ctx_circle" "Expected '$($t.out)', got '$res' for $($t.in)" }
}
Pass "ctx_circle"

# --- Test render_name ---
$script:NAME_SGR = ''
$script:five_pct = ''
$script:week_pct = ''
$res = render_name "Claude"
if ($res -ne "Claude") { Fail "render_name plain" "Expected 'Claude', got '$res'" }
Pass "render_name plain"

$script:NAME_SGR = '1;38;5;214'
$res = render_name "Claude"
if ($res -ne "$([char]27)[1;38;5;214mClaude$([char]27)[0m") { Fail "render_name color" "Got '$res'" }
Pass "render_name color"

$script:five_pct = '100'
$res = render_name "Claude"
if ($res -ne "$([char]27)[2mClaude$([char]27)[0m") { Fail "render_name pegged" "Got '$res'" }
Pass "render_name pegged"
$script:five_pct = ''
$script:NAME_SGR = ''

# --- Test end-to-end via child process ---
function Run-E2E($json, $theme, $epoch, $tz, $noColor) {
    $tempHome = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), [System.Guid]::NewGuid().ToString())
    New-Item -ItemType Directory -Path "$tempHome/.claude" | Out-Null
    if ($theme) {
        Set-Content -Path "$tempHome/.claude/plan-statusline.conf" -Value "theme=$theme"
    }

    $env:HOME = $tempHome
    if ($epoch) { $env:PLAN_SL_NOW = $epoch } else { Remove-Item Env:\PLAN_SL_NOW -ErrorAction SilentlyContinue }
    if ($tz) { $env:TZ = $tz } else { Remove-Item Env:\TZ -ErrorAction SilentlyContinue }
    if ($noColor) { $env:NO_COLOR = $noColor } else { Remove-Item Env:\NO_COLOR -ErrorAction SilentlyContinue }

    # We call pwsh because ps-tests.ps1 is already running in pwsh/powershell
    $pwsh = if ($PSVersionTable.PSVersion.Major -ge 6) { "pwsh" } else { "powershell" }

    $inFile = [System.IO.Path]::Combine($tempHome, "in.json")
    $outFile = [System.IO.Path]::Combine($tempHome, "out.txt")
    $errFile = [System.IO.Path]::Combine($tempHome, "err.txt")

    Set-Content -Path $inFile -Value $json
    $proc = Start-Process -FilePath $pwsh -ArgumentList "-NoProfile", "-File", "statusline.ps1" -RedirectStandardInput $inFile -RedirectStandardOutput $outFile -RedirectStandardError $errFile -PassThru -Wait

    $out = ""
    $err = ""
    try { $out = Get-Content $outFile -Raw -Encoding UTF8 } catch {}
    try { $err = Get-Content $errFile -Raw -Encoding UTF8 } catch {}
    $exitCode = $proc.ExitCode

    Remove-Item -Recurse -Force $tempHome

    return @{out=$out; err=$err; exitCode=$exitCode}
}

# Hearth spot check
$json = '{"model": {"display_name": "Claude"}, "rate_limits": {"five_hour": {"used_percentage": 42}}}'
$res = Run-E2E $json 'hearth'
if ($res.out -notmatch '\[1;38;5;214mClaude') { Fail "e2e hearth" "Model name not amber" }
if ($res.out.Contains("[38;5;214m$([char]0x25D1)") -eq $false) { Fail "e2e hearth" "Circle not amber" }
Pass "e2e hearth"

# Default pending
$res = Run-E2E '{"model": {"display_name": "Claude"}}' ''
if ($res.out -notmatch 'usage data pending') { Fail "e2e pending" "Did not show pending" }
Pass "e2e pending"

# Malformed
$res = Run-E2E 'not json {' ''
if ($res.out -notmatch 'usage data pending') { Fail "e2e malformed" "Did not handle malformed json" }
if ($res.exitCode -ne 0) { Fail "e2e malformed exit" "Exit code $($res.exitCode)" }
Pass "e2e malformed"

# Pegged egg
$json = '{"model": {"display_name": "Claude"}, "rate_limits": {"five_hour": {"used_percentage": 100}}}'
$res = Run-E2E $json 'glow' '1000000000'
if ($res.out -notmatch 'GAME OVER') { Fail "e2e egg even" "Did not show GAME OVER" }
$res = Run-E2E $json 'glow' '1000000001'
if ($res.out -notmatch 'INSERT COIN') { Fail "e2e egg odd" "Did not show INSERT COIN" }
Pass "e2e egg"

# Enterprise
$json = '{"model": {"display_name": "Claude"}, "cost": {"total_cost_usd": 1.009058, "total_duration_ms": 136020, "total_lines_added": 1, "total_lines_removed": 0}, "context_window": {"total_input_tokens": 63015, "total_output_tokens": 248, "used_percentage": 6, "context_window_size": 1000000}}'
$res = Run-E2E $json ''
if ($res.out -notmatch '\$1\.01') { Fail "e2e enterprise" "No cost" }
if ($res.out -notmatch '2m16s') { Fail "e2e enterprise" "No duration" }
if ($res.out -notmatch '\+1/-0') { Fail "e2e enterprise" "No lines" }
if ($res.out -notmatch '63k↑ 248↓') { Fail "e2e enterprise" "No tokens" }
if ($res.out.Contains("$([char]0x25CB)") -eq $false -or $res.out.Contains("6%") -eq $false) { Fail "e2e enterprise" "No ctx" }
Pass "e2e enterprise"

# NO_COLOR: no ANSI, glyphs + layout intact
$json = '{"model": {"display_name": "Opus 4.8"}, "rate_limits": {"five_hour": {"used_percentage": 42, "resets_at": 1746234000}, "seven_day": {"used_percentage": 78, "resets_at": 1746500400}}, "context_window": {"used_percentage": 15, "context_window_size": 1000000}}'
$res = Run-E2E $json '' '1000000001' 'UTC' '1'
if ($res.out.Contains([char]27)) { Fail "no_color" "ANSI ESC leaked under NO_COLOR" }
if ($res.out -notmatch '5h: 42%' -or $res.out -notmatch 'week: 78%' -or $res.out -notmatch '15% of 1M') { Fail "no_color" "layout/values lost: $($res.out)" }
Pass "no_color basic"

$res = Run-E2E $json 'scrubs' '1000000000' 'UTC' '1'
if ($res.out.Contains([char]27)) { Fail "no_color scrubs" "ANSI ESC leaked" }
Pass "no_color scrubs"

# pegged egg under NO_COLOR keeps its words, drops color
$pegged = '{"model": {"display_name": "M"}, "rate_limits": {"five_hour": {"used_percentage": 100, "resets_at": 1746234000}}}'
$res = Run-E2E $pegged 'scrubs' '1000000000' 'UTC' '1'
if ($res.out.Contains([char]27)) { Fail "no_color egg" "ANSI ESC leaked" }
if ($res.out -notmatch 'CODE BLUE' -or $res.out -notmatch 'defib') { Fail "no_color egg" "egg word lost: $($res.out)" }
Pass "no_color egg"

# --- Model-scoped weekly windows (model_weekly) ---
# Mirrors the iso_to_epoch / sanitize_label cases in tests/unit.sh one for one;
# any divergence here is a byte-parity break.
$isoTests = @(
    @{in='2026-08-16T03:00:00.336012+00:00'; out='1786849200'}
    @{in='1970-01-01T00:00:00Z';             out='0'}
    @{in='2000-02-29T12:00:00Z';             out='951825600'}
    @{in='2026-08-15T20:00:00-07:00';        out='1786849200'}
    @{in='2026-08-15T20:00:00-0700';         out='1786849200'}
    @{in='2026-08-16T08:30:00+05:30';        out='1786849200'}
    @{in='1999-01-01T00:00:00';              out='915148800'}
    @{in='1999-01-01 00:00:00';              out='915148800'}
    @{in='2024-12-31T23:59:59Z';             out='1735689599'}
    @{in='2026-01-15T00:00:00Z';             out='1768435200'}
    @{in='2026-02-15T00:00:00Z';             out='1771113600'}
    @{in='2026-08-09T08:09:08Z';             out='1786262948'}
    @{in='garbage';                          out=''}
    @{in='';                                 out=''}
    @{in=$null;                              out=''}
    @{in='2026-13-01T00:00:00Z';             out=''}
    @{in='2026-01-32T00:00:00Z';             out=''}
    @{in='2026-01-01T24:00:00Z';             out=''}
    @{in='2026-08-16';                       out=''}
)
foreach ($t in $isoTests) {
    $res = Iso-ToEpoch $t.in
    if ($res -ne $t.out) { Fail "Iso-ToEpoch" "Expected '$($t.out)', got '$res' for '$($t.in)'" }
}
Pass "Iso-ToEpoch"

$lblTests = @(
    @{in='Fable';               out='fable'}
    @{in='Opus 4.8';            out='opus 4.8'}
    @{in='ReallyLongModelName'; out='reallylongmo'}
    @{in="Ev$([char]27)[31mil"; out='ev31mil'}
    @{in="a`tb`nc";             out='abc'}
    @{in='Fable' + [char]0x2122; out='fable'}
    @{in="$([char]27)]0;x$([char]7)"; out='0x'}
    @{in='';                    out=''}
    @{in=$null;                 out=''}
)
foreach ($t in $lblTests) {
    $res = Sanitize-Label $t.in
    if ($res -ne $t.out) { Fail "Sanitize-Label" "Expected '$($t.out)', got '$res' for '$($t.in)'" }
}
Pass "Sanitize-Label"

# End-to-end, with a stand-in for Claude Code's ~/.claude.json.
function Run-E2E-Scoped($json, $confBody, $scopedJsonPath, $epoch, $tz, $noColor) {
    $tempHome = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), [System.Guid]::NewGuid().ToString())
    New-Item -ItemType Directory -Path "$tempHome/.claude" | Out-Null
    if ($confBody) { Set-Content -Path "$tempHome/.claude/plan-statusline.conf" -Value $confBody }
    if ($scopedJsonPath) { Copy-Item $scopedJsonPath "$tempHome/.claude.json" }

    $env:HOME = $tempHome
    if ($epoch) { $env:PLAN_SL_NOW = $epoch } else { Remove-Item Env:\PLAN_SL_NOW -ErrorAction SilentlyContinue }
    if ($tz) { $env:TZ = $tz } else { Remove-Item Env:\TZ -ErrorAction SilentlyContinue }
    if ($noColor) { $env:NO_COLOR = $noColor } else { Remove-Item Env:\NO_COLOR -ErrorAction SilentlyContinue }

    $pwsh = if ($PSVersionTable.PSVersion.Major -ge 6) { "pwsh" } else { "powershell" }
    $inFile = [System.IO.Path]::Combine($tempHome, "in.json")
    $outFile = [System.IO.Path]::Combine($tempHome, "out.txt")
    $errFile = [System.IO.Path]::Combine($tempHome, "err.txt")
    Set-Content -Path $inFile -Value $json
    $proc = Start-Process -FilePath $pwsh -ArgumentList "-NoProfile", "-File", "statusline.ps1" -RedirectStandardInput $inFile -RedirectStandardOutput $outFile -RedirectStandardError $errFile -PassThru -Wait
    $out = ""; $err = ""
    try { $out = Get-Content $outFile -Raw -Encoding UTF8 } catch {}
    try { $err = Get-Content $errFile -Raw -Encoding UTF8 } catch {}
    $exitCode = $proc.ExitCode
    Remove-Item -Recurse -Force $tempHome
    return @{out=$out; err=$err; exitCode=$exitCode}
}

$scopedSrc = Join-Path $PSScriptRoot 'scoped-claude-config.json'
$planJson = '{"model": {"display_name": "M"}, "rate_limits": {"five_hour": {"used_percentage": 42, "resets_at": 1746234000}, "seven_day": {"used_percentage": 50, "resets_at": 1746500400}}}'

# Off by default even though the file is present and readable.
$res = Run-E2E-Scoped $planJson "theme=default" $scopedSrc '1786663300' 'UTC' '1'
if ($res.out -match 'fable') { Fail "model_weekly off" "Rendered while disabled: $($res.out)" }
Pass "model_weekly off by default"

# On: renders after the all-models week, ISO reset resolves to a weekday.
$res = Run-E2E-Scoped $planJson "theme=default`nmodel_weekly=on" $scopedSrc '1786663300' 'UTC' '1'
if ($res.exitCode -ne 0) { Fail "model_weekly on" "exit $($res.exitCode)" }
if ($res.err) { Fail "model_weekly on" "stderr: $($res.err)" }
if ($res.out -notmatch 'week: 50%.*fable: 21%') { Fail "model_weekly on" "not rendered after week: $($res.out)" }
# Must be a real weekday, not just an open paren: 'fable: 21% (' also matches the
# empty '(->)' clause, which is exactly what the gotcha-10 PS 7 [datetime]
# regression produced — the whole suite passed while the reset silently vanished.
if ($res.out -notmatch 'fable: 21% \(\u2192(mon|tue|wed|thu|fri|sat|sun)\)') { Fail "model_weekly on" "reset weekday missing: $($res.out)" }
if ($res.out -notmatch 'sonnet: 7%') { Fail "model_weekly on" "fractional pct wrong: $($res.out)" }
if ($res.out -notmatch 'opus31m 4\.8-:') { Fail "model_weekly on" "label not sanitised: $($res.out)" }
if ($res.out -match 'dropped') { Fail "model_weekly on" "3-record cap not applied: $($res.out)" }
if ($res.out.Contains([char]27)) { Fail "model_weekly on" "ESC leaked from label under NO_COLOR" }
Pass "model_weekly on"

# Missing file / malformed file degrade to "segment absent", never a broken line.
$res = Run-E2E-Scoped $planJson "theme=default`nmodel_weekly=on" $null '1786663300' 'UTC' '1'
if ($res.exitCode -ne 0 -or $res.err) { Fail "model_weekly missing file" "rc=$($res.exitCode) err=$($res.err)" }
if ($res.out -notmatch 'week: 50%' -or $res.out -match 'fable') { Fail "model_weekly missing file" "$($res.out)" }
Pass "model_weekly missing file"

$badDir = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), [System.Guid]::NewGuid().ToString())
New-Item -ItemType Directory -Path $badDir | Out-Null
$badFile = Join-Path $badDir 'bad.json'
Set-Content -Path $badFile -Value 'not json {'
$res = Run-E2E-Scoped $planJson "theme=default`nmodel_weekly=on" $badFile '1786663300' 'UTC' '1'
if ($res.exitCode -ne 0 -or $res.err) { Fail "model_weekly malformed" "rc=$($res.exitCode) err=$($res.err)" }
if ($res.out -notmatch 'week: 50%' -or $res.out -match 'fable') { Fail "model_weekly malformed" "$($res.out)" }
Remove-Item -Recurse -Force $badDir
Pass "model_weekly malformed file"

# Separator injection: a display_name carrying the \x1f/\x1e delimiters the bash
# side re-splits on used to forge extra windows there (with an attacker-chosen
# 100% that fired the pegged egg) while this implementation rendered one. Both
# must now render exactly one window at the real percentage.
$injSrc = Join-Path $PSScriptRoot 'scoped-injection.json'
$res = Run-E2E-Scoped $planJson "theme=default`nmodel_weekly=on" $injSrc '1786663300' 'UTC' '1'
if ($res.exitCode -ne 0 -or $res.err) { Fail "model_weekly injection" "rc=$($res.exitCode) err=$($res.err)" }
if ($res.out -match '100%' -or $res.out -match 'respawn') { Fail "model_weekly injection" "forged window: $($res.out)" }
if ($res.out -notmatch 'fable999inje: 21%') { Fail "model_weekly injection" "real window lost: $($res.out)" }
if (($res.out -split [char]0x2502).Count -ne 4) { Fail "model_weekly injection" "expected exactly one scoped segment: $($res.out)" }
if ($res.out -match '\p{Cc}' -and $res.out -notmatch '^[^\p{Cc}]*\n?$') { Fail "model_weekly injection" "control byte reached stdout" }
Pass "model_weekly separator injection"

# Enterprise payloads carry no rate_limits, so plan-mode segments stay out.
$entJson = '{"model": {"display_name": "M"}, "cost": {"total_cost_usd": 1.01}}'
$res = Run-E2E-Scoped $entJson "theme=default`nmodel_weekly=on" $scopedSrc '1786663300' 'UTC' '1'
if ($res.out -match 'fable') { Fail "model_weekly enterprise" "leaked into Enterprise mode: $($res.out)" }
Pass "model_weekly absent in Enterprise mode"

if ($script:Failed) {
    exit 1
}
exit 0