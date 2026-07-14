#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

require_text() {
  local file="$1"
  local needle="$2"
  local label="$3"

  if ! grep -Fq -- "$needle" "${ROOT}/${file}"; then
    echo "execute-async-surface: missing ${label}: ${file}" >&2
    echo "  expected text: ${needle}" >&2
    exit 1
  fi
}

require_normalized_text() {
  local file="$1"
  local needle="$2"
  local label="$3"
  local haystack

  haystack="$(tr '\n' ' ' < "${ROOT}/${file}" | tr -s ' ')"
  if [[ "${haystack}" != *"${needle}"* ]]; then
    echo "execute-async-surface: missing ${label}: ${file}" >&2
    echo "  expected text: ${needle}" >&2
    exit 1
  fi
}

reject_text() {
  local file="$1"
  local needle="$2"
  local label="$3"

  if grep -Fq -- "$needle" "${ROOT}/${file}"; then
    echo "execute-async-surface: forbidden ${label}: ${file}" >&2
    echo "  forbidden text: ${needle}" >&2
    exit 1
  fi
}

require_text \
  "docs/EXECUTE-RUNBOOK.md" \
  "Execute is typed-only: callers provide" \
  "typed-only Execute runbook claim"
require_normalized_text \
  "docs/EXECUTE-RUNBOOK.md" \
  "old background task lifecycle are not part of the callable surface" \
  "background lifecycle exclusion in Execute runbook"
require_normalized_text \
  "docs/EXECUTE-RUNBOOK.md" \
  "It does not expose \`job_id\`, \`request_id\`, \`poll\`, or \`cancel\` fields." \
  "async lifecycle field exclusion in Execute runbook"

require_normalized_text \
  "lib/tool_surface/tool_shard_types_schemas_execute.ml" \
  "Accepted fields: argv, pipeline, env, cwd, timeout_sec, stdin, stdout, stderr." \
  "typed Execute accepted-field list"
require_normalized_text \
  "lib/tool_surface/tool_shard_types_schemas_execute.ml" \
  "this tool does not expose background task lifecycle tools" \
  "typed Execute background lifecycle exclusion"
reject_text \
  "lib/tool_surface/tool_shard_types_schemas_execute.ml" \
  "run_in_background" \
  "legacy Execute background flag"
reject_text \
  "lib/tool_surface/tool_shard_types_schemas_execute.ml" \
  "job_id" \
  "Execute async job id field"
reject_text \
  "lib/tool_surface/tool_shard_types_schemas_execute.ml" \
  "backgroundTaskId" \
  "Execute legacy background task id field"

require_text \
  "test/test_tool_input_validation.ml" \
  "legacy background flag not exposed" \
  "schema rejection proof"
require_text \
  "test/test_tool_input_validation.ml" \
  "test_validate_args_tool_execute_rejects_background_flag" \
  "validation rejection proof"
require_text \
  "test/test_tool_input_validation.ml" \
  "test_validate_args_tool_execute_rejects_async_lifecycle_fields" \
  "async lifecycle field rejection proof"
require_text \
  "test/test_tool_input_validation.ml" \
  "job_id" \
  "async job id rejection proof"
require_text \
  "test/test_tool_input_validation.ml" \
  "backgroundTaskId" \
  "legacy background task id rejection proof"

require_text \
  "lib/process/bg_task.mli" \
  "Background shell task lifecycle" \
  "internal Bg_task lifecycle owner"
require_text "lib/process/bg_task.mli" "val spawn" "Bg_task spawn primitive"
require_text "lib/process/bg_task.mli" "val read" "Bg_task read primitive"
require_text "lib/process/bg_task.mli" "val kill" "Bg_task kill primitive"
require_text "lib/process/bg_task.mli" "val list" "Bg_task list primitive"

require_text \
  "lib/keeper/keeper_msg_async.mli" \
  "Fire-and-forget keeper message execution" \
  "keeper_msg async owner"
require_text "lib/keeper/keeper_msg_async.mli" "val submit" "keeper_msg submit"
require_text "lib/keeper/keeper_msg_async.mli" "val poll" "keeper_msg poll"
require_text "lib/keeper/keeper_msg_async.mli" "val cancel" "keeper_msg cancel"
require_text \
  "lib/keeper/keeper_msg_async.mli" \
  "val list_for_keeper" \
  "keeper_msg async list"
require_text \
  "lib/keeper/keeper_turn_admission.mli" \
  "async [Keeper_msg_async] dispatch" \
  "async keeper_msg admission contract"
require_text \
  "lib/keeper/keeper_turn_admission.mli" \
  "run_serialized" \
  "keeper turn serialized admission"

echo "execute-async-surface: PASS"
