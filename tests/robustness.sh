#!/usr/bin/env bash
# Robustness tests: malformed / partial / hostile stdin must never leak
# stderr noise, never render a malformed line, and always exit 0 (a broken
# statusline must not break the Claude Code statusline pipeline).
# Also covers the PLAN_SL_NOW determinism hook used by the parity cross-check.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

ESC=$(printf '\033')
strip_ansi() { sed -E "s/${ESC}\[[0-9;]*m//g"; }

fails=0
ok()  { printf 'PASS %s\n' "$1"; }
bad() { printf 'FAIL %s\n' "$1" >&2; fails=$((fails+1)); }

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/.claude"

# run NAME JSON -> stdout in $out, stderr in $err, exit code in $rc
run() {
  local json=$1
  out=$(printf '%s' "$json" | HOME="$TMP" bash statusline.sh 2>"$TMP/err")
  rc=$?
  err=$(cat "$TMP/err")
  plain=$(printf '%s' "$out" | strip_ansi)
}

# ── malformed JSON ───────────────────────────────────────────────────────────
run 'not json {'
[[ $rc -eq 0 ]] && ok "malformed: exit 0" || bad "malformed: exit $rc"
[[ -z "$err" ]] && ok "malformed: no stderr leak" || bad "malformed: stderr leaked: $err"
[[ "$plain" == 'Claude │ usage data pending - make a request' ]] \
  && ok "malformed: clean pending line with name" || bad "malformed: got '$plain'"

# ── empty stdin ──────────────────────────────────────────────────────────────
run ''
[[ $rc -eq 0 && -z "$err" ]] && ok "empty stdin: exit 0, quiet stderr" || bad "empty stdin: rc=$rc err=$err"
[[ "$plain" == 'Claude │ usage data pending - make a request' ]] \
  && ok "empty stdin: clean pending line" || bad "empty stdin: got '$plain'"

# ── model object missing entirely (but rate limits present) ─────────────────
run '{"rate_limits":{"five_hour":{"used_percentage":42,"resets_at":1746234000}}}'
[[ "$plain" == Claude*'5h: 42%'* ]] && ok "no model: falls back to Claude" || bad "no model: got '$plain'"

# ── fractional + string percentages truncate like integers ──────────────────
run '{"model":{"display_name":"M"},"rate_limits":{"five_hour":{"used_percentage":42.7,"resets_at":1746234000}}}'
[[ "$plain" == *'5h: 42%'* ]] && ok "fractional pct: truncates (42.7 -> 42)" || bad "fractional pct: got '$plain'"
run '{"model":{"display_name":"M"},"rate_limits":{"five_hour":{"used_percentage":"42","resets_at":1746234000}}}'
[[ "$plain" == *'5h: 42%'* ]] && ok "string pct: tolerated" || bad "string pct: got '$plain'"

# ── missing resets_at renders without crashing ───────────────────────────────
run '{"model":{"display_name":"M"},"rate_limits":{"five_hour":{"used_percentage":42}}}'
[[ $rc -eq 0 && "$plain" == *'5h: 42%'* ]] && ok "missing resets_at: renders" || bad "missing resets_at: rc=$rc got '$plain'"

# ── config parsing: spaces, quotes, comment lines ────────────────────────────
printf '# pick a theme\ntheme = "glow"\n' > "$TMP/.claude/plan-statusline.conf"
run '{"model":{"display_name":"M"},"rate_limits":{"five_hour":{"used_percentage":42,"resets_at":1746234000}}}'
[[ "$out" == *"${ESC}[1;38;5;199mM"* ]] && ok "conf: spaces/quotes/comments parse (glow name)" \
  || bad "conf parse: got '$out'"
rm -f "$TMP/.claude/plan-statusline.conf"

# ── PLAN_SL_NOW pins the egg flash (determinism hook) ────────────────────────
PEGGED='{"model":{"display_name":"M"},"rate_limits":{"five_hour":{"used_percentage":100,"resets_at":1746234000}}}'
printf 'theme=scrubs\n' > "$TMP/.claude/plan-statusline.conf"
a=$(printf '%s' "$PEGGED" | PLAN_SL_NOW=1000000 HOME="$TMP" bash statusline.sh | strip_ansi)
b=$(printf '%s' "$PEGGED" | PLAN_SL_NOW=1000001 HOME="$TMP" bash statusline.sh | strip_ansi)
[[ "$a" == *'CODE BLUE'* ]] && ok "PLAN_SL_NOW even: egg msg A" || bad "egg A: got '$a'"
[[ "$b" == *'▁▁▁▁▁▁▁▁▁'* ]] && ok "PLAN_SL_NOW odd: egg msg B"  || bad "egg B: got '$b'"
a2=$(printf '%s' "$PEGGED" | PLAN_SL_NOW=1000000 HOME="$TMP" bash statusline.sh)
a3=$(printf '%s' "$PEGGED" | PLAN_SL_NOW=1000000 HOME="$TMP" bash statusline.sh)
[[ "$a2" == "$a3" ]] && ok "PLAN_SL_NOW: byte-stable across runs" || bad "PLAN_SL_NOW: unstable output"
rm -f "$TMP/.claude/plan-statusline.conf"

# ── PLAN_SL_NOW pins fmt_when's today check ──────────────────────────────────
# week reset 2h after "now" -> same local day -> clock time, not weekday.
now=1746234000
soon=$((now + 7200))
json="{\"model\":{\"display_name\":\"M\"},\"rate_limits\":{\"seven_day\":{\"used_percentage\":50,\"resets_at\":$soon}}}"
w=$(printf '%s' "$json" | PLAN_SL_NOW=$now HOME="$TMP" TZ=UTC bash statusline.sh | strip_ansi)
[[ "$w" == *':'*'m)'* ]] && ok "PLAN_SL_NOW: same-day week reset shows clock time" || bad "same-day week reset: got '$w'"

# ── NO_COLOR: suppress all ANSI, keep glyphs + layout ────────────────────────
NCJSON='{"model":{"display_name":"Opus 4.8"},"rate_limits":{"five_hour":{"used_percentage":42,"resets_at":1746234000},"seven_day":{"used_percentage":78,"resets_at":1746500400}},"context_window":{"used_percentage":15,"context_window_size":1000000}}'
ncout=$(printf '%s' "$NCJSON" | NO_COLOR=1 HOME="$TMP" bash statusline.sh)
if printf '%s' "$ncout" | grep -q "$ESC"; then bad "NO_COLOR: still emitted ESC bytes"; else ok "NO_COLOR: zero ESC bytes"; fi
# layout/glyphs survive: plain text still has the circle, separators, and values
[[ "$ncout" == *"Opus 4.8"*"5h: 42%"*"week: 78%"*"15% of 1M"* ]] && ok "NO_COLOR: layout + values intact" || bad "NO_COLOR layout: got '$ncout'"
[[ "$ncout" == *"◔"* || "$ncout" == *"â"* || "$ncout" == *"of 1M"* ]] && ok "NO_COLOR: context glyph present" || bad "NO_COLOR glyph"
# pegged egg still renders its word, just uncolored
printf 'theme=scrubs
' > "$TMP/.claude/plan-statusline.conf"
ncegg=$(printf '%s' "$PEGGED" | NO_COLOR=1 PLAN_SL_NOW=1000000 HOME="$TMP" bash statusline.sh)
if printf '%s' "$ncegg" | grep -q "$ESC"; then bad "NO_COLOR egg: ESC bytes leaked"; else ok "NO_COLOR egg: zero ESC bytes"; fi
[[ "$ncegg" == *"CODE BLUE"* && "$ncegg" == *"defib"* ]] && ok "NO_COLOR egg: word intact" || bad "NO_COLOR egg word: got '$ncegg'"
rm -f "$TMP/.claude/plan-statusline.conf"
# missing-jq path also respects NO_COLOR (no red wrapper)
jqdir=$(mktemp -d); for t in bash cat printf sed tr date mktemp grep; do tp=$(command -v "$t"); [[ -n "$tp" ]] && ln -s "$tp" "$jqdir/$t"; done
nojq=$(printf '%s' "$NCJSON" | PATH="$jqdir" NO_COLOR=1 HOME="$TMP" bash statusline.sh)
if printf '%s' "$nojq" | grep -q "$ESC"; then bad "NO_COLOR missing-jq: ESC leaked"; else ok "NO_COLOR missing-jq: plain"; fi
rm -rf "$jqdir"

# ── model_weekly: the opt-in model-scoped weekly windows ─────────────────────
# This is the one segment sourced from a local file rather than stdin, so every
# way that file can be absent or wrong must degrade to "segment simply missing"
# — never a broken line, never stderr, never a non-zero exit.
SCOPED_SRC="$(dirname "$0")/scoped-claude-config.json"
# The scoped cache carries a fetchedAtMs and is ignored once it is over an hour
# old, so every hand-written blob below needs a stamp inside that window
# relative to run_mw's pinned PLAN_SL_NOW (1786663300).
FRESH_MS=1786663000000
PLAN='{"model":{"display_name":"M"},"rate_limits":{"five_hour":{"used_percentage":42,"resets_at":1746234000},"seven_day":{"used_percentage":50,"resets_at":1746500400}}}'

# run_mw CONFIG_BODY -> $plain/$rc/$err, with the scoped config file installed
run_mw() {
  printf '%s\n' "$1" > "$TMP/.claude/plan-statusline.conf"
  out=$(printf '%s' "$PLAN" | TZ=UTC PLAN_SL_NOW=1786663300 HOME="$TMP" bash statusline.sh 2>"$TMP/err")
  rc=$?
  err=$(cat "$TMP/err")
  plain=$(printf '%s' "$out" | strip_ansi)
}

cp "$SCOPED_SRC" "$TMP/.claude.json"

# Off by default: the file is present and readable, but never consulted.
run_mw 'theme=default'
[[ "$plain" != *'fable'* ]] && ok "model_weekly: off by default" || bad "model_weekly: leaked when off: '$plain'"

# On: the scoped bucket renders, after the all-models week it subdivides.
run_mw $'theme=default\nmodel_weekly=on'
[[ $rc -eq 0 && -z "$err" ]] && ok "model_weekly: exit 0, quiet stderr" || bad "model_weekly: rc=$rc err=$err"
[[ "$plain" == *'week: 50%'*'fable: 21%'* ]] && ok "model_weekly: renders after week" || bad "model_weekly: got '$plain'"
# 2026-08-16T03:00:00Z is a Sunday — proves the ISO reset survived to fmt_when.
[[ "$plain" == *'fable: 21% (→sun)'* ]] && ok "model_weekly: ISO reset -> weekday" || bad "model_weekly reset: got '$plain'"
# Fractional percent truncates like every other percentage; a null reset gives "(→)".
[[ "$plain" == *'sonnet: 7% (→)'* ]] && ok "model_weekly: fractional pct + null reset" || bad "model_weekly sonnet: got '$plain'"
# Server-supplied label is sanitised and bounded before it reaches the terminal.
[[ "$plain" == *'opus31m 4.8-:'* ]] && ok "model_weekly: label sanitised + truncated" || bad "model_weekly label: got '$plain'"
# The 4th scoped bucket is dropped by the 3-record cap.
[[ "$plain" != *'dropped'* ]] && ok "model_weekly: caps at 3 records" || bad "model_weekly cap: got '$plain'"
# A pegged scoped bucket fires the egg AND dims the name, like the other limits.
[[ "$plain" == *'100% 💀 (respawn →sun)'* ]] && ok "model_weekly: 100% fires the egg" || bad "model_weekly egg: got '$plain'"
[[ "$out" == $'\033[2mM\033[0m'* ]] && ok "model_weekly: pegged scoped dims the name" || bad "model_weekly pegged name: got '$out'"
# Nothing the file contained may reach the terminal as an escape sequence.
if printf '%s' "$out" | grep -q "$ESC\]"; then bad "model_weekly: OSC leaked from label"; else ok "model_weekly: no OSC leak"; fi

# Truthy spellings all enable it; anything else leaves it off.
for v in on true 1 yes ON True YES; do
  run_mw "theme=default"$'\n'"model_weekly=$v"
  [[ "$plain" == *'fable'* ]] || bad "model_weekly: '$v' should enable"
done
ok "model_weekly: on/true/1/yes accepted (any case)"
for v in off false 0 no '' garbage; do
  run_mw "theme=default"$'\n'"model_weekly=$v"
  [[ "$plain" != *'fable'* ]] || bad "model_weekly: '$v' should NOT enable"
done
ok "model_weekly: off/false/0/no/blank/garbage stay off"

# ── separator injection via display_name ─────────────────────────────────────
# The bash side re-splits jq's output on \x1f/\x1e, so a server-supplied label
# containing those delimiters used to forge extra windows with attacker-chosen
# percentages — including a "100%" that fired the pegged egg — while PowerShell
# rendered one correct window. Control characters are now stripped before the
# join. Exactly one segment, at the real percentage, and no forged one.
cp "$(dirname "$0")/scoped-injection.json" "$TMP/.claude.json"
run_mw $'theme=default\nmodel_weekly=on'
[[ $rc -eq 0 && -z "$err" ]] && ok "injection: exit 0, quiet stderr" || bad "injection: rc=$rc err=$err"
[[ "$plain" != *'100%'* && "$plain" != *'respawn'* ]] \
  && ok "injection: no forged 100% window" || bad "injection: forged window: '$plain'"
[[ "$plain" == *'fable999inje: 21%'* ]] \
  && ok "injection: single window at the real percentage" || bad "injection: got '$plain'"
# One scoped segment only: count the separators the default theme uses.
segs=$(printf '%s' "$plain" | awk -F'│' '{print NF}')
[[ "$segs" == "4" ]] && ok "injection: exactly one scoped segment" || bad "injection: $segs fields, expected 4: '$plain'"
# Checked on the ANSI-stripped line: the theme's own SGR codes are legitimate
# control bytes, so only what survives colour-stripping can have come from the file.
if printf '%s' "$plain" | LC_ALL=C grep -q '[[:cntrl:]]'; then bad "injection: control byte reached stdout"; else ok "injection: no control byte on stdout"; fi
cp "$SCOPED_SRC" "$TMP/.claude.json"

# ── hostile / malformed field values ─────────────────────────────────────────
# Everything below diverged between the two implementations before the fields
# were type-pinned and validated: jq and .NET render booleans, nested objects and
# exponent notation differently, PowerShell's -ne is case-insensitive where jq's
# == is not, and .NET's \d matches Unicode digits where bash's [0-9] does not.
# Each case must produce the same line on both sides, silently.
mw_field() { # LABEL LIMITS_JSON
  printf '{"cachedUsageUtilization":{"fetchedAtMs":%s,"utilization":{"limits":%s}}}' "$FRESH_MS" "$2" > "$TMP/.claude.json"
  run_mw $'theme=default\nmodel_weekly=on'
  [[ $rc -eq 0 && -z "$err" ]] || { bad "field/$1: rc=$rc err=$err"; return; }
  printf '%s' "$plain" | LC_ALL=C grep -q '[[:cntrl:]]' && { bad "field/$1: control byte on stdout"; return; }
  (( ${#plain} <= 200 )) || { bad "field/$1: line ran away (${#plain} chars)"; return; }
  ok "field/$1"
}
SC='{"model":{"display_name":"Fable"}}'
# Rendered but harmless.
mw_field "exponent percent"  "[{\"kind\":\"weekly_scoped\",\"percent\":1e2,\"resets_at\":null,\"scope\":$SC}]"
mw_field "negative percent"  "[{\"kind\":\"weekly_scoped\",\"percent\":-5,\"resets_at\":null,\"scope\":$SC}]"
mw_field "zero percent"      "[{\"kind\":\"weekly_scoped\",\"percent\":0,\"resets_at\":null,\"scope\":$SC}]"
# Dropped: not a plain number, or not a plain string.
mw_field "boolean percent"   "[{\"kind\":\"weekly_scoped\",\"percent\":false,\"resets_at\":null,\"scope\":$SC}]"
mw_field "object label"      '[{"kind":"weekly_scoped","percent":21,"resets_at":null,"scope":{"model":{"display_name":{"a":1}}}}]'
mw_field "array label"       '[{"kind":"weekly_scoped","percent":21,"resets_at":null,"scope":{"model":{"display_name":["x"]}}}]'
mw_field "scope is a string" '[{"kind":"weekly_scoped","percent":21,"resets_at":null,"scope":"nope"}]'
mw_field "kind uppercased"   "[{\"kind\":\"WEEKLY_SCOPED\",\"percent\":21,\"resets_at\":null,\"scope\":$SC}]"
mw_field "limits is object"  "{\"kind\":\"weekly_scoped\",\"percent\":21,\"scope\":$SC}"
mw_field "limits is string"  '"nope"'
mw_field "reset is a number" "[{\"kind\":\"weekly_scoped\",\"percent\":21,\"resets_at\":1786849200,\"scope\":$SC}]"
mw_field "year out of range" "[{\"kind\":\"weekly_scoped\",\"percent\":21,\"resets_at\":\"9999-08-16T03:00:00Z\",\"scope\":$SC}]"
mw_field "unicode digits"    "[{\"kind\":\"weekly_scoped\",\"percent\":21,\"resets_at\":\"٢٠٢٦-08-16T03:00:00Z\",\"scope\":$SC}]"

# A 400-digit percent must not become a 400-character statusline.
big=$(printf '9%.0s' $(seq 1 400))
mw_field "400-digit percent" "[{\"kind\":\"weekly_scoped\",\"percent\":\"$big\",\"resets_at\":null,\"scope\":$SC}]"
run_mw $'theme=default\nmodel_weekly=on'
[[ "$plain" != *"$big"* ]] && ok "field: absurd percent dropped, not rendered" || bad "field: absurd percent rendered"

# One malformed record must not discard the others (PowerShell used to catch at
# the loop level and lose every window when a single entry threw).
mw_field "bad record then good" '[{"kind":"weekly_scoped","percent":21,"resets_at":null,"scope":{"model":{"display_name":{"deep":{"er":1}}}}},{"kind":"weekly_scoped","percent":33,"resets_at":"2026-08-16T03:00:00Z","scope":{"model":{"display_name":"Sonnet"}}}]'
[[ "$plain" == *'sonnet: 33%'* ]] && ok "field: good record survives a bad one" || bad "field: good record lost: '$plain'"

cp "$SCOPED_SRC" "$TMP/.claude.json"

# ── freshness gate ───────────────────────────────────────────────────────────
# Claude Code refreshes this cache during normal use and stops trusting it past
# an hour; the segment follows that rule rather than showing a stale number as
# though it were current. A visibility gate, never a countdown (see gotcha 8).
stale_case() { # LABEL FETCHED_MS SHOULD_RENDER
  printf '{"cachedUsageUtilization":{"fetchedAtMs":%s,"utilization":{"limits":[{"kind":"weekly_scoped","percent":21,"resets_at":null,"scope":{"model":{"display_name":"Fable"}}}]}}}' "$2" > "$TMP/.claude.json"
  run_mw $'theme=default\nmodel_weekly=on'
  [[ $rc -eq 0 && -z "$err" ]] || { bad "fresh/$1: rc=$rc err=$err"; return; }
  if [[ "$3" == "yes" ]]; then
    [[ "$plain" == *'fable: 21%'* ]] && ok "fresh/$1" || bad "fresh/$1: expected render, got '$plain'"
  else
    [[ "$plain" != *'fable'* ]] && ok "fresh/$1" || bad "fresh/$1: expected suppression, got '$plain'"
  fi
}
stale_case "just fetched"      1786663300000 yes
stale_case "5 min old"         1786663000000 yes
stale_case "59 min old"        1786659760000 yes
stale_case "61 min old"        1786659640000 no
stale_case "stamped in future" 1786663400000 no
stale_case "epoch zero"        0             no
printf '{"cachedUsageUtilization":{"utilization":{"limits":[{"kind":"weekly_scoped","percent":21,"resets_at":null,"scope":{"model":{"display_name":"Fable"}}}]}}}' > "$TMP/.claude.json"
run_mw $'theme=default\nmodel_weekly=on'
[[ "$plain" != *'fable'* ]] && ok "fresh/no stamp at all" || bad "fresh/no stamp: rendered '$plain'"
cp "$SCOPED_SRC" "$TMP/.claude.json"

# A conf file with no trailing newline must still apply its last setting.
# `while read` returns non-zero at EOF, so bash used to drop that line while
# PowerShell's Get-Content kept it — a silent cross-platform divergence for
# whatever happened to be last in the file, `theme=` included.
printf 'theme=glow\nmodel_weekly=on' > "$TMP/.claude/plan-statusline.conf"
nonl=$(printf '%s' "$PLAN" | TZ=UTC PLAN_SL_NOW=1786663300 HOME="$TMP" bash statusline.sh 2>/dev/null | strip_ansi)
# theme=glow proves BOTH last-line keys applied: glow drops the ':' separator.
[[ "$nonl" == *'fable 21%'* ]] && ok "conf: last line applies without trailing newline" \
  || bad "conf: last line dropped without trailing newline: '$nonl'"

# ── failure paths: every one degrades to "no segment", never a broken line ───
# A trailing '*' would let ANY extra segment slip through, so this counts the
# default theme's separators instead: name + 5h + week and nothing after it.
mw_degrades() { # LABEL
  [[ $rc -eq 0 ]] || { bad "$1: exit $rc"; return; }
  [[ -z "$err" ]] || { bad "$1: stderr leaked: $err"; return; }
  [[ "$plain" == 'M │ 5h: 42% (→'*'week: 50% (→'* ]] || { bad "$1: line malformed: '$plain'"; return; }
  local n; n=$(printf '%s' "$plain" | awk -F'│' '{print NF}')
  [[ "$n" == "3" ]] || { bad "$1: expected 3 segments, got $n: '$plain'"; return; }
  ok "$1"
}

rm -f "$TMP/.claude.json"
run_mw $'theme=default\nmodel_weekly=on'
mw_degrades "model_weekly: missing file"

printf 'not json {' > "$TMP/.claude.json"
run_mw $'theme=default\nmodel_weekly=on'
mw_degrades "model_weekly: malformed JSON"

printf '' > "$TMP/.claude.json"
run_mw $'theme=default\nmodel_weekly=on'
mw_degrades "model_weekly: empty file"

printf '{"other":1}' > "$TMP/.claude.json"
run_mw $'theme=default\nmodel_weekly=on'
mw_degrades "model_weekly: key absent"

# The shape changing underneath us (the documented risk of reading an internal
# file) must be inert, not fatal.
printf '{"cachedUsageUtilization":{"utilization":{"limits":"nolongeranarray"}}}' > "$TMP/.claude.json"
run_mw $'theme=default\nmodel_weekly=on'
mw_degrades "model_weekly: limits renamed/retyped"

printf '{"cachedUsageUtilization":{"utilization":{"limits":[{"kind":"weekly_scoped"}]}}}' > "$TMP/.claude.json"
run_mw $'theme=default\nmodel_weekly=on'
mw_degrades "model_weekly: scoped entry with no scope/percent"

printf '{"cachedUsageUtilization":null}' > "$TMP/.claude.json"
run_mw $'theme=default\nmodel_weekly=on'
mw_degrades "model_weekly: null cache"

# Unreadable file (skipped as root, which can read anything).
if [[ "$(id -u)" != "0" ]]; then
  cp "$SCOPED_SRC" "$TMP/.claude.json"; chmod 000 "$TMP/.claude.json"
  run_mw $'theme=default\nmodel_weekly=on'
  mw_degrades "model_weekly: unreadable file"
  chmod 644 "$TMP/.claude.json"
fi

# Enterprise payloads have no rate_limits, so plan-mode segments — including
# this one — stay out of the dashboard. Mode exclusivity is a hard invariant.
cp "$SCOPED_SRC" "$TMP/.claude.json"
printf 'theme=default\nmodel_weekly=on\n' > "$TMP/.claude/plan-statusline.conf"
ent=$(printf '%s' '{"model":{"display_name":"M"},"cost":{"total_cost_usd":1.01}}' \
  | TZ=UTC PLAN_SL_NOW=1786663300 HOME="$TMP" bash statusline.sh | strip_ansi)
[[ "$ent" != *'fable'* ]] && ok "model_weekly: absent in Enterprise mode" || bad "model_weekly: leaked into Enterprise: '$ent'"

# CLAUDE_CONFIG_DIR relocates the file, exactly as Claude Code resolves it.
ALT=$(mktemp -d)
cp "$SCOPED_SRC" "$ALT/.claude.json"
alt=$(printf '%s' "$PLAN" | TZ=UTC PLAN_SL_NOW=1786663300 HOME="$TMP" CLAUDE_CONFIG_DIR="$ALT" bash statusline.sh 2>/dev/null | strip_ansi)
[[ "$alt" == *'fable: 21%'* ]] && ok "model_weekly: honours CLAUDE_CONFIG_DIR" || bad "model_weekly CLAUDE_CONFIG_DIR: got '$alt'"
# <config-dir>/.config.json wins over the legacy <dir>/.claude.json.
printf '{"cachedUsageUtilization":{"fetchedAtMs":%s,"utilization":{"limits":[{"kind":"weekly_scoped","percent":88,"resets_at":null,"scope":{"model":{"display_name":"Newer"}}}]}}}' "$FRESH_MS" > "$ALT/.config.json"
alt2=$(printf '%s' "$PLAN" | TZ=UTC PLAN_SL_NOW=1786663300 HOME="$TMP" CLAUDE_CONFIG_DIR="$ALT" bash statusline.sh 2>/dev/null | strip_ansi)
[[ "$alt2" == *'newer: 88%'* && "$alt2" != *'fable'* ]] && ok "model_weekly: .config.json takes precedence" || bad "model_weekly .config.json: got '$alt2'"
rm -rf "$ALT"
rm -f "$TMP/.claude.json" "$TMP/.claude/plan-statusline.conf"

echo
if (( fails )); then echo "robustness: $fails FAILED"; exit 1; fi
echo "All robustness tests passed."
