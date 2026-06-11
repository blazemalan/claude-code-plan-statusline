#!/usr/bin/env bash
# Print sRGB hex for one or more xterm 256-color cube indices.
# Useful for keeping bash escape codes (\033[...;5;N m) in sync with the
# preview's CSS hex values when designing new themes.
#
#   ./tests/xterm-hex.sh 199 197 41
#   199 → #ff00af
#   197 → #ff005f
#    41 → #00d75f
#
# With no arguments, prints the indices currently used by each theme.

set -euo pipefail

steps=(0 95 135 175 215 255)

# sRGB hex for an xterm-256 index: 16-231 color cube, 232-255 grayscale ramp.
cube_hex() {
  local n=$1
  if (( n >= 232 && n <= 255 )); then
    local L=$(( 8 + (n - 232) * 10 ))
    printf '#%02x%02x%02x' "$L" "$L" "$L"
    return
  fi
  if (( n < 16 || n > 231 )); then
    printf 'unsupported index (16-255): %s\n' "$n" >&2
    return 1
  fi
  local cube=$((n - 16))
  local r=${steps[$((cube / 36))]}
  local g=${steps[$(((cube / 6) % 6))]}
  local b=${steps[$((cube % 6))]}
  printf '#%02x%02x%02x' "$r" "$g" "$b"
}

if (( $# > 0 )); then
  for n in "$@"; do
    printf '%3d → %s\n' "$n" "$(cube_hex "$n")"
  done
  exit 0
fi

printf 'default (tiers 208; ramp 252,255):\n'
for n in 208 252 255; do printf '  %3d → %s\n' "$n" "$(cube_hex "$n")"; done

printf '\nhearth (tiers 208,196; ramp 214,221,230):\n'
for n in 208 196 214 221 230; do printf '  %3d → %s\n' "$n" "$(cube_hex "$n")"; done

printf '\nglow (tiers 41,205,199,197; ramp 205,199,231; meta 175):\n'
for n in 41 205 199 197 231 175; do printf '  %3d → %s\n' "$n" "$(cube_hex "$n")"; done

printf '\nscrubs (tiers 30,37,214,196; ramp 30,37,159; meta 152):\n'
for n in 30 37 214 196 159 152; do printf '  %3d → %s\n' "$n" "$(cube_hex "$n")"; done
