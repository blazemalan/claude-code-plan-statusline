param()

$ESC = [char]27
# Honors NO_COLOR (https://no-color.org): any non-empty value suppresses all ANSI.
$script:NoColor = -not [string]::IsNullOrEmpty($env:NO_COLOR)

# Rainbow Road: a global hue cursor (HUE) advances once per painted unit so the
# colors sweep along the line; RAINBOW_PHASE (now_epoch * speed, set in render_line)
# offsets the wheel each repaint so the rainbow flows. Only the 'rainbow' theme sets
# RAINBOW; every other theme leaves these inert.
$script:RAINBOW_PALETTE = @(196,202,208,214,220,226,190,154,118,82,46,47,48,49,50,51,45,39,33,27,21,57,93,129,165,201,200,199,198,197)
$script:HUE = 0
$script:RAINBOW_PHASE = 0
$script:RAINBOW_SPEED = 1
$script:_RAINBOW_SGR = ''
$script:RAINBOW = ''
$script:SEP_ANIM = ''
# Model-scoped weekly windows: array of @(label, percent, resets_at_iso).
# Stays empty unless the opt-in model_weekly config key is on.
$script:scopedWindows = @()
$script:MODEL_WEEKLY = $false

function date_fmt($epoch, $fmt) {
    # Not used directly in PS, handled locally
}

function fmt_time($epoch) {
    if ([string]::IsNullOrEmpty($epoch)) { return '' }
    $n = 0
    if ([long]::TryParse($epoch, [ref]$n)) {
        return [DateTimeOffset]::FromUnixTimeSeconds($n).ToLocalTime().ToString('h:mmtt', [System.Globalization.CultureInfo]::InvariantCulture).ToLowerInvariant()
    }
    return ''
}

function fmt_size($n) {
    if ([string]::IsNullOrEmpty($n)) { return '' }
    $num = 0
    if (-not [long]::TryParse($n, [ref]$num)) { $num = 0 }
    if ($num -ge 1000000) { return "$([math]::Truncate($num / 1000000))M" }
    if ($num -ge 1000) { return "$([math]::Truncate($num / 1000))k" }
    return "$num"
}

function fmt_cost($usd) {
    if ([string]::IsNullOrEmpty($usd)) { return '' }
    $num = 0.0
    if ([double]::TryParse($usd, [System.Globalization.NumberStyles]::Any, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$num)) {
        return '$' + $num.ToString('F2', [System.Globalization.CultureInfo]::InvariantCulture)
    }
    return ''
}

function fmt_duration($ms) {
    if ([string]::IsNullOrEmpty($ms)) { return '' }
    $n = 0
    if (-not [long]::TryParse($ms, [ref]$n)) { $n = 0 }
    $s = [math]::Truncate($n / 1000)
    if ($s -ge 3600) { return "$([math]::Truncate($s / 3600))h$([math]::Truncate(($s % 3600) / 60))m" }
    if ($s -ge 60) { return "$([math]::Truncate($s / 60))m$($s % 60)s" }
    return "${s}s"
}

function now_epoch() {
    if (-not [string]::IsNullOrEmpty($env:PLAN_SL_NOW)) {
        $n = 0
        if ([long]::TryParse($env:PLAN_SL_NOW, [ref]$n)) { return $n }
    }
    return [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
}

# ISO-8601 -> epoch seconds. Mirrors bash's iso_to_epoch: the same integer
# days_from_civil math rather than [DateTimeOffset]::Parse, because the two
# implementations must agree byte for byte and .NET's parser and BSD/GNU date
# disagree about fractional seconds and offset formats. A missing offset is UTC.
# Returns '' when the string does not parse.
function Iso-ToEpoch($s) {
    if ([string]::IsNullOrEmpty($s)) { return '' }
    # [0-9], never \d: .NET's \d matches every Unicode decimal digit (Arabic-Indic
    # U+0660-0669 and friends) where bash's [0-9] matches ASCII only. Such a string
    # matched here and then threw on the [long] cast — onto stderr, which this
    # script must never write to — while bash simply declined to parse it.
    if ($s -notmatch '^([0-9]{4})-([0-9]{2})-([0-9]{2})[Tt ]([0-9]{2}):([0-9]{2}):([0-9]{2})') { return '' }
    $Y = [long]$matches[1]; $M = [long]$matches[2]; $D = [long]$matches[3]
    $h = [long]$matches[4]; $mi = [long]$matches[5]; $se = [long]$matches[6]
    # Y is bounded too: an unbounded year builds an epoch outside the range
    # [DateTimeOffset]::FromUnixTimeSeconds accepts and fmt_when would throw.
    if ($Y -lt 1970 -or $Y -gt 2200) { return '' }
    if ($M -lt 1 -or $M -gt 12 -or $D -lt 1 -or $D -gt 31 -or $h -gt 23 -or $mi -gt 59 -or $se -gt 60) { return '' }
    # NOTE: the offset match below overwrites $matches, so the fields above are read first.
    $off = [long]0
    if ($s -match '([+-])([0-9]{2}):?([0-9]{2})$') {
        $off = ([long]$matches[2] * 3600) + ([long]$matches[3] * 60)
        if ($matches[1] -eq '-') { $off = 0 - $off }
    }
    $y = $Y
    if ($M -le 2) { $y = $y - 1 }
    # Every division here floors, matching bash's truncating integer arithmetic
    # (PowerShell's '/' yields a double and would round on cast).
    $era = [long][math]::Floor($y / 400.0)
    $yoe = $y - ($era * 400)
    if ($M -gt 2) { $mAdj = -3 } else { $mAdj = 9 }
    $doy = [long][math]::Floor(((153 * ($M + $mAdj)) + 2) / 5.0) + $D - 1
    $doe = ($yoe * 365) + [long][math]::Floor($yoe / 4.0) - [long][math]::Floor($yoe / 100.0) + $doy
    $days = ($era * 146097) + $doe - 719468
    $epoch = ($days * 86400) + ($h * 3600) + ($mi * 60) + $se - $off
    return $epoch.ToString([System.Globalization.CultureInfo]::InvariantCulture)
}

# Drop control characters from a server-supplied field. Mirrors the
# gsub("[[:cntrl:]]") applied inside load_scoped_weekly's jq filter in
# statusline.sh, where it is load-bearing: bash re-splits the extracted fields on
# \x1f/\x1e, so a display_name containing one of those delimiters would forge
# extra windows with attacker-chosen percentages while this implementation, which
# keeps a real array, showed a single correct one. Applied here too so both sides
# see identical field values.
function Strip-Controls($s) {
    if ([string]::IsNullOrEmpty($s)) { return '' }
    return [System.Text.RegularExpressions.Regex]::Replace($s, '\p{Cc}', '')
}

# Bound and de-fang the server-supplied model label before it reaches the
# terminal (no ESC, no control bytes, no multibyte). Empty = unrenderable.
function Sanitize-Label($s) {
    if ([string]::IsNullOrEmpty($s)) { return '' }
    $t = [System.Text.RegularExpressions.Regex]::Replace($s, '[^A-Za-z0-9 ._-]', '')
    if ($t.Length -gt 12) { $t = $t.Substring(0, 12) }
    return $t.ToLowerInvariant()
}

function fmt_when($epoch) {
    if ([string]::IsNullOrEmpty($epoch)) { return '' }
    $n = 0
    if ([long]::TryParse($epoch, [ref]$n)) {
        $now = now_epoch
        $dtEpoch = [DateTimeOffset]::FromUnixTimeSeconds($n).ToLocalTime()
        $dtNow = [DateTimeOffset]::FromUnixTimeSeconds($now).ToLocalTime()

        if ($dtEpoch.ToString('yyyy-MM-dd') -eq $dtNow.ToString('yyyy-MM-dd')) {
            return fmt_time $epoch
        } else {
            return $dtEpoch.ToString('ddd', [System.Globalization.CultureInfo]::InvariantCulture).ToLowerInvariant()
        }
    }
    return ''
}

function truncate_pct($pct) {
    if ([string]::IsNullOrEmpty($pct)) { return '' }
    if ($pct -isnot [string]) { $pct = $pct.ToString() }; $idx = $pct.LastIndexOf('.')
    if ($idx -ge 0) { return $pct.Substring(0, $idx) }
    return $pct
}

function ctx_circle($pctraw) {
    $pct = truncate_pct $pctraw
    if ([string]::IsNullOrEmpty($pct)) { return '' }
    $n = 0
    if ([long]::TryParse($pct, [ref]$n)) {
        if ($n -ge 88) { return '●' }
        if ($n -ge 63) { return '◕' }
        if ($n -ge 38) { return '◑' }
        if ($n -ge 13) { return '◔' }
        return '○'
    }
    return '○'
}

function limit_pegged() {
    $five = truncate_pct $script:five_pct
    if (-not [string]::IsNullOrEmpty($five)) {
        $n = 0; if (-not [long]::TryParse($five, [ref]$n)) { $n = 0 }
        if ($n -ge 100) { return $true }
    }
    $week = truncate_pct $script:week_pct
    if (-not [string]::IsNullOrEmpty($week)) {
        $n = 0; if (-not [long]::TryParse($week, [ref]$n)) { $n = 0 }
        if ($n -ge 100) { return $true }
    }
    # An exhausted model-scoped week blocks real work too, so it pegs the same
    # way (inert unless model_weekly is on - scopedWindows is empty otherwise).
    foreach ($w in @($script:scopedWindows)) {
        $p = truncate_pct $w[1]
        if ([string]::IsNullOrEmpty($p)) { continue }
        $n = 0; if (-not [long]::TryParse($p, [ref]$n)) { $n = 0 }
        if ($n -ge 100) { return $true }
    }
    return $false
}

function render_name($text) {
    if ([string]::IsNullOrEmpty($text)) { return '' }
    if ($script:NoColor) { return $text }
    if (limit_pegged) {
        return "${ESC}[2m${text}${ESC}[0m"
    }
    if (-not [string]::IsNullOrEmpty($script:RAINBOW)) {
        $res = foreach ($ch in $text.ToCharArray()) {
            rainbow_next
            "${ESC}[$($script:_RAINBOW_SGR)m$ch${ESC}[0m"
        }
        return $res -join ''
    }
    if (-not [string]::IsNullOrEmpty($script:NAME_SGR)) {
        return "${ESC}[$($script:NAME_SGR)m${text}${ESC}[0m"
    }
    return $text
}

function Theme-Default() {
    $script:TIER_CALM = '32'; $script:TIER_WARN = '33'; $script:TIER_HOT = '38;5;208'; $script:TIER_URGENT = '31'
    $script:NAME_SGR = '1'
    $script:SEP = ' │ '; $script:SEP_COLOR = ''
    $script:META = ''
    $script:SEG_CIRCLE = 0; $script:LABEL_SEP = ':'
    $script:CIRCLE_SGR = '@tier'; $script:LABEL_SGR = '@tier'
    $script:EGG_GLYPH = ''; $script:EGG_GLYPH_COLOR = ''
    $script:EGG_MSG_A = '100% 💀'; $script:EGG_COLOR_A = '31'
    $script:EGG_MSG_B = '100% 💀'; $script:EGG_COLOR_B = '31'
    $script:EGG_RESET_WORD = 'respawn'
}

function Theme-Hearth() {
    $script:TIER_CALM = ''; $script:TIER_WARN = ''; $script:TIER_HOT = '38;5;208'; $script:TIER_URGENT = '1;38;5;196'
    $script:NAME_SGR = '1;38;5;214'
    $script:SEP = ' · '; $script:SEP_COLOR = '2'
    $script:META = '2;3'
    $script:SEG_CIRCLE = 1; $script:LABEL_SEP = ''
    $script:CIRCLE_SGR = '38;5;214'; $script:LABEL_SGR = ''
    $script:EGG_GLYPH = '○'; $script:EGG_GLYPH_COLOR = '2'
    $script:EGG_MSG_A = 'burnt out'; $script:EGG_COLOR_A = '1;38;5;196'
    $script:EGG_MSG_B = 'burnt out'; $script:EGG_COLOR_B = '1;38;5;196'
    $script:EGG_RESET_WORD = 'rekindles'
}

function Theme-Glow() {
    $script:TIER_CALM = '1;38;5;41'; $script:TIER_WARN = '1;38;5;205'; $script:TIER_HOT = '1;38;5;199'; $script:TIER_URGENT = '1;38;5;197'
    $script:NAME_SGR = '1;38;5;199'
    $script:SEP = ' · '; $script:SEP_COLOR = '2'
    $script:META = '3;38;5;175'
    $script:SEG_CIRCLE = 1; $script:LABEL_SEP = ''
    $script:CIRCLE_SGR = '@tier'; $script:LABEL_SGR = '@tier'
    $script:EGG_GLYPH = ''; $script:EGG_GLYPH_COLOR = ''
    $script:EGG_MSG_A = 'GAME OVER'; $script:EGG_COLOR_A = '1;38;5;197'
    $script:EGG_MSG_B = 'INSERT COIN'; $script:EGG_COLOR_B = '1;38;5;199'
    $script:EGG_RESET_WORD = '1UP'
}

function Theme-Scrubs() {
    $script:TIER_CALM = '38;5;30'; $script:TIER_WARN = '1;38;5;37'; $script:TIER_HOT = '38;5;214'; $script:TIER_URGENT = '1;38;5;196'
    $script:NAME_SGR = '1;38;5;37'
    $script:SEP = ' · '; $script:SEP_COLOR = '2'
    $script:META = '3;38;5;152'
    $script:SEG_CIRCLE = 1; $script:LABEL_SEP = ''
    $script:CIRCLE_SGR = '@tier'; $script:LABEL_SGR = '@tier'
    $script:EGG_GLYPH = ''; $script:EGG_GLYPH_COLOR = ''
    $script:EGG_MSG_A = 'CODE BLUE'; $script:EGG_COLOR_A = '1;38;5;196'
    $script:EGG_MSG_B = '▁▁▁▁▁▁▁▁▁'; $script:EGG_COLOR_B = '1;38;5;196'
    $script:EGG_RESET_WORD = 'defib'
}

function Theme-Harbor() {
    $script:TIER_CALM = ''; $script:TIER_WARN = ''; $script:TIER_HOT = '38;5;215'; $script:TIER_URGENT = '1;38;5;196'
    $script:NAME_SGR = '1;38;5;39'
    $script:SEP = ' · '; $script:SEP_COLOR = '38;5;24'
    $script:META = '2;3;38;5;67'
    $script:SEG_CIRCLE = 1; $script:LABEL_SEP = ''
    $script:CIRCLE_SGR = '38;5;38'; $script:LABEL_SGR = ''
    $script:EGG_GLYPH = '≈'; $script:EGG_GLYPH_COLOR = '1;38;5;196'
    $script:EGG_MSG_A = 'storm warning'; $script:EGG_COLOR_A = '1;38;5;196'
    $script:EGG_MSG_B = 'storm warning'; $script:EGG_COLOR_B = '1;38;5;196'
    $script:EGG_RESET_WORD = 'fair winds'
}

function Theme-Atomic() {
    $script:TIER_CALM = '38;5;43'; $script:TIER_WARN = '38;5;178'; $script:TIER_HOT = '1;38;5;208'; $script:TIER_URGENT = '1;38;5;196'
    $script:NAME_SGR = '1;38;5;208'
    $script:SEP = ' ✦ '; $script:SEP_COLOR = '38;5;143'
    $script:META = '2;3;38;5;73'
    $script:SEG_CIRCLE = 1; $script:LABEL_SEP = ''
    $script:CIRCLE_SGR = '@tier'; $script:LABEL_SGR = '@tier'
    $script:EGG_GLYPH = '✷'; $script:EGG_GLYPH_COLOR = '1;38;5;208'
    $script:EGG_MSG_A = 'KABOOM!'; $script:EGG_COLOR_A = '1;38;5;196'
    $script:EGG_MSG_B = 'KA-BLAM!'; $script:EGG_COLOR_B = '1;38;5;208'
    $script:EGG_RESET_WORD = 'rebuild'
}

function Theme-Slime() {
    $script:TIER_CALM = '38;5;71'; $script:TIER_WARN = '38;5;76'; $script:TIER_HOT = '1;38;5;118'; $script:TIER_URGENT = '1;38;5;154'
    $script:NAME_SGR = '1;38;5;118'
    $script:SEP = ' · '; $script:SEP_COLOR = '38;5;65'
    $script:SEP_ANIM = '˙|·|.| '
    $script:META = '2;3;38;5;65'
    $script:SEG_CIRCLE = 1; $script:LABEL_SEP = ''
    $script:CIRCLE_SGR = '@tier'; $script:LABEL_SGR = '@tier'
    $script:EGG_GLYPH = ''; $script:EGG_GLYPH_COLOR = ''
    $script:EGG_MSG_A = 'SLIMED!'; $script:EGG_COLOR_A = '1;38;5;118'
    $script:EGG_MSG_B = 'GLOOP!'; $script:EGG_COLOR_B = '1;38;5;154'
    $script:EGG_RESET_WORD = 'drains'
}

function Theme-Rainbow() {
    $script:RAINBOW = '1'
    $script:TIER_CALM = ''; $script:TIER_WARN = ''; $script:TIER_HOT = ''; $script:TIER_URGENT = ''
    $script:NAME_SGR = ''
    $script:SEP = ' · '; $script:SEP_COLOR = ''
    $script:META = '1'
    $script:SEG_CIRCLE = 1; $script:LABEL_SEP = ''
    $script:CIRCLE_SGR = '@tier'; $script:LABEL_SGR = '@tier'
    $script:EGG_GLYPH = ''; $script:EGG_GLYPH_COLOR = ''
    $script:EGG_MSG_A = 'OFF THE EDGE!'; $script:EGG_COLOR_A = '1;38;5;196'
    $script:EGG_MSG_B = 'LAKITU!'; $script:EGG_COLOR_B = '1;38;5;51'
    $script:EGG_RESET_WORD = 'Lakitu'
}

# --- Palettes ported from Oh My Posh themes (truecolor 38;2;R;G;B = exact hex). ---

function Theme-Dracula() {
    $script:TIER_CALM = '38;2;80;250;123'; $script:TIER_WARN = '38;2;139;233;253'; $script:TIER_HOT = '1;38;2;255;121;198'; $script:TIER_URGENT = '1;38;2;255;85;85'
    $script:NAME_SGR = '1;38;2;189;147;249'
    $script:SEP = ' · '; $script:SEP_COLOR = '38;2;98;114;164'
    $script:META = '3;38;2;98;114;164'
    $script:SEG_CIRCLE = 1; $script:LABEL_SEP = ''
    $script:CIRCLE_SGR = '@tier'; $script:LABEL_SGR = '@tier'
    $script:EGG_GLYPH = ''; $script:EGG_GLYPH_COLOR = ''
    $script:EGG_MSG_A = 'DRAINED!'; $script:EGG_COLOR_A = '1;38;2;255;85;85'
    $script:EGG_MSG_B = 'BLED DRY'; $script:EGG_COLOR_B = '1;38;2;189;147;249'
    $script:EGG_RESET_WORD = 'sunrise'
}

function Theme-Nord() {
    $script:TIER_CALM = '38;2;163;190;140'; $script:TIER_WARN = '38;2;129;161;193'; $script:TIER_HOT = '38;2;235;203;139'; $script:TIER_URGENT = '1;38;2;191;97;106'
    $script:NAME_SGR = '1;38;2;136;192;208'
    $script:SEP = ' · '; $script:SEP_COLOR = '38;2;76;86;106'
    $script:META = '3;38;2;76;86;106'
    $script:SEG_CIRCLE = 1; $script:LABEL_SEP = ''
    $script:CIRCLE_SGR = '@tier'; $script:LABEL_SGR = '@tier'
    $script:EGG_GLYPH = ''; $script:EGG_GLYPH_COLOR = ''
    $script:EGG_MSG_A = 'FROZEN SOLID'; $script:EGG_COLOR_A = '1;38;2;191;97;106'
    $script:EGG_MSG_B = 'WHITEOUT'; $script:EGG_COLOR_B = '1;38;2;236;239;244'
    $script:EGG_RESET_WORD = 'thaws'
}

function Theme-Gruvbox() {
    $script:TIER_CALM = '38;2;184;187;38'; $script:TIER_WARN = '38;2;142;192;124'; $script:TIER_HOT = '1;38;2;254;128;25'; $script:TIER_URGENT = '1;38;2;251;73;52'
    $script:NAME_SGR = '1;38;2;250;189;47'
    $script:SEP = ' · '; $script:SEP_COLOR = '38;2;146;131;116'
    $script:META = '3;38;2;146;131;116'
    $script:SEG_CIRCLE = 1; $script:LABEL_SEP = ''
    $script:CIRCLE_SGR = '@tier'; $script:LABEL_SGR = '@tier'
    $script:EGG_GLYPH = ''; $script:EGG_GLYPH_COLOR = ''
    $script:EGG_MSG_A = 'SCORCHED'; $script:EGG_COLOR_A = '1;38;2;251;73;52'
    $script:EGG_MSG_B = 'BURNT TOAST'; $script:EGG_COLOR_B = '1;38;2;254;128;25'
    $script:EGG_RESET_WORD = 'regrows'
}

function Theme-Catppuccin() {
    $script:TIER_CALM = '38;2;166;227;161'; $script:TIER_WARN = '38;2;148;226;213'; $script:TIER_HOT = '1;38;2;250;179;135'; $script:TIER_URGENT = '1;38;2;243;139;168'
    $script:NAME_SGR = '1;38;2;203;166;247'
    $script:SEP = ' · '; $script:SEP_COLOR = '38;2;108;112;134'
    $script:META = '3;38;2;108;112;134'
    $script:SEG_CIRCLE = 1; $script:LABEL_SEP = ''
    $script:CIRCLE_SGR = '@tier'; $script:LABEL_SGR = '@tier'
    $script:EGG_GLYPH = ''; $script:EGG_GLYPH_COLOR = ''
    $script:EGG_MSG_A = 'OVERBREWED'; $script:EGG_COLOR_A = '1;38;2;243;139;168'
    $script:EGG_MSG_B = 'HISS!'; $script:EGG_COLOR_B = '1;38;2;203;166;247'
    $script:EGG_RESET_WORD = 'refills'
}

function rainbow_next() {
    $n = $script:RAINBOW_PALETTE.Count
    $idx = (($script:HUE + $script:RAINBOW_PHASE) % $n)
    $script:_RAINBOW_SGR = "1;38;5;$($script:RAINBOW_PALETTE[$idx])"
    $script:HUE = $script:HUE + 1
}

function paint($sgr, $text) {
    if ((-not [string]::IsNullOrEmpty($script:RAINBOW)) -and (-not $script:NoColor)) {
        if ($text -match '^[\x20-\x7e]*$') {
            $res = foreach ($ch in $text.ToCharArray()) {
                rainbow_next
                "${ESC}[$($script:_RAINBOW_SGR)m$ch${ESC}[0m"
            }
            return $res -join ''
        } else {
            rainbow_next
            return "${ESC}[$($script:_RAINBOW_SGR)m${text}${ESC}[0m"
        }
    }
    if ((-not [string]::IsNullOrEmpty($sgr)) -and (-not $script:NoColor)) {
        return "${ESC}[${sgr}m${text}${ESC}[0m"
    }
    return $text
}

function paint_sep() {
    if (-not [string]::IsNullOrEmpty($script:SEP_ANIM)) {
        $frames = $script:SEP_ANIM -split '\|'
        $now = now_epoch
        $idx = $now % $frames.Count
        return paint $script:SEP_COLOR " $($frames[$idx]) "
    }
    return paint $script:SEP_COLOR $script:SEP
}

function tier_color($pctraw) {
    $pct = truncate_pct $pctraw
    if ([string]::IsNullOrEmpty($pct)) { return '' }
    $n = 0
    if ([long]::TryParse($pct, [ref]$n)) {
        if ($n -ge 90) { return $script:TIER_URGENT }
        if ($n -ge 70) { return $script:TIER_HOT }
        if ($n -ge 50) { return $script:TIER_WARN }
        return $script:TIER_CALM
    }
    return $script:TIER_CALM
}

function cost_tier_color($usd) {
    if ([string]::IsNullOrEmpty($usd)) { return '' }
    $dollars = truncate_pct $usd
    if ([string]::IsNullOrEmpty($dollars)) { $dollars = '0' }
    $n = 0
    if ([long]::TryParse($dollars, [ref]$n)) {
        if ($n -ge 10) { return $script:TIER_URGENT }
        if ($n -ge 5) { return $script:TIER_HOT }
        if ($n -ge 2) { return $script:TIER_WARN }
        return $script:TIER_CALM
    }
    return $script:TIER_CALM
}

function meta_sgr($tier) {
    if (-not [string]::IsNullOrEmpty($script:META)) { return $script:META }
    return $tier
}

function span_sgr($sgr, $tier) {
    if ($sgr -eq '@tier') { return $tier }
    return $sgr
}

function seg_rate($label, $pctraw, $reset_str) {
    $pct = truncate_pct $pctraw
    $n = 0
    if ([long]::TryParse($pct, [ref]$n) -and $n -ge 100) {
        return egg $label $reset_str
    }

    $tier = tier_color $pct
    $res = ""
    if ($script:SEG_CIRCLE -eq 1) {
        $res += paint (span_sgr $script:CIRCLE_SGR $tier) (ctx_circle $pct)
        $res += ' '
    }
    $res += paint (span_sgr $script:LABEL_SGR $tier) "${label}$($script:LABEL_SEP)"
    $res += ' '
    $res += paint $tier "${pct}%"
    $res += ' '
    $res += paint (meta_sgr '') "(→${reset_str})"
    return $res
}

function seg_ctx($pctraw, $size) {
    $pct = truncate_pct $pctraw
    $tier = tier_color $pct
    $res = ""
    $res += paint (span_sgr $script:CIRCLE_SGR $tier) (ctx_circle $pct)
    $res += ' '
    $res += paint $tier "${pct}%"
    if (-not [string]::IsNullOrEmpty($size)) {
        $res += paint (meta_sgr $tier) $size
    }
    return $res
}

function egg($label, $reset_str) {
    $now = now_epoch
    $msg = ""
    $col = ""
    if (($now % 2 -eq 1) -and ($script:EGG_MSG_A -ne $script:EGG_MSG_B)) {
        $msg = $script:EGG_MSG_B
        $col = $script:EGG_COLOR_B
    } else {
        $msg = $script:EGG_MSG_A
        $col = $script:EGG_COLOR_A
    }

    $res = ""
    if (-not [string]::IsNullOrEmpty($script:EGG_GLYPH)) {
        if ($script:NoColor) { $res += "$($script:EGG_GLYPH) " }
        else { $res += "${ESC}[$($script:EGG_GLYPH_COLOR)m$($script:EGG_GLYPH)${ESC}[0m " }
    }

    $lblcol = ""
    if (-not [string]::IsNullOrEmpty($script:LABEL_SGR)) {
        $lblcol = $col
    }

    $res += paint $lblcol "${label}$($script:LABEL_SEP)"
    $res += ' '
    $res += paint $col $msg
    $res += ' '

    if (-not [string]::IsNullOrEmpty($script:META)) {
        $res += paint $script:META "($($script:EGG_RESET_WORD) →${reset_str})"
    } else {
        $res += "($($script:EGG_RESET_WORD) →${reset_str})"
    }
    return $res
}

function render_line() {
    if (-not [string]::IsNullOrEmpty($script:RAINBOW)) {
        $script:HUE = 0
        $script:RAINBOW_PHASE = (now_epoch) * $script:RAINBOW_SPEED
    }
    if ([string]::IsNullOrEmpty($script:ctx_pct) -and [string]::IsNullOrEmpty($script:five_pct) -and [string]::IsNullOrEmpty($script:week_pct) -and [string]::IsNullOrEmpty($script:cost_usd)) {
        $res = render_name $script:model
        $res += paint_sep
        $res += paint $script:META 'usage data pending - make a request'
        return $res
    }

    $res = render_name $script:model

    if ((-not [string]::IsNullOrEmpty($script:five_pct)) -or (-not [string]::IsNullOrEmpty($script:week_pct))) {
        if (-not [string]::IsNullOrEmpty($script:five_pct)) {
            $res += paint_sep
            $res += seg_rate '5h' $script:five_pct (fmt_time $script:five_reset)
        }
        if (-not [string]::IsNullOrEmpty($script:week_pct)) {
            $res += paint_sep
            $res += seg_rate 'week' $script:week_pct (fmt_when $script:week_reset)
        }
        foreach ($w in @($script:scopedWindows)) {
            $lbl = Sanitize-Label $w[0]
            if ([string]::IsNullOrEmpty($lbl) -or [string]::IsNullOrEmpty($w[1])) { continue }
            $res += paint_sep
            $res += seg_rate $lbl $w[1] (fmt_when (Iso-ToEpoch $w[2]))
        }
    } else {
        if (-not [string]::IsNullOrEmpty($script:cost_usd)) {
            $res += paint_sep
            $res += paint (cost_tier_color $script:cost_usd) (fmt_cost $script:cost_usd)
        }
        if (-not [string]::IsNullOrEmpty($script:dur_ms)) {
            $res += paint_sep
            $res += paint (meta_sgr '') (fmt_duration $script:dur_ms)
        }
        if ((-not [string]::IsNullOrEmpty($script:lines_added)) -or (-not [string]::IsNullOrEmpty($script:lines_removed))) {
            $res += paint_sep
            $la = if ([string]::IsNullOrEmpty($script:lines_added)) { '0' } else { $script:lines_added }
            $lr = if ([string]::IsNullOrEmpty($script:lines_removed)) { '0' } else { $script:lines_removed }
            $res += paint (meta_sgr '') "+${la}/-${lr}"
        }
        if ((-not [string]::IsNullOrEmpty($script:in_tokens)) -or (-not [string]::IsNullOrEmpty($script:out_tokens))) {
            $res += paint_sep
            $it = if ([string]::IsNullOrEmpty($script:in_tokens)) { '0' } else { $script:in_tokens }
            $ot = if ([string]::IsNullOrEmpty($script:out_tokens)) { '0' } else { $script:out_tokens }
            $res += paint (meta_sgr '') "$(fmt_size $it)↑ $(fmt_size $ot)↓"
        }
    }

    if (-not [string]::IsNullOrEmpty($script:ctx_pct)) {
        $size = ""
        if (-not [string]::IsNullOrEmpty($script:ctx_size)) {
            $size = " of $(fmt_size $script:ctx_size)"
        }
        $res += paint_sep
        $res += seg_ctx $script:ctx_pct $size
    }

    return $res
}

# /usage shows a per-model weekly bar ("Current week (Fable)") that is often the
# binding limit. Claude Code does NOT hand it to statuslines - as of v2.1.231 the
# payload builder copies only rate_limits.five_hour and .seven_day - so this ONE
# segment reads Claude Code's own local config file instead. That is a deliberate,
# bounded exception to the stdin-only contract, which is why it is off by default
# and gated behind `model_weekly = on`. Still no network, no auth, no credentials.
# Any failure (file absent, key renamed, torn write, invalid JSON) leaves the list
# empty and the segment simply does not render. See statusline.sh for the full
# rationale and the migration path once stdin carries these windows.
function Load-ScopedWeekly() {
    if (-not $script:MODEL_WEEKLY) { return }
    # Plan mode only: the segment renders inside the rate-limit branch, so
    # loading it for an Enterprise payload would let limit_pegged dim the model
    # name with no visible segment to explain why.
    if ([string]::IsNullOrEmpty($script:five_pct) -and [string]::IsNullOrEmpty($script:week_pct)) { return }
    $homeDir = if (-not [string]::IsNullOrEmpty($env:HOME)) { $env:HOME } else { $env:USERPROFILE }
    if ([string]::IsNullOrEmpty($homeDir)) { return }
    # Claude Code resolves <config-dir>/.config.json first, then the legacy
    # <CLAUDE_CONFIG_DIR|HOME>/.claude.json. Mirror that order.
    $dir = $env:CLAUDE_CONFIG_DIR
    if ([string]::IsNullOrEmpty($dir)) { $dir = Join-Path $homeDir '.claude' }
    $f = Join-Path $dir '.config.json'
    if (-not (Test-Path $f -PathType Leaf)) {
        $base = $env:CLAUDE_CONFIG_DIR
        if ([string]::IsNullOrEmpty($base)) { $base = $homeDir }
        $f = Join-Path $base '.claude.json'
    }
    if (-not (Test-Path $f -PathType Leaf)) { return }
    try {
        # -Encoding UTF8 is mandatory: PS 5.1 would otherwise read this UTF-8
        # file in the legacy ANSI codepage and mangle non-ASCII model names.
        $rawCfg = Get-Content $f -Raw -Encoding UTF8 -ErrorAction Stop
        if ([string]::IsNullOrWhiteSpace($rawCfg)) { return }
        $cfg = ConvertFrom-Json $rawCfg -ErrorAction Stop
        if ($null -eq $cfg.cachedUsageUtilization) { return }
        # Freshness gate, mirroring Claude Code's own rule for this cache: it is
        # refreshed during normal use (throttled to at most once every 5 minutes)
        # and Claude Code stops trusting it past an hour. Anything older - or
        # stamped in the future, meaning a clock jump - is dropped rather than
        # shown as if current, as is a missing/non-numeric stamp. A visibility
        # gate, NOT a countdown (gotcha 8). Mirrors the jq filter in statusline.sh.
        $fa = $cfg.cachedUsageUtilization.fetchedAtMs
        if ($fa -isnot [int] -and $fa -isnot [long] -and $fa -isnot [double] -and $fa -isnot [decimal]) { return }
        $age = ([double](now_epoch) * 1000) - [double]$fa
        if ($age -lt 0 -or $age -gt 3600000) { return }
        if ($null -eq $cfg.cachedUsageUtilization.utilization) { return }
        $limits = $cfg.cachedUsageUtilization.utilization.limits
        # An object rather than an array is not a limits list: jq's iteration and
        # PowerShell's single-element wrap would disagree about what it contains.
        if ($null -eq $limits -or $limits -isnot [System.Array]) { return }
        # `is_active`/`severity` are deliberately ignored - the bar is worth
        # showing whether or not the server flags it as the binding one. Capped
        # at 3 so a surprise server change cannot run away with the line.
        $acc = @()
        foreach ($l in @($limits)) {
            if ($acc.Count -ge 3) { break }
            if ($null -eq $l) { continue }
            # Per-record guard: without it one malformed entry threw to the outer
            # catch and discarded EVERY window, where bash dropped only that one.
            try {
            # -cne, not -ne: PowerShell's -ne is case-INSENSITIVE, so a kind of
            # "WEEKLY_SCOPED" rendered here while jq's == rejected it in bash.
            if ($l.kind -cne 'weekly_scoped') { continue }
            $nm = ''; $pc = ''; $rs = ''
            # Type-pinned exactly like the jq filter: only a real JSON string is
            # a label, only a real number or numeric string is a percentage.
            # Blind .ToString() diverged from jq on booleans, nested objects and
            # exponent notation.
            if ($null -ne $l.scope -and $null -ne $l.scope.model -and $l.scope.model.display_name -is [string]) {
                $nm = Strip-Controls $l.scope.model.display_name
            }
            if ($l.percent -is [string]) {
                $pc = Strip-Controls $l.percent
            } elseif ($null -ne $l.percent -and $l.percent -isnot [bool]) {
                $pc = Strip-Controls $l.percent.ToString([System.Globalization.CultureInfo]::InvariantCulture)
            }
            # Bounded to three integer digits, mirroring the jq filter: real
            # percentages are 0-100, and this is what stops a 400-digit value
            # from rendering as a 400-character statusline.
            if ($pc -notmatch '^-?[0-9]{1,3}([.][0-9]{1,6})?$') { $pc = '' }
            if ($null -ne $l.resets_at) {
                # PS 7's ConvertFrom-Json rehydrates an ISO-8601 string into a
                # [datetime] (already shifted to local time); PS 5.1 leaves it a
                # string. Left alone, PS 7 hands Iso-ToEpoch "08/15/2026 20:00:00",
                # which it rightly rejects - so the reset clause silently emptied
                # while bash, reading jq's raw string, rendered the weekday.
                # Re-canonicalise to a UTC ISO string so both PowerShell versions
                # and bash agree. Kind=Unspecified is treated as UTC, matching
                # bash's rule for a timestamp with no offset.
                if ($l.resets_at -is [datetime]) {
                    $dt = [datetime]$l.resets_at
                    if ($dt.Kind -eq [System.DateTimeKind]::Unspecified) {
                        $dt = [datetime]::SpecifyKind($dt, [System.DateTimeKind]::Utc)
                    }
                    $rs = $dt.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss+00:00', [System.Globalization.CultureInfo]::InvariantCulture)
                } elseif ($l.resets_at -is [string]) {
                    $rs = Strip-Controls $l.resets_at
                }
            }
            $acc += ,@($nm, $pc, $rs)
            } catch { continue }
        }
        $script:scopedWindows = $acc
    } catch {
        $script:scopedWindows = @()
    }
}

function Main() {
    $inputRaw = [Console]::In.ReadToEnd()

    $script:model = 'Claude'
    $script:five_pct = ''
    $script:five_reset = ''
    $script:week_pct = ''
    $script:week_reset = ''
    $script:ctx_pct = ''
    $script:ctx_size = ''
    $script:cost_usd = ''
    $script:dur_ms = ''
    $script:lines_added = ''
    $script:lines_removed = ''
    $script:in_tokens = ''
    $script:out_tokens = ''

    $parsed = $null
    try {
        if (-not [string]::IsNullOrWhiteSpace($inputRaw)) {
            $parsed = ConvertFrom-Json $inputRaw -ErrorAction Stop
        }
    } catch {
        $parsed = $null
    }

    if ($null -ne $parsed) {
        $m = 'Claude'
        if ($null -ne $parsed.model) {
            if ($null -ne $parsed.model.display_name) { $m = $parsed.model.display_name }
            elseif ($null -ne $parsed.model.id) { $m = $parsed.model.id }
        }
        $script:model = $m.ToString([System.Globalization.CultureInfo]::InvariantCulture)

        if ($null -ne $parsed.rate_limits) {
            if ($null -ne $parsed.rate_limits.five_hour) {
                if ($null -ne $parsed.rate_limits.five_hour.used_percentage) { $script:five_pct = $parsed.rate_limits.five_hour.used_percentage.ToString([System.Globalization.CultureInfo]::InvariantCulture) }
                if ($null -ne $parsed.rate_limits.five_hour.resets_at) { $script:five_reset = $parsed.rate_limits.five_hour.resets_at.ToString([System.Globalization.CultureInfo]::InvariantCulture) }
            }
            if ($null -ne $parsed.rate_limits.seven_day) {
                if ($null -ne $parsed.rate_limits.seven_day.used_percentage) { $script:week_pct = $parsed.rate_limits.seven_day.used_percentage.ToString([System.Globalization.CultureInfo]::InvariantCulture) }
                if ($null -ne $parsed.rate_limits.seven_day.resets_at) { $script:week_reset = $parsed.rate_limits.seven_day.resets_at.ToString([System.Globalization.CultureInfo]::InvariantCulture) }
            }
        }
        if ($null -ne $parsed.context_window) {
            if ($null -ne $parsed.context_window.used_percentage) { $script:ctx_pct = $parsed.context_window.used_percentage.ToString([System.Globalization.CultureInfo]::InvariantCulture) }
            if ($null -ne $parsed.context_window.context_window_size) { $script:ctx_size = $parsed.context_window.context_window_size.ToString([System.Globalization.CultureInfo]::InvariantCulture) }
            if ($null -ne $parsed.context_window.total_input_tokens) { $script:in_tokens = $parsed.context_window.total_input_tokens.ToString([System.Globalization.CultureInfo]::InvariantCulture) }
            if ($null -ne $parsed.context_window.total_output_tokens) { $script:out_tokens = $parsed.context_window.total_output_tokens.ToString([System.Globalization.CultureInfo]::InvariantCulture) }
        }
        if ($null -ne $parsed.cost) {
            if ($null -ne $parsed.cost.total_cost_usd) { $script:cost_usd = $parsed.cost.total_cost_usd.ToString([System.Globalization.CultureInfo]::InvariantCulture) }
            if ($null -ne $parsed.cost.total_duration_ms) { $script:dur_ms = $parsed.cost.total_duration_ms.ToString([System.Globalization.CultureInfo]::InvariantCulture) }
            if ($null -ne $parsed.cost.total_lines_added) { $script:lines_added = $parsed.cost.total_lines_added.ToString([System.Globalization.CultureInfo]::InvariantCulture) }
            if ($null -ne $parsed.cost.total_lines_removed) { $script:lines_removed = $parsed.cost.total_lines_removed.ToString([System.Globalization.CultureInfo]::InvariantCulture) }
        }
    }

    $theme = 'default'
    $homeDir = if (-not [string]::IsNullOrEmpty($env:HOME)) { $env:HOME } else { $env:USERPROFILE }
    $configFile = "$homeDir/.claude/plan-statusline.conf"

    if (Test-Path $configFile -PathType Leaf) {
        try {
            $lines = Get-Content $configFile -ErrorAction SilentlyContinue
            if ($null -ne $lines) {
                foreach ($line in $lines) {
                    $idx = $line.IndexOf('=')
                    if ($idx -ge 0) {
                        $key = $line.Substring(0, $idx).Replace(' ', '')
                        $value = $line.Substring($idx + 1).Replace(' ', '')
                        if ($value.EndsWith('"')) { $value = $value.Substring(0, $value.Length - 1) }
                        if ($value.StartsWith('"')) { $value = $value.Substring(1) }
                        if ($key -ceq 'theme' -and -not [string]::IsNullOrEmpty($value)) {
                            $theme = $value
                        }
                        if ($key -ceq 'rainbow_speed' -and $value -match '^[0-9]+$') {
                            $sp = 0
                            if ([int]::TryParse($value, [ref]$sp) -and $sp -ge 1) { $script:RAINBOW_SPEED = $sp }
                        }
                        if ($key -ceq 'model_weekly' -and -not [string]::IsNullOrEmpty($value)) {
                            $mw = $value.ToLowerInvariant()
                            if ($mw -eq 'on' -or $mw -eq 'true' -or $mw -eq '1' -or $mw -eq 'yes') { $script:MODEL_WEEKLY = $true }
                        }
                    }
                }
            }
        } catch {}
    }

    Load-ScopedWeekly

    switch ($theme) {
        'hearth' { Theme-Hearth }
        'glow' { Theme-Glow }
        'scrubs' { Theme-Scrubs }
        'harbor' { Theme-Harbor }
        'atomic' { Theme-Atomic }
        'slime' { Theme-Slime }
        'rainbow' { Theme-Rainbow }
        'dracula' { Theme-Dracula }
        'nord' { Theme-Nord }
        'gruvbox' { Theme-Gruvbox }
        'catppuccin' { Theme-Catppuccin }
        default { Theme-Default }
    }

    $lineOut = render_line

    try {
        [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
    } catch {}
    [Console]::Out.Write($lineOut)
}

if ($MyInvocation.InvocationName -ne '.') {
    Main
}
