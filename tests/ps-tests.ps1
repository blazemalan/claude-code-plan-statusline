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

if ($script:Failed) {
    exit 1
}
exit 0