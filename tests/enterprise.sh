#!/usr/bin/env bash
# Tests for the Enterprise fallback: when the statusline stdin has no
# rate_limits block (managed / Enterprise plans), render a session dashboard
# (cost · duration · lines · tokens · context) instead of the nonexistent
# 5h / week plan windows. Plan-mode (Pro/Max) rendering must be unchanged.
set -uo pipefail
cd "$(dirname "$0")/.."

ESC=$(printf '\033')
strip_ansi() { sed -E "s/${ESC}\[[0-9;]*m//g"; }

fails=0
ok()  { printf 'PASS %s\n' "$1"; }
bad() { printf 'FAIL %s\n' "$1" >&2; fails=$((fails+1)); }

# Source helpers (guard prevents render-on-source) + load a theme so the
# TIER_* colors the cost ramp maps onto are defined.
source ./statusline.sh </dev/null
theme_default

# ── helper: fmt_cost ─────────────────────────────────────────────────────────
[[ "$(fmt_cost 1.009058)" == '$1.01' ]] && ok "fmt_cost: rounds to cents" || bad "fmt_cost 1.009058 -> '$(fmt_cost 1.009058)'"
[[ "$(fmt_cost 0)"        == '$0.00' ]] && ok "fmt_cost: zero"            || bad "fmt_cost 0 -> '$(fmt_cost 0)'"
[[ "$(fmt_cost 12.5)"     == '$12.50' ]] && ok "fmt_cost: dollars"       || bad "fmt_cost 12.5 -> '$(fmt_cost 12.5)'"
[[ -z "$(fmt_cost '')" ]] && ok "fmt_cost: empty -> empty" || bad "fmt_cost empty -> '$(fmt_cost '')'"

# ── helper: fmt_duration ─────────────────────────────────────────────────────
[[ "$(fmt_duration 45000)"   == '45s' ]]   && ok "fmt_duration: seconds" || bad "fmt_duration 45000 -> '$(fmt_duration 45000)'"
[[ "$(fmt_duration 136020)"  == '2m16s' ]] && ok "fmt_duration: minutes" || bad "fmt_duration 136020 -> '$(fmt_duration 136020)'"
[[ "$(fmt_duration 3780000)" == '1h3m' ]]  && ok "fmt_duration: hours"   || bad "fmt_duration 3780000 -> '$(fmt_duration 3780000)'"
[[ "$(fmt_duration 0)"       == '0s' ]]    && ok "fmt_duration: zero"    || bad "fmt_duration 0 -> '$(fmt_duration 0)'"
[[ -z "$(fmt_duration '')" ]] && ok "fmt_duration: empty -> empty" || bad "fmt_duration empty -> '$(fmt_duration '')'"

# ── helper: cost_tier_color (default theme TIER_* = 32 / 33 / 38;5;208 / 31) ──
[[ "$(cost_tier_color 1.50)" == '32' ]]        && ok "cost_tier: calm <\$2"     || bad "cost_tier 1.50 -> '$(cost_tier_color 1.50)'"
[[ "$(cost_tier_color 2)"    == '33' ]]        && ok "cost_tier: warn >=\$2"    || bad "cost_tier 2 -> '$(cost_tier_color 2)'"
[[ "$(cost_tier_color 7)"    == '38;5;208' ]]  && ok "cost_tier: hot >=\$5"     || bad "cost_tier 7 -> '$(cost_tier_color 7)'"
[[ "$(cost_tier_color 15)"   == '31' ]]        && ok "cost_tier: urgent >=\$10" || bad "cost_tier 15 -> '$(cost_tier_color 15)'"

# ── render: Enterprise dashboard (no rate_limits) ────────────────────────────
# Drive render_line directly: rate vars empty, enterprise vars from the real
# captured payload. cost_usd overridable via env for the color checks.
ent_render() {
  local theme=$1
  five_pct='' week_pct='' five_reset='' week_reset='' \
  cost_usd="${cost_usd:-1.009058}" dur_ms="${dur_ms:-136020}" \
  lines_added="${lines_added:-1}" lines_removed="${lines_removed:-0}" \
  in_tokens="${in_tokens:-63015}" out_tokens="${out_tokens:-248}" \
  ctx_pct="${ctx_pct:-6}" ctx_size="${ctx_size:-1000000}" model='Opus 4.8' \
  bash -c "source ./statusline.sh; theme_$theme; render_line"
}

ENT=$(ent_render default | strip_ansi)
[[ "$ENT" == *'$1.01'*      ]] && ok "enterprise default: cost"     || bad "ent default cost — got: $ENT"
[[ "$ENT" == *'2m16s'*      ]] && ok "enterprise default: duration" || bad "ent default duration — got: $ENT"
[[ "$ENT" == *'+1/-0'*      ]] && ok "enterprise default: lines"    || bad "ent default lines — got: $ENT"
[[ "$ENT" == *'63k↑ 248↓'*  ]] && ok "enterprise default: tokens"   || bad "ent default tokens — got: $ENT"
[[ "$ENT" == *'○ 6% of 1M'* ]] && ok "enterprise default: context"  || bad "ent default ctx — got: $ENT"
[[ "$ENT" != *'5h'* && "$ENT" != *'week'* ]] && ok "enterprise: no plan windows" || bad "ent leaked plan windows — got: $ENT"
[[ "$ENT" != *'pending'* ]] && ok "enterprise: not the pending placeholder" || bad "ent showed pending — got: $ENT"

# Every theme renders the dashboard (segments assembled from shared primitives).
for t in default hearth glow scrubs; do
  out=$(ent_render "$t" | strip_ansi)
  [[ "$out" == *'$1.01'* && "$out" == *'63k↑ 248↓'* && "$out" == *'○ 6% of 1M'* ]] \
    && ok "enterprise $t: dashboard renders" || bad "enterprise $t — got: $out"
done

# ── ANSI-aware: cost carries the tier ramp; meta fields are dim ──────────────
# default theme: calm cost ($1.50 < $2) is green (32).
rawc=$(cost_usd=1.50 ent_render default)
[[ "$rawc" == *"${ESC}[32m"'$1.50'* ]] && ok "enterprise: cost green at calm" || bad "cost calm color — got: $rawc"
# default theme: hot cost ($7 >= $5) is orange (38;5;208).
rawh=$(cost_usd=7 ent_render default)
[[ "$rawh" == *"${ESC}[38;5;208m"'$7.00'* ]] && ok "enterprise: cost orange at hot" || bad "cost hot color — got: $rawh"
# hearth: duration renders through META (dim italic 2;3), NOT a tier color.
rawd=$(ent_render hearth)
[[ "$rawd" == *"${ESC}[2;3m2m16s"* ]] && ok "enterprise hearth: duration is meta dim-italic" || bad "hearth duration meta — got: $rawd"

# ── mutual exclusivity: plan mode (rate_limits present) wins, ignores cost ───
plan=$(
  five_pct=42 week_pct=78 five_reset=1746234000 week_reset=1746500400 \
  cost_usd=1.009058 dur_ms=136020 lines_added=1 lines_removed=0 \
  in_tokens=63015 out_tokens=248 ctx_pct=6 ctx_size=1000000 model='Opus 4.8' \
  bash -c "source ./statusline.sh; theme_default; render_line" | strip_ansi
)
[[ "$plan" == *'5h: 42%'* ]]  && ok "plan mode: still shows 5h window" || bad "plan 5h missing — got: $plan"
[[ "$plan" == *'week: 78%'* ]] && ok "plan mode: still shows week window" || bad "plan week missing — got: $plan"
[[ "$plan" != *'$1.01'* ]]    && ok "plan mode: no cost segment (modes exclusive)" || bad "plan leaked cost — got: $plan"

# ── end to end through main(): real captured Enterprise payload via stdin ────
ENT_JSON='{"model":{"display_name":"Opus 4.8 (1M context)"},"cost":{"total_cost_usd":1.009058,"total_duration_ms":136020,"total_lines_added":1,"total_lines_removed":0},"context_window":{"total_input_tokens":63015,"total_output_tokens":248,"context_window_size":1000000,"used_percentage":6}}'
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
e2e=$(printf '%s' "$ENT_JSON" | HOME="$TMP" bash statusline.sh | strip_ansi)
[[ "$e2e" == *'Opus 4.8 (1M context)'* && "$e2e" == *'$1.01'* && "$e2e" == *'2m16s'* \
   && "$e2e" == *'+1/-0'* && "$e2e" == *'63k↑ 248↓'* && "$e2e" == *'○ 6% of 1M'* ]] \
  && ok "e2e: real Enterprise payload renders full dashboard" || bad "e2e — got: $e2e"

# ── locale regression: cost must stay dot-decimal under a comma-radix locale ──
# An inline `LC_ALL=C printf` prefix is ineffective on bash 3.2; fmt_cost uses a
# function-scoped `local LC_ALL=C` instead. Only runs where de_DE is installed.
if locale -a 2>/dev/null | grep -qiE '^de_DE\.utf-?8$'; then
  loc=$(locale -a 2>/dev/null | grep -iE '^de_DE\.utf-?8$' | head -1)
  got=$(LC_ALL="$loc" bash -c 'source ./statusline.sh; theme_default; fmt_cost 1.009058' 2>/dev/null)
  [[ "$got" == '$1.01' ]] && ok "fmt_cost: dot-decimal under $loc" || bad "fmt_cost under $loc -> '$got'"
else
  ok "fmt_cost: comma-locale test skipped (de_DE not installed)"
fi

echo
if (( fails )); then echo "enterprise: $fails FAILED"; exit 1; fi
echo "All enterprise tests passed."
