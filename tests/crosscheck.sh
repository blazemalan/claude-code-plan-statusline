#!/usr/bin/env bash

set -euo pipefail

if ! command -v pwsh >/dev/null 2>&1; then
  echo "pwsh not found, skipping cross-check."
  exit 0
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "jq not found, skipping cross-check."
  exit 0
fi

FIXTURES_DIR="$(dirname "$0")/fixtures"
THEMES=("default" "hearth" "glow" "scrubs" "harbor" "atomic" "slime" "rainbow" "dracula" "nord" "gruvbox" "catppuccin" "no-config")
EPOCHS=("1000000000" "1000000001")
NO_COLORS=("" "1")   # exercise both colored and NO_COLOR output
TIMEZONES=("UTC" "America/Phoenix")

TOTAL_CHECKS=0
FAILED_CHECKS=0

TEMP_HOME=$(mktemp -d)
trap 'rm -rf "$TEMP_HOME"' EXIT
mkdir -p "$TEMP_HOME/.claude"

for tz in "${TIMEZONES[@]}"; do
  for epoch in "${EPOCHS[@]}"; do
    for theme in "${THEMES[@]}"; do
      if [[ "$theme" == "no-config" ]]; then
        rm -f "$TEMP_HOME/.claude/plan-statusline.conf"
      else
        echo "theme=$theme" > "$TEMP_HOME/.claude/plan-statusline.conf"
      fi

      for nc in "${NO_COLORS[@]}"; do
      for fixture in "$FIXTURES_DIR"/*.json; do
        fixture_name=$(basename "$fixture")

        # Run bash script
        out_bash=$(TZ="$tz" LC_ALL=C PLAN_SL_NOW="$epoch" NO_COLOR="$nc" HOME="$TEMP_HOME" bash statusline.sh < "$fixture")

        # Run pwsh script
        out_pwsh=$(TZ="$tz" LC_ALL=C PLAN_SL_NOW="$epoch" NO_COLOR="$nc" HOME="$TEMP_HOME" pwsh -NoProfile -File statusline.ps1 < "$fixture")

        TOTAL_CHECKS=$((TOTAL_CHECKS + 1))

        if [[ "$out_bash" != "$out_pwsh" ]]; then
          echo "Mismatch!"
          echo "Fixture: $fixture_name | Theme: $theme | TZ: $tz | Epoch: $epoch | NO_COLOR='$nc'"
          echo "Bash output (hex):"
          echo -n "$out_bash" | xxd
          echo "PowerShell output (hex):"
          echo -n "$out_pwsh" | xxd
          FAILED_CHECKS=$((FAILED_CHECKS + 1))
          exit 1
        fi
      done
      done
    done
  done
done

echo "Successfully cross-checked $TOTAL_CHECKS combinations."
exit 0
