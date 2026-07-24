#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${MASC_KEEPER_EVENT_QUEUE_BOUNDARY_ROOT:-$(cd "${SCRIPT_DIR}/.." && pwd)}"
CHECKER_SOURCE="${SCRIPT_DIR}/keeper_event_queue_projection_boundary_check.ml"
CHECKER_DIR="$(mktemp -d)"
trap 'rm -rf "${CHECKER_DIR}"' EXIT

ocamlc \
  -I +compiler-libs \
  ocamlcommon.cma \
  "${CHECKER_SOURCE}" \
  -o "${CHECKER_DIR}/check-keeper-event-queue-projection-boundary"

"${CHECKER_DIR}/check-keeper-event-queue-projection-boundary" "${REPO_ROOT}"
