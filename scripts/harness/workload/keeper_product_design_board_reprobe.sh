#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

# shellcheck disable=SC1091
# shellcheck source=scripts/harness/lib/mcp_jsonrpc.sh
source "$REPO_ROOT/scripts/harness/lib/mcp_jsonrpc.sh"

RUN_ID="${RUN_ID:-keeper-product-design-board-$(date +%Y%m%d_%H%M%S)}"
RUN_DIR="${RUN_DIR:-$REPO_ROOT/logs/keeper_product_design_board/$RUN_ID}"
RUN_DIR_EXPLICIT=0
RAW_DIR="$RUN_DIR/raw"
PROMPT_DIR="$RUN_DIR/prompts"
REQUESTS_FILE="$RUN_DIR/requests.jsonl"
RESULTS_FILE="$RUN_DIR/results.jsonl"
POLL_ERRORS_FILE="$RUN_DIR/poll_errors.jsonl"
SUMMARY_FILE="$RUN_DIR/summary.json"
AUDIT_FILE="$RUN_DIR/audit-product-design.json"
AUDIT_STATUS_RESULT=0

BASE_PATH="${BASE_PATH:-${MASC_BASE_PATH:-$HOME/me}}"
EXPECTED_KEEPERS="${EXPECTED_KEEPERS:-14}"
KEEPER_NAMES="${KEEPER_NAMES:-}"
MAX_KEEPERS="${MAX_KEEPERS:-0}"
MUTATE="${MUTATE:-0}"
RUN_AUDIT="${RUN_AUDIT:-1}"
EXIT_ON_AUDIT_FAIL="${EXIT_ON_AUDIT_FAIL:-}"
MSG_TIMEOUT_SEC="${MSG_TIMEOUT_SEC:-120}"
KEEPER_TURN_TIMEOUT_SEC="${KEEPER_TURN_TIMEOUT_SEC:-600}"
INIT_TIMEOUT_SEC="${INIT_TIMEOUT_SEC:-60}"
POLL_TIMEOUT_SEC="${POLL_TIMEOUT_SEC:-900}"
POLL_INTERVAL_SEC="${POLL_INTERVAL_SEC:-10}"
REQUIRED_TOOLS="${REQUIRED_TOOLS:-keeper_board_post}"
MCP_URL="${MCP_URL:-http://127.0.0.1:8935/mcp}"
MCP_TOKEN="${MASC_MCP_TOKEN:-}"
MCP_CLIENT_NAME="${MCP_CLIENT_NAME:-keeper-product-design-board-reprobe}"
BOARD_POST_ID="${BOARD_POST_ID:-}"
FORBID_GITHUB_IDENTITIES="${FORBID_GITHUB_IDENTITIES:-}"

usage() {
  cat <<'EOF'
Usage: scripts/harness_keeper_product_design_board_reprobe.sh [options]

Render or send keeper prompts that require explicit product/design board
evidence, then audit the fleet with --require-product-evidence and
--require-design-evidence.

Options:
  --mutate                 Send prompts to keepers via masc_keeper_msg.
  --dry-run                Do not send prompts (default).
  --keeper-names CSV       Target explicit keeper names instead of config discovery.
  --max-keepers N          Limit targets after discovery/CSV expansion.
  --expected-keepers N     Minimum configured keeper count for audit.
  --base-path PATH         MASC base path for audit and config discovery.
  --mcp-url URL            MCP endpoint (default: http://127.0.0.1:8935/mcp).
  --board-post-id ID       Post a final board comment to this thread.
  --run-id ID              Stable run id for prompts and artifacts.
  --run-dir PATH           Artifact directory.
  --forbid-github-identity NAME
                           Pass a forbidden identity to the final audit.
  -h, --help               Show this help.

Environment:
  MASC_MCP_TOKEN           Optional bearer token for MCP calls.
  POLL_TIMEOUT_SEC         Overall result polling window when --mutate is used.
  POLL_INTERVAL_SEC        Poll interval in seconds.
  MSG_TIMEOUT_SEC          HTTP request timeout for MCP tool calls.
  KEEPER_TURN_TIMEOUT_SEC  Per-keeper Agent.run timeout_sec sent to masc_keeper_msg.
  REQUIRED_TOOLS           CSV required_tools sent to masc_keeper_msg.
  RUN_AUDIT=0              Skip final audit.
  FORBID_GITHUB_IDENTITIES Optional CSV of forbidden keeper GitHub identities.
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
    --base-path)
      BASE_PATH="$2"
      shift 2
      ;;
    --mcp-url)
      MCP_URL="$2"
      shift 2
      ;;
    --board-post-id)
      BOARD_POST_ID="$2"
      shift 2
      ;;
    --run-id)
      RUN_ID="$2"
      if [[ "$RUN_DIR_EXPLICIT" != "1" ]]; then
        RUN_DIR="$REPO_ROOT/logs/keeper_product_design_board/$RUN_ID"
        RAW_DIR="$RUN_DIR/raw"
        PROMPT_DIR="$RUN_DIR/prompts"
        REQUESTS_FILE="$RUN_DIR/requests.jsonl"
        RESULTS_FILE="$RUN_DIR/results.jsonl"
        POLL_ERRORS_FILE="$RUN_DIR/poll_errors.jsonl"
        SUMMARY_FILE="$RUN_DIR/summary.json"
        AUDIT_FILE="$RUN_DIR/audit-product-design.json"
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
      SUMMARY_FILE="$RUN_DIR/summary.json"
      AUDIT_FILE="$RUN_DIR/audit-product-design.json"
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

log() {
  printf '[%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >&2
}

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "required command not found: $1" >&2
    exit 127
  fi
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
  headers_file="$(mcp_mktemp_file "keeper-product-design-init" ".headers")"
  body_file="$(mcp_mktemp_file "keeper-product-design-init" ".body")"
  init_body="$(
    jq -cn --arg client_name "$MCP_CLIENT_NAME" \
      '{jsonrpc:"2.0", id:1, method:"initialize", params:{protocolVersion:"2025-11-25", clientInfo:{name:$client_name, version:"1.0"}, capabilities:{}}}'
  )"

  deadline=$(( $(date +%s) + INIT_TIMEOUT_SEC ))
  while :; do
    : >"$headers_file"
    : >"$body_file"
    local remaining_sec init_attempt_timeout
    remaining_sec=$((deadline - $(date +%s)))
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
      session_id="$(awk 'tolower($0) ~ /^mcp-session-id:/ { sub(/^[^:]+:[[:space:]]*/, "", $0); sub(/\r$/, "", $0); print $0; exit }' "$headers_file")"
      protocol_version="$(awk 'tolower($0) ~ /^mcp-protocol-version:/ { sub(/^[^:]+:[[:space:]]*/, "", $0); sub(/\r$/, "", $0); print $0; exit }' "$headers_file")"
      if [[ -n "$session_id" ]]; then
        break
      fi
      if ! jq -e '.error.code == -32002' "$body_file" >/dev/null 2>&1; then
        break
      fi
    fi
    sleep 2
  done

  if [[ -z "${session_id:-}" ]]; then
    echo "MCP initialize did not return Mcp-Session-Id before ${INIT_TIMEOUT_SEC}s deadline" >&2
    cat "$body_file" >&2 || true
    rm -f "$headers_file" "$body_file"
    exit 1
  fi

  MCP_SESSION_ID="$session_id"
  export MCP_SESSION_ID
  if [[ -n "${protocol_version:-}" ]]; then
    MCP_PROTOCOL_VERSION="$protocol_version"
    export MCP_PROTOCOL_VERSION
  fi
  rm -f "$headers_file" "$body_file"
}

ensure_mcp_session_if_needed() {
  if [[ "$MUTATE" == "1" || -n "$BOARD_POST_ID" ]]; then
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
    printf '%s\n' "$KEEPER_NAMES" | tr ',' '\n' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | awk 'NF' >"$keeper_file"
  else
    local config_dir="$BASE_PATH/.masc/config/keepers"
    if [[ ! -d "$config_dir" ]]; then
      echo "keeper config dir not found: $config_dir" >&2
      exit 1
    fi
    python3 - "$config_dir" >"$keeper_file" <<'PY'
import pathlib
import sys

try:
    import tomllib
except ModuleNotFoundError:
    import tomli as tomllib  # type: ignore

root = pathlib.Path(sys.argv[1])


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


names = []
for path in sorted(root.glob("*.toml")):
    if path.name == "base.toml":
        continue
    keeper = load_keeper_config(path)
    if keeper.get("sandbox_profile") != "docker":
        continue
    name = keeper.get("name") or path.stem
    if isinstance(name, str) and name:
        names.append(name)

unique = []
for name in names:
    if name not in unique:
        unique.append(name)
if "sangsu" in unique:
    unique.remove("sangsu")
    unique.insert(0, "sangsu")
for name in unique:
    print(name)
PY
  fi

  if [[ "$MAX_KEEPERS" =~ ^[0-9]+$ ]] && [[ "$MAX_KEEPERS" -gt 0 ]]; then
    local limited="$RUN_DIR/keepers.limited.txt"
    head -n "$MAX_KEEPERS" "$keeper_file" >"$limited"
    mv "$limited" "$keeper_file"
  fi

  local count
  count="$(awk 'NF { c++ } END { print c + 0 }' "$keeper_file")"
  if [[ "$count" -eq 0 ]]; then
    echo "no target keepers discovered; pass --keeper-names or check config state" >&2
    exit 1
  fi
  log "target keepers: $count"
}

prompt_for_keeper() {
  local keeper="$1"
  cat <<EOF
Product/design board evidence run: $RUN_ID

Keeper: $keeper

Goal: create explicit product and design-domain board evidence for the fleet readiness audit.

Required action:
1. Call keeper_board_post exactly once.
2. Use hearth: product-design
3. The post must include one concrete product decision or risk, one concrete design decision or risk, and one next action that another keeper or operator can verify.
4. Do not edit files. Do not create a PR in this run.
5. After the tool call, reply with one compact JSON object:
   {"run_id":"$RUN_ID","keeper":"$keeper","hearth":"product-design","keeper_board_post":true,"product_evidence":true,"design_evidence":true,"blocker":null}

This prompt is sent with masc_keeper_msg.required_tools=["keeper_board_post"].
If keeper_board_post is unavailable or policy-blocked, stop and reply with the exact blocker instead of substituting another surface.
EOF
}

render_prompts() {
  while IFS= read -r keeper; do
    [[ -n "$keeper" ]] || continue
    prompt_for_keeper "$keeper" >"$PROMPT_DIR/$keeper.txt"
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
        '{name:$name,message:$message,timeout_sec:$timeout,required_tools:($required_tools_csv | split(",") | map(gsub("^[[:space:]]+|[[:space:]]+$"; "")) | map(select(length > 0)))}'
    )"
    log "sending product/design prompt to $keeper"
    payload="$(tool_call "keeper-product-design-msg-$keeper-$RUN_ID" "masc_keeper_msg" "$args" "$MSG_TIMEOUT_SEC")"
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
    jq -nc --arg keeper "$keeper" --arg request_id "$request_id" --arg prompt_file "$PROMPT_DIR/$keeper.txt" \
      '{keeper:$keeper, request_id:$request_id, prompt_file:$prompt_file, status:"pending"}' >>"$REQUESTS_FILE"
  done <"$RUN_DIR/keepers.txt"
}

result_is_terminal() {
  local text="$1"
  printf '%s' "$text" | jq -e '(.reply? | type == "string" and length > 0) or ((.status? // "" | ascii_downcase) as $s | ($s == "done" or $s == "complete" or $s == "completed" or $s == "failed" or $s == "error" or $s == "cancelled"))' >/dev/null 2>&1
}

poll_results() {
  local deadline pending_file
  deadline=$(( $(date +%s) + POLL_TIMEOUT_SEC ))
  pending_file="$RUN_DIR/pending.txt"
  jq -r '.request_id + "\t" + .keeper' "$REQUESTS_FILE" >"$pending_file"

  while [[ -s "$pending_file" && "$(date +%s)" -lt "$deadline" ]]; do
    local next_pending="$RUN_DIR/pending.next"
    : >"$next_pending"
    while IFS=$'\t' read -r request_id keeper; do
      [[ -n "$request_id" ]] || continue
      local args payload text status
      args="$(jq -cn --arg request_id "$request_id" '{request_id:$request_id}')"
      payload="$(tool_call "keeper-product-design-result-$request_id" "masc_keeper_msg_result" "$args" 30)"
      printf '%s' "$payload" >"$RAW_DIR/result-$keeper-$request_id.jsonrpc.json"
      if ! mcp_require_tool_ok "$payload" "masc_keeper_msg_result:$keeper" >/dev/null 2>&1; then
        jq -nc --arg keeper "$keeper" --arg request_id "$request_id" --arg status "poll_error" \
          --arg raw_file "$RAW_DIR/result-$keeper-$request_id.jsonrpc.json" \
          '{keeper:$keeper, request_id:$request_id, status:$status, raw_file:$raw_file}' >>"$POLL_ERRORS_FILE"
        printf '%s\t%s\n' "$request_id" "$keeper" >>"$next_pending"
        continue
      fi
      text="$(tool_text_or_empty "$payload")"
      printf '%s' "$text" >"$RAW_DIR/result-$keeper-$request_id.text"
      if result_is_terminal "$text"; then
        status="$(printf '%s' "$text" | jq -r '.status // (if .reply then "completed" else "unknown" end)' 2>/dev/null || echo completed)"
        jq -nc --arg keeper "$keeper" --arg request_id "$request_id" --arg status "$status" \
          --arg text_file "$RAW_DIR/result-$keeper-$request_id.text" \
          '{keeper:$keeper, request_id:$request_id, status:$status, text_file:$text_file}' >>"$RESULTS_FILE"
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
        '{keeper:$keeper, request_id:$request_id, status:"poll_timeout"}' >>"$RESULTS_FILE"
    done <"$pending_file"
  fi
}

run_audit() {
  if [[ "$RUN_AUDIT" != "1" ]]; then
    AUDIT_STATUS_RESULT=0
    return 0
  fi
  log "running product/design fleet audit"
  local -a audit_args=(
    "$REPO_ROOT/scripts/audit-keeper-fleet-readiness.py"
    --base-path "$BASE_PATH"
    --expected-keepers "$EXPECTED_KEEPERS"
    --require-product-evidence
    --require-design-evidence
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
    --arg base_path "$BASE_PATH" \
    --arg forbid_github_identities "$FORBID_GITHUB_IDENTITIES" \
    --argjson mutate "$MUTATE" \
    --argjson keeper_count "$keeper_count" \
    --argjson request_count "$request_count" \
    --argjson result_count "$result_count" \
    --argjson timeout_count "$timeout_count" \
    --argjson poll_error_count "$poll_error_count" \
    --argjson audit_status "$audit_status" \
    --arg audit_file "$AUDIT_FILE" \
    '{run_id:$run_id,run_dir:$run_dir,base_path:$base_path,forbid_github_identities:$forbid_github_identities,mutate:$mutate,keeper_count:$keeper_count,request_count:$request_count,result_count:$result_count,timeout_count:$timeout_count,poll_error_count:$poll_error_count,audit_status:$audit_status,audit_file:$audit_file}' \
    >"$SUMMARY_FILE"
}

post_board_summary() {
  [[ -n "$BOARD_POST_ID" ]] || return 0
  local content args payload
  content="$(jq -r '"Product/design board reprobe " + .run_id + "\n- mutate: " + (.mutate | tostring) + "\n- keepers: " + (.keeper_count | tostring) + "\n- requests: " + (.request_count | tostring) + "\n- results: " + (.result_count | tostring) + "\n- timeouts: " + (.timeout_count | tostring) + "\n- poll_errors: " + (.poll_error_count | tostring) + "\n- audit_status: " + (.audit_status | tostring) + "\n- artifacts: " + .run_dir' "$SUMMARY_FILE")"
  args="$(jq -cn --arg post_id "$BOARD_POST_ID" --arg content "$content" \
    '{post_id:$post_id, author:"keeper-product-design-board-reprobe", content:$content, ttl_hours:168}')"
  payload="$(tool_call "product-design-board-comment-$RUN_ID" "masc_board_comment" "$args" 30)"
  printf '%s' "$payload" >"$RAW_DIR/board-comment.jsonrpc.json"
}

require_cmd jq
require_cmd python3
require_cmd curl

ensure_mcp_session_if_needed
discover_keepers
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
