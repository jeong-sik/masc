#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

# shellcheck disable=SC1091
# shellcheck source=scripts/harness/lib/mcp_jsonrpc.sh
source "$REPO_ROOT/scripts/harness/lib/mcp_jsonrpc.sh"

RUN_ID="${RUN_ID:-keeper-docker-pr-lifecycle-$(date +%Y%m%d_%H%M%S)}"
RUN_DIR="${RUN_DIR:-$REPO_ROOT/logs/keeper_docker_pr_lifecycle/$RUN_ID}"
RUN_DIR_EXPLICIT=0
RAW_DIR="$RUN_DIR/raw"
PROMPT_DIR="$RUN_DIR/prompts"
REQUESTS_FILE="$RUN_DIR/requests.jsonl"
RESULTS_FILE="$RUN_DIR/results.jsonl"
POLL_ERRORS_FILE="$RUN_DIR/poll_errors.jsonl"
REVIEW_TARGETS_FILE="$RUN_DIR/review-targets.jsonl"
GITHUB_IDENTITY_COUNTS_FILE="$RUN_DIR/github-identity-counts.json"
PROOF_BRANCH_COLLISIONS_FILE="$RUN_DIR/proof-branch-collisions.jsonl"
CREATE_READINESS_FAILURES_FILE="$RUN_DIR/create-readiness-failures.jsonl"
SUMMARY_FILE="$RUN_DIR/summary.json"
AUDIT_FILE="$RUN_DIR/audit-docker-pr-lifecycle.json"
AUDIT_STATUS_RESULT=0

BASE_PATH="${BASE_PATH:-${MASC_BASE_PATH:-$HOME/me}}"
EXPECTED_KEEPERS="${EXPECTED_KEEPERS:-14}"
KEEPER_NAMES="${KEEPER_NAMES:-}"
MAX_KEEPERS="${MAX_KEEPERS:-0}"
REPO_SLUG="${REPO_SLUG:-jeong-sik/masc-mcp}"
BOARD_POST_ID="${BOARD_POST_ID:-}"
MUTATE="${MUTATE:-0}"
RUN_AUDIT="${RUN_AUDIT:-1}"
EXIT_ON_AUDIT_FAIL="${EXIT_ON_AUDIT_FAIL:-}"
MSG_TIMEOUT_SEC="${MSG_TIMEOUT_SEC:-120}"
KEEPER_TURN_TIMEOUT_SEC="${KEEPER_TURN_TIMEOUT_SEC:-900}"
INIT_TIMEOUT_SEC="${INIT_TIMEOUT_SEC:-60}"
POLL_TIMEOUT_SEC="${POLL_TIMEOUT_SEC:-1200}"
POLL_INTERVAL_SEC="${POLL_INTERVAL_SEC:-10}"
LIFECYCLE_MUTATION_MODE="split"
REQUIRED_TOOLS_LEGACY="${REQUIRED_TOOLS:-}"
CREATE_REQUIRED_TOOLS="${CREATE_REQUIRED_TOOLS:-${REQUIRED_TOOLS_LEGACY:-keeper_bash,keeper_pr_create}}"
REVIEW_REQUIRED_TOOLS="${REVIEW_REQUIRED_TOOLS:-${REQUIRED_TOOLS_LEGACY:-keeper_pr_review_comment}}"
MCP_URL="${MCP_URL:-http://127.0.0.1:8935/mcp}"
MCP_TOKEN="${MASC_MCP_TOKEN:-}"
MCP_CLIENT_NAME="${MCP_CLIENT_NAME:-keeper-docker-pr-lifecycle-reprobe}"
EXPECTED_SERVER_COMMIT="${EXPECTED_SERVER_COMMIT:-}"
FORBID_GITHUB_IDENTITIES="${FORBID_GITHUB_IDENTITIES:-}"
ALLOW_FORK_PR_FOR_READONLY="${ALLOW_FORK_PR_FOR_READONLY:-0}"
SERVER_HEALTH_URL="${SERVER_HEALTH_URL:-}"
SERVER_COMMIT_ACTUAL=""
SERVER_STARTED_AT_ACTUAL=""
SERVER_INCARNATION_ACTUAL=""
SERVER_HEALTH_CHECK_FILE=""
SERVER_INCARNATION_LAST_ACTUAL=""
SERVER_INCARNATION_LAST_REASON=""
SERVER_INCARNATION_LAST_FILE=""

usage() {
  cat <<'EOF'
Usage: scripts/harness_keeper_docker_pr_lifecycle_reprobe.sh [options]

Post-merge/live reprobe harness for Docker PR lifecycle evidence.

Default mode is dry-run: discover target keepers, render per-keeper prompts,
render a cross-keeper approval ring, and run the read-only Docker lifecycle
audit. It does not send keeper messages unless --mutate is supplied.

Options:
  --mutate                 Send prompts to keepers via masc_keeper_msg.
  --dry-run                Do not send prompts (default).
  --keeper-names CSV       Target explicit keeper names instead of discovery.
  --max-keepers N          Limit targets after discovery/CSV expansion.
  --expected-keepers N     Expected configured keeper count for audit.
  --repo OWNER/REPO        Target repository slug in the keeper prompt.
  --base-path PATH         MASC base path for audit (default: $HOME/me).
  --mcp-url URL            MCP endpoint (default: http://127.0.0.1:8935/mcp).
  --expected-server-commit COMMIT
                           Fail unless /health build.commit matches this commit.
  --forbid-github-identity NAME
                           Fail --mutate preflight when a target keeper uses
                           this GitHub identity. Repeat or pass comma-separated.
  --allow-fork-pr-for-readonly
                           Permit PUBLIC repo READ/TRIAGE credentials to satisfy
                           create proof by pushing to their own fork and opening
                           a draft PR with head OWNER:BRANCH.
  --server-health-url URL  Health endpoint for commit verification.
  --board-post-id ID       Post a final board comment to this thread.
  --run-id ID              Stable run id for prompts and artifacts.
  --run-dir PATH           Artifact directory.
  -h, --help               Show this help.

Environment:
  MASC_MCP_TOKEN           Optional bearer token for MCP calls.
  POLL_TIMEOUT_SEC         Overall result polling window when --mutate is used.
  POLL_INTERVAL_SEC        Poll interval in seconds.
  MSG_TIMEOUT_SEC          HTTP request timeout for MCP tool calls.
  KEEPER_TURN_TIMEOUT_SEC  Per-keeper Agent.run timeout_sec sent to masc_keeper_msg.
  REQUIRED_TOOLS           Legacy CSV applied to both split phases when
                           phase-specific overrides are unset.
  CREATE_REQUIRED_TOOLS    CSV required_tools for split create phase.
  REVIEW_REQUIRED_TOOLS    CSV required_tools for split review phase.
  RUN_AUDIT=0              Skip final audit.
  EXPECTED_SERVER_COMMIT   Optional expected /health build.commit prefix.
  FORBID_GITHUB_IDENTITIES Optional CSV of forbidden keeper GitHub identities.
  ALLOW_FORK_PR_FOR_READONLY=1
                           Same as --allow-fork-pr-for-readonly.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --mutate)
      MUTATE=1
      shift
      ;;
    --dry-run)
      MUTATE=0
      shift
      ;;
    --keeper-names)
      KEEPER_NAMES="$2"
      shift 2
      ;;
    --max-keepers)
      MAX_KEEPERS="$2"
      shift 2
      ;;
    --expected-keepers)
      EXPECTED_KEEPERS="$2"
      shift 2
      ;;
    --repo)
      REPO_SLUG="$2"
      shift 2
      ;;
    --base-path)
      BASE_PATH="$2"
      shift 2
      ;;
    --mcp-url)
      MCP_URL="$2"
      shift 2
      ;;
    --expected-server-commit)
      EXPECTED_SERVER_COMMIT="$2"
      shift 2
      ;;
    --forbid-github-identity)
      if [[ -n "$FORBID_GITHUB_IDENTITIES" ]]; then
        FORBID_GITHUB_IDENTITIES="$FORBID_GITHUB_IDENTITIES,$2"
      else
        FORBID_GITHUB_IDENTITIES="$2"
      fi
      shift 2
      ;;
    --allow-fork-pr-for-readonly)
      ALLOW_FORK_PR_FOR_READONLY=1
      shift
      ;;
    --server-health-url)
      SERVER_HEALTH_URL="$2"
      shift 2
      ;;
    --board-post-id)
      BOARD_POST_ID="$2"
      shift 2
      ;;
    --run-id)
      RUN_ID="$2"
      if [[ "$RUN_DIR_EXPLICIT" != "1" ]]; then
        RUN_DIR="$REPO_ROOT/logs/keeper_docker_pr_lifecycle/$RUN_ID"
        RAW_DIR="$RUN_DIR/raw"
        PROMPT_DIR="$RUN_DIR/prompts"
        REQUESTS_FILE="$RUN_DIR/requests.jsonl"
        RESULTS_FILE="$RUN_DIR/results.jsonl"
        POLL_ERRORS_FILE="$RUN_DIR/poll_errors.jsonl"
        REVIEW_TARGETS_FILE="$RUN_DIR/review-targets.jsonl"
        GITHUB_IDENTITY_COUNTS_FILE="$RUN_DIR/github-identity-counts.json"
        PROOF_BRANCH_COLLISIONS_FILE="$RUN_DIR/proof-branch-collisions.jsonl"
        CREATE_READINESS_FAILURES_FILE="$RUN_DIR/create-readiness-failures.jsonl"
        SUMMARY_FILE="$RUN_DIR/summary.json"
        AUDIT_FILE="$RUN_DIR/audit-docker-pr-lifecycle.json"
      fi
      shift 2
      ;;
    --run-dir)
      RUN_DIR="$2"
      RUN_DIR_EXPLICIT=1
      RAW_DIR="$RUN_DIR/raw"
      PROMPT_DIR="$RUN_DIR/prompts"
      REQUESTS_FILE="$RUN_DIR/requests.jsonl"
      RESULTS_FILE="$RUN_DIR/results.jsonl"
      POLL_ERRORS_FILE="$RUN_DIR/poll_errors.jsonl"
      REVIEW_TARGETS_FILE="$RUN_DIR/review-targets.jsonl"
      GITHUB_IDENTITY_COUNTS_FILE="$RUN_DIR/github-identity-counts.json"
      PROOF_BRANCH_COLLISIONS_FILE="$RUN_DIR/proof-branch-collisions.jsonl"
      CREATE_READINESS_FAILURES_FILE="$RUN_DIR/create-readiness-failures.jsonl"
      SUMMARY_FILE="$RUN_DIR/summary.json"
      AUDIT_FILE="$RUN_DIR/audit-docker-pr-lifecycle.json"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [[ -z "$EXIT_ON_AUDIT_FAIL" ]]; then
  EXIT_ON_AUDIT_FAIL="$MUTATE"
fi

mkdir -p "$RUN_DIR" "$RAW_DIR" "$PROMPT_DIR"
: >"$REQUESTS_FILE"
: >"$RESULTS_FILE"
: >"$POLL_ERRORS_FILE"
: >"$REVIEW_TARGETS_FILE"
: >"$PROOF_BRANCH_COLLISIONS_FILE"
: >"$CREATE_READINESS_FAILURES_FILE"

log() {
  printf '[%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >&2
}

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "required command not found: $1" >&2
    exit 127
  fi
}

server_health_url() {
  if [[ -n "$SERVER_HEALTH_URL" ]]; then
    printf '%s\n' "$SERVER_HEALTH_URL"
    return 0
  fi
  local base="$MCP_URL"
  base="${base%/mcp}"
  if [[ "$base" == "$MCP_URL" ]]; then
    base="${MCP_URL%/}"
  fi
  printf '%s/health\n' "$base"
}

assert_expected_server_commit() {
  local health_file fields rc actual started incarnation
  health_file="$RAW_DIR/server-health.json"
  if fields="$(capture_server_incarnation "$health_file")"; then
    :
  else
    rc=$?
    if [[ $rc -eq 2 ]]; then
      echo "server health missing build.commit for incarnation check: url=$(server_health_url) file=$health_file" >&2
    else
      echo "failed to fetch server health for incarnation check: url=$(server_health_url) file=$health_file" >&2
    fi
    exit 1
  fi
  IFS=$'\t' read -r actual started incarnation <<<"$fields"
  SERVER_COMMIT_ACTUAL="$actual"
  SERVER_STARTED_AT_ACTUAL="$started"
  SERVER_INCARNATION_ACTUAL="$incarnation"
  SERVER_HEALTH_CHECK_FILE="$health_file"

  if [[ -n "$EXPECTED_SERVER_COMMIT" \
      && "$actual" != "$EXPECTED_SERVER_COMMIT" \
      && "$actual" != "$EXPECTED_SERVER_COMMIT"* \
      && "$EXPECTED_SERVER_COMMIT" != "$actual"* ]]; then
    echo "server commit mismatch: expected=$EXPECTED_SERVER_COMMIT actual=$actual url=$(server_health_url)" >&2
    exit 1
  fi
  log "server incarnation verified: commit=$actual started_at=${started:-unknown}"
}

capture_server_incarnation() {
  # Exit codes:
  #   0 - prints "$actual\t$started\t$incarnation"
  #   1 - HTTP fetch failed (server_health_unavailable, transient)
  #   2 - HTTP succeeded but build.commit was missing/empty
  #       (server_health_missing_commit, distinct from "server down")
  local health_file="$1"
  local health_url actual started incarnation
  health_url="$(server_health_url)"
  if ! curl -fsS --max-time 5 "$health_url" >"$health_file"; then
    return 1
  fi

  actual="$(jq -r '.build.commit // .build_commit // .commit // empty' "$health_file")"
  started="$(jq -r '.build.started_at // .started_at // .startup.started_at // empty' "$health_file")"
  if [[ -z "$actual" ]]; then
    return 2
  fi
  incarnation="$actual|$started"
  printf '%s\t%s\t%s\n' "$actual" "$started" "$incarnation"
}

assert_server_incarnation_unchanged() {
  # SERVER_INCARNATION_LAST_REASON is set to one of:
  #   server_incarnation_changed   - real restart (caller must terminate
  #                                  polling and record pending as lost)
  #   server_health_unavailable    - transient HTTP failure (caller should
  #                                  keep polling; the server may come back
  #                                  without having restarted)
  #   server_health_missing_commit - HTTP succeeded but build.commit empty
  #                                  (poll-side data shape, not a restart)
  # Capture exit status with rc=$? so callers can preserve the distinction
  # between "transient" and "real restart" instead of collapsing both into
  # server_health_unavailable.
  [[ -n "$SERVER_INCARNATION_ACTUAL" ]] || return 0

  local health_file fields rc actual started incarnation
  health_file="$RAW_DIR/server-health-poll.json"
  if fields="$(capture_server_incarnation "$health_file")"; then
    :
  else
    rc=$?
    case $rc in
      2) SERVER_INCARNATION_LAST_REASON="server_health_missing_commit" ;;
      *) SERVER_INCARNATION_LAST_REASON="server_health_unavailable" ;;
    esac
    SERVER_INCARNATION_LAST_FILE="$health_file"
    SERVER_INCARNATION_LAST_ACTUAL=""
    return 1
  fi
  IFS=$'\t' read -r actual started incarnation <<<"$fields"
  SERVER_INCARNATION_LAST_FILE="$health_file"
  SERVER_INCARNATION_LAST_ACTUAL="$incarnation"
  if [[ "$incarnation" != "$SERVER_INCARNATION_ACTUAL" ]]; then
    SERVER_INCARNATION_LAST_REASON="server_incarnation_changed"
    return 1
  fi
  return 0
}

record_pending_server_incarnation_loss() {
  local pending_file="$1"
  local status="$2"
  local raw_file="$3"
  local phase="${4:-}"
  while IFS=$'\t' read -r request_id keeper; do
    [[ -n "$request_id" ]] || continue
    jq -nc \
      --arg keeper "$keeper" \
      --arg phase "$phase" \
      --arg request_id "$request_id" \
      --arg status "$status" \
      --arg expected_incarnation "$SERVER_INCARNATION_ACTUAL" \
      --arg actual_incarnation "$SERVER_INCARNATION_LAST_ACTUAL" \
      --arg raw_file "$raw_file" \
      '{keeper:$keeper, phase:$phase, request_id:$request_id, status:$status, server_expected_incarnation:$expected_incarnation, server_actual_incarnation:$actual_incarnation, raw_file:$raw_file}' \
      >>"$RESULTS_FILE"
  done <"$pending_file"
}

load_mcp_token() {
  if [[ -n "$MCP_TOKEN" ]]; then
    return 0
  fi
  local token_file="$BASE_PATH/.masc/auth/codex-mcp-client.token"
  if [[ -f "$token_file" ]]; then
    MCP_TOKEN="$(tr -d '\n' <"$token_file")"
  fi
}

init_mcp_session() {
  if [[ -n "${MCP_SESSION_ID:-}" ]]; then
    return 0
  fi

  local headers_file body_file init_body session_id protocol_version deadline
  headers_file="$(mcp_mktemp_file "keeper-docker-reprobe-init" ".headers")"
  body_file="$(mcp_mktemp_file "keeper-docker-reprobe-init" ".body")"
  init_body="$(
    jq -cn \
      --arg client_name "$MCP_CLIENT_NAME" \
      '{
        jsonrpc:"2.0",
        id:1,
        method:"initialize",
        params:{
          protocolVersion:"2025-11-25",
          clientInfo:{name:$client_name, version:"1.0"},
          capabilities:{}
        }
      }'
  )"

  deadline=$(( $(date +%s) + INIT_TIMEOUT_SEC ))
  while :; do
    : >"$headers_file"
    : >"$body_file"
    session_id=""
    protocol_version=""

    local now_ts remaining_sec init_attempt_timeout
    now_ts="$(date +%s)"
    remaining_sec=$((deadline - now_ts))
    if [[ "$remaining_sec" -le 0 ]]; then
      break
    fi
    init_attempt_timeout="$remaining_sec"
    if [[ "$MSG_TIMEOUT_SEC" -gt 0 && "$MSG_TIMEOUT_SEC" -lt "$init_attempt_timeout" ]]; then
      init_attempt_timeout="$MSG_TIMEOUT_SEC"
    fi

    local -a cmd=(
      curl -sS --max-time "$init_attempt_timeout"
      -D "$headers_file"
      -o "$body_file"
      -X POST "$MCP_URL"
      -H "Content-Type: application/json"
      -H "Accept: application/json, text/event-stream"
    )
    if [[ -n "$MCP_TOKEN" ]]; then
      cmd+=( -H "Authorization: Bearer $MCP_TOKEN" )
    fi
    cmd+=( --data-binary "$init_body" )

    if "${cmd[@]}" >/dev/null; then
      session_id="$(
        awk '
          tolower($0) ~ /^mcp-session-id:/ {
            sub(/^[^:]+:[[:space:]]*/, "", $0)
            sub(/\r$/, "", $0)
            print $0
            exit
          }' "$headers_file"
      )"
      protocol_version="$(
        awk '
          tolower($0) ~ /^mcp-protocol-version:/ {
            sub(/^[^:]+:[[:space:]]*/, "", $0)
            sub(/\r$/, "", $0)
            print $0
            exit
          }' "$headers_file"
      )"
      if [[ -n "$session_id" ]]; then
        break
      fi
      if ! jq -e '.error.code == -32002' "$body_file" >/dev/null 2>&1; then
        break
      fi
    fi

    if [[ "$(date +%s)" -ge "$deadline" ]]; then
      break
    fi
    sleep 2
  done

  if [[ -z "$session_id" ]]; then
    echo "MCP initialize did not return Mcp-Session-Id before ${INIT_TIMEOUT_SEC}s deadline" >&2
    cat "$body_file" >&2 || true
    rm -f "$headers_file" "$body_file"
    exit 1
  fi

  MCP_SESSION_ID="$session_id"
  export MCP_SESSION_ID
  if [[ -n "$protocol_version" ]]; then
    MCP_PROTOCOL_VERSION="$protocol_version"
    export MCP_PROTOCOL_VERSION
  fi
  rm -f "$headers_file" "$body_file"
}

ensure_mcp_session_if_needed() {
  if [[ -z "$KEEPER_NAMES" || "$MUTATE" == "1" || -n "$BOARD_POST_ID" ]]; then
    load_mcp_token
    init_mcp_session
  fi
}

tool_call() {
  local id="$1"
  local tool_name="$2"
  local args_json="$3"
  local timeout_sec="${4:-$MSG_TIMEOUT_SEC}"
  local saved_timeout="${HTTP_TIMEOUT_SEC:-}"
  HTTP_TIMEOUT_SEC="$timeout_sec"
  local json_id payload
  json_id="$(jq -cn --arg value "$id" '$value')"
  payload="$(mcp_call_tool "$json_id" "$tool_name" "$args_json" "${MCP_SESSION_ID:-}" "$MCP_TOKEN" "$MCP_URL")"
  HTTP_TIMEOUT_SEC="$saved_timeout"
  printf '%s' "$payload"
}

tool_text_or_empty() {
  local payload="$1"
  printf '%s' "$payload" | mcp_extract_text
}

discover_keepers() {
  local keeper_file="$RUN_DIR/keepers.txt"
  if [[ -n "$KEEPER_NAMES" ]]; then
    printf '%s\n' "$KEEPER_NAMES" \
      | tr ',' '\n' \
      | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' \
      | awk 'NF' >"$keeper_file"
  else
    log "discovering docker keepers via masc_keeper_list"
    local payload text runtime_names runtime_docker config_docker config_dir
    runtime_names="$RUN_DIR/keepers.runtime.txt"
    runtime_docker="$RUN_DIR/keepers.runtime-docker.txt"
    config_docker="$RUN_DIR/keepers.config-docker.txt"
    config_dir="$BASE_PATH/.masc/config/keepers"
    payload="$(tool_call "keeper-list-$RUN_ID" "masc_keeper_list" '{"detailed":true,"limit":100}' 30)"
    printf '%s' "$payload" >"$RAW_DIR/keeper-list.jsonrpc.json"
    mcp_require_tool_ok "$payload" "masc_keeper_list"
    text="$(tool_text_or_empty "$payload")"
    printf '%s' "$text" | jq '.' >"$RAW_DIR/keeper-list.json"
    printf '%s' "$text" \
      | jq -r '
          def rows:
            if type == "array" then .
            elif ((.keepers? // null) | type) == "array" then .keepers
            elif ((.items? // null) | type) == "array" then .items
            elif ((.agents? // null) | type) == "array" then .agents
            else [] end;
          rows[]
          | select(type == "object")
          | .name
          | select(type == "string" and length > 0)
        ' >"$runtime_names"
    printf '%s' "$text" \
      | jq -r '
          def rows:
            if type == "array" then .
            elif ((.keepers? // null) | type) == "array" then .keepers
            elif ((.items? // null) | type) == "array" then .items
            elif ((.agents? // null) | type) == "array" then .agents
            else [] end;
          rows[]
          | select(type == "object")
          | select((.sandbox_profile // .config.sandbox_profile // .meta.sandbox_profile // "") == "docker")
          | .name
          | select(type == "string" and length > 0)
        ' >"$runtime_docker"

    if [[ -d "$config_dir" ]]; then
      python3 - "$config_dir" >"$config_docker" <<'PY'
import pathlib
import sys

try:
    import tomllib
except ModuleNotFoundError:
    import tomli as tomllib  # type: ignore

root = pathlib.Path(sys.argv[1])
for path in sorted(root.glob("*.toml")):
    try:
        data = tomllib.loads(path.read_text())
    except Exception:
        continue
    keeper = data.get("keeper")
    if not isinstance(keeper, dict):
        keeper = data
    if keeper.get("sandbox_profile") == "docker":
        name = keeper.get("name") or data.get("name") or path.stem
        if isinstance(name, str) and name:
            print(name)
PY
    else
      : >"$config_docker"
    fi

    if [[ -s "$config_docker" ]]; then
      awk 'NR == FNR { docker[$0] = 1; next } docker[$0]' "$config_docker" "$runtime_names" >"$keeper_file"
    elif [[ -s "$runtime_docker" ]]; then
      cp "$runtime_docker" "$keeper_file"
    else
      log "warning: runtime did not expose sandbox_profile and config docker list is empty; using all runtime keepers"
      cp "$runtime_names" "$keeper_file"
    fi
  fi

  if [[ "$MAX_KEEPERS" =~ ^[0-9]+$ ]] && [[ "$MAX_KEEPERS" -gt 0 ]]; then
    local limited="$RUN_DIR/keepers.limited.txt"
    head -n "$MAX_KEEPERS" "$keeper_file" >"$limited"
    mv "$limited" "$keeper_file"
  fi

  local count
  count="$(awk 'NF { c++ } END { print c + 0 }' "$keeper_file")"
  if [[ "$count" -eq 0 ]]; then
    echo "no target keepers discovered; pass --keeper-names or check MCP/runtime state" >&2
    exit 1
  fi
  log "target keepers: $count"
}

build_review_targets() {
  python3 - "$RUN_DIR/keepers.txt" "$GITHUB_IDENTITY_COUNTS_FILE" \
    "$REVIEW_TARGETS_FILE" <<'PY'
import json
import pathlib
import sys

keepers_file = pathlib.Path(sys.argv[1])
identity_counts_file = pathlib.Path(sys.argv[2])
review_targets_file = pathlib.Path(sys.argv[3])

keepers = [line.strip() for line in keepers_file.read_text().splitlines() if line.strip()]
try:
    identity_payload = json.loads(identity_counts_file.read_text())
except Exception:
    identity_payload = {}
identities = identity_payload.get("keepers")
if not isinstance(identities, dict):
    identities = {}
accounts = identity_payload.get("keeper_accounts")
if not isinstance(accounts, dict):
    accounts = {}


def fallback_target(index):
    if len(keepers) < 2:
        return None
    return keepers[(index + 1) % len(keepers)]


with review_targets_file.open("w", encoding="utf-8") as handle:
    for index, keeper in enumerate(keepers):
        keeper_identity = identities.get(keeper)
        keeper_account = accounts.get(keeper)
        review_target = None
        mode = "insufficient_targets"

        if len(keepers) >= 2 and isinstance(keeper_account, str):
            for candidate in keepers:
                if candidate == keeper:
                    continue
                candidate_account = accounts.get(candidate)
                if isinstance(candidate_account, str) and candidate_account != keeper_account:
                    review_target = candidate
                    mode = "account_aware"
                    break
            if review_target is None:
                mode = "account_pool_insufficient"
        elif len(keepers) >= 2 and isinstance(keeper_identity, str):
            for candidate in keepers:
                if candidate == keeper:
                    continue
                candidate_identity = identities.get(candidate)
                if isinstance(candidate_identity, str) and candidate_identity != keeper_identity:
                    review_target = candidate
                    mode = "identity_name_aware_unresolved_account"
                    break
            if review_target is None:
                mode = "identity_name_pool_insufficient"
        elif len(keepers) >= 2:
            review_target = fallback_target(index)
            mode = "ring_unverified_identity"

        row = {
            "keeper": keeper,
            "keeper_identity": keeper_identity,
            "keeper_account_login": keeper_account,
            "review_target": review_target,
            "review_target_identity": identities.get(review_target) if review_target else None,
            "review_target_account_login": accounts.get(review_target) if review_target else None,
            "mode": mode,
        }
        handle.write(json.dumps(row, sort_keys=True, separators=(",", ":")) + "\n")
PY
  if [[ "$MUTATE" == "1" ]] \
    && jq -e 'select(.review_target == null)' "$REVIEW_TARGETS_FILE" >/dev/null; then
    echo "cross-keeper approval targets could not be assigned for every keeper" >&2
    jq -c 'select(.review_target == null)' "$REVIEW_TARGETS_FILE" >&2 || true
    exit 1
  fi
  log "review targets: $REVIEW_TARGETS_FILE"
}

build_github_identity_counts() {
  python3 - "$BASE_PATH" "$RUN_DIR/keepers.txt" "$GITHUB_IDENTITY_COUNTS_FILE" "$FORBID_GITHUB_IDENTITIES" "$REPO_SLUG" <<'PY'
import json
import os
import pathlib
import subprocess
import sys
from collections import Counter

try:
    import tomllib
except ModuleNotFoundError:
    import tomli as tomllib  # type: ignore


base_path = pathlib.Path(sys.argv[1]).expanduser().resolve()
keepers_file = pathlib.Path(sys.argv[2])
out_file = pathlib.Path(sys.argv[3])
forbidden = {
    item.strip()
    for item in sys.argv[4].split(",")
    if item.strip()
}
repo_slug = sys.argv[5]
config_dir = base_path / ".masc" / "config" / "keepers"
runtime_dir = base_path / ".masc" / "keepers"


def merge_dicts(base, overlay):
    merged = dict(base)
    for key, value in overlay.items():
        if isinstance(value, dict) and isinstance(merged.get(key), dict):
            merged[key] = merge_dicts(merged[key], value)
        else:
            merged[key] = value
    return merged


def load_keeper_config(path, seen=None):
    seen = set() if seen is None else seen
    resolved = path.resolve()
    if resolved in seen:
        return {}
    seen.add(resolved)
    try:
        raw = tomllib.loads(path.read_text())
    except Exception:
        return {}
    keeper = raw.get("keeper")
    if not isinstance(keeper, dict):
        return {}
    base_name = keeper.get("base")
    if isinstance(base_name, str) and base_name.strip():
        return merge_dicts(load_keeper_config(path.parent / base_name, seen), keeper)
    return keeper


def string_field(data, key):
    value = data.get(key)
    return value if isinstance(value, str) and value else None


def read_account_login(identity):
    hosts_path = base_path / ".masc" / "github-identities" / identity / "gh" / "hosts.yml"
    if not hosts_path.is_file():
        return None
    try:
        lines = hosts_path.read_text(encoding="utf-8", errors="replace").splitlines()
    except Exception:
        return None
    for line in lines:
        stripped = line.strip()
        if not stripped.startswith("user:"):
            continue
        value = stripped.split(":", 1)[1].split("#", 1)[0].strip().strip("'\"")
        return value or None
    return None


def read_repo_info(identity):
    gh_config_dir = base_path / ".masc" / "github-identities" / identity / "gh"
    if not gh_config_dir.is_dir():
        return None, None, "gh_config_dir_missing"
    env = os.environ.copy()
    env["GH_CONFIG_DIR"] = str(gh_config_dir)
    try:
        completed = subprocess.run(
            [
                "gh",
                "repo",
                "view",
                repo_slug,
                "--json",
                "viewerPermission,visibility",
            ],
            check=False,
            env=env,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            timeout=20,
        )
    except Exception as exc:
        return None, None, f"repo_permission_probe_exception:{exc}"
    if completed.returncode != 0:
        detail = (completed.stderr or completed.stdout).strip().splitlines()
        preview = detail[0] if detail else f"gh_exit_{completed.returncode}"
        return None, None, preview[:200]
    try:
        payload = json.loads(completed.stdout)
    except Exception as exc:
        return None, None, f"repo_permission_probe_json_error:{exc}"
    permission = payload.get("viewerPermission")
    visibility = payload.get("visibility")
    permission = permission if isinstance(permission, str) and permission else None
    visibility = visibility if isinstance(visibility, str) and visibility else None
    return permission, visibility, None


keepers = [line.strip() for line in keepers_file.read_text().splitlines() if line.strip()]
identities = {}
accounts = {}
permissions = {}
visibilities = {}
missing = []
unresolved_accounts = []
permission_errors = []
forbidden_keepers = []
for keeper in keepers:
    config = load_keeper_config(config_dir / f"{keeper}.toml")
    runtime = {}
    runtime_path = runtime_dir / f"{keeper}.json"
    if runtime_path.exists():
        try:
            loaded = json.loads(runtime_path.read_text())
            if isinstance(loaded, dict):
                runtime = loaded
        except Exception:
            runtime = {}
    identity = string_field(runtime, "github_identity") or string_field(
        config, "github_identity"
    )
    if identity:
        identities[keeper] = identity
        account_login = read_account_login(identity)
        if account_login:
            accounts[keeper] = account_login
        else:
            unresolved_accounts.append({"keeper": keeper, "github_identity": identity})
        permission, visibility, permission_error = read_repo_info(identity)
        if permission:
            permissions[keeper] = permission
            if visibility:
                visibilities[keeper] = visibility
        else:
            permission_errors.append(
                {
                    "keeper": keeper,
                    "github_identity": identity,
                    "error": permission_error or "permission_unresolved",
                }
            )
        if identity in forbidden:
            forbidden_keepers.append(
                {
                    "keeper": keeper,
                    "github_identity": identity,
                    "matched": "github_identity",
                }
            )
        if account_login and account_login in forbidden and account_login != identity:
            forbidden_keepers.append(
                {
                    "keeper": keeper,
                    "github_identity": identity,
                    "github_account_login": account_login,
                    "matched": "github_account_login",
                }
            )
    else:
        missing.append(keeper)

counts = Counter(identities.values())
account_counts = Counter(accounts.values())
permission_counts = Counter(permissions.values())
visibility_counts = Counter(visibilities.values())
out_file.write_text(
    json.dumps(
        {
            "base_path": str(base_path),
            "keeper_count": len(keepers),
            "unique_count": len(counts),
            "account_unique_count": len(account_counts),
            "counts": dict(sorted(counts.items())),
            "account_counts": dict(sorted(account_counts.items())),
            "repo_permission_counts": dict(sorted(permission_counts.items())),
            "repo_visibility_counts": dict(sorted(visibility_counts.items())),
            "keepers": identities,
            "keeper_accounts": accounts,
            "keeper_repo_permissions": permissions,
            "keeper_repo_visibilities": visibilities,
            "missing": missing,
            "unresolved_accounts": unresolved_accounts,
            "repo_permission_errors": permission_errors,
            "forbidden_identities": sorted(forbidden),
            "forbidden_keepers": forbidden_keepers,
        },
        sort_keys=True,
        indent=2,
    )
    + "\n"
)
PY
}

assert_github_identity_pool_for_mutate() {
  build_github_identity_counts
  local unique_count
  unique_count="$(jq -r '.unique_count // 0' "$GITHUB_IDENTITY_COUNTS_FILE")"
  local unresolved_accounts_count
  unresolved_accounts_count="$(jq -r '(.unresolved_accounts // []) | length' "$GITHUB_IDENTITY_COUNTS_FILE")"
  if [[ "$MUTATE" == "1" && "$unique_count" -lt 2 ]]; then
    echo "at least two unique github_identity values are required for cross-keeper approval proof" >&2
    jq -c '{unique_count, counts, missing}' "$GITHUB_IDENTITY_COUNTS_FILE" >&2 || true
    exit 1
  fi
  if [[ "$MUTATE" == "1" && "$unresolved_accounts_count" -gt 0 ]]; then
    echo "target keeper set has unresolved GitHub account logins" >&2
    jq -c '{unresolved_accounts}' "$GITHUB_IDENTITY_COUNTS_FILE" >&2 || true
    exit 1
  fi
  local account_unique_count
  account_unique_count="$(jq -r '.account_unique_count // 0' "$GITHUB_IDENTITY_COUNTS_FILE")"
  if [[ "$MUTATE" == "1" && "$account_unique_count" -lt 2 ]]; then
    echo "at least two unique authenticated GitHub accounts are required for cross-keeper approval proof" >&2
    jq -c '{account_unique_count, account_counts, keeper_accounts}' "$GITHUB_IDENTITY_COUNTS_FILE" >&2 || true
    exit 1
  fi
  local repo_permission_error_count
  repo_permission_error_count="$(jq -r '(.repo_permission_errors // []) | length' "$GITHUB_IDENTITY_COUNTS_FILE")"
  if [[ "$MUTATE" == "1" && "$repo_permission_error_count" -gt 0 ]]; then
    echo "target keeper set has unresolved GitHub repository permissions" >&2
    jq -c '{repo_permission_errors}' "$GITHUB_IDENTITY_COUNTS_FILE" >&2 || true
    exit 1
  fi
  local non_writable_file
  non_writable_file="$RUN_DIR/non-writable-keepers.json"
  python3 - "$GITHUB_IDENTITY_COUNTS_FILE" "$ALLOW_FORK_PR_FOR_READONLY" >"$non_writable_file" <<'PY'
import json
import pathlib
import sys

payload = json.loads(pathlib.Path(sys.argv[1]).read_text())
allow_fork = sys.argv[2] == "1"
permissions = payload.get("keeper_repo_permissions")
if not isinstance(permissions, dict):
    permissions = {}
visibilities = payload.get("keeper_repo_visibilities")
if not isinstance(visibilities, dict):
    visibilities = {}

writable = {"ADMIN", "MAINTAIN", "WRITE"}
forkable_read = {"READ", "TRIAGE"}
non_writable = []
for keeper, permission in sorted(permissions.items()):
    visibility = visibilities.get(keeper)
    if permission in writable:
        continue
    if allow_fork and permission in forkable_read and visibility == "PUBLIC":
        continue
    non_writable.append(
        {"keeper": keeper, "permission": permission, "visibility": visibility}
    )

print(json.dumps({"non_writable_keepers": non_writable}, sort_keys=True))
PY
  if [[ "$MUTATE" == "1" && -s "$non_writable_file" ]] \
    && jq -e '(.non_writable_keepers // []) | length > 0' "$non_writable_file" >/dev/null; then
    echo "target keeper set includes accounts without upstream write permission" >&2
    jq -c --arg allow_fork "$ALLOW_FORK_PR_FOR_READONLY" '{
      keeper_repo_permissions,
      keeper_repo_visibilities,
      non_writable_keepers: (
        input.non_writable_keepers
      ),
      allow_fork_pr_for_readonly: $allow_fork
    }' "$GITHUB_IDENTITY_COUNTS_FILE" "$non_writable_file" >&2 || true
    exit 1
  fi
  if [[ "$MUTATE" == "1" ]] \
    && jq -e '(.forbidden_keepers // []) | length > 0' "$GITHUB_IDENTITY_COUNTS_FILE" >/dev/null; then
    echo "target keeper set includes forbidden github_identity values" >&2
    jq -c '{forbidden_identities, forbidden_keepers}' "$GITHUB_IDENTITY_COUNTS_FILE" >&2 || true
    exit 1
  fi
}

review_target_for_keeper() {
  local keeper="$1"
  jq -r --arg keeper "$keeper" '
    select(.keeper == $keeper) | .review_target // empty
  ' "$REVIEW_TARGETS_FILE" | head -n 1
}

proof_branch_for_keeper() {
  local keeper="$1"
  printf 'keeper-%s-agent/%s' "$keeper" "$RUN_ID"
}

github_account_for_keeper() {
  local keeper="$1"
  jq -r --arg keeper "$keeper" '.keeper_accounts[$keeper] // empty' "$GITHUB_IDENTITY_COUNTS_FILE"
}

repo_permission_for_keeper() {
  local keeper="$1"
  jq -r --arg keeper "$keeper" '.keeper_repo_permissions[$keeper] // empty' "$GITHUB_IDENTITY_COUNTS_FILE"
}

repo_visibility_for_keeper() {
  local keeper="$1"
  jq -r --arg keeper "$keeper" '.keeper_repo_visibilities[$keeper] // empty' "$GITHUB_IDENTITY_COUNTS_FILE"
}

keeper_uses_fork_pr_route() {
  local keeper="$1"
  local permission visibility
  permission="$(repo_permission_for_keeper "$keeper")"
  visibility="$(repo_visibility_for_keeper "$keeper")"
  [[ "$ALLOW_FORK_PR_FOR_READONLY" == "1" \
    && "$visibility" == "PUBLIC" \
    && ( "$permission" == "READ" || "$permission" == "TRIAGE" ) ]]
}

assert_no_proof_branch_collisions_for_mutate() {
  [[ "$MUTATE" == "1" ]] || return 0

  local branches_file remote_heads_file
  branches_file="$RUN_DIR/proof-branches.txt"
  remote_heads_file="$RUN_DIR/proof-branch-remote-heads.txt"
  : >"$branches_file"
  : >"$remote_heads_file"
  : >"$PROOF_BRANCH_COLLISIONS_FILE"

  local keeper branch
  while IFS= read -r keeper; do
    [[ -n "$keeper" ]] || continue
    branch="$(proof_branch_for_keeper "$keeper")"
    printf '%s\t%s\n' "$keeper" "$branch" >>"$branches_file"
  done <"$RUN_DIR/keepers.txt"

  local proof_branches=()
  while IFS=$'\t' read -r _ branch; do
    [[ -n "$branch" ]] || continue
    proof_branches+=( "$branch" )
  done <"$branches_file"
  if [[ "${#proof_branches[@]}" -gt 0 ]]; then
    if ! git -C "$REPO_ROOT" ls-remote --heads origin "${proof_branches[@]}" \
        >"$remote_heads_file"; then
      echo "failed to check remote proof branch uniqueness before mutate" >&2
      exit 1
    fi
  fi

  while IFS=$'\t' read -r keeper branch; do
    [[ -n "$keeper" && -n "$branch" ]] || continue
    local local_branch remote_tracking_branch remote_head worktree_branch
    local_branch=false
    remote_tracking_branch=false
    remote_head=false
    worktree_branch=false

    if git -C "$REPO_ROOT" show-ref --verify --quiet "refs/heads/$branch"; then
      local_branch=true
    fi
    if git -C "$REPO_ROOT" show-ref --verify --quiet "refs/remotes/origin/$branch"; then
      remote_tracking_branch=true
    fi
    if awk -v ref="refs/heads/$branch" '$2 == ref { found = 1 } END { exit(found ? 0 : 1) }' \
        "$remote_heads_file"; then
      remote_head=true
    fi
    if git -C "$REPO_ROOT" worktree list --porcelain \
        | awk -v ref="refs/heads/$branch" '$1 == "branch" && $2 == ref { found = 1 } END { exit(found ? 0 : 1) }'; then
      worktree_branch=true
    fi

    if [[ "$local_branch" == "true" || "$remote_tracking_branch" == "true" \
        || "$remote_head" == "true" || "$worktree_branch" == "true" ]]; then
      jq -nc \
        --arg keeper "$keeper" \
        --arg branch "$branch" \
        --argjson local_branch "$local_branch" \
        --argjson remote_tracking_branch "$remote_tracking_branch" \
        --argjson remote_head "$remote_head" \
        --argjson worktree_branch "$worktree_branch" \
        '{
          keeper:$keeper,
          branch:$branch,
          local_branch:$local_branch,
          remote_tracking_branch:$remote_tracking_branch,
          remote_head:$remote_head,
          worktree_branch:$worktree_branch,
          blocker:"branch_collision_preflight"
        }' >>"$PROOF_BRANCH_COLLISIONS_FILE"
    fi
  done <"$branches_file"

  if [[ -s "$PROOF_BRANCH_COLLISIONS_FILE" ]]; then
    echo "proof branch collision preflight failed; choose a fresh --run-id" >&2
    cat "$PROOF_BRANCH_COLLISIONS_FILE" >&2
    exit 1
  fi
}

prompt_for_keeper_create() {
  local keeper="$1"
  local branch
  branch="$(proof_branch_for_keeper "$keeper")"
  local account permission visibility head_ref git_route_rule push_step pr_step
  account="$(github_account_for_keeper "$keeper")"
  permission="$(repo_permission_for_keeper "$keeper")"
  visibility="$(repo_visibility_for_keeper "$keeper")"
  if keeper_uses_fork_pr_route "$keeper"; then
    head_ref="$account:$branch"
    git_route_rule="- You may use keeper_bash for gh repo fork / git remote setup only to prepare your own fork branch for this proof. Do not run gh pr create, gh pr review, or other PR mutations through keeper_shell or keeper_bash."
    push_step="$(cat <<EOF
4. Commit and push exactly branch $branch with keeper_bash using the fork PR route because your upstream repo permission is $permission:
   - Confirm your GitHub account login is $account.
   - Ensure the fork $account/${REPO_SLUG#*/} exists. If needed, run gh repo fork $REPO_SLUG --remote=false from keeper_bash; if GitHub blocks fork creation, stop and report blocker="fork_create_blocked" with the exact output.
   - Add or update a remote named keeper-fork pointing at https://github.com/$account/${REPO_SLUG#*/}.git in the returned proof worktree.
   - Push with git push keeper-fork HEAD:$branch.
   - The tool result must show explicit Docker-backed route evidence such as via=docker, route_via=docker, via=brokered, or route_via=brokered.
EOF
)"
    pr_step="$(cat <<EOF
5. Create a draft PR from your fork branch with keeper_pr_create. The call must include
   repo="$REPO_SLUG", head="$head_ref", base="main", draft=true, and cwd set to
   the returned proof worktree path. Do not leave head/base empty and do not use
   the base repo path if the proof branch lives in a separate worktree. Do not
   mark ready, do not merge, do not add human-approved-ready.
EOF
)"
  else
    head_ref="$branch"
    git_route_rule="- Do not run gh pr create, gh pr review, or other mutating GitHub commands through keeper_shell or keeper_bash."
    push_step="$(cat <<EOF
4. Commit and git push exactly branch $branch with keeper_bash. The tool result must show explicit Docker-backed route evidence such as via=docker, route_via=docker, via=brokered, or route_via=brokered.
EOF
)"
    pr_step="$(cat <<EOF
5. Create a draft PR for that branch with keeper_pr_create. The call must include
   repo="$REPO_SLUG", head="$head_ref", base="main", draft=true, and cwd set to
   the returned proof worktree path. Do not leave head/base empty and do not use
   the base repo path if the proof branch lives in a separate worktree. Do not
   mark ready, do not merge, do not add human-approved-ready.
EOF
)"
  fi
  cat <<EOF
Docker PR lifecycle proof run: $RUN_ID
Phase: create

Target repo: $REPO_SLUG
Keeper: $keeper
GitHub account: ${account:-unknown}
Repo permission: ${permission:-unknown}
Repo visibility: ${visibility:-unknown}

Goal: create a fresh, auditable Docker-backed proof branch and draft PR. Do
not review or approve another keeper's PR in this phase.

Tool route rules:
- Use keeper_bash inside your Docker playground for proof-file creation and git add/commit/push on the proof branch.
$git_route_rule
- Do not use approval-requiring host code-write paths such as masc_code_write for this proof file.
- If keeper_bash rejects mutating git as policy-blocked, stop and report the exact blocker instead of switching to host-local credentials.
- Use keeper_pr_create for PR creation.

Required create lane:
1. Confirm your runtime is sandbox_profile=docker before mutating.
2. Create a unique proof worktree/branch for exactly this run id:
   - branch: $branch
   - preferred tool: masc_worktree_create with task_id=$RUN_ID
   - use the returned worktree path for every later keeper_bash git/file command.
   - the returned branch must be $branch. If it is different, stop and report blocker="branch_mismatch".
   - Do not reuse any branch, worktree, or proof file from another run id.
   - Do not remove this run's worktree during the proof attempt. If Git says
     the branch/worktree already exists, stop and report blocker="branch_collision".
3. Make a minimal, non-product proof edit under docs/runtime-proof/keepers/$keeper-$RUN_ID.md with keeper_bash from inside the Docker playground. The file content must include run_id=$RUN_ID and branch=$branch.
$push_step
$pr_step
6. Reply with one compact JSON object:
   {
     "run_id": "$RUN_ID",
     "phase": "create",
     "keeper": "$keeper",
     "branch": "$branch",
     "head": "$head_ref",
     "pr_url": "...",
     "docker_pr_create": true,
     "docker_git_push": true,
     "blocker": null
   }

Safety rules:
- No protected branches.
- No force push.
- No ready/merge.
- No human-approved-ready label.
- If a tool is missing or policy-blocked, stop and reply with blocker plus exact structured tool output.

This prompt is sent with create-phase masc_keeper_msg.required_tools so the
runtime records tool_surface_mismatch or missing_required_tool_use when
keeper_bash/keeper_pr_create are not visible or not used.
EOF
}

prompt_for_keeper_review() {
  local keeper="$1"
  local review_target="${2:-}"
  local review_branch=""
  local review_target_json="null"
  local review_branch_json="null"
  local review_instruction=""
  if [[ -n "$review_target" ]]; then
    review_branch="$(proof_branch_for_keeper "$review_target")"
    review_target_json="\"$review_target\""
    review_branch_json="\"$review_branch\""
    review_instruction="$(cat <<EOF
Cross-keeper approval target:
- You must review and APPROVE the draft PR whose head branch is: $review_branch
- This target belongs to keeper: $review_target
- Do not approve your own PR or your own branch.
- First use keeper_shell once to resolve the target PR number:
  gh pr view $review_branch -R $REPO_SLUG --json number,url,isDraft,headRefName
- If that command reports no PR or cannot resolve the branch, do not wait in a loop. Reply with blocker="target_pr_missing" and the exact tool output.
- If GitHub reports the target PR has the same author identity as your current credential and rejects approval as self-approval, stop and report blocker="github_self_approve_policy" with the exact tool output.
- Once the PR number is known, call keeper_pr_review_comment with event="APPROVE" and a body that includes run_id=$RUN_ID, reviewer=$keeper, and target_branch=$review_branch.
EOF
)"
  else
    review_instruction="$(cat <<'EOF'
Cross-keeper approval target:
- No distinct review target was available. This phase cannot satisfy PR APPROVE evidence.
- Stop immediately and report blocker="insufficient_review_targets".
EOF
)"
  fi
  cat <<EOF
Docker PR lifecycle proof run: $RUN_ID
Phase: review

Target repo: $REPO_SLUG
Keeper: $keeper

Goal: produce direct, auditable Docker-backed PR review and APPROVE evidence
for another keeper's draft proof PR. Do not create a new branch or PR in this
phase.

Tool route rules:
- Use keeper_shell for read-only GitHub inspection.
- Do not run mutating gh review commands through keeper_shell or keeper_bash.
- Use keeper_pr_review_comment for the APPROVE mutation.

$review_instruction

Reply with one compact JSON object:
   {
     "run_id": "$RUN_ID",
     "phase": "review",
     "keeper": "$keeper",
     "review_target_keeper": $review_target_json,
     "review_target_branch": $review_branch_json,
     "approved_pr_url": "...",
     "docker_pr_approve": true,
     "blocker": null
   }

Safety rules:
- No ready/merge.
- No human-approved-ready label.
- If a tool is missing or policy-blocked, stop and reply with blocker plus exact structured tool output.

This prompt is sent with review-phase masc_keeper_msg.required_tools so the
runtime records tool_surface_mismatch or missing_required_tool_use when
keeper_pr_review_comment is not visible or not used. keeper_shell is read-only
inspection and intentionally not part of the required-tool contract.
EOF
}

render_prompts() {
  while IFS= read -r keeper; do
    [[ -n "$keeper" ]] || continue
    prompt_for_keeper_create "$keeper" >"$PROMPT_DIR/$keeper-create.txt"
    prompt_for_keeper_review "$keeper" "$(review_target_for_keeper "$keeper")" >"$PROMPT_DIR/$keeper-review.txt"
  done <"$RUN_DIR/keepers.txt"
}

send_phase_prompts() {
  local phase="$1"
  local required_tools_csv="$2"
  while IFS= read -r keeper; do
    [[ -n "$keeper" ]] || continue
    local prompt args payload text request_id
    prompt="$(cat "$PROMPT_DIR/$keeper-$phase.txt")"
    args="$(
      jq -cn \
        --arg name "$keeper" \
        --arg message "$prompt" \
        --arg required_tools_csv "$required_tools_csv" \
        --argjson timeout "$KEEPER_TURN_TIMEOUT_SEC" \
        '{
          name:$name,
          message:$message,
          timeout_sec:$timeout,
          required_tools: (
            $required_tools_csv
            | split(",")
            | map(gsub("^[[:space:]]+|[[:space:]]+$"; ""))
            | map(select(length > 0))
          )
        }'
    )"
    log "sending $phase proof prompt to $keeper"
    payload="$(tool_call "keeper-msg-$phase-$keeper-$RUN_ID" "masc_keeper_msg" "$args" "$MSG_TIMEOUT_SEC")"
    printf '%s' "$payload" >"$RAW_DIR/msg-$phase-$keeper.jsonrpc.json"
    mcp_require_tool_ok "$payload" "masc_keeper_msg:$keeper"
    text="$(tool_text_or_empty "$payload")"
    printf '%s' "$text" >"$RAW_DIR/msg-$phase-$keeper.text"
    request_id="$(printf '%s' "$text" | jq -r '.request_id // .id // empty' 2>/dev/null || true)"
    if [[ -z "$request_id" ]]; then
      echo "masc_keeper_msg did not return request_id for $keeper" >&2
      printf '%s\n' "$text" >&2
      exit 1
    fi
    jq -nc \
      --arg keeper "$keeper" \
      --arg phase "$phase" \
      --arg request_id "$request_id" \
      --arg prompt_file "$PROMPT_DIR/$keeper-$phase.txt" \
      --arg review_target "$(review_target_for_keeper "$keeper")" \
      '{keeper:$keeper, phase:$phase, request_id:$request_id, prompt_file:$prompt_file, review_target:$review_target, status:"pending"}' \
      >>"$REQUESTS_FILE"
  done <"$RUN_DIR/keepers.txt"
}

result_is_terminal() {
  local text="$1"
  printf '%s' "$text" | jq -e '
    (.reply? | type == "string" and length > 0)
    or ((.status? // "" | ascii_downcase) as $s
        | ($s == "done" or $s == "complete" or $s == "completed"
           or $s == "failed" or $s == "error" or $s == "cancelled"))
  ' >/dev/null 2>&1
}

poll_results() {
  local phase="$1"
  # Honor MUTATE_POLL_DEADLINE_TS when the caller has already opened the
  # phase loop with a shared overall budget (split keeper lifecycle PR
  # #13842). Falling back to the per-call POLL_TIMEOUT_SEC keeps
  # backwards compatibility for direct invocations of this function.
  local deadline
  if [[ -n "${MUTATE_POLL_DEADLINE_TS:-}" ]]; then
    deadline="$MUTATE_POLL_DEADLINE_TS"
  else
    deadline=$(( $(date +%s) + POLL_TIMEOUT_SEC ))
  fi
  local pending_file="$RUN_DIR/pending-$phase.txt"
  jq -r --arg phase "$phase" \
    'select(.phase == $phase) | .request_id + "\t" + .keeper' \
    "$REQUESTS_FILE" >"$pending_file"

  while [[ -s "$pending_file" && "$(date +%s)" -lt "$deadline" ]]; do
    if ! assert_server_incarnation_unchanged; then
      # Only terminate early on a confirmed restart. Transient failures
      # (server_health_unavailable, server_health_missing_commit) can fix
      # themselves on the next /health poll without the server having
      # restarted, so prematurely clearing pending requests here would
      # discard live in-flight keeper results.
      if [[ "$SERVER_INCARNATION_LAST_REASON" == "server_incarnation_changed" ]]; then
        log "server incarnation changed while polling keeper results: expected=$SERVER_INCARNATION_ACTUAL actual=${SERVER_INCARNATION_LAST_ACTUAL:-unknown}"
        record_pending_server_incarnation_loss "$pending_file" \
          "$SERVER_INCARNATION_LAST_REASON" \
          "$SERVER_INCARNATION_LAST_FILE" \
          "$phase"
        : >"$pending_file"
        break
      fi
      log "server health transient ($SERVER_INCARNATION_LAST_REASON); keep polling pending=$(wc -l <"$pending_file" | tr -d ' ')"
      sleep 1
      continue
    fi
    local next_pending="$RUN_DIR/pending.next"
    : >"$next_pending"
    while IFS=$'\t' read -r request_id keeper; do
      [[ -n "$request_id" ]] || continue
      local args payload text status
      args="$(jq -cn --arg request_id "$request_id" '{request_id:$request_id}')"
      payload="$(tool_call "keeper-msg-result-$request_id" "masc_keeper_msg_result" "$args" 30)"
      printf '%s' "$payload" >"$RAW_DIR/result-$phase-$keeper-$request_id.jsonrpc.json"
      if ! mcp_require_tool_ok "$payload" "masc_keeper_msg_result:$keeper" >/dev/null 2>&1; then
        jq -nc --arg keeper "$keeper" --arg phase "$phase" --arg request_id "$request_id" \
          --arg status "poll_error" \
          --arg raw_file "$RAW_DIR/result-$phase-$keeper-$request_id.jsonrpc.json" \
          '{keeper:$keeper, phase:$phase, request_id:$request_id, status:$status, raw_file:$raw_file}' \
          >>"$POLL_ERRORS_FILE"
        printf '%s\t%s\n' "$request_id" "$keeper" >>"$next_pending"
        continue
      fi
      text="$(tool_text_or_empty "$payload")"
      printf '%s' "$text" >"$RAW_DIR/result-$phase-$keeper-$request_id.text"
      if result_is_terminal "$text"; then
        status="$(printf '%s' "$text" | jq -r '.status // (if .reply then "completed" else "unknown" end)' 2>/dev/null || echo completed)"
        jq -nc --arg keeper "$keeper" --arg phase "$phase" --arg request_id "$request_id" --arg status "$status" \
          --arg text_file "$RAW_DIR/result-$phase-$keeper-$request_id.text" \
          '{keeper:$keeper, phase:$phase, request_id:$request_id, status:$status, text_file:$text_file}' \
          >>"$RESULTS_FILE"
      else
        printf '%s\t%s\n' "$request_id" "$keeper" >>"$next_pending"
      fi
    done <"$pending_file"
    mv "$next_pending" "$pending_file"
    [[ -s "$pending_file" ]] || break
    sleep "$POLL_INTERVAL_SEC"
  done

  if [[ -s "$pending_file" ]]; then
    while IFS=$'\t' read -r request_id keeper; do
      jq -nc --arg keeper "$keeper" --arg phase "$phase" --arg request_id "$request_id" \
        '{keeper:$keeper, phase:$phase, request_id:$request_id, status:"poll_timeout"}' \
        >>"$RESULTS_FILE"
    done <"$pending_file"
  fi
}

ere_escape() {
  # Escape ERE metacharacters in a literal value before splicing it
  # into a [grep -Eq] pattern. Without this, an operator-supplied
  # --run-id like "post-act.live" or a branch name carrying a literal
  # "+" would produce false matches/false failures.
  printf '%s' "$1" | sed -e 's/[][\\^$.|?*+(){}]/\\&/g'
}

create_result_has_success_markers() {
  local keeper="$1"
  local text_file="$2"
  local branch reply run_id_re branch_re
  branch="$(proof_branch_for_keeper "$keeper")"
  run_id_re="$(ere_escape "$RUN_ID")"
  branch_re="$(ere_escape "$branch")"
  reply="$(jq -r '.result.reply // .reply // empty' "$text_file" 2>/dev/null || true)"

  printf '%s' "$reply" | grep -Eq '"run_id"[[:space:]]*:[[:space:]]*"'"$run_id_re"'"' \
    && printf '%s' "$reply" | grep -Eq '"branch"[[:space:]]*:[[:space:]]*"'"$branch_re"'"' \
    && printf '%s' "$reply" | grep -Eq '"docker_pr_create"[[:space:]]*:[[:space:]]*true' \
    && printf '%s' "$reply" | grep -Eq '"docker_git_push"[[:space:]]*:[[:space:]]*true' \
    && printf '%s' "$reply" | grep -Eq '"blocker"[[:space:]]*:[[:space:]]*null' \
    && printf '%s' "$reply" | grep -Eq 'https://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/pull/[0-9]+'
}

all_create_results_ready_for_review() {
  : >"$CREATE_READINESS_FAILURES_FILE"

  local keeper status text_file
  while IFS= read -r keeper; do
    [[ -n "$keeper" ]] || continue
    status="$(
      jq -r --arg keeper "$keeper" '
        select(.phase == "create" and .keeper == $keeper)
        | .status // empty
      ' "$RESULTS_FILE" | tail -n 1
    )"
    text_file="$(
      jq -r --arg keeper "$keeper" '
        select(.phase == "create" and .keeper == $keeper)
        | .text_file // empty
      ' "$RESULTS_FILE" | tail -n 1
    )"

    if [[ -z "$status" || -z "$text_file" ]]; then
      jq -nc --arg keeper "$keeper" \
        '{keeper:$keeper, blocker:"create_result_missing"}' \
        >>"$CREATE_READINESS_FAILURES_FILE"
      continue
    fi
    if [[ "$status" != "done" && "$status" != "completed" && "$status" != "complete" ]]; then
      jq -nc --arg keeper "$keeper" --arg status "$status" \
        '{keeper:$keeper, status:$status, blocker:"create_status_not_success"}' \
        >>"$CREATE_READINESS_FAILURES_FILE"
      continue
    fi
    if ! create_result_has_success_markers "$keeper" "$text_file"; then
      jq -nc --arg keeper "$keeper" --arg status "$status" --arg text_file "$text_file" \
        '{keeper:$keeper, status:$status, text_file:$text_file, blocker:"create_success_markers_missing"}' \
        >>"$CREATE_READINESS_FAILURES_FILE"
    fi
  done <"$RUN_DIR/keepers.txt"

  [[ ! -s "$CREATE_READINESS_FAILURES_FILE" ]]
}

run_audit() {
  if [[ "$RUN_AUDIT" != "1" ]]; then
    AUDIT_STATUS_RESULT=0
    return 0
  fi
  log "running Docker PR lifecycle audit"
  local audit_args=(
    "$REPO_ROOT/scripts/audit-keeper-fleet-readiness.py"
    --base-path "$BASE_PATH"
    --expected-keepers "$EXPECTED_KEEPERS"
    --require-docker-pr-lifecycle-evidence
    --evidence-run-id "$RUN_ID"
    --json
  )
  if [[ -n "$FORBID_GITHUB_IDENTITIES" ]]; then
    IFS=',' read -r -a forbidden_items <<<"$FORBID_GITHUB_IDENTITIES"
    local forbidden_item
    for forbidden_item in "${forbidden_items[@]}"; do
      forbidden_item="${forbidden_item#"${forbidden_item%%[![:space:]]*}"}"
      forbidden_item="${forbidden_item%"${forbidden_item##*[![:space:]]}"}"
      if [[ -n "$forbidden_item" ]]; then
        audit_args+=(--forbid-github-identity "$forbidden_item")
      fi
    done
  fi
  set +e
  python3 "${audit_args[@]}" >"$AUDIT_FILE"
  local audit_status=$?
  set -e
  AUDIT_STATUS_RESULT="$audit_status"
  return 0
}

write_summary() {
  local audit_status="$1"
  local keeper_count request_count result_count timeout_count poll_error_count
  keeper_count="$(awk 'NF { c++ } END { print c + 0 }' "$RUN_DIR/keepers.txt")"
  request_count="$(awk 'NF { c++ } END { print c + 0 }' "$REQUESTS_FILE")"
  result_count="$(awk 'NF { c++ } END { print c + 0 }' "$RESULTS_FILE")"
  timeout_count="$(jq -s '[.[] | select(.status == "poll_timeout")] | length' "$RESULTS_FILE" 2>/dev/null || echo 0)"
  poll_error_count="$(awk 'NF { c++ } END { print c + 0 }' "$POLL_ERRORS_FILE")"
  jq -n \
    --arg run_id "$RUN_ID" \
    --arg run_dir "$RUN_DIR" \
    --arg repo "$REPO_SLUG" \
    --arg base_path "$BASE_PATH" \
    --arg lifecycle_mutation_mode "$LIFECYCLE_MUTATION_MODE" \
    --arg create_required_tools "$CREATE_REQUIRED_TOOLS" \
    --arg review_required_tools "$REVIEW_REQUIRED_TOOLS" \
    --arg expected_server_commit "$EXPECTED_SERVER_COMMIT" \
    --arg forbid_github_identities "$FORBID_GITHUB_IDENTITIES" \
    --arg allow_fork_pr_for_readonly "$ALLOW_FORK_PR_FOR_READONLY" \
    --arg server_commit "$SERVER_COMMIT_ACTUAL" \
    --arg server_started_at "$SERVER_STARTED_AT_ACTUAL" \
    --arg server_incarnation "$SERVER_INCARNATION_ACTUAL" \
    --arg server_health_file "$SERVER_HEALTH_CHECK_FILE" \
    --arg review_targets_file "$REVIEW_TARGETS_FILE" \
    --arg github_identity_counts_file "$GITHUB_IDENTITY_COUNTS_FILE" \
    --arg proof_branch_collisions_file "$PROOF_BRANCH_COLLISIONS_FILE" \
    --arg create_readiness_failures_file "$CREATE_READINESS_FAILURES_FILE" \
    --argjson mutate "$MUTATE" \
    --argjson keeper_count "$keeper_count" \
    --argjson request_count "$request_count" \
    --argjson result_count "$result_count" \
    --argjson timeout_count "$timeout_count" \
    --argjson poll_error_count "$poll_error_count" \
    --argjson audit_status "$audit_status" \
    --arg audit_file "$AUDIT_FILE" \
    '{
      run_id:$run_id,
      run_dir:$run_dir,
      repo:$repo,
      base_path:$base_path,
      lifecycle_mutation_mode:$lifecycle_mutation_mode,
      create_required_tools:$create_required_tools,
      review_required_tools:$review_required_tools,
      expected_server_commit:$expected_server_commit,
      forbid_github_identities:$forbid_github_identities,
      allow_fork_pr_for_readonly:$allow_fork_pr_for_readonly,
      server_commit:$server_commit,
      server_started_at:$server_started_at,
      server_incarnation:$server_incarnation,
      server_health_file:$server_health_file,
      review_targets_file:$review_targets_file,
      github_identity_counts_file:$github_identity_counts_file,
      proof_branch_collisions_file:$proof_branch_collisions_file,
      create_readiness_failures_file:$create_readiness_failures_file,
      mutate:$mutate,
      keeper_count:$keeper_count,
      request_count:$request_count,
      result_count:$result_count,
      timeout_count:$timeout_count,
      poll_error_count:$poll_error_count,
      audit_status:$audit_status,
      audit_file:$audit_file
    }' >"$SUMMARY_FILE"
}

post_board_summary() {
  [[ -n "$BOARD_POST_ID" ]] || return 0
  local content args payload
  content="$(
    jq -r '
      "Docker PR lifecycle reprobe " + .run_id
      + "\n- mutate: " + (.mutate | tostring)
      + "\n- keepers: " + (.keeper_count | tostring)
      + "\n- requests: " + (.request_count | tostring)
      + "\n- results: " + (.result_count | tostring)
      + "\n- timeouts: " + (.timeout_count | tostring)
      + "\n- poll_errors: " + (.poll_error_count | tostring)
      + "\n- audit_status: " + (.audit_status | tostring)
      + "\n- artifacts: " + .run_dir
    ' "$SUMMARY_FILE"
  )"
  args="$(jq -cn --arg post_id "$BOARD_POST_ID" --arg content "$content" \
    '{post_id:$post_id, author:"keeper-docker-pr-lifecycle-reprobe", content:$content, ttl_hours:168}')"
  payload="$(tool_call "board-comment-$RUN_ID" "masc_board_comment" "$args" 30)"
  printf '%s' "$payload" >"$RAW_DIR/board-comment.jsonrpc.json"
}

require_cmd jq
require_cmd python3
require_cmd curl
# git is used by assert_no_proof_branch_collisions_for_mutate
# (ls-remote/show-ref/worktree). Surface it up-front so a missing
# git binary fails immediately at startup with a consistent
# "required command not found" message rather than partway through
# the run with a less obvious git-not-found error.
require_cmd git

if [[ "$MUTATE" == "1" || -n "$EXPECTED_SERVER_COMMIT" ]]; then
  assert_expected_server_commit
fi
ensure_mcp_session_if_needed
discover_keepers
assert_github_identity_pool_for_mutate
build_review_targets
render_prompts
assert_no_proof_branch_collisions_for_mutate

if [[ "$MUTATE" == "1" ]]; then
  # Share one POLL_TIMEOUT_SEC budget across both phases so the overall
  # mutate window remains the single configured value rather than
  # silently doubling when create + review each compute their own
  # deadline (PR #13842 review).
  export MUTATE_POLL_DEADLINE_TS=$(( $(date +%s) + POLL_TIMEOUT_SEC ))
  send_phase_prompts "create" "$CREATE_REQUIRED_TOOLS"
  poll_results "create"
  if all_create_results_ready_for_review; then
    send_phase_prompts "review" "$REVIEW_REQUIRED_TOOLS"
    poll_results "review"
  else
    log "skipping review phase because create phase did not produce complete success evidence"
  fi
  unset MUTATE_POLL_DEADLINE_TS
else
  log "dry-run mode: prompts rendered under $PROMPT_DIR; no keeper messages sent"
fi

audit_status=0
if [[ "$RUN_AUDIT" == "1" ]]; then
  run_audit
  audit_status="$AUDIT_STATUS_RESULT"
fi
write_summary "$audit_status"
post_board_summary || true

log "summary: $SUMMARY_FILE"
if [[ "$audit_status" -ne 0 && "$EXIT_ON_AUDIT_FAIL" == "1" ]]; then
  exit "$audit_status"
fi
