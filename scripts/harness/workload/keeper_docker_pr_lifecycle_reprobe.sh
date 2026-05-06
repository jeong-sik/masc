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
REQUIRED_TOOLS="${REQUIRED_TOOLS:-keeper_shell,keeper_bash,masc_code_git,keeper_pr_create,keeper_pr_review_comment}"
MCP_URL="${MCP_URL:-http://127.0.0.1:8935/mcp}"
MCP_TOKEN="${MASC_MCP_TOKEN:-}"
MCP_CLIENT_NAME="${MCP_CLIENT_NAME:-keeper-docker-pr-lifecycle-reprobe}"
EXPECTED_SERVER_COMMIT="${EXPECTED_SERVER_COMMIT:-}"
SERVER_HEALTH_URL="${SERVER_HEALTH_URL:-}"
SERVER_COMMIT_ACTUAL=""
SERVER_HEALTH_CHECK_FILE=""

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
  REQUIRED_TOOLS           CSV required_tools sent to masc_keeper_msg when mutating.
  RUN_AUDIT=0              Skip final audit.
  EXPECTED_SERVER_COMMIT   Optional expected /health build.commit prefix.
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
  if [[ -z "$EXPECTED_SERVER_COMMIT" ]]; then
    return 0
  fi

  local health_url health_file actual
  health_url="$(server_health_url)"
  health_file="$RAW_DIR/server-health.json"
  if ! curl -fsS --max-time 5 "$health_url" >"$health_file"; then
    echo "failed to fetch server health for commit check: $health_url" >&2
    exit 1
  fi

  actual="$(jq -r '.build.commit // .build_commit // .commit // empty' "$health_file")"
  SERVER_COMMIT_ACTUAL="$actual"
  SERVER_HEALTH_CHECK_FILE="$health_file"
  if [[ -z "$actual" ]]; then
    echo "server health did not expose build.commit: $health_url" >&2
    exit 1
  fi
  if [[ "$actual" != "$EXPECTED_SERVER_COMMIT" \
      && "$actual" != "$EXPECTED_SERVER_COMMIT"* \
      && "$EXPECTED_SERVER_COMMIT" != "$actual"* ]]; then
    echo "server commit mismatch: expected=$EXPECTED_SERVER_COMMIT actual=$actual url=$health_url" >&2
    exit 1
  fi
  log "server commit verified: expected=$EXPECTED_SERVER_COMMIT actual=$actual"
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
  local keeper_count
  keeper_count="$(awk 'NF { c++ } END { print c + 0 }' "$RUN_DIR/keepers.txt")"
  : >"$REVIEW_TARGETS_FILE"
  if [[ "$keeper_count" -lt 2 ]]; then
    while IFS= read -r keeper; do
      [[ -n "$keeper" ]] || continue
      jq -nc \
        --arg keeper "$keeper" \
        '{keeper:$keeper, review_target:null, mode:"insufficient_targets"}' \
        >>"$REVIEW_TARGETS_FILE"
    done <"$RUN_DIR/keepers.txt"
    if [[ "$MUTATE" == "1" ]]; then
      echo "at least two target keepers are required for cross-keeper approval proof" >&2
      exit 1
    fi
    return 0
  fi

  awk 'NF { keepers[++n] = $0 }
       END {
         for (i = 1; i <= n; i++) {
           target = keepers[(i % n) + 1]
           printf "%s\t%s\n", keepers[i], target
         }
       }' "$RUN_DIR/keepers.txt" |
    while IFS=$'\t' read -r keeper review_target; do
      [[ -n "$keeper" ]] || continue
      jq -nc \
        --arg keeper "$keeper" \
        --arg review_target "$review_target" \
        '{keeper:$keeper, review_target:$review_target, mode:"ring"}' \
        >>"$REVIEW_TARGETS_FILE"
    done
  log "review target ring: $REVIEW_TARGETS_FILE"
}

build_github_identity_counts() {
  python3 - "$BASE_PATH" "$RUN_DIR/keepers.txt" "$GITHUB_IDENTITY_COUNTS_FILE" <<'PY'
import json
import pathlib
import sys
from collections import Counter

try:
    import tomllib
except ModuleNotFoundError:
    import tomli as tomllib  # type: ignore


base_path = pathlib.Path(sys.argv[1]).expanduser().resolve()
keepers_file = pathlib.Path(sys.argv[2])
out_file = pathlib.Path(sys.argv[3])
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


keepers = [line.strip() for line in keepers_file.read_text().splitlines() if line.strip()]
identities = {}
missing = []
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
    else:
        missing.append(keeper)

counts = Counter(identities.values())
out_file.write_text(
    json.dumps(
        {
            "base_path": str(base_path),
            "keeper_count": len(keepers),
            "unique_count": len(counts),
            "counts": dict(sorted(counts.items())),
            "keepers": identities,
            "missing": missing,
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
  if [[ "$MUTATE" == "1" && "$unique_count" -lt 2 ]]; then
    echo "at least two unique github_identity values are required for cross-keeper approval proof" >&2
    jq -c '{unique_count, counts, missing}' "$GITHUB_IDENTITY_COUNTS_FILE" >&2 || true
    exit 1
  fi
}

review_target_for_keeper() {
  local keeper="$1"
  jq -r --arg keeper "$keeper" '
    select(.keeper == $keeper) | .review_target // empty
  ' "$REVIEW_TARGETS_FILE" | head -n 1
}

prompt_for_keeper() {
  local keeper="$1"
  local review_target="${2:-}"
  local review_branch=""
  local review_target_json="null"
  local review_branch_json="null"
  local review_instruction=""
  if [[ -n "$review_target" ]]; then
    review_branch="keeper/$review_target-docker-pr-proof-$RUN_ID"
    review_target_json="\"$review_target\""
    review_branch_json="\"$review_branch\""
    review_instruction="$(cat <<EOF
Cross-keeper approval target:
- You must review and APPROVE the draft PR whose head branch is: $review_branch
- This target belongs to keeper: $review_target
- Do not approve your own PR or your own branch.
- If the target PR is not visible yet, wait/retry briefly by listing PRs for that head branch before declaring a blocker.
- If GitHub reports the target PR has the same author identity as your current credential and rejects approval as self-approval, stop and report blocker="github_self_approve_policy" with the exact tool output.
EOF
)"
  else
    review_instruction="$(cat <<'EOF'
Cross-keeper approval target:
- No distinct review target was available. You can create/push/comment on your own draft PR, but this run cannot satisfy PR APPROVE evidence.
- Stop before approval and report blocker="insufficient_review_targets".
EOF
)"
  fi
  cat <<EOF
Docker PR lifecycle proof run: $RUN_ID

Target repo: $REPO_SLUG
Keeper: $keeper

Goal: produce direct, auditable Docker-backed evidence for PR create, git push, PR review/comment, and PR APPROVE. Use native keeper tools where available; do not use host-local ambient GitHub credentials.

Required proof lane:
1. Confirm your runtime is sandbox_profile=docker before mutating.
2. Create a unique proof branch named: keeper/$keeper-docker-pr-proof-$RUN_ID
3. Make a minimal, non-product proof edit under docs/runtime-proof/keepers/$keeper-$RUN_ID.md.
4. Commit and git push that branch. The tool result must show explicit Docker-backed route evidence such as via=docker, route_via=docker, via=brokered, or route_via=brokered.
5. Create a draft PR for that branch with keeper_pr_create or the native PR-create tool path. Do not mark ready, do not merge, do not add human-approved-ready.
6. Use keeper_pr_review_read and keeper_pr_review_comment for review evidence. COMMENT is allowed on your own proof PR. APPROVE must target the cross-keeper PR below, not your own PR.

$review_instruction

7. Reply with one compact JSON object:
   {
     "run_id": "$RUN_ID",
     "keeper": "$keeper",
     "branch": "keeper/$keeper-docker-pr-proof-$RUN_ID",
     "review_target_keeper": $review_target_json,
     "review_target_branch": $review_branch_json,
     "pr_url": "...",
     "approved_pr_url": "...",
     "docker_pr_create": true,
     "docker_git_push": true,
     "docker_pr_review": true,
     "docker_pr_approve": true,
     "blocker": null
   }

Safety rules:
- No protected branches.
- No force push.
- No ready/merge.
- No human-approved-ready label.
- If a tool is missing or policy-blocked, stop and reply with blocker plus exact structured tool output.

This prompt is sent with masc_keeper_msg.required_tools so the runtime records
tool_surface_mismatch or missing_required_tool_use when the Docker PR lifecycle
tools are not visible or not used.
EOF
}

render_prompts() {
  while IFS= read -r keeper; do
    [[ -n "$keeper" ]] || continue
    prompt_for_keeper "$keeper" "$(review_target_for_keeper "$keeper")" >"$PROMPT_DIR/$keeper.txt"
  done <"$RUN_DIR/keepers.txt"
}

send_prompts() {
  while IFS= read -r keeper; do
    [[ -n "$keeper" ]] || continue
    local prompt args payload text request_id
    prompt="$(cat "$PROMPT_DIR/$keeper.txt")"
    args="$(
      jq -cn \
        --arg name "$keeper" \
        --arg message "$prompt" \
        --arg required_tools_csv "$REQUIRED_TOOLS" \
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
    log "sending proof prompt to $keeper"
    payload="$(tool_call "keeper-msg-$keeper-$RUN_ID" "masc_keeper_msg" "$args" "$MSG_TIMEOUT_SEC")"
    printf '%s' "$payload" >"$RAW_DIR/msg-$keeper.jsonrpc.json"
    mcp_require_tool_ok "$payload" "masc_keeper_msg:$keeper"
    text="$(tool_text_or_empty "$payload")"
    printf '%s' "$text" >"$RAW_DIR/msg-$keeper.text"
    request_id="$(printf '%s' "$text" | jq -r '.request_id // .id // empty' 2>/dev/null || true)"
    if [[ -z "$request_id" ]]; then
      echo "masc_keeper_msg did not return request_id for $keeper" >&2
      printf '%s\n' "$text" >&2
      exit 1
    fi
    jq -nc \
      --arg keeper "$keeper" \
      --arg request_id "$request_id" \
      --arg prompt_file "$PROMPT_DIR/$keeper.txt" \
      --arg review_target "$(review_target_for_keeper "$keeper")" \
      '{keeper:$keeper, request_id:$request_id, prompt_file:$prompt_file, review_target:$review_target, status:"pending"}' \
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
  local deadline
  deadline=$(( $(date +%s) + POLL_TIMEOUT_SEC ))
  local pending_file="$RUN_DIR/pending.txt"
  jq -r '.request_id + "\t" + .keeper' "$REQUESTS_FILE" >"$pending_file"

  while [[ -s "$pending_file" && "$(date +%s)" -lt "$deadline" ]]; do
    local next_pending="$RUN_DIR/pending.next"
    : >"$next_pending"
    while IFS=$'\t' read -r request_id keeper; do
      [[ -n "$request_id" ]] || continue
      local args payload text status
      args="$(jq -cn --arg request_id "$request_id" '{request_id:$request_id}')"
      payload="$(tool_call "keeper-msg-result-$request_id" "masc_keeper_msg_result" "$args" 30)"
      printf '%s' "$payload" >"$RAW_DIR/result-$keeper-$request_id.jsonrpc.json"
      if ! mcp_require_tool_ok "$payload" "masc_keeper_msg_result:$keeper" >/dev/null 2>&1; then
        jq -nc --arg keeper "$keeper" --arg request_id "$request_id" \
          --arg status "poll_error" \
          --arg raw_file "$RAW_DIR/result-$keeper-$request_id.jsonrpc.json" \
          '{keeper:$keeper, request_id:$request_id, status:$status, raw_file:$raw_file}' \
          >>"$POLL_ERRORS_FILE"
        printf '%s\t%s\n' "$request_id" "$keeper" >>"$next_pending"
        continue
      fi
      text="$(tool_text_or_empty "$payload")"
      printf '%s' "$text" >"$RAW_DIR/result-$keeper-$request_id.text"
      if result_is_terminal "$text"; then
        status="$(printf '%s' "$text" | jq -r '.status // (if .reply then "completed" else "unknown" end)' 2>/dev/null || echo completed)"
        jq -nc --arg keeper "$keeper" --arg request_id "$request_id" --arg status "$status" \
          --arg text_file "$RAW_DIR/result-$keeper-$request_id.text" \
          '{keeper:$keeper, request_id:$request_id, status:$status, text_file:$text_file}' \
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
      jq -nc --arg keeper "$keeper" --arg request_id "$request_id" \
        '{keeper:$keeper, request_id:$request_id, status:"poll_timeout"}' \
        >>"$RESULTS_FILE"
    done <"$pending_file"
  fi
}

run_audit() {
  if [[ "$RUN_AUDIT" != "1" ]]; then
    AUDIT_STATUS_RESULT=0
    return 0
  fi
  log "running Docker PR lifecycle audit"
  set +e
  python3 "$REPO_ROOT/scripts/audit-keeper-fleet-readiness.py" \
    --base-path "$BASE_PATH" \
    --expected-keepers "$EXPECTED_KEEPERS" \
    --require-docker-pr-lifecycle-evidence \
    --json >"$AUDIT_FILE"
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
    --arg expected_server_commit "$EXPECTED_SERVER_COMMIT" \
    --arg server_commit "$SERVER_COMMIT_ACTUAL" \
    --arg server_health_file "$SERVER_HEALTH_CHECK_FILE" \
    --arg review_targets_file "$REVIEW_TARGETS_FILE" \
    --arg github_identity_counts_file "$GITHUB_IDENTITY_COUNTS_FILE" \
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
      expected_server_commit:$expected_server_commit,
      server_commit:$server_commit,
      server_health_file:$server_health_file,
      review_targets_file:$review_targets_file,
      github_identity_counts_file:$github_identity_counts_file,
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

assert_expected_server_commit
ensure_mcp_session_if_needed
discover_keepers
build_review_targets
assert_github_identity_pool_for_mutate
render_prompts

if [[ "$MUTATE" == "1" ]]; then
  send_prompts
  poll_results
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
