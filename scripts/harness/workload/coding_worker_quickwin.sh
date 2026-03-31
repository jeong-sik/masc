#!/usr/bin/env bash
set -euo pipefail
export PYTHONDONTWRITEBYTECODE=1

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
source "${ROOT_DIR}/scripts/harness/lib/mcp_jsonrpc.sh"

SERVER_EXE="${SERVER_EXE:-${ROOT_DIR}/_build/default/bin/main_eio.exe}"
HTTP_TIMEOUT_SEC="${HTTP_TIMEOUT_SEC:-120}"
MCP_CURL_EXTRA_ARGS="${MCP_CURL_EXTRA_ARGS:---http1.1}"
MCP_CURL_EXTRA_ARGS="${MCP_CURL_EXTRA_ARGS:---http1.1}"
STOP_WAIT_SEC="${STOP_WAIT_SEC:-60}"
LLAMA_SWARM_MODEL="${LLAMA_SWARM_MODEL:-qwen3.5-35b-a3b-ud-q8-xl}"
SMOKE_AGENT="${SMOKE_AGENT:-coding-smoke-supervisor}"
TEAM_STEP_WAIT_MODE="${TEAM_STEP_WAIT_MODE:-blocking}"

PORT=""
MCP_URL=""
SERVER_PID=""
SERVER_LOG=""
declare -a TMP_DIRS=()
declare -a TMP_WORKTREES=()

random_port() {
  python3 - <<'PY'
import socket
s = socket.socket()
s.bind(("127.0.0.1", 0))
print(s.getsockname()[1])
s.close()
PY
}

cleanup_server() {
  if [ -n "${SERVER_PID}" ]; then
    kill "${SERVER_PID}" >/dev/null 2>&1 || true
    wait "${SERVER_PID}" >/dev/null 2>&1 || true
    SERVER_PID=""
  fi
}

cleanup() {
  cleanup_server
  for wt in "${TMP_WORKTREES[@]:-}"; do
    git -C "${ROOT_DIR}" worktree remove "${wt}" --force >/dev/null 2>&1 || true
  done
  for dir in "${TMP_DIRS[@]:-}"; do
    rm -rf "${dir}" >/dev/null 2>&1 || true
  done
}
trap cleanup EXIT

wait_for_health() {
  local deadline=$(( $(date +%s) + 20 ))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    if curl -fsS --http2-prior-knowledge "http://127.0.0.1:${PORT}/health" >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done
  return 1
}

start_server() {
  local base_path="$1"
  cleanup_server
  PORT="$(random_port)"
  MCP_URL="http://127.0.0.1:${PORT}/mcp"
  SERVER_LOG="$(mktemp "${TMPDIR:-/tmp}/coding-worker-harness.XXXXXX")"
  "${SERVER_EXE}" --port "${PORT}" --base-path "${base_path}" >"${SERVER_LOG}" 2>&1 &
  SERVER_PID=$!
  if ! wait_for_health; then
    echo "FAIL: server did not become healthy"
    cat "${SERVER_LOG}"
    exit 1
  fi
}

bootstrap_room() {
  local session_id="$1"
  mcp_require_tool_ok "$(mcp_call_tool 1 "masc_init" "$(jq -cn --arg a "$SMOKE_AGENT" '{agent_name:$a}')")"
  mcp_require_tool_ok "$(mcp_call_tool 2 "masc_switch_mode" '{"mode":"full"}')"
  mcp_require_tool_ok "$(mcp_call_tool 3 "masc_join" "$(jq -cn --arg a "$SMOKE_AGENT" '{agent_name:$a,capabilities:["python","bash","worker"]}')")"
}

start_team_session() {
  local session_id="$1"
  local goal="$2"
  local execution_scope="$3"
  local raw
  raw="$(mcp_call_tool 4 "masc_team_session_start" "$(jq -cn \
    --arg goal "$goal" \
    --arg scope "$execution_scope" \
    '{goal:$goal,duration_seconds:180,checkpoint_interval_sec:15,orchestration_mode:"assist",communication_mode:"broadcast",execution_scope:$scope,fallback_policy:"cascade_then_task",instruction_profile:"strict",min_agents:1,agents:[]}' )")"
  mcp_require_tool_ok "$raw"
  printf '%s' "$raw" | mcp_extract_result | jq -r '.session_id // empty'
}

wait_until_terminal() {
  local client_session_id="$1"
  local team_session_id="$2"
  local deadline=$(( $(date +%s) + STOP_WAIT_SEC ))
  while :; do
    local raw status
    raw="$(mcp_call_tool 90 "masc_team_session_status" "$(jq -cn --arg s "$team_session_id" '{session_id:$s}')")"
    mcp_require_tool_ok "$raw"
    status="$(printf '%s' "$raw" | mcp_extract_result | jq -r '.session.status // empty')"
    if [ "$status" != "running" ]; then
      return 0
    fi
    if [ "$(date +%s)" -ge "$deadline" ]; then
      echo "FAIL: team session did not stop in time"
      printf '%s\n' "$raw"
      exit 1
    fi
    sleep 1
  done
}

wait_for_worker_run_event() {
  local client_session_id="$1"
  local team_session_id="$2"
  local worker_run_id="$3"
  local expected_event="$4"
  local deadline=$(( $(date +%s) + STOP_WAIT_SEC ))
  while :; do
    local raw events_json match
    raw="$(mcp_call_tool 91 "masc_team_session_events" "$(jq -cn --arg s "$team_session_id" --arg ev "$expected_event" '{session_id:$s,event_types:[$ev],limit:200}')")"
    mcp_require_tool_ok "$raw"
    events_json="$(printf '%s' "$raw" | mcp_extract_result)"
    match="$(printf '%s' "$events_json" | jq -c --arg id "$worker_run_id" '.events[]? | select(.detail.worker_run_id? == $id) | .detail' | tail -n1)"
    if [ -n "$match" ]; then
      printf '%s' "$match"
      return 0
    fi
    if [ "$(date +%s)" -ge "$deadline" ]; then
      echo "FAIL: worker run ${worker_run_id} did not emit ${expected_event} in time"
      printf '%s\n' "$events_json"
      exit 1
    fi
    sleep 1
  done
}

verify_worker_run_trace() {
  local client_session_id="$1"
  local team_session_id="$2"
  local worker_run_id="$3"
  local raw result
  raw="$(mcp_call_tool 92 "masc_team_session_verify_trace" "$(jq -cn --arg s "$team_session_id" --arg r "$worker_run_id" '{session_id:$s,worker_run_id:$r}')")"
  mcp_require_tool_ok "$raw"
  result="$(printf '%s' "$raw" | mcp_extract_result)"
  printf '%s' "$result"
}

fixture_repo_setup() {
  local fixture_dir
  fixture_dir="$(mktemp -d "${TMPDIR:-/tmp}/coding-worker-fixture.XXXXXX")"
  TMP_DIRS+=("$fixture_dir")
  cat >"${fixture_dir}/calc.py" <<'PY'
def add_two_and_three():
    return 4
PY
  cat >"${fixture_dir}/check.py" <<'PY'
import importlib.util
import pathlib

path = pathlib.Path("calc.py")
spec = importlib.util.spec_from_file_location("fixture_calc", path)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
value = module.add_two_and_three()
assert value == 5, f"expected 5, got {value}"
print("PASS")
PY
  git -C "$fixture_dir" init -q
  git -C "$fixture_dir" add calc.py check.py
  printf '%s' "$fixture_dir"
}

real_repo_setup() {
  local wt
  local rev
  wt="$(mktemp -d "${TMPDIR:-/tmp}/coding-worker-repo.XXXXXX")"
  rm -rf "$wt"
  rev="$(git -C "${ROOT_DIR}" rev-parse HEAD)"
  git -C "${ROOT_DIR}" worktree add --detach "$wt" "$rev" >/dev/null
  if [ -d "${ROOT_DIR}/test/fixtures/coding_worker_repo_smoke" ]; then
    mkdir -p "$wt/test/fixtures"
    cp -R "${ROOT_DIR}/test/fixtures/coding_worker_repo_smoke" "$wt/test/fixtures/"
    cat >"$wt/test/fixtures/coding_worker_repo_smoke/calc.py" <<'PY'
def add_two_and_three():
    return 4
PY
  fi
  TMP_WORKTREES+=("$wt")
  printf '%s' "$wt"
}

run_fixture_smoke() {
  echo "[fixture] setup temp repo"
  local fixture_dir
  fixture_dir="$(fixture_repo_setup)"
  start_server "$fixture_dir"
  bootstrap_room "fixture-client"
  local team_session_id
  team_session_id="$(start_team_session "fixture-client" "coding worker fixture smoke" "limited_code_change")"
  local inspect_prompt write_prompt raw result spawn delegate_raw delegate_json
  inspect_prompt="$(cat <<'EOF'
Use file_read and shell_exec only.
1. Read calc.py with file_read.
2. Run shell_exec with command "python3 check.py".
3. Reply with exactly one short line describing the current bug.
Do not modify files and do not call masc_team_session_step yourself.
EOF
)"
  write_prompt="$(cat <<'EOF'
Now perform the fix using file_write and shell_exec.
Rewrite calc.py so its full contents become exactly:
def add_two_and_three():
    return 5
Then run shell_exec with command "python3 check.py" and confirm it passes.
Reply with exactly one short line describing the applied fix.
Do not call masc_team_session_step yourself.
EOF
)"
  raw="$(mcp_call_tool 10 "masc_team_session_step" "$(jq -cn \
    --arg s "$team_session_id" \
    --arg prompt "$inspect_prompt" \
    --arg wait_mode "$TEAM_STEP_WAIT_MODE" \
    '{session_id:$s,spawn_role:"coder",worker_class:"executor",worker_size:"lg",execution_scope:"limited_code_change",wait_mode:$wait_mode,spawn_prompt:$prompt}')")"
  mcp_require_tool_ok "$raw"
  result="$(printf '%s' "$raw" | mcp_extract_result)"
  spawn="$(printf '%s' "$result" | jq -c '.spawn')"
  if [ "$TEAM_STEP_WAIT_MODE" = "background" ]; then
    local fixture_spawn_run_id fixture_spawn_detail fixture_spawn_verify
    printf '%s' "$spawn" | jq -e '.status == "accepted"' >/dev/null
    fixture_spawn_run_id="$(printf '%s' "$spawn" | jq -r '.worker_run_id')"
    fixture_spawn_detail="$(wait_for_worker_run_event "fixture-client" "$team_session_id" "$fixture_spawn_run_id" "team_step_spawn")"
    printf '%s' "$fixture_spawn_detail" | jq -e '.success == true' >/dev/null
    printf '%s' "$fixture_spawn_detail" | jq -e '.tool_call_count > 0' >/dev/null
    printf '%s' "$fixture_spawn_detail" | jq -e '(.tool_names | index("file_read")) != null and (.tool_names | index("shell_exec")) != null' >/dev/null
    fixture_spawn_verify="$(verify_worker_run_trace "fixture-client" "$team_session_id" "$fixture_spawn_run_id")"
    printf '%s' "$fixture_spawn_verify" | jq -e '.verification.ok == true' >/dev/null
  else
    printf '%s' "$spawn" | jq -e '.success == true' >/dev/null
    printf '%s' "$spawn" | jq -e '.tool_call_count > 0' >/dev/null
    printf '%s' "$spawn" | jq -e '(.tool_names | index("file_read")) != null and (.tool_names | index("shell_exec")) != null' >/dev/null
  fi
  delegate_raw="$(mcp_call_tool 10 "masc_team_session_step" "$(jq -cn \
    --arg s "$team_session_id" \
    --arg prompt "$write_prompt" \
    --arg wait_mode "$TEAM_STEP_WAIT_MODE" \
    '{session_id:$s,target_agent:"coder",wait_mode:$wait_mode,delegate_prompt:$prompt}')")"
  mcp_require_tool_ok "$delegate_raw"
  delegate_json="$(printf '%s' "$delegate_raw" | mcp_extract_result | jq -c '.delegate')"
  if [ "$TEAM_STEP_WAIT_MODE" = "background" ]; then
    local fixture_delegate_run_id fixture_delegate_detail fixture_delegate_verify
    printf '%s' "$delegate_json" | jq -e '.status == "accepted"' >/dev/null
    fixture_delegate_run_id="$(printf '%s' "$delegate_json" | jq -r '.worker_run_id')"
    fixture_delegate_detail="$(wait_for_worker_run_event "fixture-client" "$team_session_id" "$fixture_delegate_run_id" "team_step_delegate")"
    printf '%s' "$fixture_delegate_detail" | jq -e '.success == true' >/dev/null
    printf '%s' "$fixture_delegate_detail" | jq -e '.tool_call_count > 0' >/dev/null
    printf '%s' "$fixture_delegate_detail" | jq -e '(.tool_names | index("file_write")) != null and (.tool_names | index("shell_exec")) != null' >/dev/null
    fixture_delegate_verify="$(verify_worker_run_trace "fixture-client" "$team_session_id" "$fixture_delegate_run_id")"
    printf '%s' "$fixture_delegate_verify" | jq -e '.verification.ok == true and .verification.has_file_write == true' >/dev/null
  else
    printf '%s' "$delegate_json" | jq -e '.tool_call_count > 0' >/dev/null
    printf '%s' "$delegate_json" | jq -e '(.tool_names | index("file_write")) != null and (.tool_names | index("shell_exec")) != null' >/dev/null
  fi
  (cd "$fixture_dir" && python3 check.py >/dev/null)
  if ! grep -q 'return 5' "$fixture_dir/calc.py"; then
    echo "FAIL: fixture repo calc.py was not patched to return 5"
    exit 1
  fi
  mcp_require_tool_ok "$(mcp_call_tool 11 "masc_team_session_stop" "$(jq -cn --arg s "$team_session_id" '{session_id:$s,reason:"fixture_done",generate_report:true}')")"
  wait_until_terminal "fixture-client" "$team_session_id"
  local prove_raw prove_result
  prove_raw="$(mcp_call_tool 12 "masc_team_session_prove" "$(jq -cn --arg s "$team_session_id" '{session_id:$s,generate_report_if_missing:true}')")"
  mcp_require_tool_ok "$prove_raw"
  prove_result="$(printf '%s' "$prove_raw" | mcp_extract_result)"
  printf '%s' "$prove_result" | jq -e '.proof.evidence.spawn_tool_call_count > 0' >/dev/null
  printf '%s' "$prove_result" | jq -e '(.proof.evidence.spawn_tool_names | index("file_write")) != null' >/dev/null
  printf '%s' "$prove_result" | jq -e '.proof.evidence.write_capable_spawn_count >= 1' >/dev/null
  echo "[fixture] PASS"
}

run_real_repo_smoke() {
  echo "[repo] setup temp worktree"
  local repo_dir
  repo_dir="$(real_repo_setup)"
  start_server "$repo_dir"
  bootstrap_room "repo-client"
  local team_session_id
  team_session_id="$(start_team_session "repo-client" "coding worker real repo smoke" "limited_code_change")"
  local planner_prompt implementer_prompt implementer_write_prompt raw result delegate_raw delegate_json
  planner_prompt="$(cat <<'EOF'
Inspect test/fixtures/coding_worker_repo_smoke/calc.py and test/fixtures/coding_worker_repo_smoke/check.py.
Use file_read and shell_exec only.
Read the Python file before suggesting a fix.
Return exactly one short line describing the bug and the required fix.
Do not modify files and do not call masc_team_session_step yourself.
EOF
)"
  implementer_prompt="$(cat <<'EOF'
Inspect test/fixtures/coding_worker_repo_smoke/calc.py and test/fixtures/coding_worker_repo_smoke/check.py.
Use file_read and shell_exec only.
Return exactly one short line saying you are ready to patch the file.
Do not call masc_team_session_step yourself.
EOF
)"
  implementer_write_prompt="$(cat <<'EOF'
Now patch test/fixtures/coding_worker_repo_smoke/calc.py.
Use file_write and shell_exec.
Rewrite the file so its full contents become exactly:
def add_two_and_three():
    return 5
Then run python3 test/fixtures/coding_worker_repo_smoke/check.py and confirm it passes.
Reply with exactly one short line describing the applied patch.
Do not call masc_team_session_step yourself.
EOF
)"
  raw="$(mcp_call_tool 20 "masc_team_session_step" "$(jq -cn \
    --arg s "$team_session_id" \
    --arg planner "$planner_prompt" \
    --arg implementer "$implementer_prompt" \
    --arg wait_mode "$TEAM_STEP_WAIT_MODE" \
    '{session_id:$s,spawn_batch:[
      {spawn_role:"planner",worker_class:"manager",worker_size:"xlg",execution_scope:"observe_only",wait_mode:$wait_mode,spawn_prompt:$planner},
      {spawn_role:"implementer",worker_class:"executor",worker_size:"lg",execution_scope:"limited_code_change",wait_mode:$wait_mode,spawn_prompt:$implementer}
    ]}')")"
  mcp_require_tool_ok "$raw"
  result="$(printf '%s' "$raw" | mcp_extract_result)"
  printf '%s' "$result" | jq -e '.spawn.mode == "batch" and .spawn.count == 2 and (.spawn.results | length) == 2' >/dev/null
  if [ "$TEAM_STEP_WAIT_MODE" = "background" ]; then
    local planner_run_id implementer_run_id planner_detail implementer_detail planner_verify implementer_verify
    printf '%s' "$result" | jq -e '[.spawn.results[] | .status] | all(. == "accepted")' >/dev/null
    planner_run_id="$(printf '%s' "$result" | jq -r '.spawn.results[] | select(.spawn_role=="planner") | .worker_run_id')"
    implementer_run_id="$(printf '%s' "$result" | jq -r '.spawn.results[] | select(.spawn_role=="implementer") | .worker_run_id')"
    planner_detail="$(wait_for_worker_run_event "repo-client" "$team_session_id" "$planner_run_id" "team_step_spawn")"
    implementer_detail="$(wait_for_worker_run_event "repo-client" "$team_session_id" "$implementer_run_id" "team_step_spawn")"
    printf '%s' "$planner_detail" | jq -e '.success == true and .execution_scope == "observe_only"' >/dev/null
    printf '%s' "$implementer_detail" | jq -e '.success == true and .execution_scope == "limited_code_change"' >/dev/null
    printf '%s' "$planner_detail" | jq -e '(.tool_names | index("file_read")) != null' >/dev/null
    printf '%s' "$implementer_detail" | jq -e '(.tool_names | index("shell_exec")) != null' >/dev/null
    planner_verify="$(verify_worker_run_trace "repo-client" "$team_session_id" "$planner_run_id")"
    implementer_verify="$(verify_worker_run_trace "repo-client" "$team_session_id" "$implementer_run_id")"
    printf '%s' "$planner_verify" | jq -e '.verification.ok == true and .verification.has_file_write == false' >/dev/null
    printf '%s' "$implementer_verify" | jq -e '.verification.ok == true' >/dev/null
  else
    printf '%s' "$result" | jq -e '[.spawn.results[] | .execution_scope] | index("limited_code_change") != null' >/dev/null
    printf '%s' "$result" | jq -e '[.spawn.results[] | .tool_names[]?] | index("file_read") != null and index("shell_exec") != null' >/dev/null
  fi
  delegate_raw="$(mcp_call_tool 21 "masc_team_session_step" "$(jq -cn \
    --arg s "$team_session_id" \
    --arg prompt "$implementer_write_prompt" \
    --arg wait_mode "$TEAM_STEP_WAIT_MODE" \
    '{session_id:$s,target_agent:"implementer",wait_mode:$wait_mode,delegate_prompt:$prompt}')")"
  mcp_require_tool_ok "$delegate_raw"
  delegate_json="$(printf '%s' "$delegate_raw" | mcp_extract_result | jq -c '.delegate')"
  if [ "$TEAM_STEP_WAIT_MODE" = "background" ]; then
    local repo_delegate_run_id repo_delegate_detail repo_delegate_verify
    printf '%s' "$delegate_json" | jq -e '.status == "accepted"' >/dev/null
    repo_delegate_run_id="$(printf '%s' "$delegate_json" | jq -r '.worker_run_id')"
    repo_delegate_detail="$(wait_for_worker_run_event "repo-client" "$team_session_id" "$repo_delegate_run_id" "team_step_delegate")"
    printf '%s' "$repo_delegate_detail" | jq -e '.success == true' >/dev/null
    printf '%s' "$repo_delegate_detail" | jq -e '(.tool_names | index("file_write")) != null and (.tool_names | index("shell_exec")) != null' >/dev/null
    repo_delegate_verify="$(verify_worker_run_trace "repo-client" "$team_session_id" "$repo_delegate_run_id")"
    printf '%s' "$repo_delegate_verify" | jq -e '.verification.ok == true and .verification.has_file_write == true' >/dev/null
  else
    printf '%s' "$delegate_json" | jq -e '.tool_call_count > 0' >/dev/null
    printf '%s' "$delegate_json" | jq -e '(.tool_names | index("file_write")) != null and (.tool_names | index("shell_exec")) != null' >/dev/null
  fi
  mcp_require_tool_ok "$(mcp_call_tool 21 "masc_team_session_step" "$(jq -cn \
    --arg s "$team_session_id" \
    --arg message "planner inspected the smoke target and implementer patched calc.py; verification passed" \
    '{session_id:$s,turn_kind:"note",message:$message}')")"
  (cd "$repo_dir" && python3 test/fixtures/coding_worker_repo_smoke/check.py >/dev/null)
  if ! grep -q 'return 5' "$repo_dir/test/fixtures/coding_worker_repo_smoke/calc.py"; then
    echo "FAIL: real repo smoke calc.py was not patched to return 5"
    exit 1
  fi
  mcp_require_tool_ok "$(mcp_call_tool 22 "masc_team_session_stop" "$(jq -cn --arg s "$team_session_id" '{session_id:$s,reason:"repo_done",generate_report:true}')")"
  wait_until_terminal "repo-client" "$team_session_id"
  local prove_raw prove_result
  prove_raw="$(mcp_call_tool 23 "masc_team_session_prove" "$(jq -cn --arg s "$team_session_id" '{session_id:$s,generate_report_if_missing:true}')")"
  mcp_require_tool_ok "$prove_raw"
  prove_result="$(printf '%s' "$prove_raw" | mcp_extract_result)"
  printf '%s' "$prove_result" | jq -e '.proof.verdict == "proved"' >/dev/null
  printf '%s' "$prove_result" | jq -e '.proof.evidence.unique_turn_actors_count >= 3' >/dev/null
  printf '%s' "$prove_result" | jq -e '.proof.evidence.spawn_success_count >= 2' >/dev/null
  printf '%s' "$prove_result" | jq -e '(.proof.evidence.spawn_tool_names | index("shell_exec")) != null and (.proof.evidence.spawn_tool_names | index("file_write")) != null' >/dev/null
  printf '%s' "$prove_result" | jq -e '.proof.evidence.write_capable_spawn_count >= 1' >/dev/null
  echo "[repo] PASS"
}

if [ ! -x "$SERVER_EXE" ]; then
  echo "server executable not found: $SERVER_EXE"
  echo "build it first with: dune build --root . @default"
  exit 1
fi

echo "[1/2] fixture coding worker smoke"
run_fixture_smoke
echo "[2/2] real repo coding pair smoke"
run_real_repo_smoke
echo "PASS: coding worker quick win (${TEAM_STEP_WAIT_MODE})"
