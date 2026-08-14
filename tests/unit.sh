#!/usr/bin/env bash
# Unit tests for sourceable helpers in statusline.sh.
# Sourcing must NOT block on stdin and must NOT render — only define functions.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

ESC=$(printf '\033')
strip_ansi() { sed -E "s/${ESC}\[[0-9;]*m//g"; }

fails=0
ok()   { printf 'PASS %s\n' "$1"; }
bad()  { printf 'FAIL %s\n' "$1" >&2; fails=$((fails+1)); }

# Sourcing must define functions WITHOUT rendering (no stdout side-effect).
# The unguarded script renders during source; the guard prevents that.
out=$(source ./statusline.sh </dev/null)
[[ -z "$out" ]] && ok "source: no render side-effect" || bad "source: no render side-effect (got: $out)"

# Source in the parent shell so functions are visible to the checks below.
source ./statusline.sh </dev/null

# After sourcing, helper functions exist.
declare -F render_line >/dev/null && ok "source: functions defined" \
  || bad "source: functions defined"

# fmt_size testing
[[ "$(fmt_size "248")" == "248" ]] && ok "fmt_size: <1k -> plain" || bad "fmt_size: <1k -> plain (got '$(fmt_size "248")')"
[[ "$(fmt_size "63015")" == "63k" ]] && ok "fmt_size: >=1k -> k" || bad "fmt_size: >=1k -> k (got '$(fmt_size "63015")')"
[[ "$(fmt_size "1000000")" == "1M" ]] && ok "fmt_size: >=1M -> M" || bad "fmt_size: >=1M -> M (got '$(fmt_size "1000000")')"
[[ -z "$(fmt_size "")" ]] && ok "fmt_size: empty -> empty" || bad "fmt_size: empty -> empty (got '$(fmt_size "")')"

# render_name draws the model name as ONE solid span; ANSI-stripped output
# equals the text exactly. Set rate vars so limit_pegged works under `set -u`.
# shellcheck disable=SC2034  # consumed by the sourced limit_pegged()
five_pct=''
# shellcheck disable=SC2034  # consumed by the sourced limit_pegged()
week_pct=''
NAME_SGR='1;38;5;255'
got=$(render_name 'Opus 4.8' | strip_ansi)
[[ "$got" == "Opus 4.8" ]] && ok "render_name: preserves text" || bad "render_name: preserves text (got '$got')"
[[ -z "$(render_name '')" ]] && ok "render_name: empty -> empty" || bad "render_name: empty -> empty"
[[ "$(render_name 'X' | strip_ansi)" == "X" ]] && ok "render_name: single char" || bad "render_name: single char"

# Solid color = single opening SGR + text + reset (no per-character spans).
NAME_SGR='1;38;5;214'
[[ "$(render_name 'Opus 4.8')" == $'\033[1;38;5;214mOpus 4.8\033[0m' ]] \
  && ok "render_name: single solid span" || bad "render_name: single span (got '$(render_name 'Opus 4.8')')"

# Empty NAME_SGR -> plain text (terminal default fg).
NAME_SGR=''
[[ "$(render_name 'Opus 4.8')" == "Opus 4.8" ]] && ok "render_name: empty color plain" || bad "render_name: empty color"

# ── limit_pegged ─────────────────────────────────────────────────────────────
five_pct='' week_pct=''
limit_pegged && bad "limit_pegged: empty" || ok "limit_pegged: empty"
five_pct='99' week_pct='50'
limit_pegged && bad "limit_pegged: below" || ok "limit_pegged: below"
five_pct='100' week_pct=''
limit_pegged && ok "limit_pegged: five_pct 100" || bad "limit_pegged: five_pct 100"
five_pct='' week_pct='100'
limit_pegged && ok "limit_pegged: week_pct 100" || bad "limit_pegged: week_pct 100"
five_pct='100' week_pct='100'
limit_pegged && ok "limit_pegged: both 100" || bad "limit_pegged: both 100"
five_pct='105.5' week_pct=''
limit_pegged && ok "limit_pegged: fractional above" || bad "limit_pegged: fractional above"
five_pct='99.9' week_pct=''
limit_pegged && bad "limit_pegged: fractional below" || ok "limit_pegged: fractional below"
# shellcheck disable=SC2034  # reset for later checks
five_pct=''
# shellcheck disable=SC2034  # reset for later checks
week_pct=''

# Pegged: name dims (static), still preserves text exactly.
five_pct=100; NAME_SGR='1;38;5;214'
[[ "$(render_name 'Opus 4.8' | strip_ansi)" == "Opus 4.8" ]] && ok "render_name: pegged preserves text" || bad "render_name: pegged"
[[ "$(render_name 'Opus 4.8')" == $'\033[2mOpus 4.8\033[0m' ]] && ok "render_name: pegged dims" || bad "render_name: pegged dims"
# shellcheck disable=SC2034  # reset for later checks
five_pct=''

# ── theme loaders ────────────────────────────────────────────────────────────
theme_default
[[ "$LABEL_SEP" == ":" ]] && ok "theme_default: LABEL_SEP" || bad "theme_default: LABEL_SEP ('$LABEL_SEP')"
[[ "$SEG_CIRCLE" == "0" ]] && ok "theme_default: SEG_CIRCLE" || bad "theme_default: SEG_CIRCLE"
[[ -n "$NAME_SGR" ]] && ok "theme_default: NAME_SGR set" || bad "theme_default: NAME_SGR"

for t in hearth glow scrubs harbor atomic slime dracula nord gruvbox catppuccin; do
  "theme_$t"
  [[ -n "$NAME_SGR" ]] && ok "theme_$t: NAME_SGR set" || bad "theme_$t: NAME_SGR"
  [[ "$LABEL_SEP" == "" ]]      && ok "theme_$t: LABEL_SEP empty" || bad "theme_$t: LABEL_SEP ('$LABEL_SEP')"
  [[ "$SEG_CIRCLE" == "1" ]]    && ok "theme_$t: SEG_CIRCLE" || bad "theme_$t: SEG_CIRCLE"
  [[ -n "$EGG_RESET_WORD" ]]    && ok "theme_$t: egg word" || bad "theme_$t: egg word"
done

# rainbow drives color per-character (NAME_SGR intentionally empty); assert its flag.
theme_rainbow
[[ "${RAINBOW:-}" == "1" ]] && ok "rainbow: RAINBOW flag set" || bad "rainbow: RAINBOW flag"
[[ "$EGG_RESET_WORD" == "Lakitu" ]] && ok "rainbow: egg word" || bad "rainbow: egg word ('$EGG_RESET_WORD')"

theme_hearth
[[ "$CIRCLE_SGR" == "38;5;214" ]] && ok "hearth: CIRCLE_SGR amber" || bad "hearth: CIRCLE_SGR ('$CIRCLE_SGR')"
[[ "$LABEL_SGR" == "" ]] && ok "hearth: LABEL_SGR plain" || bad "hearth: LABEL_SGR ('$LABEL_SGR')"
theme_default
[[ "$CIRCLE_SGR" == "@tier" ]] && ok "default: CIRCLE_SGR @tier" || bad "default: CIRCLE_SGR ('$CIRCLE_SGR')"

# ── fmt_duration ─────────────────────────────────────────────────────────────
[[ -z "$(fmt_duration '')" ]] && ok "fmt_duration: empty" || bad "fmt_duration: empty"
[[ "$(fmt_duration 0)" == "0s" ]] && ok "fmt_duration: 0ms -> 0s" || bad "fmt_duration: 0ms -> 0s"
[[ "$(fmt_duration 999)" == "0s" ]] && ok "fmt_duration: 999ms -> 0s" || bad "fmt_duration: 999ms -> 0s"
[[ "$(fmt_duration 1000)" == "1s" ]] && ok "fmt_duration: 1000ms -> 1s" || bad "fmt_duration: 1000ms -> 1s"
[[ "$(fmt_duration 59999)" == "59s" ]] && ok "fmt_duration: 59999ms -> 59s" || bad "fmt_duration: 59999ms -> 59s"
[[ "$(fmt_duration 60000)" == "1m0s" ]] && ok "fmt_duration: 60000ms -> 1m0s" || bad "fmt_duration: 60000ms -> 1m0s"
[[ "$(fmt_duration 65000)" == "1m5s" ]] && ok "fmt_duration: 65000ms -> 1m5s" || bad "fmt_duration: 65000ms -> 1m5s"
[[ "$(fmt_duration 3599999)" == "59m59s" ]] && ok "fmt_duration: 3599999ms -> 59m59s" || bad "fmt_duration: 3599999ms -> 59m59s"
[[ "$(fmt_duration 3600000)" == "1h0m" ]] && ok "fmt_duration: 3600000ms -> 1h0m" || bad "fmt_duration: 3600000ms -> 1h0m"
[[ "$(fmt_duration 3660000)" == "1h1m" ]] && ok "fmt_duration: 3660000ms -> 1h1m" || bad "fmt_duration: 3660000ms -> 1h1m"
[[ "$(fmt_duration 7260000)" == "2h1m" ]] && ok "fmt_duration: 7260000ms -> 2h1m" || bad "fmt_duration: 7260000ms -> 2h1m"

# ── iso_to_epoch ─────────────────────────────────────────────────────────────
# Only the model-scoped weekly windows carry ISO timestamps; everything else in
# the payload is already an epoch. Expected values are Python's
# datetime.fromisoformat(...).timestamp(), so this also pins the leap-year and
# offset math that bash/PowerShell must agree on.
iso_eq() { # LABEL INPUT EXPECTED
  local got; got=$(iso_to_epoch "$2")
  [[ "$got" == "$3" ]] && ok "iso_to_epoch: $1" || bad "iso_to_epoch: $1 (got '$got', want '$3')"
}
iso_eq "utc with microseconds" "2026-08-16T03:00:00.336012+00:00" "1786849200"
iso_eq "Z suffix"              "1970-01-01T00:00:00Z"             "0"
iso_eq "leap day"              "2000-02-29T12:00:00Z"             "951825600"
iso_eq "negative offset"       "2026-08-15T20:00:00-07:00"        "1786849200"
iso_eq "offset without colon"  "2026-08-15T20:00:00-0700"         "1786849200"
iso_eq "positive offset"       "2026-08-16T08:30:00+05:30"        "1786849200"
iso_eq "no offset means utc"   "1999-01-01T00:00:00"              "915148800"
iso_eq "space separator"       "1999-01-01 00:00:00"              "915148800"
iso_eq "end of 2024"           "2024-12-31T23:59:59Z"             "1735689599"
# Non-March-anchored months exercise the other branch of days_from_civil.
iso_eq "january"               "2026-01-15T00:00:00Z"             "1768435200"
iso_eq "february"              "2026-02-15T00:00:00Z"             "1771113600"
# Unparseable input yields nothing, which renders as the same "(→)" the payload
# already produces for a rate limit with no resets_at.
iso_eq "garbage"        "garbage"                ""
iso_eq "empty"          ""                       ""
iso_eq "month out of range" "2026-13-01T00:00:00Z" ""
iso_eq "day out of range"   "2026-01-32T00:00:00Z" ""
iso_eq "hour out of range"  "2026-01-01T24:00:00Z" ""
iso_eq "date only"          "2026-08-16"           ""
# "08"/"09" are invalid octal; without a 10# prefix these abort the arithmetic.
iso_eq "octal-looking fields" "2026-08-09T08:09:08Z" "1786262948"

# ── sanitize_label ───────────────────────────────────────────────────────────
# display_name is server-supplied and lands in the user's terminal.
lbl_eq() { # LABEL INPUT EXPECTED
  local got; got=$(sanitize_label "$2")
  [[ "$got" == "$3" ]] && ok "sanitize_label: $1" || bad "sanitize_label: $1 (got '$got', want '$3')"
}
lbl_eq "plain name lowercased" "Fable" "fable"
lbl_eq "digits and dot kept"   "Opus 4.8" "opus 4.8"
lbl_eq "truncates to 12"       "ReallyLongModelName" "reallylongmo"
lbl_eq "strips ANSI escape"    "$(printf 'Ev\033[31mil')" "ev31mil"
lbl_eq "strips control bytes"  "$(printf 'a\tb\nc')" "abc"
lbl_eq "strips multibyte"      "Fable™" "fable"
lbl_eq "empty stays empty"     "" ""
# An OSC title-set sequence keeps only its safe characters — the ESC, ']', ';'
# and BEL that would actually retitle the user's terminal are all dropped.
lbl_eq "strips OSC sequence"   "$(printf '\033]0;x\007')" "0x"
got=$(sanitize_label "AAAAAAAAAAAAAAAAAAAAAAAAAAAA")
[[ ${#got} -le 12 ]] && ok "sanitize_label: length bounded" || bad "sanitize_label: length bounded (${#got})"

# ── limit_pegged also honours scoped windows ─────────────────────────────────
# shellcheck disable=SC2034  # consumed by the sourced limit_pegged()
five_pct='' week_pct=''
scoped_records=$(printf 'fable\x1f21\x1f2026-08-16T03:00:00Z')
limit_pegged && bad "limit_pegged: scoped below 100" || ok "limit_pegged: scoped below 100"
scoped_records=$(printf 'fable\x1f100\x1f2026-08-16T03:00:00Z')
limit_pegged && ok "limit_pegged: scoped at 100" || bad "limit_pegged: scoped at 100"
# A pegged bucket in a LATER record must still count — the records are \x1e
# joined, and reading them as one line would only ever inspect the first.
scoped_records=$(printf 'fable\x1f21\x1fx\x1esonnet\x1f100\x1fy')
limit_pegged && ok "limit_pegged: scoped 100 in second record" || bad "limit_pegged: scoped 100 in second record"
scoped_records=$(printf 'fable\x1f99.9\x1fx')
limit_pegged && bad "limit_pegged: scoped fractional below" || ok "limit_pegged: scoped fractional below"
# shellcheck disable=SC2034  # consumed by the sourced limit_pegged()
scoped_records=''
limit_pegged && bad "limit_pegged: empty scoped" || ok "limit_pegged: empty scoped"

echo
if (( fails )); then echo "unit: $fails FAILED"; exit 1; fi
echo "All unit tests passed."
