#!/usr/bin/env pwsh

$ErrorActionPreference = "Stop"
$Failed = $false

function Pass($name) {
    Write-Host "$([char]27)[32mPASS$([char]27)[0m $name"
}

function Fail($name, $msg) {
    Write-Host "$([char]27)[31mFAIL$([char]27)[0m $name - $msg"
    $script:Failed = $true
}

function Run-E2E($json, $configContent) {
    $tempHome = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), [System.Guid]::NewGuid().ToString())
    New-Item -ItemType Directory -Path "$tempHome/.claude" | Out-Null
    if ($configContent) {
        Set-Content -Path "$tempHome/.claude/plan-statusline.conf" -Value $configContent
    }

    $env:HOME = $tempHome

    # We call pwsh because the test is already running in pwsh/powershell
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

$json = '{"model":{"display_name":"M"},"rate_limits":{"five_hour":{"used_percentage":42,"resets_at":1746234000}}}'

# Case (a): theme = "glow" with a leading # comment line must render the glow name
$configGlow = "# comment`ntheme = `"glow`""
$res = Run-E2E $json $configGlow
if ($res.out -notmatch '\[1;38;5;199mM') { Fail "glow config" "Did not find expected glow SGR before M, got $($res.out)" } else { Pass "glow config" }

# Case (b): a plain theme=hearth must render the hearth name ([1;38;5;214m)
$configHearth = "theme=hearth"
$res = Run-E2E $json $configHearth
if ($res.out -notmatch '\[1;38;5;214mM') { Fail "hearth config" "Did not find expected hearth SGR before M, got $($res.out)" } else { Pass "hearth config" }

# Case (c): an unknown theme name like theme=zzz must fall through to default and still render the model name M
$configZzz = "theme=zzz"
$res = Run-E2E $json $configZzz
if ($res.out -notmatch 'M') { Fail "zzz config" "Did not fall back and render M, got $($res.out)" } else { Pass "zzz config" }

if ($script:Failed) {
    exit 1
}
exit 0
