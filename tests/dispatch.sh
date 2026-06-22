#!/usr/bin/env bash
# Snapshot test for theme dispatch in statusline.sh.
# Confirms each theme renders, unknown names fall through to default,
# and the empty-state placeholder appears when rate_limits is absent.

set -euo pipefail

cd "$(dirname "$0")/.."

SAMPLE='{"model":{"display_name":"Opus 4.8"},"rate_limits":{"five_hour":{"used_percentage":42,"resets_at":1746234000},"seven_day":{"used_percentage":78,"resets_at":1746500400}},"context_window":{"used_percentage":15,"context_window_size":1000000}}'
EMPTY='{"model":{"display_name":"Opus 4.8"}}'

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/.claude"

ESC=$(printf '\033')

# Strip CSI escape sequences (\033[...m) so substring matching works across
# the colored segments (model name, tier-colored values, separators) without
# tripping on the SGR codes interleaved between them.
strip_ansi() { sed -E "s/${ESC}\[[0-9;]*m//g"; }

assert_renders() {
  local theme=$1 input=$2 expect=$3
  if [[ -n "$theme" ]]; then
    printf 'theme=%s\n' "$theme" > "$TMP/.claude/plan-statusline.conf"
  else
    rm -f "$TMP/.claude/plan-statusline.conf"
  fi
  local raw plain
  raw=$(echo "$input" | HOME="$TMP" bash statusline.sh)
  plain=$(printf '%s' "$raw" | strip_ansi)
  if [[ "$plain" != *"$expect"* ]]; then
    printf 'FAIL theme=%-8s expected substring %q\n  got: %s\n' \
      "${theme:-<none>}" "$expect" "$plain" >&2
    return 1
  fi
  printf 'PASS theme=%-8s (matched %q)\n' "${theme:-<none>}" "$expect"
}

# Every theme that ships — add new themes here only.
THEMES=(default hearth glow scrubs harbor atomic slime rainbow dracula nord gruvbox catppuccin)
# Removed/unknown names that must silently fall through to default
# (backward compat, e.g. users with theme=pulse still in their config).
UNKNOWN=(pulse zzz)

# Every declared theme renders the model name
for t in "${THEMES[@]}"; do
  assert_renders "$t" "$SAMPLE" "Opus 4.8"
done

# Unknown/removed theme names fall through to default and still render
for t in "${UNKNOWN[@]}"; do
  assert_renders "$t" "$SAMPLE" "Opus 4.8"
done

# No config file → default theme via case-statement catch-all
assert_renders "" "$SAMPLE" "Opus 4.8"

# Empty rate_limits → "usage data pending" placeholder text, every theme
for t in "${THEMES[@]}"; do
  assert_renders "$t" "$EMPTY" "usage data pending"
done

PEGGED='{"model":{"display_name":"Opus 4.8"},"rate_limits":{"five_hour":{"used_percentage":100,"resets_at":1746234000},"seven_day":{"used_percentage":78,"resets_at":1746500400}},"context_window":{"used_percentage":15,"context_window_size":1000000}}'

# --- render_line faithfulness (TZ-independent substrings) ---
# Drive render_line directly by sourcing, loading a theme, setting parsed vars.
render_check() {
  local theme=$1 expect=$2
  local plain
  plain=$(
    five_pct=42 five_reset=1746234000 \
    week_pct=78 week_reset=1746500400 \
    ctx_pct=15 ctx_size=1000000 model='Opus 4.8' \
    bash -c "source ./statusline.sh; theme_$theme; render_line" | strip_ansi
  )
  if [[ "$plain" != *"$expect"* ]]; then
    printf 'FAIL render theme=%-8s expected %q\n  got: %s\n' "$theme" "$expect" "$plain" >&2
    return 1
  fi
  printf 'PASS render theme=%-8s (matched %q)\n' "$theme" "$expect"
}

render_check default "5h: 42%"
render_check default "◔ 15% of 1M"
for t in hearth glow scrubs; do
  render_check "$t" "◑ 5h 42%"
  render_check "$t" "◕ week 78%"
done

egg_check() {
  local theme=$1 expect=$2 plain
  plain=$(
    five_pct=100 five_reset=1746234000 \
    week_pct=78 week_reset=1746500400 \
    ctx_pct=15 ctx_size=1000000 model='Opus 4.8' \
    bash -c "source ./statusline.sh; theme_$theme; render_line" | strip_ansi
  )
  [[ "$plain" == *"$expect"* ]] && printf 'PASS egg theme=%-8s (%q)\n' "$theme" "$expect" \
    || { printf 'FAIL egg theme=%-8s expected %q got: %s\n' "$theme" "$expect" "$plain" >&2; return 1; }
}
egg_check default respawn
egg_check hearth rekindles
egg_check glow 1UP
egg_check scrubs defib
egg_check harbor 'fair winds'
egg_check atomic rebuild
egg_check slime drains
egg_check rainbow Lakitu
egg_check dracula sunrise
egg_check nord thaws
egg_check gruvbox regrows
egg_check catppuccin refills

# --- ANSI-aware faithfulness guards (the strip_ansi checks miss color bugs) ---
raw_render() {
  local theme=$1
  five_pct=${2:-42} five_reset=1746234000 \
  week_pct=78 week_reset=1746500400 \
  ctx_pct=15 ctx_size=1000000 model='Opus 4.8' \
  bash -c "source ./statusline.sh; theme_$theme; render_line"
}
ESC2=$(printf '\033')

# hearth: the circle stays amber (38;5;214) even at calm where the value is default-fg.
h=$(raw_render hearth 42)
[[ "$h" == *"${ESC2}[38;5;214m◑"* ]] && printf 'PASS hearth amber circle\n' \
  || { printf 'FAIL hearth amber circle\n  got: %s\n' "$h" >&2; exit 1; }

# hearth at hot (78%): label "5h" is plain, value is orange (38;5;208).
hh=$(raw_render hearth 78)
[[ "$hh" == *"${ESC2}[0m 5h ${ESC2}[38;5;208m78%"* ]] && printf 'PASS hearth plain label + orange value\n' \
  || { printf 'FAIL hearth label/value color\n  got: %s\n' "$hh" >&2; exit 1; }

# default: rate-segment reset time is PLAIN (value reset, space, uncolored "(→").
d=$(raw_render default 42)
[[ "$d" == *"${ESC2}[0m (→"* ]] && printf 'PASS default plain rate reset-time\n' \
  || { printf 'FAIL default rate reset-time should be plain\n  got: %s\n' "$d" >&2; exit 1; }

# default: ctx size IS tier-colored (green 32 at calm).
[[ "$d" == *"${ESC2}[32m of 1M"* ]] && printf 'PASS default ctx size tier-colored\n' \
  || { printf 'FAIL default ctx size should be tier-colored\n  got: %s\n' "$d" >&2; exit 1; }

# glow: circle uses tier (mint 1;38;5;41) at calm — confirms @tier resolves, no fixed color.
g=$(raw_render glow 42)
[[ "$g" == *"${ESC2}[1;38;5;41m◑"* ]] && printf 'PASS glow tier circle\n' \
  || { printf 'FAIL glow tier circle\n  got: %s\n' "$g" >&2; exit 1; }

# hearth egg: label "5h" stays plain, message red (1;38;5;196).
he=$(raw_render hearth 100)
[[ "$he" == *"5h ${ESC2}[1;38;5;196mburnt out"* ]] && printf 'PASS hearth egg plain label\n' \
  || { printf 'FAIL hearth egg label should be plain\n  got: %s\n' "$he" >&2; exit 1; }

# Pegged state flows through the real dispatch -> render_line -> egg (stable reset words).
assert_renders default "$PEGGED" "respawn"
assert_renders hearth  "$PEGGED" "rekindles"
assert_renders glow    "$PEGGED" "1UP"
assert_renders scrubs  "$PEGGED" "defib"
assert_renders default "$PEGGED" "100% 💀"

echo
echo "All dispatch tests passed."
