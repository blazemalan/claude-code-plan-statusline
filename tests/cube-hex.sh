#!/usr/bin/env bash
# Unit tests for the cube_hex function in tests/xterm-hex.sh.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

fails=0
ok()  { printf 'PASS %s\n' "$1"; }
bad() { printf 'FAIL %s\n' "$1" >&2; fails=$((fails+1)); }

check_hex() {
  local index=$1
  local expected=$2

  local out got
  # Invoke via the script and parse the single-line output, per instructions.
  out=$(bash tests/xterm-hex.sh "$index" 2>/dev/null)

  # Extract the hex code (last word in the line) to safely handle '->' or '→'
  got=$(awk '{print $NF}' <<< "$out")

  if [[ "$got" == "$expected" ]]; then
    ok "cube_hex $index -> $expected"
  else
    bad "cube_hex $index -> expected $expected, got '$got' from '$out'"
  fi
}

check_err() {
  local index=$1

  # To test the true exit code of the function while still exercising the real file,
  # we source the file in a subshell, redirecting the main body's output, and call the function.
  # We use the environment to pass the index so that `source` does not inherit any positional args.
  if INDEX="$index" bash -c 'source tests/xterm-hex.sh >/dev/null 2>&1; cube_hex "$INDEX"' >/dev/null 2>&1; then
    bad "cube_hex $index -> expected failure, but succeeded"
  else
    ok "cube_hex $index -> fails on out of range"
  fi
}

# ── Reference value tests ────────────────────────────────────────────────────
check_hex 199 "#ff00af"
check_hex 197 "#ff005f"
check_hex  41 "#00d75f"
check_hex  16 "#000000"
check_hex 231 "#ffffff"

# Grayscale ramp
check_hex 232 "#080808"
check_hex 255 "#eeeeee"

# Out of range
check_err   5
check_err 300

echo
if (( fails )); then echo "cube-hex: $fails FAILED"; exit 1; fi
echo "All cube-hex tests passed."
