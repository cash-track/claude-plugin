#!/usr/bin/env bash
# Fails if machine-specific absolute paths appear in shipped plugin content.
# This is the regression guard for the bug class that motivated this repo:
# skills that only worked on one laptop.
set -uo pipefail

PATTERN='/Users/|/home/[a-z]|~/projects/|~/go/src/'
TARGETS=(skills agents commands hooks bin)

present=()
for t in "${TARGETS[@]}"; do
  [ -d "$t" ] && present+=("$t")
done

if [ ${#present[@]} -eq 0 ]; then
  echo "OK: no content directories to scan yet"
  exit 0
fi

hits=$(grep -rInE "$PATTERN" "${present[@]}" 2>/dev/null || true)

if [ -n "$hits" ]; then
  echo "FAIL: machine-specific paths in plugin content:"
  echo "$hits"
  echo
  echo 'Use $(go env GOPATH), a bin/ helper on PATH, or a repo-relative path.'
  exit 1
fi

echo "OK: no machine-specific paths in ${present[*]}"
