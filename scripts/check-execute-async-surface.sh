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

require_text \
  "docs/EXECUTE-RUNBOOK.md" \
  "Execute is typed-only: callers provide" \
  "typed-only Execute runbook claim"
require_normalized_text \
  "docs/EXECUTE-RUNBOOK.md" \
  "no background shell lifecycle surface anywhere below it" \
  "synchronous Execute boundary in runbook"
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
require_text \
  "test/test_tool_input_validation.ml" \
  "test_tool_execute_schema_exposes_typed_boundary" \
  "typed schema proof"
require_text \
  "test/test_tool_input_validation.ml" \
  "test_validate_args_tool_execute_accepts_typed_exec" \
  "typed exec validation proof"
require_text \
  "test/test_tool_input_validation.ml" \
  "test_validate_args_tool_execute_accepts_typed_pipeline" \
  "typed pipeline validation proof"

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
