#!/usr/bin/env bash

set -euo pipefail

BASE_PATH="${MASC_BASE_PATH:?MASC_BASE_PATH is required}"
RUN_DIR="${MASC_RUN_DIR:?MASC_RUN_DIR is required}"
HELPER=/app/masc-deployment-preflight-helper
GATE=/app/masc-check-runtime-deployment-preflight

mkdir -p "$RUN_DIR"
chmod 0700 "$RUN_DIR"

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

MASC_DEPLOYMENT_PREFLIGHT_HELPER="$HELPER" \
  exec "$HELPER" "${HANDOFF_ARGS[@]}"
