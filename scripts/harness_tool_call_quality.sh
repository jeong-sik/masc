#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT_DIR="${TOOL_CALL_QUALITY_OUT_DIR:-$(mktemp -d "${TMPDIR:-/tmp}/tool-call-quality.XXXXXX")}"
CASES_PATH="${TOOL_CALL_QUALITY_CASES_PATH:-${ROOT_DIR}/benchmarks/data/tool_call_quality_cases.json}"
EVIDENCE_PATH="${TOOL_CALL_QUALITY_EVIDENCE_PATH:-${ROOT_DIR}/test/fixtures/tool_call_quality_benchmark/evidence_runs.json}"
FORMAT="${TOOL_CALL_QUALITY_FORMAT:-json}"
VIEW="${TOOL_CALL_QUALITY_VIEW:-provider-model-keeper}"
REQUIRE_ROUTE_EVIDENCE="${TOOL_CALL_QUALITY_REQUIRE_ROUTE_EVIDENCE:-1}"
CLI_EXE="${ROOT_DIR}/_build/default/test/tool_call_quality_benchmark_cli.exe"

MODELS="${TOOL_CALL_QUALITY_MODELS:-}"
KEEPERS="${TOOL_CALL_QUALITY_KEEPERS:-bench-analyst,bench-executor,bench-verifier}"
CASE_IDS="${TOOL_CALL_QUALITY_CASE_IDS:-}"
LIVE_MODE="${TOOL_CALL_QUALITY_LIVE:-0}"
REPEATS="${TOOL_CALL_QUALITY_REPEATS:-3}"
TIMEOUT_SEC="${TOOL_CALL_QUALITY_TIMEOUT_SEC:-90}"
WORKSPACE_ROOT="${TOOL_CALL_QUALITY_WORKSPACE_ROOT:-${ROOT_DIR}}"
PORT="${TOOL_CALL_QUALITY_PORT:-}"
POLL_INTERVAL_SEC="${TOOL_CALL_QUALITY_POLL_INTERVAL_SEC:-1}"

SERVER_PID=""
LIVE_RUN_DIR=""
TARGET_DIR=""
CONFIG_DIR=""
RAW_DIR=""
SERVER_LOG=""
LAST_TOOL_RAW=""
LAST_TOOL_ERROR=""

usage() {
  cat >&2 <<'EOF'
Usage:
  scripts/harness_tool_call_quality.sh [--cases PATH] [--evidence PATH] [--format json|csv]
                                       [--view provider-model-keeper|provider-model|keeper]
                                       [--artifact-dir DIR] [--models CSV] [--keepers CSV]
                                       [--case-ids CSV] [--no-require-route-evidence]
  scripts/harness_tool_call_quality.sh --live --models provider:model[,provider:model]
                                       [--keepers CSV] [--case-ids CSV]
                                       [--repeats N] [--timeout-sec N]
                                       [--artifact-dir DIR] [--format json|csv]
                                       [--view provider-model-keeper|provider-model|keeper]

Modes:
  default  Aggregate an existing evidence JSON file through the benchmark CLI.
  --live   Start an isolated local MASC server, execute benchmark runs, emit raw
           evidence JSON, then summarize it with the benchmark CLI.
EOF
}

# shellcheck source=scripts/harness/lib/test_framework.sh
source "${ROOT_DIR}/scripts/harness/lib/test_framework.sh"
# shellcheck source=scripts/harness/lib/server_bootstrap.sh
source "${ROOT_DIR}/scripts/harness/lib/server_bootstrap.sh"
# shellcheck source=scripts/harness/lib/mcp_call.sh
source "${ROOT_DIR}/scripts/harness/lib/mcp_call.sh"

cleanup() {
  harness_stop_server "${SERVER_PID}" 10
}
trap cleanup EXIT

# require_cmd lives in scripts/harness/lib/test_framework.sh (sourced above).

trim() {
  local value="${1:-}"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "$value"
}

slugify() {
  local value
  value="$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')"
  value="$(printf '%s' "$value" | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//; s/-{2,}/-/g')"
  printf '%s' "${value:-run}"
}

csv_to_json() {
  jq -cn --arg csv "${1:-}" '
    $csv
    | split(",")
    | map(gsub("^\\s+|\\s+$"; ""))
    | map(select(length > 0))
  '
}

sha256_text() {
  python3 - "${1:-}" <<'PY'
import hashlib
import sys

value = sys.argv[1] if len(sys.argv) > 1 else ""
print(hashlib.sha256(value.encode("utf-8")).hexdigest())
PY
}

iso_now() {
  date -u +"%Y-%m-%dT%H:%M:%SZ"
}

ensure_cli_built() {
  (
    cd "${ROOT_DIR}"
    if [[ "${TOOL_CALL_QUALITY_SKIP_BUILD:-0}" != "1" || ! -x "${CLI_EXE}" ]]; then
      scripts/dune-local.sh build ./test/tool_call_quality_benchmark_cli.exe >/dev/null
    fi
  )
}

# call_mcp_tool / tool_result_json / tool_result_payload_json /
# tool_result_text / tool_error_text live in scripts/harness/lib/mcp_call.sh
# (sourced above), shared with harness_coding_eval.sh.
select_case_rows() {
  local keepers_json case_ids_json
  keepers_json="$(csv_to_json "${KEEPERS}")"
  case_ids_json="$(csv_to_json "${CASE_IDS}")"
  jq -c \
    --argjson keepers "${keepers_json}" \
    --argjson case_ids "${case_ids_json}" \
    '
      .cases[]
      | . as $case
      | select(($case_ids | length) == 0 or ($case_ids | index($case.id)))
      | select(
          ($keepers | length) == 0
          or ([.keeper_profiles[] | select($keepers | index(.))] | length > 0)
        )
    ' "${CASES_PATH}"
}

keeper_profiles_for_case() {
  local case_json="$1"
  local keepers_json
  keepers_json="$(csv_to_json "${KEEPERS}")"
  printf '%s' "${case_json}" \
    | jq -r --argjson keepers "${keepers_json}" '
        .keeper_profiles[]
        | select(($keepers | length) == 0 or ($keepers | index(.)))
      '
}

prompt_contract_for_case() {
  case "$1" in
    read_search_prompt_fingerprint)
      cat <<'EOF'
Final reply contract:
- Reply in Korean.
- Output exactly two numbered lines.
- Each line must contain one concrete file path and one short reason.
EOF
      ;;
    text_only_triage)
      cat <<'EOF'
Final reply contract:
- Reply in Korean.
- Do not call any tools.
- Output one short sentence starting with "text_only:".
EOF
      ;;
    recovery_after_failed_read)
      cat <<'EOF'
Final reply contract:
- Reply in Korean.
- Output one short sentence starting with "recovered:".
EOF
      ;;
    multi_step_board_update)
      cat <<'EOF'
Final reply contract:
- Reply in Korean.
- Output one short sentence starting with "verified:".
EOF
      ;;
    *)
      cat <<'EOF'
Final reply contract:
- Reply in Korean.
- Keep the final answer short and evidence-based.
EOF
      ;;
  esac
}

build_case_message() {
  local case_json="$1"
  local case_id prompt max_tool_calls contract
  case_id="$(printf '%s' "${case_json}" | jq -r '.id')"
  prompt="$(printf '%s' "${case_json}" | jq -r '.prompt')"
  max_tool_calls="$(printf '%s' "${case_json}" | jq -r '.max_tool_calls')"
  contract="$(prompt_contract_for_case "${case_id}")"
  cat <<EOF
Tool-quality benchmark case: ${case_id}
Allowed workspace root: ${WORKSPACE_ROOT}
Use repo-relative or absolute paths under the allowed workspace root.
For shell commands, run inside this repo root when needed: ${WORKSPACE_ROOT}
Keep tool usage repeatable and minimal.
Target max_tool_calls: ${max_tool_calls}

${contract}

Task:
${prompt}
EOF
}

harness_prompt_asset() {
  local name="$1"
  local path="${ROOT_DIR}/config/prompts/${name}.txt"
  if [[ ! -r "${path}" ]]; then
    echo "missing required harness prompt asset: ${path}" >&2
    return 1
  fi
  cat "${path}"
}

benchmark_instructions() {
  local keeper_profile="$1"
  case "${keeper_profile}" in
    bench-analyst)
      harness_prompt_asset "harness.tool_quality.analyst"
      ;;
    bench-executor)
      harness_prompt_asset "harness.tool_quality.executor"
      ;;
    bench-verifier)
      harness_prompt_asset "harness.tool_quality.verifier"
      ;;
    *)
      echo "unknown benchmark keeper profile: ${keeper_profile}" >&2
      return 1
      ;;
  esac

}

prepare_live_environment() {
  local run_suffix
  require_cmd jq
  require_cmd curl
  run_suffix="$(date +%Y%m%d_%H%M%S)-$$"
  LIVE_RUN_DIR="${OUT_DIR}/live-${run_suffix}"
  RAW_DIR="${LIVE_RUN_DIR}/raw"
  TARGET_DIR="${LIVE_RUN_DIR}/target"
  CONFIG_DIR="${LIVE_RUN_DIR}/config"
  SERVER_LOG="${LIVE_RUN_DIR}/server.log"

  mkdir -p "${RAW_DIR}" "${TARGET_DIR}" "${CONFIG_DIR}"
  cp -R "${ROOT_DIR}/config/." "${CONFIG_DIR}"

  if [[ -z "${PORT}" ]]; then
    PORT="$(harness_pick_free_port)"
  fi
}

start_live_server() {
  local launch_log="${LIVE_RUN_DIR}/launch.log"
  local bootstrap_log="${LIVE_RUN_DIR}/bootstrap.log"
  (
    export MASC_CONFIG_DIR="${CONFIG_DIR}"
    export MASC_LOG_FILE="${SERVER_LOG}"
    export MASC_KEEPER_AUTONOMOUS_ENABLED="0"
    export MASC_ORCHESTRATOR_ENABLED="0"
    export MASC_KEEPER_BOOTSTRAP_ENABLED="0"
    export GRAPHQL_API_KEY=""
    export GRAPHQL_URL="http://127.0.0.1:9/graphql"
    export AGENT_CORE_MCP_SERVERS_CONFIG="mcp_servers={}"
    exec "${ROOT_DIR}/scripts/run-local.sh" \
      --target-dir "${TARGET_DIR}" \
      --port "${PORT}" \
      --bootstrap-only
  ) >"${bootstrap_log}" 2>&1
  (
    export MASC_CONFIG_DIR="${CONFIG_DIR}"
    export MASC_LOG_FILE="${SERVER_LOG}"
    export MASC_KEEPER_AUTONOMOUS_ENABLED="0"
    export MASC_ORCHESTRATOR_ENABLED="0"
    export MASC_KEEPER_BOOTSTRAP_ENABLED="0"
    export GRAPHQL_API_KEY=""
    export GRAPHQL_URL="http://127.0.0.1:9/graphql"
    export AGENT_CORE_MCP_SERVERS_CONFIG="mcp_servers={}"
    exec "${ROOT_DIR}/scripts/run-local.sh" --target-dir "${TARGET_DIR}" --port "${PORT}"
  ) >"${launch_log}" 2>&1 &
  SERVER_PID="$!"

  if ! harness_wait_for_health "${PORT}" 45; then
    harness_print_log_tail "${bootstrap_log}" 120
    harness_print_log_tail "${launch_log}" 120
    harness_print_log_tail "${SERVER_LOG}" 120
    echo "live harness failed: server did not become healthy on port ${PORT}" >&2
    exit 1
  fi

  MCP_URL="http://127.0.0.1:${PORT}/mcp"
  export MCP_URL
  if ! initialize_mcp_session; then
    harness_print_log_tail "${SERVER_LOG}" 120
    echo "live harness failed: MCP initialize did not return a session id" >&2
    exit 1
  fi
}

read_tool_log_entries() {
  local keeper_name="$1"
  local log_dir="${TARGET_DIR}/.masc/tool_calls"
  if [[ ! -d "${log_dir}" ]]; then
    printf '[]'
    return 0
  fi
  find "${log_dir}" -type f -name '*.jsonl' | LC_ALL=C sort \
    | while IFS= read -r path; do
        cat "${path}"
      done \
    | jq -cs --arg keeper "${keeper_name}" '
        map(select(.keeper == $keeper))
      '
}

tool_calls_for_evidence() {
  local tool_log_json="$1"
  printf '%s' "${tool_log_json}" | jq -c '
    [ .[]
      | {
          tool_name: .tool,
          success: (.success // false),
          input: (.input // {}),
          output: (.output // null),
          route_evidence: (.route_evidence // null),
          duration_ms: (.duration_ms // null)
        }
    ]
  '
}

latest_metrics_for_keeper() {
  local keeper_name="$1"
  local metrics_dir="${TARGET_DIR}/.masc/keepers/${keeper_name}/metrics"
  if [[ ! -d "${metrics_dir}" ]]; then
    printf 'null'
    return 0
  fi
  find "${metrics_dir}" -type f -name '*.jsonl' | LC_ALL=C sort \
    | while IFS= read -r path; do
        cat "${path}"
      done \
    | jq -cs 'map(select(type == "object")) | last // null'
}

prompt_fingerprint_for_run() {
  local tool_log_json="$1"
  local metrics_json="$2"
  local fp
  fp="$(printf '%s' "${tool_log_json}" | jq -r '
      map(.prompt_fingerprint // empty)
      | map(select(length > 0))
      | .[0] // empty
    ')"
  if [[ -n "${fp}" ]]; then
    printf '%s' "${fp}"
    return 0
  fi
  printf '%s' "${metrics_json}" | jq -r '.prompt_fingerprint // empty'
}

tool_surface_fingerprint_from_status() {
  local status_json="$1"
  local surface
  surface="$(printf '%s' "${status_json}" | jq -r '
      [.allowed_tool_names[]?]
      | sort
      | join(",")
    ')"
  if [[ -z "${surface}" ]]; then
    printf ''
  else
    sha256_text "${surface}"
  fi
}

derive_final_result() {
  local case_id="$1"
  local tool_calls_json="$2"

  case "${case_id}" in
    read_search_prompt_fingerprint)
      printf '%s' "${tool_calls_json}" | jq -c '
        def search_hit:
          any(.[]; .tool_name == "tool_search_files"
                    and ((.input.pattern // "") | tostring | contains("prompt_fingerprint")));
        def read_hit:
          any(.[]; .tool_name == "tool_read_file"
                    and ((.input.file_path // "") | tostring | contains("keeper_tool_call_log")));
        {
          status: (if search_hit and read_hit then "completed" else "incomplete" end),
          evidence_found: ((if search_hit then 1 else 0 end) + (if read_hit then 1 else 0 end))
        }
      '
      ;;
    text_only_triage)
      printf '%s' "${tool_calls_json}" | jq -c '
        {
          status: (if length == 0 then "completed" else "incomplete" end),
          mode: (if length == 0 then "text_only" else "tool_used" end)
        }
      '
      ;;
    recovery_after_failed_read)
      printf '%s' "${tool_calls_json}" | jq -c '
        def failure_index:
          first(
            to_entries[]
            | select(.value.tool_name == "tool_read_file" and (.value.success | not))
            | .key
          );
        def recovered_after_failure($idx):
          any(
            to_entries[];
            .key > $idx
            and .value.tool_name == "tool_read_file"
            and .value.success
            and ((.value.input.file_path // "") | tostring | contains("keeper_agent_run.ml"))
          );
        def searched:
          any(.[]; .tool_name == "tool_search_files"
                    and ((.input.pattern // "") | tostring | contains("keeper_agent_run")));
        (failure_index) as $idx
        | {
            status: (if ($idx != null and searched and recovered_after_failure($idx))
                     then "completed" else "incomplete" end),
            recovered: ($idx != null and searched and recovered_after_failure($idx))
          }
      '
      ;;
    multi_step_board_update)
      printf '%s' "${tool_calls_json}" | jq -c '
        def search_hit:
          any(.[]; .tool_name == "tool_search_files");
        def bash_hit:
          any(.[]; .tool_name == "tool_execute" and .success);
        def board_hit:
          any(
            .[];
            .tool_name == "masc_board_post"
            and .success
            and (
              ((.input.body // .input.content // "") | tostring | ascii_downcase)
              | contains("verified")
            )
          );
        {
          status: (if search_hit and bash_hit and board_hit then "completed" else "incomplete" end),
          board_updated: (search_hit and bash_hit and board_hit)
        }
      '
      ;;
    *)
      jq -cn '{status:"unknown"}'
      ;;
  esac
}

task_success_from_final_result() {
  local case_id="$1"
  local final_result_json="$2"
  case "${case_id}" in
    read_search_prompt_fingerprint)
      printf '%s' "${final_result_json}" | jq -e '.status == "completed" and (.evidence_found // 0) >= 2' >/dev/null
      ;;
    text_only_triage)
      printf '%s' "${final_result_json}" | jq -e '.status == "completed" and .mode == "text_only"' >/dev/null
      ;;
    recovery_after_failed_read)
      printf '%s' "${final_result_json}" | jq -e '.status == "completed" and .recovered == true' >/dev/null
      ;;
    multi_step_board_update)
      printf '%s' "${final_result_json}" | jq -e '.status == "completed" and .board_updated == true' >/dev/null
      ;;
    *)
      return 1
      ;;
  esac
}

classify_status() {
  local text
  text="$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')"
  case "${text}" in
    *"not supported"*|*"unsupported"*|*"invalid_request_error"*|*"unknown model"*|*"model_not_found"*)
      printf 'unsupported'
      ;;
    *)
      printf 'executed_failed'
      ;;
  esac
}

create_keeper_status_snapshot() {
  local keeper_name="$1"
  local run_dir="$2"
  local args status_json
  args="$(jq -cn --arg name "${keeper_name}" '{name:$name, fast:true}')"
  if call_mcp_tool 2500 "masc_keeper_status" "${args}" 30; then
    status_json="$(tool_result_json)"
    printf '%s' "${status_json}" > "${run_dir}/keeper-status.json"
    printf '%s' "${status_json}"
  else
    printf 'null'
  fi
}

stop_keeper_best_effort() {
  local keeper_name="$1"
  local args
  args="$(jq -cn --arg name "${keeper_name}" '{name:$name}')"
  call_mcp_tool 9000 "masc_keeper_down" "${args}" 20 >/dev/null 2>&1 || true
}

run_live_case() {
  local provider="$1"
  local model="$2"
  local keeper_profile="$3"
  local repeat_index="$4"
  local case_json="$5"

  local case_id keeper_name run_slug run_dir runtime_id instructions
  local message create_args create_json status_before_json status_after_json
  local request_json request_id result_json msg_payload final_output tool_log_json
  local tool_calls_json metrics_json prompt_fingerprint tool_surface_fingerprint
  local final_result_json task_success=false run_status latency_ms
  local input_tokens output_tokens cost_usd actual_model_used
  local start_epoch end_epoch

  case_id="$(printf '%s' "${case_json}" | jq -r '.id')"
  run_slug="$(slugify "${provider}-${model}-${keeper_profile}-${case_id}-r${repeat_index}")"
  keeper_name="bench-${run_slug}"
  runtime_id="${provider}.${model}"
  run_dir="${RAW_DIR}/${keeper_name}"
  mkdir -p "${run_dir}"

  instructions="$(benchmark_instructions "${keeper_profile}")"
  message="$(build_case_message "${case_json}")"

  create_args="$(jq -cn \
    --arg name "${keeper_name}" \
    --arg instructions "${instructions}" \
    --arg runtime_id "${runtime_id}" \
    '{
      name: $name,
      instructions: $instructions,
      runtime_id: $runtime_id,
      autoboot_enabled: false,
      proactive_enabled: false,
    }')"

  if ! call_mcp_tool 2000 "masc_keeper_up" "${create_args}" 45; then
    local create_error
    create_error="$(tool_error_text)"
    jq -cn \
      --arg case_id "${case_id}" \
      --arg provider "${provider}" \
      --arg model "${model}" \
      --arg keeper_profile "${keeper_profile}" \
      --arg run_id "${keeper_name}" \
      --argjson repeat_index "${repeat_index}" \
      --arg status "$(classify_status "${create_error}")" \
      --arg final_output "${create_error}" \
      '{
        case_id: $case_id,
        provider: $provider,
        model: $model,
        keeper_profile: $keeper_profile,
        run_id: $run_id,
        repeat_index: $repeat_index,
        status: $status,
        final_output: $final_output,
        task_success: false,
        tool_calls: []
      }' > "${run_dir}/evidence.json"
    cat "${run_dir}/evidence.json"
    return 0
  fi

  create_json="$(tool_result_json)"
  printf '%s' "${create_json}" > "${run_dir}/create.json"
  status_before_json="$(create_keeper_status_snapshot "${keeper_name}" "${run_dir}")"
  tool_surface_fingerprint="$(tool_surface_fingerprint_from_status "${status_before_json}")"

  start_epoch="$(date +%s)"
  if ! call_mcp_tool 3000 "masc_keeper_msg" \
    "$(jq -cn --arg name "${keeper_name}" --arg message "${message}" '{name:$name, message:$message}')" \
    "$((TIMEOUT_SEC + 30))"; then
    local msg_error
    msg_error="$(tool_error_text)"
    stop_keeper_best_effort "${keeper_name}"
    jq -cn \
      --arg case_id "${case_id}" \
      --arg provider "${provider}" \
      --arg model "${model}" \
      --arg keeper_profile "${keeper_profile}" \
      --arg run_id "${keeper_name}" \
      --argjson repeat_index "${repeat_index}" \
      --arg status "$(classify_status "${msg_error}")" \
      --arg final_output "${msg_error}" \
      --arg keeper_name "${keeper_name}" \
      --arg tool_surface_fingerprint "${tool_surface_fingerprint}" \
      '{
        case_id: $case_id,
        provider: $provider,
        model: $model,
        keeper_profile: $keeper_profile,
        run_id: $run_id,
        repeat_index: $repeat_index,
        keeper_name: $keeper_name,
        tool_surface_fingerprint: (if $tool_surface_fingerprint == "" then null else $tool_surface_fingerprint end),
        status: $status,
        final_output: $final_output,
        task_success: false,
        tool_calls: []
      }' > "${run_dir}/evidence.json"
    cat "${run_dir}/evidence.json"
    return 0
  fi

  request_json="$(tool_result_json)"
  printf '%s' "${request_json}" > "${run_dir}/msg-submit.json"
  request_id="$(printf '%s' "${request_json}" | jq -r '.request_id // empty')"
  if [[ -z "${request_id}" ]]; then
    stop_keeper_best_effort "${keeper_name}"
    jq -cn \
      --arg case_id "${case_id}" \
      --arg provider "${provider}" \
      --arg model "${model}" \
      --arg keeper_profile "${keeper_profile}" \
      --arg run_id "${keeper_name}" \
      --argjson repeat_index "${repeat_index}" \
      --arg status "runtime_unreachable" \
      --arg final_output "keeper_msg returned no request_id" \
      --arg keeper_name "${keeper_name}" \
      --arg tool_surface_fingerprint "${tool_surface_fingerprint}" \
      '{
        case_id: $case_id,
        provider: $provider,
        model: $model,
        keeper_profile: $keeper_profile,
        run_id: $run_id,
        repeat_index: $repeat_index,
        keeper_name: $keeper_name,
        tool_surface_fingerprint: (if $tool_surface_fingerprint == "" then null else $tool_surface_fingerprint end),
        status: $status,
        final_output: $final_output,
        task_success: false,
        tool_calls: []
      }' > "${run_dir}/evidence.json"
    cat "${run_dir}/evidence.json"
    return 0
  fi

  local poll_deadline
  poll_deadline=$(( start_epoch + TIMEOUT_SEC + 30 ))
  result_json=""
  while [[ "$(date +%s)" -lt "${poll_deadline}" ]]; do
    if call_mcp_tool 3100 "masc_keeper_msg_result" \
      "$(jq -cn --arg request_id "${request_id}" '{request_id:$request_id}')" 20; then
      msg_payload="$(tool_result_payload_json)"
      printf '%s' "${msg_payload}" > "${run_dir}/msg-result-last.json"
      case "$(printf '%s' "${msg_payload}" | jq -r '.status // empty')" in
        done|error)
          result_json="${msg_payload}"
          break
          ;;
      esac
    fi
    sleep "${POLL_INTERVAL_SEC}"
  done

  if [[ -z "${result_json}" ]]; then
    stop_keeper_best_effort "${keeper_name}"
    jq -cn \
      --arg case_id "${case_id}" \
      --arg provider "${provider}" \
      --arg model "${model}" \
      --arg keeper_profile "${keeper_profile}" \
      --arg run_id "${keeper_name}" \
      --argjson repeat_index "${repeat_index}" \
      --arg status "runtime_unreachable" \
      --arg final_output "keeper_msg_result polling timed out" \
      --arg keeper_name "${keeper_name}" \
      --arg tool_surface_fingerprint "${tool_surface_fingerprint}" \
      '{
        case_id: $case_id,
        provider: $provider,
        model: $model,
        keeper_profile: $keeper_profile,
        run_id: $run_id,
        repeat_index: $repeat_index,
        keeper_name: $keeper_name,
        tool_surface_fingerprint: (if $tool_surface_fingerprint == "" then null else $tool_surface_fingerprint end),
        status: $status,
        final_output: $final_output,
        task_success: false,
        tool_calls: []
      }' > "${run_dir}/evidence.json"
    cat "${run_dir}/evidence.json"
    return 0
  fi

  end_epoch="$(date +%s)"
  latency_ms="$(( (end_epoch - start_epoch) * 1000 ))"
  printf '%s' "${result_json}" > "${run_dir}/msg-result.json"

  tool_log_json="$(read_tool_log_entries "${keeper_name}")"
  printf '%s' "${tool_log_json}" > "${run_dir}/tool-log.json"
  tool_calls_json="$(tool_calls_for_evidence "${tool_log_json}")"
  printf '%s' "${tool_calls_json}" > "${run_dir}/tool-calls.json"

  metrics_json="$(latest_metrics_for_keeper "${keeper_name}")"
  printf '%s' "${metrics_json}" > "${run_dir}/latest-metrics.json"
  prompt_fingerprint="$(prompt_fingerprint_for_run "${tool_log_json}" "${metrics_json}")"

  status_after_json="$(create_keeper_status_snapshot "${keeper_name}" "${run_dir}")"
  if [[ -z "${tool_surface_fingerprint}" ]]; then
    tool_surface_fingerprint="$(tool_surface_fingerprint_from_status "${status_after_json}")"
  fi

  final_output="$(printf '%s' "${result_json}" | jq -r '
      if (.result.reply? // empty) != "" then .result.reply
      elif (.result | type) == "string" then .result
      else (.result | tostring)
      end
    ')"
  input_tokens="$(printf '%s' "${result_json}" | jq -r '.result.usage.input_tokens // empty')"
  output_tokens="$(printf '%s' "${result_json}" | jq -r '.result.usage.output_tokens // empty')"
  cost_usd="$(printf '%s' "${result_json}" | jq -r '.result.usage.cost_usd // empty')"
  actual_model_used="$(printf '%s' "${result_json}" | jq -r '.result.model // empty')"

  if [[ "$(printf '%s' "${result_json}" | jq -r '.status')" == "done" ]] \
    && [[ "$(printf '%s' "${result_json}" | jq -r '.ok // false')" == "true" ]]; then
    run_status="ok"
    final_result_json="$(derive_final_result "${case_id}" "${tool_calls_json}")"
    if task_success_from_final_result "${case_id}" "${final_result_json}"; then
      task_success=true
    fi
  else
    local failure_text
    failure_text="$(printf '%s' "${result_json}" | jq -r '
        if (.result | type) == "string" then .result
        else (.result | tostring)
        end
      ')"
    run_status="$(classify_status "${failure_text}")"
    final_result_json='null'
  fi

  stop_keeper_best_effort "${keeper_name}"

  jq -cn \
    --arg case_id "${case_id}" \
    --arg provider "${provider}" \
    --arg model "${model}" \
    --arg keeper_profile "${keeper_profile}" \
    --arg run_id "${keeper_name}" \
    --arg keeper_name "${keeper_name}" \
    --argjson repeat_index "${repeat_index}" \
    --arg prompt_fingerprint "${prompt_fingerprint}" \
    --arg tool_surface_fingerprint "${tool_surface_fingerprint}" \
    --arg status "${run_status}" \
    --arg final_output "${final_output}" \
    --arg actual_model_used "${actual_model_used}" \
    --argjson task_success "$( [[ "${task_success}" == "true" ]] && printf 'true' || printf 'false' )" \
    --argjson final_result "${final_result_json}" \
    --argjson tool_calls "${tool_calls_json}" \
    --argjson latency_ms "${latency_ms:-null}" \
    --argjson input_tokens "${input_tokens:-null}" \
    --argjson output_tokens "${output_tokens:-null}" \
    --argjson cost_usd "${cost_usd:-null}" \
    '{
      case_id: $case_id,
      provider: $provider,
      model: $model,
      keeper_profile: $keeper_profile,
      run_id: $run_id,
      repeat_index: $repeat_index,
      keeper_name: $keeper_name,
      prompt_fingerprint: (if $prompt_fingerprint == "" then null else $prompt_fingerprint end),
      tool_surface_fingerprint: (if $tool_surface_fingerprint == "" then null else $tool_surface_fingerprint end),
      task_success: $task_success,
      final_output: $final_output,
      final_result: $final_result,
      latency_ms: $latency_ms,
      input_tokens: $input_tokens,
      output_tokens: $output_tokens,
      cost_usd: $cost_usd,
      status: $status,
      actual_model_used: (if $actual_model_used == "" then null else $actual_model_used end),
      tool_calls: $tool_calls
    }' > "${run_dir}/evidence.json"
  cat "${run_dir}/evidence.json"
}

run_live_harness() {
  local model_label provider model case_json keeper_profile repeat_index
  local evidence_jsonl raw_evidence_path args

  if [[ -z "${MODELS}" ]]; then
    echo "--live requires --models provider:model[,provider:model]" >&2
    exit 2
  fi
  if ! [[ "${REPEATS}" =~ ^[0-9]+$ ]] || [[ "${REPEATS}" -le 0 ]]; then
    echo "--repeats must be a positive integer" >&2
    exit 2
  fi
  if ! [[ "${TIMEOUT_SEC}" =~ ^[0-9]+$ ]] || [[ "${TIMEOUT_SEC}" -le 0 ]]; then
    echo "--timeout-sec must be a positive integer" >&2
    exit 2
  fi

  prepare_live_environment
  start_live_server

  evidence_jsonl="${LIVE_RUN_DIR}/evidence_runs.jsonl"
  : > "${evidence_jsonl}"

  while IFS= read -r model_label; do
    model_label="$(trim "${model_label}")"
    [[ -z "${model_label}" ]] && continue
    if [[ "${model_label}" != *:* ]]; then
      echo "invalid model label (expected provider:model): ${model_label}" >&2
      exit 2
    fi
    provider="${model_label%%:*}"
    model="${model_label#*:}"
    while IFS= read -r case_json; do
      [[ -z "${case_json}" ]] && continue
      while IFS= read -r keeper_profile; do
        [[ -z "${keeper_profile}" ]] && continue
        for (( repeat_index = 1; repeat_index <= REPEATS; repeat_index++ )); do
          run_live_case "${provider}" "${model}" "${keeper_profile}" "${repeat_index}" "${case_json}" \
            >> "${evidence_jsonl}"
        done
      done < <(keeper_profiles_for_case "${case_json}")
    done < <(select_case_rows)
  done < <(printf '%s\n' "${MODELS}" | tr ',' '\n')

  raw_evidence_path="${LIVE_RUN_DIR}/evidence_runs.json"
  jq -cs '{runs: .}' "${evidence_jsonl}" > "${raw_evidence_path}"
  EVIDENCE_PATH="${raw_evidence_path}"

  ensure_cli_built
  (
    cd "${ROOT_DIR}"
    args=(
      --cases "${CASES_PATH}"
      --evidence "${EVIDENCE_PATH}"
      --format "${FORMAT}"
      --view "${VIEW}"
      --artifact-dir "${LIVE_RUN_DIR}"
    )
    if [[ -n "${MODELS}" ]]; then
      args+=(--models "${MODELS}")
    fi
    if [[ -n "${KEEPERS}" ]]; then
      args+=(--keepers "${KEEPERS}")
    fi
    if [[ "${REQUIRE_ROUTE_EVIDENCE}" == "1" ]]; then
      args+=(--require-route-evidence)
    fi
    "${CLI_EXE}" "${args[@]}"
  )

  printf '\nartifact_dir=%s\n' "${LIVE_RUN_DIR}"
  printf 'evidence_path=%s\n' "${EVIDENCE_PATH}"
}

run_evidence_summary() {
  local args
  ensure_cli_built
  mkdir -p "${OUT_DIR}"
  (
    cd "${ROOT_DIR}"
    args=(
      --cases "${CASES_PATH}"
      --evidence "${EVIDENCE_PATH}"
      --format "${FORMAT}"
      --view "${VIEW}"
      --artifact-dir "${OUT_DIR}"
    )
    if [[ -n "${MODELS}" ]]; then
      args+=(--models "${MODELS}")
    fi
    if [[ -n "${KEEPERS}" ]]; then
      args+=(--keepers "${KEEPERS}")
    fi
    if [[ "${REQUIRE_ROUTE_EVIDENCE}" == "1" ]]; then
      args+=(--require-route-evidence)
    fi
    "${CLI_EXE}" "${args[@]}"
  )
  printf '\nartifact_dir=%s\n' "${OUT_DIR}"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --cases)
      CASES_PATH="$2"
      shift 2
      ;;
    --case-ids)
      CASE_IDS="$2"
      shift 2
      ;;
    --evidence)
      EVIDENCE_PATH="$2"
      shift 2
      ;;
    --format)
      FORMAT="$2"
      shift 2
      ;;
    --view)
      VIEW="$2"
      shift 2
      ;;
    --artifact-dir)
      OUT_DIR="$2"
      shift 2
      ;;
    --models)
      MODELS="$2"
      shift 2
      ;;
    --keepers)
      KEEPERS="$2"
      shift 2
      ;;
    --require-route-evidence)
      REQUIRE_ROUTE_EVIDENCE=1
      shift
      ;;
    --no-require-route-evidence)
      REQUIRE_ROUTE_EVIDENCE=0
      shift
      ;;
    --live)
      LIVE_MODE=1
      shift
      ;;
    --repeats)
      REPEATS="$2"
      shift 2
      ;;
    --timeout-sec)
      TIMEOUT_SEC="$2"
      shift 2
      ;;
    --port)
      PORT="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "unknown arg: $1" >&2
      usage
      exit 2
      ;;
  esac
done

mkdir -p "${OUT_DIR}"

if [[ "${LIVE_MODE}" == "1" ]]; then
  run_live_harness
else
  run_evidence_summary
fi
