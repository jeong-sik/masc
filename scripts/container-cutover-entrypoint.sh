#!/usr/bin/env bash

set -euo pipefail

BASE_PATH="${MASC_BASE_PATH:?MASC_BASE_PATH is required}"
HELPER=/app/masc-keeper-event-queue-v15-cutover-helper
GATE=/app/masc-check-keeper-event-queue-v15-cutover

if [[ $# -eq 0 ]]; then
  set -- /app/masc --port "${PORT:-8080}" --base-path "$BASE_PATH"
elif [[ "$1" == "/app/masc" && $# -eq 1 ]]; then
  set -- /app/masc --port "${PORT:-8080}" --base-path "$BASE_PATH"
fi

NEXT_EXECUTABLE="$1"
shift

HANDOFF_ARGS=(
  lease-handoff
  --base-path "$BASE_PATH"
  --next-executable "$NEXT_EXECUTABLE"
)
for argument in "$@"; do
  HANDOFF_ARGS+=(--next-argument="$argument")
done
HANDOFF_ARGS+=(
  --
  "$GATE"
  --base-path "$BASE_PATH"
  --allow-empty-workspace
)

MASC_EVENT_QUEUE_V15_CUTOVER_HELPER="$HELPER" \
  exec "$HELPER" "${HANDOFF_ARGS[@]}"
