#!/bin/bash
# Test that missing jq gracefully errors out
set -euo pipefail

cd "$(dirname "$0")/.."

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# Create a fake bin directory that lacks jq but has everything else
mkdir -p "$TMP/bin"
# Link essential tools needed to run the test
for tool in bash cat printf sed tr date mktemp; do
  tool_path=$(command -v "$tool" || true)
  if [[ -n "$tool_path" ]]; then
    ln -s "$tool_path" "$TMP/bin/$tool"
  fi
done

# Run script with restricted PATH
PATH="$TMP/bin" bash statusline.sh < /dev/null
