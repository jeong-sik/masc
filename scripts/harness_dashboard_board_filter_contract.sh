#!/usr/bin/env bash
set -euo pipefail

BASE_URL="${BASE_URL:-http://127.0.0.1:8935}"
RESPONSE="$(curl -sS "${BASE_URL}/api/v1/board?limit=50&exclude_system=true")"

system_rows="$(printf '%s' "$RESPONSE" | jq -r '.posts[] | select(.author == "lodge-system" or .author == "team-session") | [.author, .title] | @tsv')"

if [ -n "$system_rows" ]; then
  echo "Board filter contract violated at ${BASE_URL}: exclude_system=true still returned system authors" >&2
  printf '%s\n' "$system_rows" >&2
  exit 1
fi

echo "Board filter contract ok at ${BASE_URL}"
