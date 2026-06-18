#!/bin/bash
test_injection() {
  local pct='a[$(touch /tmp/hacked_injection)]'

  # The issue is evaluating unfiltered input in `((...))` arithmetic contexts.
  # If we validate with regex `^[-+]?[0-9]+$`, we prevent this.

  if [[ ! "$pct" =~ ^[-+]?[0-9]+$ ]]; then
    echo "Invalid input"
    return 1
  fi

  ((pct >= 88))
}

test_injection
if [ -f /tmp/hacked_injection ]; then
    echo "VULNERABLE"
else
    echo "SAFE"
fi
