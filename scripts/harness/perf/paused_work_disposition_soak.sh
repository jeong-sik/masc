#!/usr/bin/env bash
# Exact 10-Keeper soak gate for paused-work disposition (#25191).
#
# This attaches to an isolated, already-running MASC. It does not build or boot
# the server. Each case pauses one owner, injects one exact Board_signal, commits
# Resume_owner, Transfer_owner, or Cancel_accepted, replays the same request, and
# verifies durable receipt/queue identity. A restart hook is optional for smoke
# runs and mandatory for release-eligible 8h evidence.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
# shellcheck source=scripts/harness/lib/test_framework.sh
source "$REPO_ROOT/scripts/harness/lib/test_framework.sh"

BASE_URL="${BASE_URL:-http://127.0.0.1:8935}"
MCP_URL="${MCP_URL:-${BASE_URL%/}/mcp}"
MASC_BASE_PATH="${MASC_BASE_PATH:-}"
KEEPER_NAMES="${KEEPER_NAMES:-}"
DURATION_SEC="${DURATION_SEC:-28800}"
WAIT_TIMEOUT_SEC="${WAIT_TIMEOUT_SEC:-180}"
REPLAY_SETTLE_SEC="${REPLAY_SETTLE_SEC:-3}"
RESTART_EVERY="${RESTART_EVERY:-7}"
RESTART_HOOK="${RESTART_HOOK:-}"
RUN_ID="${RUN_ID:-paused-work-soak-$(date -u +%Y%m%dT%H%M%SZ)-$$}"
RUN_DIR="${RUN_DIR:-$REPO_ROOT/logs/paused-work-soak/$RUN_ID}"
AUTHOR="${AUTHOR:-paused_work_soak}"
REQUEST_SCHEMA="masc.keeper.paused-work.operator-request.v1"
MIN_ACCEPTANCE_SEC=28800

usage() {
  printf '%s\n' \
    "Usage: $(basename "$0") [options]" \
    "  --base-url URL          running MASC origin (default: $BASE_URL)" \
    "  --base-path PATH        exact isolated MASC base path" \
    "  --keepers CSV           exactly 10 unique keeper names" \
    "  --duration-sec N        default 28800 (8h)" \
    "  --wait-timeout-sec N    per-transition timeout (default: $WAIT_TIMEOUT_SEC)" \
    "  --restart-every N       restart every Nth case; 0 disables (default: $RESTART_EVERY)" \
    "  --restart-hook PATH     executable synchronous restart hook" \
    "  --run-dir PATH          artifact directory" \
    "  -h|--help               show this help" \
    "" \
    "Required acknowledgement: MASC_PAUSED_WORK_SOAK_ISOLATED=1" \
    "Auth: MCP_TOKEN (MCP and authenticated dashboard API bearer token)." \
    "Restart hook argv: PHASE ITERATION SOURCE_KEEPER TARGET_KEEPER." \
    "The hook must return after the replacement server has been launched."
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --base-url) BASE_URL="$2"; MCP_URL="${2%/}/mcp"; shift 2 ;;
    --base-path) MASC_BASE_PATH="$2"; shift 2 ;;
    --keepers) KEEPER_NAMES="$2"; shift 2 ;;
    --duration-sec) DURATION_SEC="$2"; shift 2 ;;
    --wait-timeout-sec) WAIT_TIMEOUT_SEC="$2"; shift 2 ;;
    --restart-every) RESTART_EVERY="$2"; shift 2 ;;
    --restart-hook) RESTART_HOOK="$2"; shift 2 ;;
    --run-dir) RUN_DIR="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) printf 'ERROR: unknown argument: %s\n' "$1" >&2; usage >&2; exit 1 ;;
  esac
done
export MCP_URL

for tool in curl jq awk date sleep mkdir mktemp find head rm; do
  command -v "$tool" >/dev/null 2>&1 || {
    printf 'ERROR: missing required tool: %s\n' "$tool" >&2
    exit 1
  }
done

is_uint() { [[ "$1" =~ ^[0-9]+$ ]]; }
for value_name in DURATION_SEC WAIT_TIMEOUT_SEC REPLAY_SETTLE_SEC RESTART_EVERY; do
  value="${!value_name}"
  is_uint "$value" || { printf 'ERROR: %s must be an unsigned integer\n' "$value_name" >&2; exit 1; }
done
(( DURATION_SEC > 0 && WAIT_TIMEOUT_SEC > 0 )) || {
  printf 'ERROR: duration and wait timeout must be positive\n' >&2
  exit 1
}

[[ "${MASC_PAUSED_WORK_SOAK_ISOLATED:-}" == "1" ]] || {
  printf 'ERROR: set MASC_PAUSED_WORK_SOAK_ISOLATED=1 for the isolated target\n' >&2
  exit 1
}
[[ -n "$MASC_BASE_PATH" && -d "$MASC_BASE_PATH" && "$MASC_BASE_PATH" != "/" ]] || {
  printf 'ERROR: --base-path must be an existing, non-root isolated base path\n' >&2
  exit 1
}
case "$BASE_URL" in
  http://127.0.0.1:*|http://localhost:*|http://\[::1\]:*) ;;
  *)
    [[ "${ALLOW_NON_LOOPBACK:-}" == "1" ]] || {
      printf 'ERROR: non-loopback target requires ALLOW_NON_LOOPBACK=1\n' >&2
      exit 1
    }
    ;;
esac
if (( RESTART_EVERY > 0 )); then
  [[ -n "$RESTART_HOOK" && -f "$RESTART_HOOK" && -x "$RESTART_HOOK" ]] || {
    printf 'ERROR: --restart-hook must be an executable file when restarts are enabled\n' >&2
    exit 1
  }
fi

IFS=',' read -r -a KEEPERS <<<"$KEEPER_NAMES"
(( ${#KEEPERS[@]} == 10 )) || {
  printf 'ERROR: --keepers must contain exactly 10 names\n' >&2
  exit 1
}
for ((keeper_index = 0; keeper_index < ${#KEEPERS[@]}; keeper_index++)); do
  keeper="${KEEPERS[$keeper_index]}"
  [[ -n "$keeper" && ${#keeper} -le 128 && ! "$keeper" =~ [^A-Za-z0-9_-] ]] || {
    printf 'ERROR: invalid keeper name: %s\n' "$keeper" >&2
    exit 1
  }
  for ((prior_index = 0; prior_index < keeper_index; prior_index++)); do
    [[ "$keeper" != "${KEEPERS[$prior_index]}" ]] || {
      printf 'ERROR: duplicate keeper name: %s\n' "$keeper" >&2
      exit 1
    }
  done
done

mkdir -p "$RUN_DIR"
LEDGER_FILE="$RUN_DIR/cases.jsonl"
SUMMARY_FILE="$RUN_DIR/summary.json"
FAILURE_FILE="$RUN_DIR/failure.json"
: >"$LEDGER_FILE"

START_EPOCH="$(date +%s)"
ITERATIONS=0
RESTARTS=0
DUPLICATES=0
SILENT_LOSSES=0
RESUME_CASES=0
TRANSFER_CASES=0
CANCEL_CASES=0
RESTART_RESUME=0
RESTART_TRANSFER=0
RESTART_CANCEL=0
FINALIZED=0
HTTP_LAST_BODY=""
HTTP_LAST_STATUS=""
INVENTORY=""

write_summary() {
  local verdict="$1" reason="$2" end_epoch elapsed eligible
  end_epoch="$(date +%s)"
  elapsed=$((end_epoch - START_EPOCH))
  eligible=false
  if [[ "$verdict" == "pass" ]] \
    && (( elapsed >= MIN_ACCEPTANCE_SEC )) \
    && (( ${#KEEPERS[@]} == 10 )) \
    && (( RESUME_CASES >= 10 && TRANSFER_CASES >= 10 && CANCEL_CASES >= 10 )) \
    && (( RESTART_RESUME > 0 && RESTART_TRANSFER > 0 && RESTART_CANCEL > 0 )) \
    && (( DUPLICATES == 0 && SILENT_LOSSES == 0 )); then
    eligible=true
  fi
  jq -n \
    --arg schema "masc.keeper.paused-work.soak-summary.v1" \
    --arg run_id "$RUN_ID" --arg verdict "$verdict" --arg reason "$reason" \
    --arg base_url "$BASE_URL" --arg base_path "$MASC_BASE_PATH" \
    --argjson started_at "$START_EPOCH" --argjson ended_at "$end_epoch" \
    --argjson elapsed_sec "$elapsed" --argjson configured_duration_sec "$DURATION_SEC" \
    --argjson acceptance_eligible "$eligible" --argjson keeper_count "${#KEEPERS[@]}" \
    --argjson iterations "$ITERATIONS" --argjson restarts "$RESTARTS" \
    --argjson resume_cases "$RESUME_CASES" --argjson transfer_cases "$TRANSFER_CASES" \
    --argjson cancel_cases "$CANCEL_CASES" --argjson restart_resume "$RESTART_RESUME" \
    --argjson restart_transfer "$RESTART_TRANSFER" --argjson restart_cancel "$RESTART_CANCEL" \
    --argjson duplicate_terminal_effects "$DUPLICATES" \
    --argjson silent_losses "$SILENT_LOSSES" \
    --argjson keepers "$(printf '%s\n' "${KEEPERS[@]}" | jq -R . | jq -s .)" \
    '{schema:$schema,run_id:$run_id,verdict:$verdict,reason:$reason,
      target:{base_url:$base_url,base_path:$base_path},
      started_at_unix:$started_at,ended_at_unix:$ended_at,elapsed_sec:$elapsed_sec,
      configured_duration_sec:$configured_duration_sec,
      acceptance_eligible:$acceptance_eligible,keeper_count:$keeper_count,keepers:$keepers,
      cases:{total:$iterations,resume:$resume_cases,transfer:$transfer_cases,cancel:$cancel_cases},
      restart_faults:{total:$restarts,resume:$restart_resume,transfer:$restart_transfer,cancel:$restart_cancel,
        phase:"after_disposition_commit_before_terminal_observation"},
      duplicate_terminal_effects:$duplicate_terminal_effects,silent_losses:$silent_losses}' \
    >"$SUMMARY_FILE"
}

die() {
  local reason="$1" class="${2:-harness_error}"
  [[ "$class" == "silent_loss" ]] && SILENT_LOSSES=$((SILENT_LOSSES + 1))
  [[ "$class" == "duplicate" ]] && DUPLICATES=$((DUPLICATES + 1))
  jq -n --arg reason "$reason" --arg class "$class" --argjson iteration "$ITERATIONS" \
    '{reason:$reason,class:$class,iteration:$iteration}' >"$FAILURE_FILE"
  write_summary "fail" "$reason"
  FINALIZED=1
  printf 'FAIL: %s\n' "$reason" >&2
  exit 1
}

on_exit() {
  local status=$?
  if (( FINALIZED == 0 )); then
    write_summary "fail" "unexpected exit status $status"
  fi
}
trap on_exit EXIT
trap 'die "interrupted"' INT TERM

http_call() {
  local method="$1" path="$2" body="${3:-}" body_file auth_token auth_file="" status
  body_file="$(mktemp "${TMPDIR:-/tmp}/paused-work-http.XXXXXX")" || return 1
  auth_token="$(mcp_default_auth_token)"
  if [[ -n "$auth_token" ]]; then
    auth_file="$(_mcp_auth_header_file "$auth_token")" || { rm -f "$body_file"; return 1; }
  fi
  local -a args=(-sS --max-time "$CURL_TIMEOUT_SEC" -o "$body_file" -w '%{http_code}' -X "$method")
  args+=(-H 'Accept: application/json')
  [[ -n "$auth_file" ]] && args+=(-H "@$auth_file")
  if [[ "$method" == "POST" ]]; then
    args+=(-H 'Content-Type: application/json' -d "$body")
  fi
  if ! status="$(curl "${args[@]}" "${BASE_URL%/}${path}")"; then
    rm -f "$body_file" "$auth_file"
    return 1
  fi
  HTTP_LAST_BODY="$(<"$body_file")"
  HTTP_LAST_STATUS="$status"
  rm -f "$body_file" "$auth_file"
  jq -e . <<<"$HTTP_LAST_BODY" >/dev/null 2>&1
}

require_http_ok() {
  local label="$1"
  [[ "$HTTP_LAST_STATUS" == "200" || "$HTTP_LAST_STATUS" == "202" ]] ||
    die "$label returned HTTP $HTTP_LAST_STATUS: $HTTP_LAST_BODY"
}

get_inventory() {
  local keeper="$1"
  http_call GET "/api/v1/keepers/$keeper/paused-work" || return 1
  [[ "$HTTP_LAST_STATUS" == "200" ]] || return 1
  INVENTORY="$HTTP_LAST_BODY"
  jq -e '
    .schema == "masc.keeper.paused-work.inventory.v1" and
    .operator_request_schema == "masc.keeper.paused-work.operator-request.v1"
  ' <<<"$INVENTORY" >/dev/null 2>&1
}

wait_health() {
  local deadline=$(( $(date +%s) + WAIT_TIMEOUT_SEC ))
  while (( $(date +%s) <= deadline )); do
    if curl -fsS --max-time 5 "${BASE_URL%/}/health" >/dev/null 2>&1; then
      MCP_SESSION_ID=""
      export MCP_SESSION_ID
      initialize_mcp_session >/dev/null 2>&1 && return 0
    fi
    sleep 1
  done
  return 1
}

queue_path() {
  printf '%s/.masc/keepers/%s/event-queue.json\n' "$MASC_BASE_PATH" "$1"
}

read_state() {
  local keeper="$1" path
  path="$(queue_path "$keeper")"
  [[ -f "$path" ]] || return 1
  jq -e '
    if .schema == "keeper.event_queue.state.v4" then .
    else error("paused-work soak requires event queue schema v4")
    end
  ' "$path"
}

source_count() {
  local state="$1" source="$2"
  jq --argjson source "$source" '[
    .pending.items[]?, .leases[].stimuli[]?, .transition_outbox[].stimuli[]?
    | select(. == $source)
  ] | length' <<<"$state"
}

wait_paused_source() {
  local keeper="$1" post_id="$2" deadline=$(( $(date +%s) + WAIT_TIMEOUT_SEC )) count
  while (( $(date +%s) <= deadline )); do
    if get_inventory "$keeper"; then
      count="$(jq --arg post_id "$post_id" '[.queue.pending[] | select(.source.post_id == $post_id)] | length' <<<"$INVENTORY")"
      if [[ "$count" == "1" ]] \
        && jq -e '.owner.paused == true and .queue.active_lease == null and .queue.transition_outbox_count == 0' \
          <<<"$INVENTORY" >/dev/null; then
        return 0
      fi
    fi
    sleep 1
  done
  return 1
}

wait_ack() {
  local keeper="$1" expected_sequence="$2" source="$3"
  local deadline=$(( $(date +%s) + WAIT_TIMEOUT_SEC )) state count
  while (( $(date +%s) <= deadline )); do
    if state="$(read_state "$keeper" 2>/dev/null)"; then
      count="$(source_count "$state" "$source")"
      if [[ "$count" == "0" ]] && jq -e --arg seq "$expected_sequence" '
        (.last_settlement.lease_sequence | tostring) == $seq and
        .last_settlement.settlement.kind == "ack"
      ' <<<"$state" >/dev/null; then
        printf '%s' "$state"
        return 0
      fi
    fi
    sleep 1
  done
  return 1
}

wait_source_settlement() {
  local keeper="$1" operation_id="$2" kind="$3" source="$4"
  local deadline=$(( $(date +%s) + WAIT_TIMEOUT_SEC )) state count
  while (( $(date +%s) <= deadline )); do
    if state="$(read_state "$keeper" 2>/dev/null)"; then
      count="$(source_count "$state" "$source")"
      if [[ "$count" == "0" ]] && jq -e --arg op "$operation_id" --arg kind "$kind" '
        .last_settlement.settlement.kind == $kind and
        .last_settlement.settlement.operator_operation_id == $op
      ' <<<"$state" >/dev/null; then
        printf '%s' "$state"
        return 0
      fi
    fi
    sleep 1
  done
  return 1
}

post_pause() {
  local keeper="$1"
  http_call POST "/api/v1/keepers/$keeper/directive" '{"action":"pause"}' ||
    die "pause transport failed for $keeper"
  require_http_ok "pause $keeper"
  jq -e '.ok == true and .action == "pause"' <<<"$HTTP_LAST_BODY" >/dev/null ||
    die "pause response was not exact for $keeper: $HTTP_LAST_BODY"
}

post_disposition() {
  local keeper="$1" request="$2" label="$3"
  http_call POST "/api/v1/keepers/$keeper/paused-work" "$request" ||
    die "$label transport failed"
  require_http_ok "$label"
  jq -e '.committed == true and (.receipt | type == "object")' <<<"$HTTP_LAST_BODY" >/dev/null ||
    die "$label did not return a committed receipt: $HTTP_LAST_BODY"
}

receipt_canonical() { jq -S -c '.receipt' <<<"$1"; }

verify_receipt_file() {
  local keeper="$1" operation_id="$2" root="$MASC_BASE_PATH/.masc/paused-work-dispositions"
  local matches=0 file
  [[ -d "$root" ]] || return 1
  while IFS= read -r -d '' file; do
    if jq -e --arg keeper "$keeper" --arg op "$operation_id" '
      .keeper_name == $keeper and .operator_operation_id == $op
    ' "$file" >/dev/null 2>&1; then
      matches=$((matches + 1))
    fi
  done < <(find "$root" -type f -name 'operation-*.json' -print0)
  [[ "$matches" == "1" ]]
}

inject_board_source() {
  local keeper="$1" iteration="$2" response post_id args
  args="$(jq -cn --arg author "$AUTHOR" --arg title "$RUN_ID/$iteration" \
    --arg content "@$keeper paused-work disposition soak $RUN_ID/$iteration" \
    '{author:$author,title:$title,content:$content,visibility:"internal"}')"
  response="$(call_tool "$((10000 + iteration))" masc_board_post "$args")" ||
    die "board injection transport failed for $keeper"
  require_ok "$response" || die "board injection failed for $keeper"
  post_id="$(jq -r 'try (.result.structuredContent.id) catch empty | strings' <<<"$response" | head -n1)"
  [[ -n "$post_id" ]] || die "board injection returned no post_id for $keeper"
  printf '%s' "$post_id"
}

maybe_restart() {
  local action="$1" iteration="$2" source_keeper="$3" target_keeper="$4"
  (( RESTART_EVERY > 0 && (iteration + 1) % RESTART_EVERY == 0 )) || return 1
  "$RESTART_HOOK" after_disposition_commit_before_terminal_observation \
    "$iteration" "$source_keeper" "$target_keeper" ||
    die "restart hook failed at iteration $iteration"
  RESTARTS=$((RESTARTS + 1))
  case "$action" in
    resume) RESTART_RESUME=$((RESTART_RESUME + 1)) ;;
    transfer) RESTART_TRANSFER=$((RESTART_TRANSFER + 1)) ;;
    cancel) RESTART_CANCEL=$((RESTART_CANCEL + 1)) ;;
  esac
  wait_health || die "server did not recover after restart at iteration $iteration" "silent_loss"
  return 0
}

resume_cleanup() {
  local keeper="$1" generation="$2" operation_id="$3" request
  request="$(jq -cn --arg schema "$REQUEST_SCHEMA" --arg op "$operation_id" \
    --argjson generation "$generation" \
    '{schema:$schema,operation:"resume_owner",owner_generation:$generation,operator_operation_id:$op}')"
  post_disposition "$keeper" "$request" "cleanup resume $keeper"
  jq -e '.ok == true and .operation == "resume_owner"' <<<"$HTTP_LAST_BODY" >/dev/null ||
    die "cleanup resume projection incomplete for $keeper: $HTTP_LAST_BODY"
}

for keeper in "${KEEPERS[@]}"; do
  get_inventory "$keeper" || die "preflight inventory unavailable for $keeper"
  jq -e '
    .owner.paused == false and .queue.pending_count == 0 and
    .queue.active_lease == null and .queue.transition_outbox_count == 0
  ' <<<"$INVENTORY" >/dev/null ||
    die "preflight requires active empty lane for $keeper"
done
wait_health || die "server or MCP session is unavailable"

printf '[soak] run=%s duration=%ss keepers=10 artifacts=%s\n' "$RUN_ID" "$DURATION_SEC" "$RUN_DIR" >&2

while (( $(date +%s) - START_EPOCH < DURATION_SEC )); do
  index=$((ITERATIONS % 10))
  round=$((ITERATIONS / 10))
  source_keeper="${KEEPERS[$index]}"
  target_keeper="${KEEPERS[$(((index + 1) % 10))]}"
  case $((round % 3)) in
    0) action="resume" ;;
    1) action="transfer" ;;
    2) action="cancel" ;;
  esac

  get_inventory "$source_keeper" || die "inventory unavailable before case for $source_keeper"
  jq -e '.owner.paused == false and .queue.pending_count == 0 and .queue.active_lease == null and .queue.transition_outbox_count == 0' \
    <<<"$INVENTORY" >/dev/null || die "source lane is not clean before iteration $ITERATIONS"
  source_generation="$(jq '.owner.generation' <<<"$INVENTORY")"
  if [[ "$action" == "transfer" ]]; then
    get_inventory "$target_keeper" || die "target inventory unavailable for $target_keeper"
    jq -e '.owner.paused == false and .queue.pending_count == 0 and .queue.active_lease == null and .queue.transition_outbox_count == 0' \
      <<<"$INVENTORY" >/dev/null || die "target lane is not active and clean before iteration $ITERATIONS"
    target_generation="$(jq '.owner.generation' <<<"$INVENTORY")"
  else
    target_generation=0
  fi

  post_pause "$source_keeper"
  post_id="$(inject_board_source "$source_keeper" "$ITERATIONS")"
  wait_paused_source "$source_keeper" "$post_id" ||
    die "paused source was not retained exactly once for $source_keeper/$post_id" "silent_loss"
  source="$(jq -c --arg post_id "$post_id" '.queue.pending[] | select(.source.post_id == $post_id) | .source' <<<"$INVENTORY")"
  binding="$(jq -c --arg post_id "$post_id" '.queue.pending[] | select(.source.post_id == $post_id) | .continuation_binding' <<<"$INVENTORY")"
  source_revision="$(jq -r '.queue.revision | tostring' <<<"$INVENTORY")"
  source_state_before="$(read_state "$source_keeper")" || die "source v4 queue state unavailable"
  expected_sequence="$(jq -r '.next_lease_sequence | tostring' <<<"$source_state_before")"
  operation_id="$RUN_ID/$ITERATIONS/$action"
  settled_at="$(date +%s)"

  case "$action" in
    resume)
      request="$(jq -cn --arg schema "$REQUEST_SCHEMA" --arg op "$operation_id" \
        --argjson generation "$source_generation" \
        '{schema:$schema,operation:"resume_owner",owner_generation:$generation,operator_operation_id:$op}')"
      RESUME_CASES=$((RESUME_CASES + 1))
      ;;
    transfer)
      request="$(jq -cn --arg schema "$REQUEST_SCHEMA" --arg op "$operation_id" \
        --argjson source "$source" --arg revision "$source_revision" \
        --argjson generation "$source_generation" --argjson target_generation "$target_generation" \
        --arg target "$target_keeper" --argjson binding "$binding" --argjson settled_at "$settled_at" \
        '{schema:$schema,operation:"transfer_owner",source:$source,source_revision:$revision,
          owner_generation:$generation,target_generation:$target_generation,to_keeper:$target,
          continuation_binding:$binding,operator_operation_id:$op,settled_at:$settled_at}')"
      target_queue_path="$(queue_path "$target_keeper")"
      if [[ -f "$target_queue_path" ]]; then
        target_state_before="$(read_state "$target_keeper")" ||
          die "target queue exists but is not a valid v4 state"
        target_expected_sequence="$(jq -r '.next_lease_sequence | tostring' <<<"$target_state_before")"
      else
        target_expected_sequence=1
      fi
      TRANSFER_CASES=$((TRANSFER_CASES + 1))
      ;;
    cancel)
      request="$(jq -cn --arg schema "$REQUEST_SCHEMA" --arg op "$operation_id" \
        --argjson source "$source" --arg revision "$source_revision" \
        --argjson generation "$source_generation" --argjson settled_at "$settled_at" \
        '{schema:$schema,operation:"cancel_accepted",source_state:"pending",source:$source,
          source_revision:$revision,owner_generation:$generation,operator_operation_id:$op,
          reason:"paused-work soak accepted cancellation",settled_at:$settled_at}')"
      CANCEL_CASES=$((CANCEL_CASES + 1))
      ;;
  esac

  post_disposition "$source_keeper" "$request" "$action first commit"
  first_body="$HTTP_LAST_BODY"
  first_receipt="$(receipt_canonical "$first_body")"
  restarted=false
  if maybe_restart "$action" "$ITERATIONS" "$source_keeper" "$target_keeper"; then restarted=true; fi

  post_disposition "$source_keeper" "$request" "$action replay before terminal"
  replay_receipt="$(receipt_canonical "$HTTP_LAST_BODY")"
  [[ "$first_receipt" == "$replay_receipt" ]] ||
    die "$action replay changed its durable receipt" "duplicate"

  case "$action" in
    resume)
      terminal_state="$(wait_ack "$source_keeper" "$expected_sequence" "$source")" ||
        die "resume source did not reach one exact ACK" "silent_loss"
      ;;
    transfer)
      wait_source_settlement "$source_keeper" "$operation_id" transfer_accepted "$source" >/dev/null ||
        die "transfer source settlement was not durable" "silent_loss"
      terminal_state="$(wait_ack "$target_keeper" "$target_expected_sequence" "$source")" ||
        die "transfer target did not reach one exact ACK" "silent_loss"
      projection_count="$(jq --arg op "$operation_id" --argjson source "$source" '[
        .accepted_transfer_projections[] |
        select(.kind == "transfer_accepted" and .operator_operation_id == $op and .source == $source)
      ] | length' <<<"$terminal_state")"
      [[ "$projection_count" == "1" ]] ||
        die "transfer target projection ledger count is $projection_count, expected 1" "duplicate"
      ;;
    cancel)
      terminal_state="$(wait_source_settlement "$source_keeper" "$operation_id" cancel_accepted "$source")" ||
        die "cancel source did not reach one durable terminal receipt" "silent_loss"
      ;;
  esac

  terminal_next_sequence="$(jq -r '.next_lease_sequence | tostring' <<<"$terminal_state")"
  post_disposition "$source_keeper" "$request" "$action replay after terminal"
  final_body="$HTTP_LAST_BODY"
  final_receipt="$(receipt_canonical "$final_body")"
  [[ "$first_receipt" == "$final_receipt" ]] ||
    die "$action post-terminal replay changed its durable receipt" "duplicate"
  jq -e '.ok == true' <<<"$final_body" >/dev/null ||
    die "$action post-terminal replay did not repair its projection: $final_body"
  sleep "$REPLAY_SETTLE_SEC"

  if [[ "$action" == "transfer" ]]; then
    replay_state="$(read_state "$target_keeper")" || die "target state missing after replay"
  else
    replay_state="$(read_state "$source_keeper")" || die "source state missing after replay"
  fi
  replay_next_sequence="$(jq -r '.next_lease_sequence | tostring' <<<"$replay_state")"
  [[ "$terminal_next_sequence" == "$replay_next_sequence" ]] ||
    die "$action replay allocated another lease sequence" "duplicate"
  [[ "$(source_count "$replay_state" "$source")" == "0" ]] ||
    die "$action replay restored the consumed source" "duplicate"
  if [[ "$action" == "transfer" ]]; then
    [[ "$(jq --arg op "$operation_id" '[.accepted_transfer_projections[] | select(.operator_operation_id == $op)] | length' <<<"$replay_state")" == "1" ]] ||
      die "transfer replay duplicated the target projection ledger" "duplicate"
  fi
  verify_receipt_file "$source_keeper" "$operation_id" ||
    die "$action operation does not have exactly one durable disposition receipt"

  jq -n --arg schema "masc.keeper.paused-work.soak-case.v1" --arg run_id "$RUN_ID" \
    --argjson iteration "$ITERATIONS" --arg action "$action" --arg source_keeper "$source_keeper" \
    --arg target_keeper "$( [[ "$action" == "transfer" ]] && printf '%s' "$target_keeper" || printf '')" \
    --arg post_id "$post_id" --arg operation_id "$operation_id" --argjson source "$source" \
    --argjson source_revision "$source_revision" --argjson owner_generation "$source_generation" \
    --argjson restarted "$restarted" --argjson receipt "$first_receipt" \
    '{schema:$schema,run_id:$run_id,iteration:$iteration,action:$action,
      source_keeper:$source_keeper,target_keeper:(if $target_keeper == "" then null else $target_keeper end),
      post_id:$post_id,operation_id:$operation_id,source:$source,source_revision:$source_revision,
      owner_generation:$owner_generation,restarted:$restarted,receipt:$receipt,
      duplicate_terminal_effects:0,silent_losses:0}' >>"$LEDGER_FILE"

  if [[ "$action" != "resume" ]]; then
    resume_cleanup "$source_keeper" "$source_generation" "$operation_id/cleanup-resume"
  fi
  ITERATIONS=$((ITERATIONS + 1))
  printf '[soak] case=%d keeper=%s action=%s restart=%s PASS\n' \
    "$ITERATIONS" "$source_keeper" "$action" "$restarted" >&2
done

reason="configured soak completed"
verdict=pass
elapsed=$(( $(date +%s) - START_EPOCH ))
if (( elapsed < MIN_ACCEPTANCE_SEC )); then
  reason="smoke completed; duration below 8h acceptance floor"
elif (( RESUME_CASES < 10 || TRANSFER_CASES < 10 || CANCEL_CASES < 10 )); then
  verdict=fail
  reason="8h run did not cover every keeper with resume, transfer, and cancel"
elif (( RESTART_RESUME == 0 || RESTART_TRANSFER == 0 || RESTART_CANCEL == 0 )); then
  verdict=fail
  reason="8h run did not inject restart faults for every disposition class"
fi
write_summary "$verdict" "$reason"
FINALIZED=1
if [[ "$verdict" != "pass" ]]; then
  printf 'FAIL: %s\n' "$reason" >&2
  exit 1
fi
printf '[soak] PASS summary=%s acceptance_eligible=%s\n' "$SUMMARY_FILE" \
  "$(jq -r '.acceptance_eligible' "$SUMMARY_FILE")" >&2
