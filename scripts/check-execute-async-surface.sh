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

  # A TOML basic string wraps with a trailing backslash, so the sentence the
  # contract names is split by "\\\n" rather than a bare newline. Drop the
  # continuation before folding whitespace, or the check passes only while the
  # text happens to live in OCaml.
  haystack="$(sed 's/\\$//' "${ROOT}/${file}" | tr '\n' ' ' | tr -s ' ')"
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
  "Accepted fields: argv, script, shell, cwd, timeout_sec." \
  "typed Execute accepted-field list"
# The sentence is in the tool's description, in the TOML the model is handed.
# Check it where it is.
require_normalized_text \
  "config/tools/tool_execute.toml" \
  "there is no background task lifecycle" \
  "typed Execute background lifecycle exclusion"
reject_text \
  "lib/tool_surface/tool_shard_types_schemas_execute.ml" \
  "run_in_background" \
  "legacy Execute background flag"
reject_text \
  "config/tools/tool_execute.toml" \
  "run_in_background" \
  "legacy Execute background flag (declaration)"
reject_text \
  "lib/tool_surface/tool_shard_types_schemas_execute.ml" \
  "job_id" \
  "Execute async job id field"
reject_text \
  "config/tools/tool_execute.toml" \
  "job_id" \
  "Execute async job id field (declaration)"
reject_text \
  "lib/tool_surface/tool_shard_types_schemas_execute.ml" \
  "backgroundTaskId" \
  "Execute legacy background task id field"
reject_text \
  "config/tools/tool_execute.toml" \
  "backgroundTaskId" \
  "Execute legacy background task id field (declaration)"

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
echo "execute-async-surface: PASS"
