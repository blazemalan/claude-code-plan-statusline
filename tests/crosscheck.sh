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

# ── model-scoped weekly windows (model_weekly=on) ────────────────────────────
# Kept as a separate, bounded pass rather than another dimension on the matrix
# above: the segment's rendering depends on theme/TZ/epoch/NO_COLOR but not on
# which stdin fixture is used, so three representative payloads (plan, the
# Enterprise dashboard it must stay out of, and pending) cover it without
# multiplying the whole run. The scoped fixture deliberately includes a bucket
# at 100% (egg + name dimming), a label needing sanitising, a fractional
# percent, a null reset, and a fourth bucket that the 3-record cap must drop.
SCOPED_SRC="$(dirname "$0")/scoped-claude-config.json"
cp "$SCOPED_SRC" "$TEMP_HOME/.claude.json"
# Must sit within the freshness window of the fixtures' fetchedAtMs
# (1786663000000) or the segment is suppressed and this pass tests nothing.
SCOPED_EPOCHS=("1786663300" "1786663301")

for tz in "${TIMEZONES[@]}"; do
  for epoch in "${SCOPED_EPOCHS[@]}"; do
    for theme in "${THEMES[@]}"; do
      if [[ "$theme" == "no-config" ]]; then
        # model_weekly can't be set without a config file, so this combination
        # only proves the feature stays off — already covered above.
        continue
      fi
      printf 'theme=%s\nmodel_weekly=on\n' "$theme" > "$TEMP_HOME/.claude/plan-statusline.conf"

      for nc in "${NO_COLORS[@]}"; do
        for fixture_name in plan-normal enterprise-full pending; do
          fixture="$FIXTURES_DIR/$fixture_name.json"

          out_bash=$(TZ="$tz" LC_ALL=C PLAN_SL_NOW="$epoch" NO_COLOR="$nc" HOME="$TEMP_HOME" bash statusline.sh < "$fixture")
          out_pwsh=$(TZ="$tz" LC_ALL=C PLAN_SL_NOW="$epoch" NO_COLOR="$nc" HOME="$TEMP_HOME" pwsh -NoProfile -File statusline.ps1 < "$fixture")

          TOTAL_CHECKS=$((TOTAL_CHECKS + 1))

          if [[ "$out_bash" != "$out_pwsh" ]]; then
            echo "Mismatch! (model_weekly=on)"
            echo "Fixture: $fixture_name.json | Theme: $theme | TZ: $tz | Epoch: $epoch | NO_COLOR='$nc'"
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

# The separator-injection fixture, across every theme. This one is a parity
# regression as much as a security one: a display_name carrying \x1f/\x1e made
# bash forge extra windows while PowerShell rendered a single correct one.
# One TZ/epoch is enough — the divergence was in field splitting, not time.
cp "$(dirname "$0")/scoped-injection.json" "$TEMP_HOME/.claude.json"
for theme in "${THEMES[@]}"; do
  [[ "$theme" == "no-config" ]] && continue
  printf 'theme=%s\nmodel_weekly=on\n' "$theme" > "$TEMP_HOME/.claude/plan-statusline.conf"
  for nc in "${NO_COLORS[@]}"; do
    fixture="$FIXTURES_DIR/plan-normal.json"
    out_bash=$(TZ=UTC LC_ALL=C PLAN_SL_NOW="${SCOPED_EPOCHS[0]}" NO_COLOR="$nc" HOME="$TEMP_HOME" bash statusline.sh < "$fixture")
    out_pwsh=$(TZ=UTC LC_ALL=C PLAN_SL_NOW="${SCOPED_EPOCHS[0]}" NO_COLOR="$nc" HOME="$TEMP_HOME" pwsh -NoProfile -File statusline.ps1 < "$fixture")

    TOTAL_CHECKS=$((TOTAL_CHECKS + 1))

    if [[ "$out_bash" != "$out_pwsh" ]]; then
      echo "Mismatch! (scoped-injection fixture)"
      echo "Theme: $theme | NO_COLOR='$nc'"
      echo "Bash output (hex):"
      echo -n "$out_bash" | xxd
      echo "PowerShell output (hex):"
      echo -n "$out_pwsh" | xxd
      FAILED_CHECKS=$((FAILED_CHECKS + 1))
      exit 1
    fi
  done
done

rm -f "$TEMP_HOME/.claude.json"

echo "Successfully cross-checked $TOTAL_CHECKS combinations."
exit 0
