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

echo
if (( fails )); then echo "unit: $fails FAILED"; exit 1; fi
echo "All unit tests passed."
