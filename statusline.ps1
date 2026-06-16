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
    if ([long]::TryParse($n, [ref]$num)) {
        if ($num -ge 1000000) { return "$([math]::Truncate($num / 1000000))M" }
        if ($num -ge 1000) { return "$([math]::Truncate($num / 1000))k" }
        return "$num"
    }
    return ''
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
    if ([long]::TryParse($ms, [ref]$n)) {
        $s = [math]::Truncate($n / 1000)
        if ($s -ge 3600) { return "$([math]::Truncate($s / 3600))h$([math]::Truncate(($s % 3600) / 60))m" }
        if ($s -ge 60) { return "$([math]::Truncate($s / 60))m$($s % 60)s" }
        return "${s}s"
    }
    return ''
}

function now_epoch() {
    if (-not [string]::IsNullOrEmpty($env:PLAN_SL_NOW)) {
        $n = 0
        if ([long]::TryParse($env:PLAN_SL_NOW, [ref]$n)) { return $n }
    }
    return [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
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
    return ''
}

function limit_pegged() {
    $five = truncate_pct $script:five_pct
    if (-not [string]::IsNullOrEmpty($five)) {
        $n = 0; if ([long]::TryParse($five, [ref]$n) -and $n -ge 100) { return $true }
    }
    $week = truncate_pct $script:week_pct
    if (-not [string]::IsNullOrEmpty($week)) {
        $n = 0; if ([long]::TryParse($week, [ref]$n) -and $n -ge 100) { return $true }
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
        $res = ''
        foreach ($ch in $text.ToCharArray()) {
            rainbow_next
            $res += "${ESC}[$($script:_RAINBOW_SGR)m$ch${ESC}[0m"
        }
        return $res
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
            $res = ''
            foreach ($ch in $text.ToCharArray()) {
                rainbow_next
                $res += "${ESC}[$($script:_RAINBOW_SGR)m$ch${ESC}[0m"
            }
            return $res
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
    return ''
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
    return ''
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
                        if ($key -eq 'theme' -and -not [string]::IsNullOrEmpty($value)) {
                            $theme = $value
                        }
                        if ($key -eq 'rainbow_speed' -and $value -match '^[0-9]+$') {
                            $sp = 0
                            if ([int]::TryParse($value, [ref]$sp) -and $sp -ge 1) { $script:RAINBOW_SPEED = $sp }
                        }
                    }
                }
            }
        } catch {}
    }

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
