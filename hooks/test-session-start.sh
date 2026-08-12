#!/usr/bin/env bash
# Three cases: cash-track remote, monorepo signature, unrelated repo.
set -uo pipefail

HOOK="$(cd "$(dirname "$0")" && pwd)/session-start.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fails=0

check() {
  local name="$1" dir="$2" want="$3"
  local out
  out=$(printf '{"cwd":"%s"}' "$dir" | "$HOOK" 2>/dev/null)
  if [ "$want" = "inject" ]; then
    if printf '%s' "$out" | grep -q "cash-track:base"; then
      echo "PASS: $name"
    else
      echo "FAIL: $name - expected injection, got: ${out:-<empty>}"; fails=$((fails+1))
    fi
  else
    if [ -z "$out" ]; then
      echo "PASS: $name"
    else
      echo "FAIL: $name - expected no output, got: $out"; fails=$((fails+1))
    fi
  fi
}

# Case 1: repo whose origin is a cash-track repo
mkdir -p "$TMP/withremote" && git -C "$TMP/withremote" init -q
git -C "$TMP/withremote" remote add origin git@github.com:cash-track/gateway.git
check "cash-track remote" "$TMP/withremote" inject

# Case 2: monorepo directory signature, no git
mkdir -p "$TMP/monorepo/api/app/src" "$TMP/monorepo/frontend/src"
check "monorepo signature" "$TMP/monorepo" inject

# Case 3: unrelated repo
mkdir -p "$TMP/other" && git -C "$TMP/other" init -q
git -C "$TMP/other" remote add origin git@github.com:someone/unrelated.git
check "unrelated repo" "$TMP/other" silent

[ $fails -eq 0 ] && echo "All hook tests passed" || echo "$fails hook test(s) failed"
exit $fails
