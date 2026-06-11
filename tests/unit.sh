#!/usr/bin/env bash
# Unit tests for sourceable helpers in statusline.sh.
# Sourcing must NOT block on stdin and must NOT render — only define functions.
set -uo pipefail
cd "$(dirname "$0")/.."

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

# render_name draws the model name as ONE solid span; ANSI-stripped output
# equals the text exactly. Set rate vars so limit_pegged works under `set -u`.
five_pct=''; week_pct=''
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

# Pegged: name dims (static), still preserves text exactly.
five_pct=100; NAME_SGR='1;38;5;214'
[[ "$(render_name 'Opus 4.8' | strip_ansi)" == "Opus 4.8" ]] && ok "render_name: pegged preserves text" || bad "render_name: pegged"
[[ "$(render_name 'Opus 4.8')" == $'\033[2mOpus 4.8\033[0m' ]] && ok "render_name: pegged dims" || bad "render_name: pegged dims"
five_pct=''

# ── theme loaders ────────────────────────────────────────────────────────────
theme_default
[[ "$LABEL_SEP" == ":" ]] && ok "theme_default: LABEL_SEP" || bad "theme_default: LABEL_SEP ('$LABEL_SEP')"
[[ "$SEG_CIRCLE" == "0" ]] && ok "theme_default: SEG_CIRCLE" || bad "theme_default: SEG_CIRCLE"
[[ -n "$NAME_SGR" ]] && ok "theme_default: NAME_SGR set" || bad "theme_default: NAME_SGR"

for t in hearth glow scrubs; do
  "theme_$t"
  [[ -n "$NAME_SGR" ]] && ok "theme_$t: NAME_SGR set" || bad "theme_$t: NAME_SGR"
  [[ "$LABEL_SEP" == "" ]]      && ok "theme_$t: LABEL_SEP empty" || bad "theme_$t: LABEL_SEP ('$LABEL_SEP')"
  [[ "$SEG_CIRCLE" == "1" ]]    && ok "theme_$t: SEG_CIRCLE" || bad "theme_$t: SEG_CIRCLE"
  [[ -n "$EGG_RESET_WORD" ]]    && ok "theme_$t: egg word" || bad "theme_$t: egg word"
done

theme_hearth
[[ "$CIRCLE_SGR" == "38;5;214" ]] && ok "hearth: CIRCLE_SGR amber" || bad "hearth: CIRCLE_SGR ('$CIRCLE_SGR')"
[[ "$LABEL_SGR" == "" ]] && ok "hearth: LABEL_SGR plain" || bad "hearth: LABEL_SGR ('$LABEL_SGR')"
theme_default
[[ "$CIRCLE_SGR" == "@tier" ]] && ok "default: CIRCLE_SGR @tier" || bad "default: CIRCLE_SGR ('$CIRCLE_SGR')"

echo
if (( fails )); then echo "unit: $fails FAILED"; exit 1; fi
echo "All unit tests passed."
