#!/usr/bin/env bash
# Injects a pointer to cash-track:base when the session is in a Cash-Track checkout.
# Emits nothing and exits 0 anywhere else, so leaving it enabled globally is harmless.
# The context is a static string, so the script never needs to locate the plugin root;
# hooks.json resolves this script's path via ${CLAUDE_PLUGIN_ROOT}.
set -uo pipefail

input="$(cat)"
cwd="$(printf '%s' "$input" \
  | python3 -c 'import json,sys; print(json.load(sys.stdin).get("cwd",""))' 2>/dev/null || true)"
[ -z "$cwd" ] && cwd="$PWD"
[ -d "$cwd" ] || exit 0

match=""
remote="$(git -C "$cwd" remote get-url origin 2>/dev/null || true)"
if printf '%s' "$remote" | grep -qE 'github\.com[:/]cash-track/'; then
  match=1
elif [ -d "$cwd/api/app/src" ] && [ -d "$cwd/frontend/src" ]; then
  match=1
fi
[ -z "$match" ] && exit 0

# Plain single-quoted assignment, deliberately not a heredoc: superpowers hit a heredoc hang on
# bash 5.3+ (obra/superpowers#571). Keep this string free of single quotes.
context='You are working in a Cash-Track repository.

Load the `cash-track:base` skill before doing anything else. It carries the monorepo layout, the
request flow, per-component commands, the local dev stack start order and URLs, and the commit
conventions.

Then load the skill for the component you are editing:
  ./api      -> cash-track:api
  ./frontend -> cash-track:frontend
  ./infra    -> cash-track:infra
  gateway    -> cash-track:gateway

For building a feature or fixing a bug end to end, use cash-track:agentic-dev.
For dependency CVEs, use cash-track:security-upgrade.'

escape_for_json() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\n'/\\n}"
  s="${s//$'\r'/\\r}"
  s="${s//$'\t'/\\t}"
  printf '%s' "$s"
}

printf '{\n  "hookSpecificOutput": {\n    "hookEventName": "SessionStart",\n    "additionalContext": "%s"\n  }\n}\n' \
  "$(escape_for_json "$context")"

exit 0
