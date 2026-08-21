#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
if [[ "$#" -gt 1 ]] || [[ "$MODE" != "run" && "$MODE" != "--verify-provenance-only" ]]; then
  echo "usage: $0 [--verify-provenance-only]" >&2
  exit 64
fi

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BINARY="${KEEPER_ACCEPTANCE_BINARY:?KEEPER_ACCEPTANCE_BINARY is required}"
MANIFEST="${KEEPER_ACCEPTANCE_MANIFEST:?KEEPER_ACCEPTANCE_MANIFEST is required}"
OUTPUT_DIR="${KEEPER_ACCEPTANCE_OUTPUT_DIR:?KEEPER_ACCEPTANCE_OUTPUT_DIR is required}"
EXPECTED_EVENT="${KEEPER_ACCEPTANCE_EXPECTED_EVENT:?KEEPER_ACCEPTANCE_EXPECTED_EVENT is required}"
EXPECTED_SHA="${KEEPER_ACCEPTANCE_EXPECTED_SHA:?KEEPER_ACCEPTANCE_EXPECTED_SHA is required}"
EXPECTED_REF="${KEEPER_ACCEPTANCE_EXPECTED_REF:?KEEPER_ACCEPTANCE_EXPECTED_REF is required}"
EXPECTED_REF_PROTECTED="${KEEPER_ACCEPTANCE_EXPECTED_REF_PROTECTED:?KEEPER_ACCEPTANCE_EXPECTED_REF_PROTECTED is required}"
EXPECTED_WORKFLOW_REF="${KEEPER_ACCEPTANCE_EXPECTED_WORKFLOW_REF:?KEEPER_ACCEPTANCE_EXPECTED_WORKFLOW_REF is required}"
EXPECTED_WORKFLOW_SHA="${KEEPER_ACCEPTANCE_EXPECTED_WORKFLOW_SHA:?KEEPER_ACCEPTANCE_EXPECTED_WORKFLOW_SHA is required}"
RUNTIME_ID="${KEEPER_ACCEPTANCE_RUNTIME_ID:-glm-coding.glm-4-7-coding}"
RUNTIME_BY_ROLE_JSON="${KEEPER_ACCEPTANCE_RUNTIME_BY_ROLE_JSON:-}"
REQUIRE_HETEROGENEOUS_RUNTIMES="${KEEPER_ACCEPTANCE_REQUIRE_HETEROGENEOUS_RUNTIMES:-false}"
TURN_TIMEOUT_SEC="${KEEPER_ACCEPTANCE_TURN_TIMEOUT_SEC:-300}"
RUNNER_TEMP_ROOT="${RUNNER_TEMP:?RUNNER_TEMP is required}"
: "${ZAI_API_KEY_SB:?ZAI_API_KEY_SB is required by the isolated GLM runtime}"

fail() {
  echo "keeper-realworld-acceptance: $*" >&2
  exit 1
}

for command_name in curl jq python3 sha256sum; do
  command -v "$command_name" >/dev/null 2>&1 \
    || fail "missing required command: $command_name"
done

[[ -f "$BINARY" ]] || fail "binary not found: $BINARY"
[[ -f "$MANIFEST" ]] || fail "manifest not found: $MANIFEST"
case "$EXPECTED_EVENT" in
  push|workflow_dispatch) ;;
  *) fail "expected event must be push or workflow_dispatch: $EXPECTED_EVENT" ;;
esac
[[ "$EXPECTED_SHA" =~ ^[0-9a-f]{40}$ ]] \
  || fail "expected source SHA must be a full 40-character lowercase SHA"
[[ "$EXPECTED_REF" == "refs/heads/main" ]] \
  || fail "expected source ref must be refs/heads/main: $EXPECTED_REF"
[[ "$EXPECTED_REF_PROTECTED" == "true" ]] \
  || fail "expected source ref must be protected"
[[ "$EXPECTED_WORKFLOW_REF" == "$GITHUB_REPOSITORY/.github/workflows/ci.yml@refs/heads/main" ]] \
  || fail "expected workflow ref is not the trusted main workflow: $EXPECTED_WORKFLOW_REF"
[[ "$EXPECTED_WORKFLOW_SHA" == "$EXPECTED_SHA" ]] \
  || fail "expected workflow/source mismatch: workflow=$EXPECTED_WORKFLOW_SHA source=$EXPECTED_SHA"

runner_sha="$(git -C "$ROOT_DIR" rev-parse HEAD)"
[[ "$runner_sha" == "$EXPECTED_SHA" ]] \
  || fail "runner checkout mismatch: expected=$EXPECTED_SHA actual=$runner_sha"

manifest_schema="$(jq -er '.schema' "$MANIFEST")"
manifest_event="$(jq -er '.event_name' "$MANIFEST")"
manifest_sha="$(jq -er '.source_sha' "$MANIFEST")"
manifest_ref="$(jq -er '.source_ref' "$MANIFEST")"
manifest_ref_protected="$(jq -er '.source_ref_protected' "$MANIFEST")"
manifest_workflow_ref="$(jq -er '.workflow_ref' "$MANIFEST")"
manifest_workflow_sha="$(jq -er '.workflow_sha' "$MANIFEST")"
manifest_binary_sha="$(jq -er '.binary_sha256' "$MANIFEST")"
actual_binary_sha="$(sha256sum "$BINARY" | awk '{print $1}')"
[[ "$manifest_schema" == "masc.keeper_acceptance_runtime.v2" ]] \
  || fail "manifest schema mismatch: $manifest_schema"
[[ "$manifest_event" == "$EXPECTED_EVENT" ]] \
  || fail "manifest event mismatch: expected=$EXPECTED_EVENT actual=$manifest_event"
[[ "$manifest_sha" == "$EXPECTED_SHA" ]] \
  || fail "manifest source mismatch: expected=$EXPECTED_SHA actual=$manifest_sha"
[[ "$manifest_ref" == "$EXPECTED_REF" ]] \
  || fail "manifest ref mismatch: expected=$EXPECTED_REF actual=$manifest_ref"
[[ "$manifest_ref_protected" == "$EXPECTED_REF_PROTECTED" ]] \
  || fail "manifest protected-ref mismatch: expected=$EXPECTED_REF_PROTECTED actual=$manifest_ref_protected"
[[ "$manifest_workflow_ref" == "$EXPECTED_WORKFLOW_REF" ]] \
  || fail "manifest workflow ref mismatch: expected=$EXPECTED_WORKFLOW_REF actual=$manifest_workflow_ref"
[[ "$manifest_workflow_sha" == "$EXPECTED_WORKFLOW_SHA" ]] \
  || fail "manifest workflow SHA mismatch: expected=$EXPECTED_WORKFLOW_SHA actual=$manifest_workflow_sha"
[[ "$actual_binary_sha" == "$manifest_binary_sha" ]] \
  || fail "binary digest mismatch: expected=$manifest_binary_sha actual=$actual_binary_sha"

if [[ "$MODE" == "--verify-provenance-only" ]]; then
  echo "keeper-realworld-acceptance: provenance PASS event=$EXPECTED_EVENT source=$EXPECTED_SHA ref=$EXPECTED_REF"
  exit 0
fi

base_path="$(mktemp -d "$RUNNER_TEMP_ROOT/keeper-realworld-base.XXXXXX")"
case "$base_path" in
  "$RUNNER_TEMP_ROOT"/keeper-realworld-base.*) ;;
  *) fail "mktemp returned an unexpected base path: $base_path" ;;
esac

mkdir -p "$OUTPUT_DIR" "$base_path/.masc/config"
[[ -z "$(find "$OUTPUT_DIR" -mindepth 1 -maxdepth 1 -print -quit)" ]] \
  || fail "output directory must be empty: $OUTPUT_DIR"
cp "$ROOT_DIR/config/runtime.toml" "$base_path/.masc/config/runtime.toml"
cp "$ROOT_DIR/config/agent-core-models-overlay.toml" \
  "$base_path/.masc/config/agent-core-models-overlay.toml"
cp "$ROOT_DIR/scripts/fixtures/keeper-multi-collaboration/tool-compositions.toml" \
  "$base_path/.masc/config/tool-compositions.toml"
cp "$MANIFEST" "$OUTPUT_DIR/runtime-artifact-manifest.json"

server_log="$OUTPUT_DIR/server.log"
preflight_json="$OUTPUT_DIR/preflight-command.json"
run_json="$OUTPUT_DIR/run-command.json"
verify_json="$OUTPUT_DIR/verify-command.json"
token_file="$base_path/.masc/keeper-realworld.token"
evidence_dir="$OUTPUT_DIR/evidence"

port="$(python3 - <<'PY'
import socket

with socket.socket() as sock:
    sock.bind(("127.0.0.1", 0))
    print(sock.getsockname()[1])
PY
)"
base_url="http://127.0.0.1:$port"
mcp_url="$base_url/mcp"
health_url="$base_url/health?full=1"

server_pid=""
cleanup() {
  if [[ -n "$server_pid" ]] && kill -0 "$server_pid" 2>/dev/null; then
    kill -TERM "$server_pid" 2>/dev/null || true
    wait "$server_pid" 2>/dev/null || true
  fi
}
trap cleanup EXIT INT TERM

chmod +x "$BINARY"
env \
  MASC_BASE_PATH="$base_path" \
  MASC_ADMIN_TOKEN= \
  MASC_INTERNAL_MCP_TOKEN= \
  MASC_TOKEN= \
  MASC_GRPC_ENABLED=0 \
  MASC_WS_ENABLED=0 \
  MASC_KEEPER_BOOTSTRAP_ENABLED=false \
  ZAI_API_KEY_SB="$ZAI_API_KEY_SB" \
  "$BINARY" --host 127.0.0.1 --port "$port" --base-path "$base_path" \
  >"$server_log" 2>&1 &
server_pid=$!

health_ready=false
for _ in $(seq 1 90); do
  if curl -fsS "$health_url" >/dev/null 2>&1; then
    health_ready=true
    break
  fi
  if ! kill -0 "$server_pid" 2>/dev/null; then
    tail -n 100 "$server_log" >&2 || true
    fail "isolated server exited before health became ready"
  fi
  sleep 1
done
[[ "$health_ready" == true ]] || {
  tail -n 100 "$server_log" >&2 || true
  fail "isolated server did not become healthy"
}

token_ready=false
for _ in $(seq 1 30); do
  if curl -fsS -H 'Accept: application/json' \
    "$base_url/api/v1/dashboard/dev-token" \
    | jq -er '.token' >"$token_file" 2>/dev/null; then
    token_ready=true
    break
  fi
  sleep 1
done
[[ "$token_ready" == true ]] || fail "could not mint the loopback dashboard token"
chmod 600 "$token_file"

common_args=(
  --mcp-url "$mcp_url"
  --health-url "$health_url"
  --token-file "$token_file"
  --expected-base-path "$base_path"
  --expected-source-sha "$EXPECTED_SHA"
  --timeout "$TURN_TIMEOUT_SEC"
  --browser-proof-script "$ROOT_DIR/dashboard/e2e/keeper-composition-real-backend.mjs"
)

runtime_args=(--runtime-id "$RUNTIME_ID")
if [[ -n "$RUNTIME_BY_ROLE_JSON" ]]; then
  runtime_args=(--runtime-by-role-json "$RUNTIME_BY_ROLE_JSON")
fi
if [[ "$REQUIRE_HETEROGENEOUS_RUNTIMES" == "true" ]]; then
  runtime_args+=(--require-heterogeneous-runtimes)
elif [[ "$REQUIRE_HETEROGENEOUS_RUNTIMES" != "false" ]]; then
  fail "KEEPER_ACCEPTANCE_REQUIRE_HETEROGENEOUS_RUNTIMES must be true or false"
fi
GATE_RUNTIME_BY_ROLE_JSON="$RUNTIME_BY_ROLE_JSON"
if [[ -z "$GATE_RUNTIME_BY_ROLE_JSON" ]]; then
  GATE_RUNTIME_BY_ROLE_JSON="{}"
fi

python3 "$ROOT_DIR/scripts/harness/workload/keeper_multi_collaboration_acceptance.py" \
  --preflight "${common_args[@]}" >"$preflight_json"

python3 "$ROOT_DIR/scripts/harness/workload/keeper_multi_collaboration_acceptance.py" \
  --run \
  --allow-mutation \
  "${runtime_args[@]}" \
  --run-id "rw-${GITHUB_RUN_ID:-local}-${GITHUB_RUN_ATTEMPT:-1}" \
  --output-dir "$evidence_dir" \
  "${common_args[@]}" >"$run_json"

python3 "$ROOT_DIR/scripts/harness/workload/keeper_multi_collaboration_acceptance.py" \
  --verify \
  --output-dir "$evidence_dir" \
  --expected-base-path "$base_path" \
  --expected-source-sha "$EXPECTED_SHA" >"$verify_json"

jq -n \
  --arg schema "masc.keeper_realworld_gate.v1" \
  --arg status "passed" \
  --arg event_name "$EXPECTED_EVENT" \
  --arg source_sha "$EXPECTED_SHA" \
  --arg source_ref "$EXPECTED_REF" \
  --arg workflow_ref "$EXPECTED_WORKFLOW_REF" \
  --arg workflow_sha "$EXPECTED_WORKFLOW_SHA" \
  --arg binary_sha256 "$actual_binary_sha" \
  --arg effective_base_path "$base_path" \
  --arg runtime_id "$RUNTIME_ID" \
  --arg runtime_by_role_json "$GATE_RUNTIME_BY_ROLE_JSON" \
  --arg require_heterogeneous_runtimes "$REQUIRE_HETEROGENEOUS_RUNTIMES" \
  --arg run_id "${GITHUB_RUN_ID:-local}" \
  --arg run_attempt "${GITHUB_RUN_ATTEMPT:-1}" \
  '{
    schema: $schema,
    status: $status,
    event_name: $event_name,
    source_sha: $source_sha,
    source_ref: $source_ref,
    source_ref_protected: true,
    workflow_ref: $workflow_ref,
    workflow_sha: $workflow_sha,
    binary_sha256: $binary_sha256,
    effective_base_path: $effective_base_path,
    runtime_id: (if ($runtime_by_role_json | fromjson | length) > 0 then null else $runtime_id end),
    runtime_by_role: ($runtime_by_role_json | fromjson),
    require_heterogeneous_runtimes: ($require_heterogeneous_runtimes == "true"),
    github_run_id: $run_id,
    github_run_attempt: $run_attempt
  }' >"$OUTPUT_DIR/gate-result.json"

echo "keeper-realworld-acceptance: PASS event=$EXPECTED_EVENT source=$EXPECTED_SHA evidence=$evidence_dir"
