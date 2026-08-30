#!/usr/bin/env bash
# Coding-outcome eval runner (RFC-0396 W2).
#
# For every selected case x model x repeat: boot nothing new per run — one
# isolated MASC server serves the whole invocation — copy the case workspace
# fresh, create one keeper, send it the task, wait for the episode to finish,
# then run the case's verify script. The verify exit code is the entire pass
# verdict (RFC-0396 D2); this script records evidence and never re-judges.
#
# Evidence: one JSON file per run plus an appended runs.jsonl, then
# test/coding_eval_report_cli.exe turns rows into pass@k / buckets. A run
# whose evidence file already exists is skipped, so re-invoking with the same
# --out directory resumes a sharded collection (RFC-0396 D4).
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CASES_DIR="${CODING_EVAL_CASES_DIR:-${ROOT_DIR}/benchmarks/coding/cases}"
OUT_DIR="${CODING_EVAL_OUT_DIR:-}"
MODELS="${CODING_EVAL_MODELS:-}"
CASE_IDS="${CODING_EVAL_CASE_IDS:-}"
REPEATS="${CODING_EVAL_REPEATS:-2}"
PASS_AT_K="${CODING_EVAL_K:-1}"
MEMORY_MODE="${CODING_EVAL_MEMORY_MODE:-seeded}"
PORT="${CODING_EVAL_PORT:-}"
POLL_INTERVAL_SEC="${CODING_EVAL_POLL_INTERVAL_SEC:-2}"
TIMEOUT_SEC="${CODING_EVAL_MCP_TIMEOUT_SEC:-30}"
CLI_EXE="${ROOT_DIR}/_build/default/test/coding_eval_report_cli.exe"

SERVER_PID=""
LIVE_RUN_DIR=""
TARGET_DIR=""
CONFIG_DIR=""
SERVER_LOG=""

usage() {
  cat >&2 <<'EOF'
Usage:
  scripts/harness_coding_eval.sh --models provider:model[,provider:model]
                                 [--cases DIR] [--case-ids CSV] [--repeats N]
                                 [--out DIR] [--k N] [--port N]
                                 [--memory-mode seeded|verified|filtered|source-bound|off]

Runs each selected coding case against each model, records one evidence row
per run into <out>/runs.jsonl, and summarizes with coding_eval_report_cli.
Re-running with the same --out skips runs whose evidence already exists.
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

while [[ $# -gt 0 ]]; do
  case "$1" in
    --cases) CASES_DIR="$2"; shift 2 ;;
    --out) OUT_DIR="$2"; shift 2 ;;
    --models) MODELS="$2"; shift 2 ;;
    --case-ids) CASE_IDS="$2"; shift 2 ;;
    --repeats) REPEATS="$2"; shift 2 ;;
    --k) PASS_AT_K="$2"; shift 2 ;;
    --memory-mode) MEMORY_MODE="$2"; shift 2 ;;
    --port) PORT="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown argument: $1" >&2; usage; exit 2 ;;
  esac
done

if [[ "${MEMORY_MODE}" != "seeded" && "${MEMORY_MODE}" != "verified" && "${MEMORY_MODE}" != "filtered" && "${MEMORY_MODE}" != "source-bound" && "${MEMORY_MODE}" != "off" ]]; then
  echo "--memory-mode must be seeded, verified, filtered, source-bound, or off, got: ${MEMORY_MODE}" >&2
  exit 2
fi

require_cmd jq
require_cmd curl

if [[ -z "${MODELS}" ]]; then
  echo "--models is required (example: --models ollama:qwen3-coder)" >&2
  usage
  exit 2
fi
if [[ ! -d "${CASES_DIR}" ]]; then
  echo "case corpus not found: ${CASES_DIR}" >&2
  exit 2
fi
if [[ -z "${OUT_DIR}" ]]; then
  OUT_DIR="$(mktemp -d "${TMPDIR:-/tmp}/coding-eval.XXXXXX")"
fi
mkdir -p "${OUT_DIR}/runs"
RUNS_JSONL="${OUT_DIR}/runs.jsonl"

ensure_cli_built() {
  (
    cd "${ROOT_DIR}"
    if [[ "${CODING_EVAL_SKIP_BUILD:-0}" != "1" || ! -x "${CLI_EXE}" ]]; then
      scripts/dune-local.sh build ./test/coding_eval_report_cli.exe ./bin/main_eio.exe >/dev/null
    fi
  )
}

selected_case_dirs() {
  local dir case_id
  for dir in "${CASES_DIR}"/*/; do
    [[ -f "${dir}/case.json" ]] || continue
    case_id="$(jq -r '.id' "${dir}/case.json")"
    if [[ -n "${CASE_IDS}" ]]; then
      case ",${CASE_IDS}," in
        *",${case_id},"*) printf '%s\n' "${dir%/}" ;;
        *) ;;
      esac
    else
      printf '%s\n' "${dir%/}"
    fi
  done
}

context_recovery_cases_selected() {
  local case_dir
  while IFS= read -r case_dir; do
    if [[ -f "${case_dir}/memory.json" || -f "${case_dir}/source-memory.json" ]]; then
      return 0
    fi
  done < <(selected_case_dirs)
  return 1
}

# Runtime and model ids must match [A-Za-z0-9._-]+; the raw provider tag
# (slashes, colons) goes into api-name and the id is its sanitized alias.
model_alias_of() {
  printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '-'
}

# The server dispatches only runtimes declared in runtime.toml, so a model
# asked for on the command line must exist there as a keeper-dispatchable
# entry (positive max-request-body-bytes). The declaration goes into this
# invocation's isolated config copy only; the repo config is not touched.
declare_requested_runtimes() {
  local runtime_toml="${CONFIG_DIR}/runtime.toml"
  local entry provider model alias
  local -a entries
  IFS=',' read -r -a entries <<< "${MODELS}"
  for entry in "${entries[@]}"; do
    provider="${entry%%:*}"
    model="${entry#*:}"
    alias="$(model_alias_of "${model}")"
    if grep -qF "[${provider}.${alias}]" "${runtime_toml}" \
      || grep -qF "[${provider}.\"${alias}\"]" "${runtime_toml}"; then
      continue
    fi
    if ! grep -qF "[models.${alias}]" "${runtime_toml}" \
      && ! grep -qF "[models.\"${alias}\"]" "${runtime_toml}"; then
      printf '\n[models."%s"]\napi-name = "%s"\nmax-context = 32768\ntools-support = true\nstreaming = true\n' \
        "${alias}" "${model}" >> "${runtime_toml}"
    fi
    printf '\n[%s."%s"]\nmax-request-body-bytes = 524288\nmax-concurrent = 1\n' \
      "${provider}" "${alias}" >> "${runtime_toml}"
    # The runtime also needs an agent-core catalog row, or the server boots it
    # disabled ("degraded catalog mode") and quietly routes the keeper to the
    # default lane — the eval would then measure a different model.
    local overlay_toml="${CONFIG_DIR}/agent-core-models-overlay.toml"
    if ! grep -qF "id_prefix = \"${model}\"" "${overlay_toml}"; then
      printf '\n[[models]]\nid_prefix = "%s"\nprovider_name = "%s"\nbase = "%s"\nmax_context_tokens = 32768\nsupports_tools = true\nsupports_reasoning = false\nsupports_native_streaming = true\n' \
        "${model}" "${provider}" "${provider}" >> "${overlay_toml}"
    fi
    echo "[coding-eval] declared runtime ${provider}.${alias} (api-name ${model}) in the isolated config copy" >&2
  done
}

prepare_live_environment() {
  local run_suffix
  run_suffix="$(date +%Y%m%d_%H%M%S)-$$"
  LIVE_RUN_DIR="${OUT_DIR}/live-${run_suffix}"
  TARGET_DIR="${LIVE_RUN_DIR}/target"
  CONFIG_DIR="${LIVE_RUN_DIR}/config"
  SERVER_LOG="${LIVE_RUN_DIR}/server.log"
  mkdir -p "${TARGET_DIR}" "${CONFIG_DIR}"
  cp -R "${ROOT_DIR}/config/." "${CONFIG_DIR}"
  declare_requested_runtimes
  if [[ -z "${PORT}" ]]; then
    PORT="$(harness_pick_free_port)"
  fi
}

start_live_server() {
  local launch_log="${LIVE_RUN_DIR}/launch.log"
  local bootstrap_log="${LIVE_RUN_DIR}/bootstrap.log"

  # Mint the workspace-local bearer BEFORE the server starts: the login CLI
  # writes the credential into the base path's auth store for the server to
  # read at boot, and running it against a base path a live server owns makes
  # that server yield ownership and shut down (transport/common.sh carries the
  # same ordering note).
  local minted_token
  if ! minted_token="$(harness_mint_admin_token \
    "${ROOT_DIR}/_build/default/bin/main_eio.exe" "${PORT}" "${TARGET_DIR}" \
    "coding-eval-harness")"; then
    echo "coding eval failed: could not mint a harness bearer" >&2
    exit 1
  fi
  MCP_TOKEN="${minted_token}"
  export MCP_TOKEN

  (
    # The ambient shell may carry tokens for a different live server; the
    # eval server must not adopt them as its own identity.
    unset MCP_TOKEN MCP_AUTH_TOKEN MASC_ADMIN_TOKEN MASC_TOKEN
    # Connector credentials stay out too: an eval server joining the real
    # Slack/Discord workspaces is an isolation hole, not a feature.
    unset SLACK_BOT_TOKEN SLACK_APP_TOKEN DISCORD_BOT_TOKEN
    # No cloud-provider fallback: if the requested local runtime cannot
    # serve, the eval must fail loudly, not silently measure another model.
    unset OLLAMA_CLOUD_API_KEY
    export MASC_CONFIG_DIR="${CONFIG_DIR}"
    export MASC_LOG_FILE="${SERVER_LOG}"
    export MASC_KEEPER_AUTONOMOUS_ENABLED="0"
    export MASC_ORCHESTRATOR_ENABLED="0"
    export MASC_KEEPER_BOOTSTRAP_ENABLED="0"
    if context_recovery_cases_selected; then
      export MASC_KEEPER_MEMORY_OS_RECALL="1"
      export MASC_KEEPER_MEMORY_OS_LIBRARIAN="0"
    fi
    export GRAPHQL_API_KEY=""
    export GRAPHQL_URL="http://127.0.0.1:9/graphql"
    export AGENT_CORE_MCP_SERVERS_CONFIG="mcp_servers={}"
    # RFC-0394 turned the local playground fail-closed; the eval harness is
    # exactly the dev/test caller that knob exists for. Episodes edit files
    # only inside run workspaces this script creates and owns.
    export MASC_EXEC_ALLOW_LOCAL_PLAYGROUND=1
    exec "${ROOT_DIR}/scripts/run-local.sh" \
      --target-dir "${TARGET_DIR}" \
      --port "${PORT}" \
      --bootstrap-only
  ) >"${bootstrap_log}" 2>&1
  (
    unset MCP_TOKEN MCP_AUTH_TOKEN MASC_ADMIN_TOKEN MASC_TOKEN
    # Connector credentials stay out too: an eval server joining the real
    # Slack/Discord workspaces is an isolation hole, not a feature.
    unset SLACK_BOT_TOKEN SLACK_APP_TOKEN DISCORD_BOT_TOKEN
    # No cloud-provider fallback: if the requested local runtime cannot
    # serve, the eval must fail loudly, not silently measure another model.
    unset OLLAMA_CLOUD_API_KEY
    export MASC_CONFIG_DIR="${CONFIG_DIR}"
    export MASC_LOG_FILE="${SERVER_LOG}"
    export MASC_KEEPER_AUTONOMOUS_ENABLED="0"
    export MASC_ORCHESTRATOR_ENABLED="0"
    export MASC_KEEPER_BOOTSTRAP_ENABLED="0"
    if context_recovery_cases_selected; then
      export MASC_KEEPER_MEMORY_OS_RECALL="1"
      export MASC_KEEPER_MEMORY_OS_LIBRARIAN="0"
    fi
    export GRAPHQL_API_KEY=""
    export GRAPHQL_URL="http://127.0.0.1:9/graphql"
    export AGENT_CORE_MCP_SERVERS_CONFIG="mcp_servers={}"
    # RFC-0394 turned the local playground fail-closed; the eval harness is
    # exactly the dev/test caller that knob exists for. Episodes edit files
    # only inside run workspaces this script creates and owns.
    export MASC_EXEC_ALLOW_LOCAL_PLAYGROUND=1
    exec "${ROOT_DIR}/scripts/run-local.sh" --target-dir "${TARGET_DIR}" --port "${PORT}"
  ) >"${launch_log}" 2>&1 &
  SERVER_PID="$!"

  # Three sequential boots precede readiness (login mini-stack, bootstrap-only,
  # the server itself), so the health budget is generous on purpose.
  if ! harness_wait_for_health "${PORT}" 180; then
    harness_print_log_tail "${bootstrap_log}" 120
    harness_print_log_tail "${launch_log}" 120
    harness_print_log_tail "${SERVER_LOG}" 120
    echo "coding eval failed: server did not become healthy on port ${PORT}" >&2
    exit 1
  fi

  MCP_URL="http://127.0.0.1:${PORT}/mcp"
  export MCP_URL
  # /health can answer while the MCP session layer is still in its lazy-init
  # phase, so a single initialize can land in that window under load.
  local init_attempt initialized=0
  for init_attempt in 1 2 3 4 5 6; do
    if initialize_mcp_session; then
      initialized=1
      break
    fi
    sleep 5
  done
  if [[ "${initialized}" != "1" ]]; then
    harness_print_log_tail "${SERVER_LOG}" 120
    echo "coding eval failed: MCP initialize did not return a session id" >&2
    exit 1
  fi
}

coding_keeper_instructions() {
  printf '%s\n' "너는 coding-outcome eval 전용 keeper다. 주어진 워크스페이스 디렉터리 안에서만 파일을 읽고 수정한다. 먼저 검사를 실행해 실패를 눈으로 확인하고, 원인을 고친 뒤, 같은 검사가 통과하는 것을 확인하고 나서 DONE이라고 답한다. 검사 스크립트 자체는 수정하지 않는다."
}

keeper_tool_call_names() {
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
        [ .[] | select(.keeper == $keeper) | .tool ] | map(select(type == "string"))
      '
}

stop_keeper_best_effort() {
  local keeper_name="$1"
  call_mcp_tool 9000 "masc_keeper_down" \
    "$(jq -cn --arg name "${keeper_name}" '{name:$name}')" 20 >/dev/null 2>&1 || true
}

# A case-local memory.json lets the same real workspace run with and without a
# stale Memory OS fact.  The file is harness input, not part of case.json, so
# the coding case contract and pass authority stay unchanged.  The generated
# snapshot is the production current-only wire shape and is copied into the run
# directory before the keeper assembles its first task prompt.
seed_case_memory() {
  local case_dir="$1" keeper_name="$2" run_dir="$3"
  local declaration="${case_dir}/memory.json"
  if [[ "${MEMORY_MODE}" == "off" || ! -f "${declaration}" ]]; then
    return 1
  fi
  if ! jq -e '
      (.age_sec | type == "number" and . >= 0)
      and (.claims | type == "array" and length > 0)
      and all(.claims[]; type == "string" and length > 0)
    ' "${declaration}" >/dev/null; then
    echo "invalid context-recovery memory declaration: ${declaration}" >&2
    return 2
  fi

  local age_sec observed_at facts snapshot_path
  age_sec="$(jq -r '.age_sec | floor' "${declaration}")"
  observed_at=$(( $(date +%s) - age_sec ))
  facts="$(jq -c --argjson observed_at "${observed_at}" '
    [.claims[] | {claim: ., category: "fact", first_seen: $observed_at}]
  ' "${declaration}")"
  # This harness sets MASC_CONFIG_DIR, and Config_dir_resolver deliberately
  # resolves Keeper Memory OS beside the keeper profiles in that directory.
  # Writing under TARGET_DIR/.masc/keepers would create a valid but unread
  # shadow snapshot.
  snapshot_path="${CONFIG_DIR}/keepers/${keeper_name}.memory-current.json"
  mkdir -p "$(dirname "${snapshot_path}")"
  jq -n \
    --argjson observed_at "${observed_at}" \
    --argjson facts "${facts}" \
    '{
      revision: 1,
      updated_at: $observed_at,
      source: {kind: "explicit_write", trace_id: "context-recovery-seed"},
      facts: $facts,
      change: {added: $facts, removed: [], retained: 0}
    }' > "${snapshot_path}"
  cp "${snapshot_path}" "${run_dir}/memory-seed.json"
  return 0
}

seed_case_source_memory() {
  local case_dir="$1" keeper_name="$2" run_dir="$3"
  local declaration="${case_dir}/source-memory.json"
  [[ "${MEMORY_MODE}" == "source-bound" && -f "${declaration}" ]] || return 1
  if ! jq -e '
      (.age_sec | type == "number" and . >= 0)
      and (.source_path | type == "string" and length > 0)
      and (.stale_source | type == "string")
      and (.claim | type == "string" and length > 0)
    ' "${declaration}" >/dev/null; then
    echo "invalid source-bound memory declaration: ${declaration}" >&2
    return 2
  fi

  local age_sec observed_at source_path claim digest snapshot_path
  age_sec="$(jq -r '.age_sec | floor' "${declaration}")"
  observed_at=$(( $(date +%s) - age_sec ))
  source_path="$(jq -r '.source_path' "${declaration}")"
  claim="$(jq -r '.claim' "${declaration}")"
  # Keep the declared bytes exact. Command substitution strips trailing
  # newlines, so only the digest output may cross that boundary; the source
  # bytes stream directly from jq into shasum.
  digest="sha256:$(jq -rj '.stale_source' "${declaration}" | shasum -a 256 | awk '{print $1}')"
  snapshot_path="${CONFIG_DIR}/keepers/${keeper_name}.memory-source-current.json"
  mkdir -p "$(dirname "${snapshot_path}")"
  jq -n \
    --argjson observed_at "${observed_at}" \
    --arg source_path "${source_path}" \
    --arg digest "${digest}" \
    --arg claim "${claim}" \
    '{
      revision: 1,
      updated_at: $observed_at,
      trace_id: "context-recovery-source-seed",
      facts: [{
        claim: $claim,
        first_seen: $observed_at,
        source: {kind: "file", path: $source_path, sha256: $digest}
      }],
      invalidations: []
    }' > "${snapshot_path}"
  cp "${snapshot_path}" "${run_dir}/memory-source-seed.json"
}

capture_last_prompt() {
  local case_dir="$1" keeper_name="$2" run_dir="$3"
  local declaration="${case_dir}/memory.json"
  local capture_path="${run_dir}/last-prompt.json"
  if ! curl -fsS -m 20 \
    "http://127.0.0.1:${PORT}/api/v1/keepers/${keeper_name}/last-prompt" \
    -H "Authorization: Bearer ${MCP_TOKEN}" > "${capture_path}"; then
    return 1
  fi
  if [[ "${MEMORY_MODE}" == "source-bound" ]]; then
    declaration="${case_dir}/source-memory.json"
    local stale_claim source_path
    stale_claim="$(jq -r '.claim' "${declaration}")"
    source_path="$(jq -r '.source_path' "${declaration}")"
    jq -e --arg claim "${stale_claim}" --arg source_path "${source_path}" '
      ([.. | strings | select(contains($claim))] | length) == 0
      and ([.. | strings | select(contains("reason=source_changed"))] | length) > 0
      and ([.. | strings | select(contains($source_path))] | length) > 0
    ' "${capture_path}" >/dev/null
    return
  fi
  while IFS= read -r claim; do
    local matches
    matches="$(jq --arg claim "${claim}" '
      [.. | strings | select(contains($claim))] | length
    ' "${capture_path}")"
    if [[ "${MEMORY_MODE}" == "filtered" ]]; then
      [[ "${matches}" == "0" ]] || return 1
    else
      [[ "${matches}" -gt 0 ]] || return 1
    fi
  done < <(jq -r '.claims[]' "${declaration}")
  if [[ "${MEMORY_MODE}" == "verified" || "${MEMORY_MODE}" == "filtered" ]]; then
    local probe_output="${run_dir}/live-probe.txt"
    [[ -s "${probe_output}" ]] || return 1
    if ! jq -e --rawfile probe "${probe_output}" '
      [.. | strings | select(contains($probe | rtrimstr("\n")))] | length > 0
    ' "${capture_path}" >/dev/null; then
      return 1
    fi
  fi
}

capture_recreated_source_memory() {
  local case_dir="$1" keeper_name="$2" run_dir="$3" workspace="$4"
  local declaration="${case_dir}/source-memory.json"
  local snapshot_path="${CONFIG_DIR}/keepers/${keeper_name}.memory-source-current.json"
  local source_path host_source_path digest
  source_path="$(jq -r '.source_path' "${declaration}")"
  host_source_path="${workspace}/${source_path#workspace/}"
  [[ -f "${snapshot_path}" && -f "${host_source_path}" ]] || return 1
  digest="sha256:$(shasum -a 256 "${host_source_path}" | awk '{print $1}')"
  cp "${snapshot_path}" "${run_dir}/memory-source-final.json"
  jq -e --arg source_path "${source_path}" --arg digest "${digest}" '
    (.invalidations | length) == 0
    and (.facts | length) == 1
    and .facts[0].source.path == $source_path
    and .facts[0].source.sha256 == $digest
  ' "${snapshot_path}" >/dev/null
}

apply_live_probe() {
  local case_dir="$1" keeper_name="$2" run_dir="$3" workspace="$4"
  local probe="${case_dir}/probe.sh"
  if [[ ! -f "${probe}" ]]; then
    echo "live-probe memory mode requires ${probe}" >&2
    return 1
  fi
  local note
  if ! note="$(bash "${probe}" "${workspace}")" || [[ -z "${note}" ]]; then
    echo "live context probe failed for ${case_dir}" >&2
    return 1
  fi
  printf '%s\n' "${note}" > "${run_dir}/live-probe.txt"
  if [[ "${MEMORY_MODE}" == "verified" ]]; then
    curl -fsS -m 20 -X POST \
      "http://127.0.0.1:${PORT}/api/v1/keepers/${keeper_name}/operator-note" \
      -H "Authorization: Bearer ${MCP_TOKEN}" \
      -H 'Content-Type: application/json' \
      -d "$(jq -cn --arg text "${note}" '{text:$text}')" \
      > "${run_dir}/operator-note-response.json"
  else
    local now old_facts refreshed_fact snapshot_path journal_path
    now="$(date +%s)"
    old_facts="$(jq -c '.facts' "${run_dir}/memory-seed.json")"
    refreshed_fact="$(jq -cn --arg claim "${note}" --argjson now "${now}" \
      '{claim:$claim, category:"fact", first_seen:$now}')"
    snapshot_path="${CONFIG_DIR}/keepers/${keeper_name}.memory-current.json"
    journal_path="${CONFIG_DIR}/keepers/${keeper_name}.memory-journal.jsonl"
    jq -n \
      --argjson now "${now}" \
      --argjson old_facts "${old_facts}" \
      --argjson refreshed_fact "${refreshed_fact}" \
      '{
        revision: 2,
        updated_at: $now,
        source: {kind: "explicit_write", trace_id: "context-recovery-filtered"},
        facts: [$refreshed_fact],
        change: {added: [$refreshed_fact], removed: $old_facts, retained: 0}
      }' > "${snapshot_path}"
    jq -cn \
      --argjson now "${now}" \
      --argjson old_facts "${old_facts}" \
      --argjson refreshed_fact "${refreshed_fact}" \
      '{
        outcome:"committed",
        recorded_at:$now,
        revision:2,
        source:{kind:"explicit_write", trace_id:"context-recovery-filtered"},
        change:{added:[$refreshed_fact], removed:$old_facts, retained:0}
      }' >> "${journal_path}"
    cp "${snapshot_path}" "${run_dir}/memory-refreshed.json"
    cp "${journal_path}" "${run_dir}/memory-journal.jsonl"
  fi
}

append_row() {
  local row="$1"
  local evidence_path="$2"
  printf '%s\n' "${row}" > "${evidence_path}"
  printf '%s\n' "${row}" >> "${RUNS_JSONL}"
}

# Build one evidence row. passed is derived here exactly the way the report
# CLI re-derives it (status=ok && verify_exit=0 && regression stayed green);
# the CLI refuses a row where the two stories diverge, so a bug in either side
# surfaces as a loud decode error instead of a silently wrong number.
evidence_row() {
  jq -cn \
    --arg case_id "$1" \
    --argjson run_index "$2" \
    --arg run_id "$3" \
    --arg provider "$4" \
    --arg model "$5" \
    --arg status "$6" \
    --argjson verify_exit "$7" \
    --argjson duration_ms "$8" \
    --argjson recorded_at "$9" \
    --argjson tool_calls "${10}" \
    --argjson input_tokens "${11}" \
    --argjson output_tokens "${12}" \
    --argjson cost_usd "${13}" \
    --argjson error "${14}" \
    --argjson regression_exit "${15}" \
    --argjson edited_source_files "${16}" \
    --argjson edited_target_files "${17}" \
    --argjson build_exit "${18}" \
    '{
      case_id: $case_id,
      run_index: $run_index,
      run_id: $run_id,
      provider: $provider,
      model: $model,
      status: $status,
      verify_exit: $verify_exit,
      regression_exit: $regression_exit,
      edited_source_files: $edited_source_files,
      edited_target_files: $edited_target_files,
      build_exit: $build_exit,
      passed: ($status == "ok" and $verify_exit == 0
               and ($regression_exit == null or $regression_exit == 0)),
      duration_ms: $duration_ms,
      recorded_at: $recorded_at,
      tool_calls: $tool_calls,
      input_tokens: $input_tokens,
      output_tokens: $output_tokens,
      cost_usd: $cost_usd,
      error: $error
    }'
}

json_string_or_null() {
  local value="$1"
  if [[ -z "${value}" ]]; then
    printf 'null'
  else
    jq -cn --arg v "${value}" '$v'
  fi
}

json_number_or_null() {
  local value="$1"
  if [[ "${value}" =~ ^-?[0-9]+([.][0-9]+)?$ ]]; then
    printf '%s' "${value}"
  else
    printf 'null'
  fi
}

# Count how many of the reference-solution target files the candidate actually
# changed, comparing the graded workspace against the case's pristine copy by
# content (cmp, never output parsing). A target file the candidate created that
# the pristine tree lacks, or one whose bytes differ, counts as edited; one it
# left untouched or never wrote does not. The solution overlay is the case
# author's fix, so its file set is the ground-truth "files that needed editing".
count_edited_target_files() {
  local case_dir="$1" workspace="$2"
  local solution_dir="${case_dir}/solution"
  local pristine_dir="${case_dir}/workspace"
  local count=0 rel
  while IFS= read -r target_path; do
    rel="${target_path#"${solution_dir}/"}"
    if [[ -f "${workspace}/${rel}" ]] \
      && ! cmp -s "${pristine_dir}/${rel}" "${workspace}/${rel}"; then
      count=$(( count + 1 ))
    fi
  done < <(find "${solution_dir}" -type f)
  printf '%s' "${count}"
}

# Count the pristine source files (everything in the canonical workspace except
# the protected test oracles) whose bytes the candidate changed. Only files that
# exist in the pristine tree are compared, so artifacts a check run drops
# (e.g. __pycache__) never read as candidate edits. Zero here means the run
# touched no source at all -- it gave up rather than edited the wrong file.
count_edited_source_files() {
  local case_dir="$1" workspace="$2" test_files="$3"
  local pristine_dir="${case_dir}/workspace"
  local count=0 rel is_test test_file
  while IFS= read -r pristine_path; do
    rel="${pristine_path#"${pristine_dir}/"}"
    is_test=0
    while IFS= read -r test_file; do
      [[ -z "${test_file}" ]] && continue
      if [[ "${rel}" == "${test_file}" ]]; then
        is_test=1
        break
      fi
    done <<< "${test_files}"
    [[ "${is_test}" == "1" ]] && continue
    if [[ ! -f "${workspace}/${rel}" ]] \
      || ! cmp -s "${pristine_path}" "${workspace}/${rel}"; then
      count=$(( count + 1 ))
    fi
  done < <(find "${pristine_dir}" -type f)
  printf '%s' "${count}"
}

run_one() {
  local provider="$1"
  local model="$2"
  local case_dir="$3"
  local repeat_index="$4"

  local case_id timeout_sec verify_rel prompt test_files regression_rel build_rel
  case_id="$(jq -r '.id' "${case_dir}/case.json")"
  timeout_sec="$(jq -r '.timeout_sec' "${case_dir}/case.json")"
  verify_rel="$(jq -r '.verify' "${case_dir}/case.json")"
  prompt="$(jq -r '.prompt' "${case_dir}/case.json")"
  # Protected test oracle files (one per line), restored pristine before
  # grading. Defaults to check.sh when the key is absent — the corpus
  # convention Coding_eval_case also defaults to.
  test_files="$(jq -r '(.test_files // ["check.sh"])[]' "${case_dir}/case.json")"
  # Optional PASS_TO_PASS regression script (case-relative). Empty when absent.
  regression_rel="$(jq -r '.regression // empty' "${case_dir}/case.json")"
  # Optional build probe (case-relative). Empty when absent.
  build_rel="$(jq -r '.build // empty' "${case_dir}/case.json")"

  local run_id run_dir workspace evidence_path mode_suffix=""
  if [[ -f "${case_dir}/memory.json" || -f "${case_dir}/source-memory.json" ]]; then
    mode_suffix="-${MEMORY_MODE}"
  fi
  run_id="$(printf '%s-%s-%s%s-r%d' "${provider}" "${model}" "${case_id}" "${mode_suffix}" "${repeat_index}" \
    | tr -c 'A-Za-z0-9._-' '-')"
  run_dir="${OUT_DIR}/runs/${run_id}"
  evidence_path="${run_dir}/evidence.json"
  if [[ -f "${evidence_path}" ]]; then
    echo "[coding-eval] skip ${run_id} (evidence exists)" >&2
    return 0
  fi
  mkdir -p "${run_dir}"

  local keeper_name="coding-eval-${run_id}"
  # Effectful tools (Execute/Edit/Write) are operator-gated by default, and an
  # eval run has no operator: every call sat in elicitation until its ~180s
  # expiry and the episode starved (#31640 measured exactly this). The
  # product's own per-keeper trust knob answers it — a keeper profile TOML
  # read at creation time. MASC_CONFIG_DIR (which this harness sets) shadows
  # the <base_path>/.masc/config overlay, so the profile goes into the
  # isolated config copy, not the base path.
  local profile_dir="${CONFIG_DIR}/keepers"
  mkdir -p "${profile_dir}"
  {
    printf '[keeper]\nalways_allow = true\nsandbox_profile = "docker"\ninstructions = """\n'
    coding_keeper_instructions
    printf '"""\n'
  } > "${profile_dir}/${keeper_name}.toml"
  local runtime_id="${provider}.$(model_alias_of "${model}")"
  local start_epoch end_epoch duration_ms recorded_at
  start_epoch="$(date +%s)"

  local finish_status="ok" error_text="" verify_exit_json="null" regression_exit_json="null"
  local build_exit_json="null" edited_source_json="null" edited_target_json="null"
  local tool_calls_json='[]' input_tokens_json="null" output_tokens_json="null"
  local cost_usd_json="null"
  local memory_seeded=0

  local create_args
  create_args="$(jq -cn \
    --arg name "${keeper_name}" \
    --arg instructions "$(coding_keeper_instructions)" \
    --arg runtime_id "${runtime_id}" \
    '{
      name: $name,
      instructions: $instructions,
      runtime_id: $runtime_id,
      autoboot_enabled: false,
      proactive_enabled: false
    }')"

  if ! call_mcp_tool 4000 "masc_keeper_up" "${create_args}" 45; then
    finish_status="transport_error"
    error_text="keeper_up: $(tool_error_text)"
  else
    # The chat-stream approval hook asks an operator per effectful call and
    # expires unanswered asks (#31640 measured ~180s per round). Yolo is the
    # product's explicit per-keeper, process-lifetime "stop asking in this
    # chat" stance; the durable Keeper_gate still decides external effects,
    # where the profile's always_allow answers.
    if ! curl -fsS -m 20 -X POST       "http://127.0.0.1:${PORT}/api/v1/keepers/tool-approval-mode"       -H "Authorization: Bearer ${MCP_TOKEN}" -H 'Content-Type: application/json'       -d "$(jq -cn --arg name "${keeper_name}" '{name:$name, mode:"yolo"}')"       >/dev/null 2>&1; then
      finish_status="transport_error"
      error_text="tool-approval-mode yolo set failed for ${keeper_name}"
    fi
    if [[ "${finish_status}" == "ok" && -f "${case_dir}/memory.json" && "${MEMORY_MODE}" != "off" && "${MEMORY_MODE}" != "source-bound" ]]; then
      if seed_case_memory "${case_dir}" "${keeper_name}" "${run_dir}"; then
        memory_seeded=1
      else
        finish_status="transport_error"
        error_text="failed to seed stale Memory OS fact for ${keeper_name}"
      fi
    fi
    if [[ "${finish_status}" == "ok" && -f "${case_dir}/source-memory.json" && "${MEMORY_MODE}" == "source-bound" ]]; then
      if seed_case_source_memory "${case_dir}" "${keeper_name}" "${run_dir}"; then
        memory_seeded=1
      else
        finish_status="transport_error"
        error_text="failed to seed source-bound Memory OS fact for ${keeper_name}"
      fi
    fi
  fi

  if [[ "${finish_status}" == "ok" ]]; then
    # The local profile writes inside the keeper playground and the model
    # addresses paths relative to it, so the case workspace lives there —
    # an external absolute directory produced playground-confined
    # cwd_not_directory / File-not-found on every call.
    # Docker keepers mount <playgrounds>/docker/<name>/ as their working
    # root (keeper_sandbox_config.host_root_rel_of_profile) — the profile
    # segment keeps lanes from finding each other's trees. The profile is
    # pinned to docker in the keeper TOML above.
    workspace="${TARGET_DIR}/.masc/playground/docker/${keeper_name}/workspace"
    rm -rf "${workspace}"
    mkdir -p "${workspace}"
    cp -R "${case_dir}/workspace/." "${workspace}"
    if [[ "${MEMORY_MODE}" == "verified" || "${MEMORY_MODE}" == "filtered" ]]; then
      if ! apply_live_probe "${case_dir}" "${keeper_name}" "${run_dir}" "${workspace}"; then
        finish_status="transport_error"
        error_text="failed to inject live context probe for ${keeper_name}"
      fi
    fi
    local message request_json request_id
    message="$(printf '%s\n\nWorkspace directory (relative to your working root): workspace\nRun the check inside that directory.' \
      "${prompt}")"
    if [[ "${finish_status}" == "ok" ]]; then
      if ! call_mcp_tool 4100 "masc_keeper_msg" \
        "$(jq -cn --arg name "${keeper_name}" --arg message "${message}" \
          '{name:$name, message:$message}')" 30; then
        finish_status="transport_error"
        error_text="keeper_msg: $(tool_error_text)"
      else
        request_json="$(tool_result_json)"
        printf '%s' "${request_json}" > "${run_dir}/msg-submit.json"
      # masc_keeper_msg submits an async chat operation; the settle signal is
      # masc_keeper_delegate_status with the same operation_id (the tool's own
      # description names this contract). Terminal states are Succeeded /
      # Failed / Cancelled.
        local operation_id
        operation_id="$(printf '%s' "${request_json}" | jq -r '.operation_id // empty')"
        if [[ -z "${operation_id}" ]]; then
          finish_status="transport_error"
          error_text="keeper_msg returned no operation_id"
        else
          local poll_deadline result_json op_state
          poll_deadline=$(( start_epoch + timeout_sec ))
          result_json=""
          while [[ "$(date +%s)" -lt "${poll_deadline}" ]]; do
            if call_mcp_tool 4200 "masc_keeper_delegate_status" \
              "$(jq -cn --arg name "${keeper_name}" --arg op "${operation_id}" \
                '{target:{kind:"keeper", name:$name}, operation_id:$op}')" 20; then
              local status_payload
              status_payload="$(tool_result_json)"
              op_state="$(printf '%s' "${status_payload}" | jq -r '.state // empty')"
              case "${op_state}" in
                Succeeded|Failed|Cancelled)
                  result_json="${status_payload}"
                  break
                  ;;
              esac
            fi
            sleep "${POLL_INTERVAL_SEC}"
          done
          if [[ -z "${result_json}" ]]; then
            finish_status="timeout"
            error_text="episode did not finish within ${timeout_sec}s"
          else
            printf '%s' "${result_json}" > "${run_dir}/operation-final.json"
            case "$(printf '%s' "${result_json}" | jq -r '.state')" in
              Succeeded)
                finish_status="ok"
                ;;
              *)
                finish_status="provider_error"
                error_text="$(printf '%s' "${result_json}" | jq -r \
                  '[.state, (.failure_kind // empty), (.failure_detail // empty)] | map(select(. != "")) | join(": ")')"
                ;;
            esac
          fi
        fi
      fi
    fi
  fi

  # Prompt capture exists only after the first turn has been assembled.  Keep
  # this after the async operation settles; checking it before keeper_msg would
  # turn the expected pre-turn 404 into a false transport failure.
  if [[ "${memory_seeded}" == "1" ]]; then
    if ! capture_last_prompt "${case_dir}" "${keeper_name}" "${run_dir}"; then
      if [[ "${finish_status}" == "ok" ]]; then
        finish_status="transport_error"
        error_text="seeded Memory OS fact was absent from last-prompt evidence"
      fi
    fi
  fi

  if [[ "${finish_status}" == "ok" && "${MEMORY_MODE}" == "source-bound" && -f "${case_dir}/source-memory.json" ]]; then
    if ! capture_recreated_source_memory "${case_dir}" "${keeper_name}" "${run_dir}" "${workspace}"; then
      finish_status="provider_error"
      error_text="source-bound memory was not recreated from the live source"
    fi
  fi

  # verify runs for every episode that had a workspace, timeouts included:
  # the artifact state is diagnostic even when the episode never settled.
  # The pass verdict stays status=ok AND verify_exit=0 (an unsettled episode
  # is not a completed task), and the report CLI enforces that equation.
  if [[ -d "${workspace}" ]]; then
    # Deterministic trajectory signals for the D5 failure taxonomy: how many
    # pristine source files the candidate changed, and how many of them were the
    # reference-solution targets. Computed before the oracle restore below so a
    # candidate's edit to a test file is not what these count -- only real source
    # edits are. The report splits a verify-red run by these without guessing.
    edited_source_json="$(count_edited_source_files "${case_dir}" "${workspace}" "${test_files}")"
    edited_target_json="$(count_edited_target_files "${case_dir}" "${workspace}")"

    # SWE-bench-style honest oracle: restore each protected test file from the
    # case's canonical workspace before grading, so a run cannot pass by
    # editing the very test it is judged on (the prompt's "do not modify
    # check.sh" is guidance, not an enforced boundary).
    while IFS= read -r test_file; do
      [[ -z "${test_file}" ]] && continue
      if [[ -f "${case_dir}/workspace/${test_file}" ]]; then
        mkdir -p "${workspace}/$(dirname "${test_file}")"
        cp -f "${case_dir}/workspace/${test_file}" "${workspace}/${test_file}"
      fi
    done <<< "${test_files}"
    set +e
    bash "${case_dir}/${verify_rel}" "${workspace}" \
      >"${run_dir}/verify.log" 2>&1
    local verify_code=$?
    set -e
    verify_exit_json="${verify_code}"

    # PASS_TO_PASS: a declared regression guard runs against the same graded
    # workspace and must stay green. A run that turns verify green while
    # breaking it does not pass. The script is case-level (hidden from the
    # candidate) like verify itself.
    if [[ -n "${regression_rel}" ]]; then
      set +e
      bash "${case_dir}/${regression_rel}" "${workspace}" \
        >"${run_dir}/regression.log" 2>&1
      local regression_code=$?
      set -e
      regression_exit_json="${regression_code}"
    fi

    # Optional build probe: separates a candidate edit that does not compile
    # (Build_failed) from one that compiles but is wrong (Wrong_solution). It is
    # diagnostic only -- the pass verdict stays verify + regression -- and runs
    # against the same graded workspace.
    if [[ -n "${build_rel}" ]]; then
      set +e
      bash "${case_dir}/${build_rel}" "${workspace}" \
        >"${run_dir}/build.log" 2>&1
      local build_code=$?
      set -e
      build_exit_json="${build_code}"
    fi
  fi

  tool_calls_json="$(keeper_tool_call_names "${keeper_name}")"
  stop_keeper_best_effort "${keeper_name}"

  end_epoch="$(date +%s)"
  duration_ms=$(( (end_epoch - start_epoch) * 1000 ))
  recorded_at="${end_epoch}"

  local row
  row="$(evidence_row \
    "${case_id}" "${repeat_index}" "${run_id}" "${provider}" "${model}" \
    "${finish_status}" "${verify_exit_json}" "${duration_ms}" "${recorded_at}" \
    "${tool_calls_json}" "${input_tokens_json}" "${output_tokens_json}" \
    "${cost_usd_json}" "$(json_string_or_null "${error_text}")" \
    "${regression_exit_json}" "${edited_source_json}" "${edited_target_json}" \
    "${build_exit_json}")"
  append_row "${row}" "${evidence_path}"
  echo "[coding-eval] ${run_id}: status=${finish_status} verify_exit=${verify_exit_json} regression_exit=${regression_exit_json} edited_target=${edited_target_json} build=${build_exit_json}" >&2
}

main() {
  ensure_cli_built
  prepare_live_environment
  start_live_server

  local case_dirs
  case_dirs="$(selected_case_dirs)"
  if [[ -z "${case_dirs}" ]]; then
    echo "no cases selected under ${CASES_DIR}" >&2
    exit 2
  fi

  local model_entry provider model case_dir repeat_index
  IFS=',' read -r -a model_entries <<< "${MODELS}"
  for model_entry in "${model_entries[@]}"; do
    provider="${model_entry%%:*}"
    model="${model_entry#*:}"
    if [[ -z "${provider}" || -z "${model}" || "${provider}" == "${model_entry}" ]]; then
      echo "model entries must look like provider:model, got: ${model_entry}" >&2
      exit 2
    fi
    while IFS= read -r case_dir; do
      for (( repeat_index = 1; repeat_index <= REPEATS; repeat_index++ )); do
        run_one "${provider}" "${model}" "${case_dir}" "${repeat_index}"
      done
    done <<< "${case_dirs}"
  done

  "${CLI_EXE}" --cases "${CASES_DIR}" --runs "${RUNS_JSONL}" --out "${OUT_DIR}" \
    --k "${PASS_AT_K}"
  echo "[coding-eval] report: ${OUT_DIR}/REPORT.md" >&2
}

main
