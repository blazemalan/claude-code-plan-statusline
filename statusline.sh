#!/usr/bin/env bash
# Claude Code statusline that shows plan rate-limit usage (5-hour session + 7-day weekly).
# Reads Claude Code's statusline JSON from stdin — no network, no auth, just jq.
# Requires Claude Code v2.1.80+ (when rate_limits was added to statusline stdin).
#
# Each theme renders the model name in its own solid color. Select via
# ~/.claude/plan-statusline.conf, e.g.:
#   theme=default   # basic ANSI; bold name
#   theme=hearth    # warm amber, fixed-amber circles, silent until 70%
#   theme=glow      # pink neon arcade, mint→magenta tier ramp
#   theme=scrubs    # clinical teal vitals monitor
# Missing or invalid theme → default.

set -uo pipefail

if ! command -v jq >/dev/null 2>&1; then
  printf '\033[31mplan-statusline requires jq to parse data (e.g. brew install jq)\033[0m'
  # Return successfully so we don't break the terminal statusline pipeline
  exit 0
fi

# ============================================================================
# Shared helpers (used by every theme)
# ============================================================================

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

# Session cost in dollars -> "$1.01". jq always emits a dot-decimal, but printf's
# %f parses AND formats in the current locale, so a comma-radix locale (de_DE …)
# would both reject "1.009058" and print "$0,00". A *function-scoped* LC_ALL=C
# pins the radix to '.' for the builtin (an inline `LC_ALL=C printf` prefix does
# NOT take effect on bash 3.2, macOS's system bash); `local` restores it on return.
fmt_cost() {
  local usd=$1
  [[ -z "$usd" ]] && return
  local LC_ALL=C
  printf '$%.2f' "$usd"
}

# Milliseconds of wall-clock -> compact "45s" / "2m16s" / "1h3m".
fmt_duration() {
  local ms=$1
  [[ -z "$ms" ]] && return
  local s=$(( ms / 1000 ))
  if   (( s >= 3600 )); then printf '%dh%dm' $(( s / 3600 )) $(( (s % 3600) / 60 ))
  elif (( s >= 60 ));   then printf '%dm%ds' $(( s / 60 )) $(( s % 60 ))
  else                       printf '%ds' "$s"
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

# True when either rate limit is pegged at 100% — drives each theme's
# 100% easter egg state (flatline, burnout, game over, skull).
limit_pegged() {
  { [[ -n "$five_pct" ]] && (( ${five_pct%.*} >= 100 )); } ||
  { [[ -n "$week_pct" ]] && (( ${week_pct%.*} >= 100 )); }
}

# Render the model name in the theme's solid NAME_SGR (empty -> terminal default
# fg). One opening SGR for the whole string, so the name is a single clean span.
# At 100% plan usage the name "dies": dimmed, matching each theme's pegged
# easter-egg state. (The statusline repaints at most ~1×/sec, far too coarse for
# smooth motion, so the name is static rather than animated.)
render_name() {
  local text=$1
  (( ${#text} == 0 )) && return
  if limit_pegged; then
    printf '\033[2m%s\033[0m' "$text"
    return
  fi
  if [[ -n "$NAME_SGR" ]]; then
    printf '\033[%sm%s\033[0m' "$NAME_SGR" "$text"
  else
    printf '%s' "$text"
  fi
}

# ============================================================================
# Theme loaders — each sets the globals render_line consumes. Pure data.
# Tier thresholds are shared: urgent >=90, hot >=70, warn >=50, else calm.
# Empty TIER_* = terminal default fg (used by hearth's silent calm/warn).
# ============================================================================

theme_default() {            # basic ANSI, faithful to the original look
  TIER_CALM=32; TIER_WARN=33; TIER_HOT='38;5;208'; TIER_URGENT=31
  NAME_SGR='1'                                # bold, terminal default fg
  SEP=' │ '; SEP_COLOR=''
  META=''                                      # reset/size inherit tier color
  SEG_CIRCLE=0; LABEL_SEP=':'
  # '@tier' sentinel: circle/label color tracks the value's tier color (all-one-span).
  CIRCLE_SGR='@tier'; LABEL_SGR='@tier'
  EGG_GLYPH=''; EGG_GLYPH_COLOR=''
  EGG_MSG_A='100% 💀'; EGG_COLOR_A=31
  EGG_MSG_B='100% 💀'; EGG_COLOR_B=31          # equal -> no flash
  EGG_RESET_WORD='respawn'
}

theme_hearth() {             # warm amber, restrained (silent calm/warn)
  TIER_CALM=''; TIER_WARN=''; TIER_HOT='38;5;208'; TIER_URGENT='1;38;5;196'
  NAME_SGR='1;38;5;214'                               # bold amber
  SEP=' · '; SEP_COLOR=2
  META='2;3'                                   # dim italic
  SEG_CIRCLE=1; LABEL_SEP=''
  CIRCLE_SGR='38;5;214'; LABEL_SGR=''
  EGG_GLYPH='○'; EGG_GLYPH_COLOR=2
  EGG_MSG_A='burnt out'; EGG_COLOR_A='1;38;5;196'
  EGG_MSG_B='burnt out'; EGG_COLOR_B='1;38;5;196'
  EGG_RESET_WORD='rekindles'
}

theme_glow() {               # pink neon arcade
  TIER_CALM='1;38;5;41'; TIER_WARN='1;38;5;205'; TIER_HOT='1;38;5;199'; TIER_URGENT='1;38;5;197'
  NAME_SGR='1;38;5;199'                                   # bold magenta
  SEP=' · '; SEP_COLOR=2
  META='3;38;5;175'                            # italic rose
  SEG_CIRCLE=1; LABEL_SEP=''
  CIRCLE_SGR='@tier'; LABEL_SGR='@tier'
  EGG_GLYPH=''; EGG_GLYPH_COLOR=''
  EGG_MSG_A='GAME OVER';   EGG_COLOR_A='1;38;5;197'
  EGG_MSG_B='INSERT COIN'; EGG_COLOR_B='1;38;5;199'   # flashes
  EGG_RESET_WORD='1UP'
}

theme_scrubs() {             # clinical teal vitals monitor
  TIER_CALM='38;5;30'; TIER_WARN='1;38;5;37'; TIER_HOT='38;5;214'; TIER_URGENT='1;38;5;196'
  NAME_SGR='1;38;5;37'                              # bold bright teal
  SEP=' · '; SEP_COLOR=2
  META='3;38;5;152'                            # italic light teal
  SEG_CIRCLE=1; LABEL_SEP=''
  CIRCLE_SGR='@tier'; LABEL_SGR='@tier'
  EGG_GLYPH=''; EGG_GLYPH_COLOR=''
  EGG_MSG_A='CODE BLUE';      EGG_COLOR_A='1;38;5;196'
  EGG_MSG_B='▁▁▁▁▁▁▁▁▁';      EGG_COLOR_B='1;38;5;196'   # flashes (text <-> flat trace)
  EGG_RESET_WORD='defib'
}

# ============================================================================
# Shared renderer
# ============================================================================

# Wrap TEXT in an SGR if non-empty (self-terminating); else print plain.
paint() {
  local sgr=$1 text=$2
  if [[ -n "$sgr" ]]; then printf '\033[%sm%s\033[0m' "$sgr" "$text"
  else printf '%s' "$text"; fi
}

paint_sep() { paint "$SEP_COLOR" "$SEP"; }

# SGR for a percentage by shared tier thresholds (may be empty = default fg).
tier_color() {
  local pct=${1%.*}
  [[ -z "$pct" ]] && return
  if   (( pct >= 90 )); then printf '%s' "$TIER_URGENT"
  elif (( pct >= 70 )); then printf '%s' "$TIER_HOT"
  elif (( pct >= 50 )); then printf '%s' "$TIER_WARN"
  else                       printf '%s' "$TIER_CALM"
  fi
}

# SGR for a session cost (USD) by dollar thresholds, mapped onto the shared
# TIER_* colors so each theme's ramp applies. Compared on the integer-dollar
# part to dodge bash float math. Thresholds are tunable: calm <$2, warn >=$2,
# hot >=$5, urgent >=$10.
cost_tier_color() {
  local usd=$1
  [[ -z "$usd" ]] && return
  local dollars=${usd%.*}; dollars=${dollars:-0}
  if   (( dollars >= 10 )); then printf '%s' "$TIER_URGENT"
  elif (( dollars >= 5 ));  then printf '%s' "$TIER_HOT"
  elif (( dollars >= 2 ));  then printf '%s' "$TIER_WARN"
  else                           printf '%s' "$TIER_CALM"
  fi
}

# Meta SGR: explicit META if set, else inherit the segment's tier SGR
# (so default's reset times / size label match the value color, as before).
meta_sgr() { if [[ -n "$META" ]]; then printf '%s' "$META"; else printf '%s' "$1"; fi; }

# Resolve a span-color spec against the value's tier color: '@tier' -> tier,
# anything else (including '' = default fg) is used literally.
span_sgr() { if [[ "$1" == '@tier' ]]; then printf '%s' "$2"; else printf '%s' "$1"; fi; }

# A rate segment (5h / week). Circle, label, and value are painted as separate
# spans so each can take its own color (hearth: amber circle, plain label,
# tier value; others: all tier). Falls through to the easter egg at 100%.
seg_rate() {
  local label=$1 pctraw=$2 reset_str=$3
  local pct=${pctraw%.*}
  if (( pct >= 100 )); then egg "$label" "$reset_str"; return; fi
  local tier; tier=$(tier_color "$pct")
  if (( SEG_CIRCLE )); then
    paint "$(span_sgr "$CIRCLE_SGR" "$tier")" "$(ctx_circle "$pct")"; printf ' '
  fi
  paint "$(span_sgr "$LABEL_SGR" "$tier")" "${label}${LABEL_SEP}"
  printf ' '
  paint "$tier" "${pct}%"
  printf ' '
  paint "$(meta_sgr '')" "(→${reset_str})"
}

# The context segment: always circled, no label / reset / egg. Circle uses
# CIRCLE_SGR (hearth: amber; others: tier); value uses tier; size uses META
# (or tier when META is empty, matching default's original look).
seg_ctx() {
  local pctraw=$1 size=$2
  local pct=${pctraw%.*}
  local tier; tier=$(tier_color "$pct")
  paint "$(span_sgr "$CIRCLE_SGR" "$tier")" "$(ctx_circle "$pct")"; printf ' '
  paint "$tier" "${pct}%"
  [[ -n "$size" ]] && paint "$(meta_sgr "$tier")" "$size"
}

# 100% easter egg for a rate segment. Flashes A<->B per second when they differ.
# The label is colored like the message EXCEPT when LABEL_SGR is empty (hearth),
# where it stays default-fg. The reset clause uses META, or plain when META is
# empty (default), matching the originals.
egg() {
  local label=$1 reset_str=$2 msg col lblcol
  if (( $(date +%s) % 2 )) && [[ "$EGG_MSG_A" != "$EGG_MSG_B" ]]; then
    msg=$EGG_MSG_B; col=$EGG_COLOR_B
  else
    msg=$EGG_MSG_A; col=$EGG_COLOR_A
  fi
  [[ -n "$EGG_GLYPH" ]] && printf '\033[%sm%s\033[0m ' "$EGG_GLYPH_COLOR" "$EGG_GLYPH"
  if [[ -n "$LABEL_SGR" ]]; then lblcol=$col; else lblcol=''; fi
  paint "$lblcol" "${label}${LABEL_SEP}"
  printf ' '
  paint "$col" "$msg"
  printf ' '
  if [[ -n "$META" ]]; then
    paint "$META" "(${EGG_RESET_WORD} →${reset_str})"
  else
    printf '(%s →%s)' "$EGG_RESET_WORD" "$reset_str"
  fi
}

# The one renderer: swept model name, then any present segments joined by SEP.
render_line() {
  # Enterprise/managed payloads carry no rate_limits; default the fields they
  # DO carry to empty so plan-mode callers under `set -u` (tests, etc.) that
  # never set them don't trip the unbound-variable guard.
  local cost_usd=${cost_usd:-} dur_ms=${dur_ms:-} \
        lines_added=${lines_added:-} lines_removed=${lines_removed:-} \
        in_tokens=${in_tokens:-} out_tokens=${out_tokens:-}

  # Nothing to show yet (fresh session, before the first API response).
  if [[ -z "$ctx_pct" && -z "$five_pct" && -z "$week_pct" && -z "$cost_usd" ]]; then
    render_name "$model"; paint_sep
    paint "$META" 'usage data pending - make a request'
    return
  fi

  render_name "$model"

  if [[ -n "$five_pct" || -n "$week_pct" ]]; then
    # Plan mode (Pro/Max): rolling rate-limit windows.
    [[ -n "$five_pct" ]] && { paint_sep; seg_rate '5h' "$five_pct" "$(fmt_time "$five_reset")"; }
    [[ -n "$week_pct" ]] && { paint_sep; seg_rate 'week' "$week_pct" "$(fmt_when "$week_reset")"; }
  else
    # Enterprise/managed mode: no rate windows exist in the payload. Show a
    # session dashboard — each segment only if its data is present. Cost
    # carries the green->red tier ramp (the headline); duration/lines/tokens
    # are informational and ride META (plain in default, dim in other themes).
    [[ -n "$cost_usd" ]] && { paint_sep; paint "$(cost_tier_color "$cost_usd")" "$(fmt_cost "$cost_usd")"; }
    [[ -n "$dur_ms" ]]   && { paint_sep; paint "$(meta_sgr '')" "$(fmt_duration "$dur_ms")"; }
    [[ -n "$lines_added" || -n "$lines_removed" ]] && \
      { paint_sep; paint "$(meta_sgr '')" "+${lines_added:-0}/-${lines_removed:-0}"; }
    [[ -n "$in_tokens" || -n "$out_tokens" ]] && \
      { paint_sep; paint "$(meta_sgr '')" "$(fmt_size "${in_tokens:-0}")↑ $(fmt_size "${out_tokens:-0}")↓"; }
  fi

  # Context fill renders in both modes (it is per-chat, not a plan limit).
  if [[ -n "$ctx_pct" ]]; then
    local size=''; [[ -n "$ctx_size" ]] && size=" of $(fmt_size "$ctx_size")"
    paint_sep; seg_ctx "$ctx_pct" "$size"
  fi
}

# ============================================================================
# main — only runs when executed, not when sourced
# ============================================================================

main() {
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

  # --- Parse stdin JSON (one jq call into 13 vars) ---
  # First 7 are the Pro/Max plan fields; the last 6 are the Enterprise/managed
  # fields (that payload has no rate_limits). Join with the ASCII unit separator
  # (\x1f), NOT @tsv: tab counts as IFS *whitespace*, so bash `read` collapses
  # consecutive tabs and empty fields shift everything left (a missing context %
  # once rendered the 1M window size as "1000000%"). Non-whitespace delimiters
  # preserve empty fields.
  IFS=$'\x1f' read -r model five_pct five_reset week_pct week_reset ctx_pct ctx_size \
    cost_usd dur_ms lines_added lines_removed in_tokens out_tokens < <(
    printf '%s' "$input" | jq -r '[
      .model.display_name // .model.id // "Claude",
      .rate_limits.five_hour.used_percentage // "",
      .rate_limits.five_hour.resets_at // "",
      .rate_limits.seven_day.used_percentage // "",
      .rate_limits.seven_day.resets_at // "",
      .context_window.used_percentage // "",
      .context_window.context_window_size // "",
      .cost.total_cost_usd // "",
      .cost.total_duration_ms // "",
      .cost.total_lines_added // "",
      .cost.total_lines_removed // "",
      .context_window.total_input_tokens // "",
      .context_window.total_output_tokens // ""
    ] | map(tostring) | join("\u001f")'
  )

  # --- Dispatch: load theme data, render once ---
  case "$theme" in
    hearth) theme_hearth ;;
    glow)   theme_glow ;;
    scrubs) theme_scrubs ;;
    default|*) theme_default ;;
  esac
  render_line
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main
fi
