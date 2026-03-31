#!/usr/bin/env bash
set -euo pipefail

if ! command -v jq >/dev/null 2>&1; then
  echo "jq is required" >&2
  exit 1
fi

BASE_PATH="${1:-$(pwd)}"
MASC_DIR="${BASE_PATH}/.masc"
TEAM_DIR="${MASC_DIR}/team-sessions"
CONTROL_DIR="${MASC_DIR}/control-plane"

count=0
event_rows_total=0
event_rows_missing_session=0
event_rows_missing_operation=0
event_rows_missing_worker=0
worker_meta_total=0
worker_meta_missing_session=0
worker_meta_missing_operation=0
worker_meta_missing_trace_ref=0
worker_meta_missing_evidence_refs=0

while IFS= read -r -d '' session_file; do
  count=$((count + 1))
done < <(find "${TEAM_DIR}" -type f -name 'session.json' -print0 2>/dev/null || true) || true

while IFS= read -r -d '' event_file; do
  while IFS= read -r line; do
    if [[ -z "${line// }" ]]; then
      continue
    fi
    event_rows_total=$((event_rows_total + 1))
    if ! printf '%s\n' "$line" | jq -e '(.detail.session_id? // "") | length > 0' >/dev/null; then
      event_rows_missing_session=$((event_rows_missing_session + 1))
    fi
    if ! printf '%s\n' "$line" | jq -e '(.detail.operation_id? // "") | length > 0' >/dev/null; then
      event_rows_missing_operation=$((event_rows_missing_operation + 1))
    fi
    if ! printf '%s\n' "$line" | jq -e '(.detail.worker_run_id? // "") | length > 0' >/dev/null; then
      event_rows_missing_worker=$((event_rows_missing_worker + 1))
    fi
  done < "$event_file"
done < <(find "${TEAM_DIR}" -type f -name 'events.jsonl' -print0 2>/dev/null || true) || true

while IFS= read -r -d '' meta_file; do
  worker_meta_total=$((worker_meta_total + 1))
  if ! jq -e '(.session_id? // "") | length > 0' "$meta_file" >/dev/null; then
    worker_meta_missing_session=$((worker_meta_missing_session + 1))
  fi
  if ! jq -e '(.operation_id? // "") | length > 0' "$meta_file" >/dev/null; then
    worker_meta_missing_operation=$((worker_meta_missing_operation + 1))
  fi
  if ! jq -e '.trace_ref != null' "$meta_file" >/dev/null; then
    worker_meta_missing_trace_ref=$((worker_meta_missing_trace_ref + 1))
  fi
  if ! jq -e '((.evidence_refs? // []) | length) > 0' "$meta_file" >/dev/null; then
    worker_meta_missing_evidence_refs=$((worker_meta_missing_evidence_refs + 1))
  fi
done < <(find "${TEAM_DIR}" -type f -name 'meta.json' -path '*/worker-runs/*' -print0 2>/dev/null || true) || true

if [[ -d "${CONTROL_DIR}/traces" ]]; then
  cp_trace_file_count="$(find "${CONTROL_DIR}/traces" -type f | wc -l | tr -d ' ')"
else
  cp_trace_file_count=0
fi

gaps_text=''
if [[ "${event_rows_missing_session}" -gt 0 ]]; then
  gaps_text="${gaps_text}session events missing detail.session_id: ${event_rows_missing_session}"$'\n'
fi
if [[ "${event_rows_missing_operation}" -gt 0 ]]; then
  gaps_text="${gaps_text}session events missing detail.operation_id: ${event_rows_missing_operation}"$'\n'
fi
if [[ "${worker_meta_missing_session}" -gt 0 ]]; then
  gaps_text="${gaps_text}worker meta missing session_id: ${worker_meta_missing_session}"$'\n'
fi
if [[ "${worker_meta_missing_operation}" -gt 0 ]]; then
  gaps_text="${gaps_text}worker meta missing operation_id: ${worker_meta_missing_operation}"$'\n'
fi
if [[ "${worker_meta_missing_trace_ref}" -gt 0 ]]; then
  gaps_text="${gaps_text}worker meta missing trace_ref: ${worker_meta_missing_trace_ref}"$'\n'
fi
if [[ "${worker_meta_missing_evidence_refs}" -gt 0 ]]; then
  gaps_text="${gaps_text}worker meta missing evidence_refs: ${worker_meta_missing_evidence_refs}"$'\n'
fi
if [[ "${cp_trace_file_count}" -eq 0 ]]; then
  gaps_text="${gaps_text}command-plane trace files missing"$'\n'
fi

if [[ -n "${gaps_text}" ]]; then
  gaps_json="$(printf '%s' "${gaps_text}" | sed '/^$/d' | jq -R . | jq -s '.')"
else
  gaps_json='[]'
fi

jq -n \
  --arg base_path "${BASE_PATH}" \
  --argjson session_count "${count}" \
  --argjson event_rows_total "${event_rows_total}" \
  --argjson event_rows_missing_session "${event_rows_missing_session}" \
  --argjson event_rows_missing_operation "${event_rows_missing_operation}" \
  --argjson event_rows_missing_worker "${event_rows_missing_worker}" \
  --argjson worker_meta_total "${worker_meta_total}" \
  --argjson worker_meta_missing_session "${worker_meta_missing_session}" \
  --argjson worker_meta_missing_operation "${worker_meta_missing_operation}" \
  --argjson worker_meta_missing_trace_ref "${worker_meta_missing_trace_ref}" \
  --argjson worker_meta_missing_evidence_refs "${worker_meta_missing_evidence_refs}" \
  --argjson cp_trace_file_count "${cp_trace_file_count}" \
  --argjson gaps "${gaps_json}" \
  '{
    schema_version: "1.0.0",
    base_path: $base_path,
    sessions: {
      session_count: $session_count,
      event_rows_total: $event_rows_total,
      event_rows_missing_session: $event_rows_missing_session,
      event_rows_missing_operation: $event_rows_missing_operation,
      event_rows_missing_worker: $event_rows_missing_worker
    },
    worker_runs: {
      meta_count: $worker_meta_total,
      missing_session_id: $worker_meta_missing_session,
      missing_operation_id: $worker_meta_missing_operation,
      missing_trace_ref: $worker_meta_missing_trace_ref,
      missing_evidence_refs: $worker_meta_missing_evidence_refs
    },
    command_plane: {
      trace_file_count: $cp_trace_file_count
    },
    gaps: $gaps
  }'
