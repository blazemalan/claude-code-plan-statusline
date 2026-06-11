#!/usr/bin/env bash
# Claude Code statusline that shows plan rate-limit usage (5-hour session + 7-day weekly).
# Reads Claude Code's statusline JSON from stdin — no network, no auth, just jq.
# Requires Claude Code v2.1.80+ (when rate_limits was added to statusline stdin).
#
# Themes: select via ~/.claude/plan-statusline.conf, e.g.:
#   theme=default   # today's look (the safe one)
#   theme=hearth    # warm amber, pulsing sparkle, model-name shimmer
#   theme=glow      # bold bright neon-style, animated sparkle
# Missing or invalid theme → default.

set -uo pipefail

if ! command -v jq >/dev/null 2>&1; then
  printf '\033[31mplan-statusline requires jq to parse data (e.g. brew install jq)\033[0m'
  # Return successfully so we don't break the terminal statusline pipeline
  exit 0
fi

input=$(cat)

# --- Config: read theme name from ~/.claude/plan-statusline.conf if present ---
theme=default
config_file="${HOME}/.claude/plan-statusline.conf"
if [[ -f "$config_file" ]]; then
  while IFS='=' read -r key value; do
    key=${key// /}
    value=${value// /}
    value=${value%\"}; value=${value#\"}
    case "$key" in
      theme) [[ -n "$value" ]] && theme="$value" ;;
    esac
  done < "$config_file"
fi

# --- Parse stdin JSON (one jq call into 7 vars) ---
# Join with the ASCII unit separator (\x1f), NOT @tsv: tab counts as IFS
# *whitespace*, so bash `read` collapses consecutive tabs and empty fields
# shift everything left (a missing context % once rendered the 1M window
# size as "1000000%"). Non-whitespace delimiters preserve empty fields.
IFS=$'\x1f' read -r model five_pct five_reset week_pct week_reset ctx_pct ctx_size < <(
  printf '%s' "$input" | jq -r '[
    .model.display_name // .model.id // "Claude",
    .rate_limits.five_hour.used_percentage // "",
    .rate_limits.five_hour.resets_at // "",
    .rate_limits.seven_day.used_percentage // "",
    .rate_limits.seven_day.resets_at // "",
    .context_window.used_percentage // "",
    .context_window.context_window_size // ""
  ] | map(tostring) | join("\u001f")'
)

# ============================================================================
# Shared helpers (used by every theme)
# ============================================================================

reset_color() { printf '\033[0m'; }

# Format an epoch with a strftime string. BSD date (macOS) uses `-r`; GNU date (Linux/WSL) uses `-d @`.
date_fmt() {
  local epoch=$1 fmt=$2
  date -r "$epoch" "$fmt" 2>/dev/null || date -d "@$epoch" "$fmt" 2>/dev/null
}

fmt_time() {
  local epoch=$1
  [[ -z "$epoch" ]] && return
  date_fmt "$epoch" "+%-I:%M%p" | tr '[:upper:]' '[:lower:]'
}

fmt_size() {
  local n=$1
  [[ -z "$n" ]] && return
  if   ((n >= 1000000)); then printf '%dM' $((n / 1000000))
  elif ((n >= 1000));    then printf '%dk' $((n / 1000))
  else                        printf '%d' "$n"
  fi
}

fmt_when() {
  local epoch=$1
  [[ -z "$epoch" ]] && return
  if [[ "$(date_fmt "$epoch" "+%Y-%m-%d")" == "$(date "+%Y-%m-%d")" ]]; then
    fmt_time "$epoch"
  else
    date_fmt "$epoch" "+%a" | tr '[:upper:]' '[:lower:]'
  fi
}

# Five-step fill circle, used by every theme.
ctx_circle() {
  local pct=${1%.*}
  [[ -z "$pct" ]] && return
  if   ((pct >= 88)); then printf '●'
  elif ((pct >= 63)); then printf '◕'
  elif ((pct >= 38)); then printf '◑'
  elif ((pct >= 13)); then printf '◔'
  else                     printf '○'
  fi
}

# Sparkle frames pulse small ↔ large so the change between renders is dramatic
# (a dot turning into a star is unmistakable, even at slow refresh cadence).
SPARKLES=('·' '✦' '✶' '✦')
sparkle_now() {
  local frame=$(( $(date +%s) % ${#SPARKLES[@]} ))
  printf '%s' "${SPARKLES[$frame]}"
}

# True when either rate limit is pegged at 100% — drives each theme's
# 100% easter egg state (flatline, burnout, game over, skull).
limit_pegged() {
  { [[ -n "$five_pct" ]] && (( ${five_pct%.*} >= 100 )); } ||
  { [[ -n "$week_pct" ]] && (( ${week_pct%.*} >= 100 )); }
}

# ============================================================================
# Theme: default — today's look (preserved exactly)
# ============================================================================

default_color() {
  local pct=${1%.*}
  [[ -z "$pct" ]] && return
  if   ((pct >= 90)); then printf '\033[31m'
  elif ((pct >= 70)); then printf '\033[38;5;208m'
  elif ((pct >= 50)); then printf '\033[33m'
  else                     printf '\033[32m'
  fi
}

render_default() {
  local segments=()
  segments+=("$(printf '\033[1m%s\033[0m' "$model")")

  if [[ -n "$five_pct" ]]; then
    local pct=${five_pct%.*}
    if ((pct >= 100)); then
      # 100% easter egg: you died. Respawn timer below.
      segments+=("$(printf '\033[31m5h: 100%% 💀\033[0m') (respawn →$(fmt_time "$five_reset"))")
    else
      segments+=("$(default_color "$five_pct")5h: ${pct}%$(reset_color) (→$(fmt_time "$five_reset"))")
    fi
  fi

  if [[ -n "$week_pct" ]]; then
    local pct=${week_pct%.*}
    if ((pct >= 100)); then
      segments+=("$(printf '\033[31mweek: 100%% 💀\033[0m') (respawn →$(fmt_when "$week_reset"))")
    else
      segments+=("$(default_color "$week_pct")week: ${pct}%$(reset_color) (→$(fmt_when "$week_reset"))")
    fi
  fi

  if [[ -n "$ctx_pct" ]]; then
    local pct=${ctx_pct%.*}
    local size_label=""
    [[ -n "$ctx_size" ]] && size_label=" of $(fmt_size "$ctx_size")"
    segments+=("$(default_color "$ctx_pct")$(ctx_circle "$ctx_pct") ${pct}%${size_label}$(reset_color)")
  fi

  if [[ -z "$ctx_pct" && -z "$five_pct" && -z "$week_pct" ]]; then
    segments+=("usage data pending - make a request")
  fi

  local sep=" │ "
  local out=""
  local s
  for s in "${segments[@]}"; do
    [[ -n "$out" ]] && out+="$sep"
    out+="$s"
  done
  printf '%b' "$out"
}

# ============================================================================
# Theme: hearth — restrained warm
#   • pulsing sparkle (· ↔ ✶) prefixes the model name
#   • shimmer: one character of the model name is bolded per render, position
#     rotates per second so the bright char "drifts" across the name
#   • amber glyphs, dim italic reset times
#   • tier color only kicks in for warn (orange) and urgent (bold red)
# ============================================================================

H_AMBER='\033[38;5;214m'    # warm amber — visible on light & dark
H_DIM='\033[2m'             # dim attribute — adapts to terminal bg
H_DIM_IT='\033[2;3m'        # dim italic — adapts
H_ORANGE='\033[38;5;208m'   # warning
H_RED='\033[1;38;5;196m'    # bold red, urgent
H_BOLD='\033[1m'
H_NOBOLD='\033[22m'
H_RESET='\033[0m'

# Body text uses the terminal's default foreground so the theme reads on
# both light and dark backgrounds. Tier colors only kick in for warn/urgent.
hearth_tier_fg() {
  local pct=${1%.*}
  [[ -z "$pct" ]] && return  # empty = no color = terminal default
  if   ((pct >= 90)); then printf '%b' "$H_RED"
  elif ((pct >= 70)); then printf '%b' "$H_ORANGE"
  fi
  # else: silent → text renders in default fg
}

# Render TEXT with one character bolded; the bold position rotates per second
# so a "shimmer" appears to drift across the text between renders. No color
# applied — the terminal's default fg carries it on both light & dark bg.
hearth_shimmer() {
  local text=$1
  local n=${#text}
  (( n == 0 )) && { printf '%s' "$text"; return; }
  local pos=$(( $(date +%s) % n ))
  local i char
  for ((i=0; i<n; i++)); do
    char="${text:i:1}"
    if (( i == pos )); then
      printf '%b%s%b' "$H_BOLD" "$char" "$H_NOBOLD"
    else
      printf '%s' "$char"
    fi
  done
}

# 100% easter egg: the fire has gone out. The sparkle stops and a wisp of
# smoke drifts up from the cold hearth (frames rise · → ˚ per second).
HEARTH_SMOKE=('∙' '∘' '°' '˚')
hearth_spark() {
  if limit_pegged; then
    local frame=$(( $(date +%s) % ${#HEARTH_SMOKE[@]} ))
    printf '%b%s%b' "$H_DIM" "${HEARTH_SMOKE[$frame]}" "$H_RESET"
  else
    printf '%b%s%b' "$H_AMBER" "$(sparkle_now)" "$H_RESET"
  fi
}

# A pegged limit reads as a cold ember: dim hollow circle, "burnt out",
# and the reset time becomes the rekindling.
hearth_burnout() {
  local label=$1 reset_label=$2
  printf '%b○%b %s %bburnt out%b %b(rekindles →%s)%b' \
    "$H_DIM" "$H_RESET" "$label" \
    "$H_RED" "$H_RESET" \
    "$H_DIM_IT" "$reset_label" "$H_RESET"
}

render_hearth() {
  if [[ -z "$ctx_pct" && -z "$five_pct" && -z "$week_pct" ]]; then
    printf '%b%s%b %busage data pending - make a request%b' \
      "$H_AMBER" "$(sparkle_now)" "$H_RESET" "$H_DIM_IT" "$H_RESET"
    return
  fi

  local sep
  sep=$(printf '%b · %b' "$H_DIM" "$H_RESET")

  printf '%s %s' "$(hearth_spark)" "$(hearth_shimmer "$model")"

  if [[ -n "$five_pct" ]]; then
    local pct=${five_pct%.*}
    printf '%b' "$sep"
    if (( pct >= 100 )); then
      hearth_burnout "5h" "$(fmt_time "$five_reset")"
    else
      printf '%b%s%b 5h %b%d%%%b %b(→%s)%b' \
        "$H_AMBER" "$(ctx_circle "$five_pct")" "$H_RESET" \
        "$(hearth_tier_fg "$five_pct")" "$pct" "$H_RESET" \
        "$H_DIM_IT" "$(fmt_time "$five_reset")" "$H_RESET"
    fi
  fi

  if [[ -n "$week_pct" ]]; then
    local pct=${week_pct%.*}
    printf '%b' "$sep"
    if (( pct >= 100 )); then
      hearth_burnout "week" "$(fmt_when "$week_reset")"
    else
      printf '%b%s%b week %b%d%%%b %b(→%s)%b' \
        "$H_AMBER" "$(ctx_circle "$week_pct")" "$H_RESET" \
        "$(hearth_tier_fg "$week_pct")" "$pct" "$H_RESET" \
        "$H_DIM_IT" "$(fmt_when "$week_reset")" "$H_RESET"
    fi
  fi

  if [[ -n "$ctx_pct" ]]; then
    local pct=${ctx_pct%.*}
    local size_label=""
    [[ -n "$ctx_size" ]] && size_label=" of $(fmt_size "$ctx_size")"
    printf '%b' "$sep"
    printf '%b%s%b %b%d%%%b%b%s%b' \
      "$H_AMBER" "$(ctx_circle "$ctx_pct")" "$H_RESET" \
      "$(hearth_tier_fg "$ctx_pct")" "$pct" "$H_RESET" \
      "$H_DIM_IT" "$size_label" "$H_RESET"
  fi
}

# ============================================================================
# Theme: glow — pink neon arcade
#   • Two hue families only: pink (the theme) + mint (cool counterpoint at
#     calm). Sparkle and hot-tier share the same magenta on purpose — when
#     usage climbs into the hot zone, the data lights up in the theme's
#     signature color, then breaks to red at urgent for the alarm escape.
#   • Bold weight + saturated 256-color values approximate "neon tube"
#     since terminals can't text-shadow.
#   • Italic rose halo for meta; dim middle-dot separators.
# ============================================================================

G_NEON='\033[1;38;5;199m'   # bold magenta — signature theme color.
                            #   Used for: sparkle (the bright headline tube)
                            #   AND the hot tier (data joins the theme color
                            #   when usage gets serious).
G_MODEL='\033[1m'           # bold only — uses terminal default fg, adapts
G_MINT='\033[1;38;5;41m'    # bold electric mint — calm tier, the only
                            #   non-pink hue. Reads as "you're fine" without
                            #   adding a third color family.
G_PINK='\033[1;38;5;205m'   # bold light hot pink — warn tier, the on-ramp
                            #   into the pink spectrum before it deepens to
                            #   magenta at hot.
G_RED='\033[1;38;5;197m'    # bold pink-red — urgent, the red end of the pink
                            #   spectrum. Stays on theme (magenta hue family)
                            #   while reading clearly as alarm. Pure 196 broke
                            #   the palette identity; 197 keeps it inside.
G_DIM='\033[2m'             # plain dim — separators only; adapts to bg
G_META='\033[3;38;5;175m'   # italic desaturated rose — soft bloom halo. Lower
                            #   luminance than the bright tubes so it reads as
                            #   "the air around them glowing," not as data.
G_RESET='\033[0m'

glow_tier_fg() {
  local pct=${1%.*}
  [[ -z "$pct" ]] && { printf '%b' "$G_MINT"; return; }
  if   ((pct >= 90)); then printf '%b' "$G_RED"
  elif ((pct >= 70)); then printf '%b' "$G_NEON"
  elif ((pct >= 50)); then printf '%b' "$G_PINK"
  else                     printf '%b' "$G_MINT"
  fi
}

# 100% easter egg: the cabinet drops into attract mode. The segment flashes
# between GAME OVER (alarm red-pink) and INSERT COIN (signature magenta) once
# per second, and the reset time becomes the free credit — your 1UP.
glow_gameover() {
  local label=$1 reset_label=$2
  local msg='GAME OVER' fg="$G_RED"
  (( $(date +%s) % 2 )) && { msg='INSERT COIN'; fg="$G_NEON"; }
  printf '%b%s %s%b %b(1UP →%s)%b' \
    "$fg" "$label" "$msg" "$G_RESET" \
    "$G_META" "$reset_label" "$G_RESET"
}

render_glow() {
  if [[ -z "$ctx_pct" && -z "$five_pct" && -z "$week_pct" ]]; then
    printf '%b%s%b %busage data pending - make a request%b' \
      "$G_NEON" "$(sparkle_now)" "$G_RESET" "$G_META" "$G_RESET"
    return
  fi

  local sep
  sep=$(printf '%b · %b' "$G_DIM" "$G_RESET")

  printf '%b%s%b %b%s%b' \
    "$G_NEON" "$(sparkle_now)" "$G_RESET" \
    "$G_MODEL" "$model" "$G_RESET"

  if [[ -n "$five_pct" ]]; then
    local pct=${five_pct%.*}
    printf '%b' "$sep"
    if (( pct >= 100 )); then
      glow_gameover "5h" "$(fmt_time "$five_reset")"
    else
      printf '%b%s 5h %d%%%b %b(→%s)%b' \
        "$(glow_tier_fg "$five_pct")" "$(ctx_circle "$five_pct")" "$pct" "$G_RESET" \
        "$G_META" "$(fmt_time "$five_reset")" "$G_RESET"
    fi
  fi

  if [[ -n "$week_pct" ]]; then
    local pct=${week_pct%.*}
    printf '%b' "$sep"
    if (( pct >= 100 )); then
      glow_gameover "week" "$(fmt_when "$week_reset")"
    else
      printf '%b%s week %d%%%b %b(→%s)%b' \
        "$(glow_tier_fg "$week_pct")" "$(ctx_circle "$week_pct")" "$pct" "$G_RESET" \
        "$G_META" "$(fmt_when "$week_reset")" "$G_RESET"
    fi
  fi

  if [[ -n "$ctx_pct" ]]; then
    local pct=${ctx_pct%.*}
    local size_label=""
    [[ -n "$ctx_size" ]] && size_label=" of $(fmt_size "$ctx_size")"
    printf '%b' "$sep"
    printf '%b%s %d%%%b%b%s%b' \
      "$(glow_tier_fg "$ctx_pct")" "$(ctx_circle "$ctx_pct")" "$pct" "$G_RESET" \
      "$G_META" "$size_label" "$G_RESET"
  fi
}

# ============================================================================
# Theme: scrubs — clinical teal vitals monitor
#   • Surgical-scrubs teal as the calm/normal state; the line reads like a
#     patient-vitals display. Brand-clean clinical palette (teal primaries
#     + soft light-teal halo), with universal monitor-alarm colors (amber,
#     red) reserved for when usage actually climbs — so the teal dominates
#     the healthy range you sit in most of the time.
#   • A health-cross "heartbeat" pulses in place of the model-name sparkle.
# ============================================================================

S_TEAL='\033[38;5;30m'      # teal (#008787) — calm/normal tier, the resting vital
S_BRIGHT='\033[1;38;5;37m'  # bold bright teal (#00afaf) — heartbeat + elevated tier
S_AMBER='\033[38;5;214m'    # amber (#ffaf00) — caution tier, monitor alarm yellow
S_RED='\033[1;38;5;196m'    # bold red (#ff0000) — critical tier, the alarm
S_META='\033[3;38;5;152m'   # italic light teal (#afd7d7) — soft halo for reset times
S_DIM='\033[2m'             # plain dim — separators only; adapts to bg
S_BOLD='\033[1m'            # bold only — model name, uses terminal default fg
S_RESET='\033[0m'

# Health-cross heartbeat: dot → thin plus → heavy cross → thin plus. Pulses
# once per second so the "·" swelling into "✚" reads as a vital sign ticking.
SCRUBS_BEAT=('·' '+' '✚' '+')

scrubs_beat() {
  # No pulse on a coded patient: the heartbeat flatlines.
  limit_pegged && { printf '─'; return; }
  local frame=$(( $(date +%s) % ${#SCRUBS_BEAT[@]} ))
  printf '%s' "${SCRUBS_BEAT[$frame]}"
}

# 100% easter egg: the monitor calls a code. The segment flashes between the
# alarm call and a flat trace once per second, and the reset time becomes the
# defib charge time ("when the paddles bring you back").
scrubs_flatline() {
  local label=$1 reset_label=$2
  local msg='CODE BLUE'
  (( $(date +%s) % 2 )) && msg='▁▁▁▁▁▁▁▁▁'
  printf '%b%s %s%b %b(defib →%s)%b' \
    "$S_RED" "$label" "$msg" "$S_RESET" \
    "$S_META" "$reset_label" "$S_RESET"
}

scrubs_tier_fg() {
  local pct=${1%.*}
  [[ -z "$pct" ]] && { printf '%b' "$S_TEAL"; return; }
  if   ((pct >= 90)); then printf '%b' "$S_RED"
  elif ((pct >= 70)); then printf '%b' "$S_AMBER"
  elif ((pct >= 50)); then printf '%b' "$S_BRIGHT"
  else                     printf '%b' "$S_TEAL"
  fi
}

render_scrubs() {
  if [[ -z "$ctx_pct" && -z "$five_pct" && -z "$week_pct" ]]; then
    printf '%b%s%b %busage data pending - make a request%b' \
      "$S_BRIGHT" "$(scrubs_beat)" "$S_RESET" "$S_META" "$S_RESET"
    return
  fi

  local sep
  sep=$(printf '%b · %b' "$S_DIM" "$S_RESET")

  printf '%b%s%b %b%s%b' \
    "$S_BRIGHT" "$(scrubs_beat)" "$S_RESET" \
    "$S_BOLD" "$model" "$S_RESET"

  if [[ -n "$five_pct" ]]; then
    local pct=${five_pct%.*}
    printf '%b' "$sep"
    if (( pct >= 100 )); then
      scrubs_flatline "5h" "$(fmt_time "$five_reset")"
    else
      printf '%b%s 5h %d%%%b %b(→%s)%b' \
        "$(scrubs_tier_fg "$five_pct")" "$(ctx_circle "$five_pct")" "$pct" "$S_RESET" \
        "$S_META" "$(fmt_time "$five_reset")" "$S_RESET"
    fi
  fi

  if [[ -n "$week_pct" ]]; then
    local pct=${week_pct%.*}
    printf '%b' "$sep"
    if (( pct >= 100 )); then
      scrubs_flatline "week" "$(fmt_when "$week_reset")"
    else
      printf '%b%s week %d%%%b %b(→%s)%b' \
        "$(scrubs_tier_fg "$week_pct")" "$(ctx_circle "$week_pct")" "$pct" "$S_RESET" \
        "$S_META" "$(fmt_when "$week_reset")" "$S_RESET"
    fi
  fi

  if [[ -n "$ctx_pct" ]]; then
    local pct=${ctx_pct%.*}
    local size_label=""
    [[ -n "$ctx_size" ]] && size_label=" of $(fmt_size "$ctx_size")"
    printf '%b' "$sep"
    printf '%b%s %d%%%b%b%s%b' \
      "$(scrubs_tier_fg "$ctx_pct")" "$(ctx_circle "$ctx_pct")" "$pct" "$S_RESET" \
      "$S_META" "$size_label" "$S_RESET"
  fi
}

# ============================================================================
# Dispatch
# ============================================================================

case "$theme" in
  hearth)         render_hearth ;;
  glow)           render_glow ;;
  scrubs)         render_scrubs ;;
  default|*)      render_default ;;
esac
