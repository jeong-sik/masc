#!/usr/bin/env bash
# keeper_load_gate.sh — Mode B: reproduce main-domain starvation under REAL
# autonomous keeper turns, network-free.
#
# Mode A (scheduler_starvation_gate.sh) drives the main domain with serving load
# (--inproc-load) only; an idle (autoboot-disabled) boot has no keeper compute,
# so its absolute regime is milder than production. Mode B seeds N declarative
# keepers that run real turns against mock_openai_provider.py, then probes
# /health TTFB while those keepers (and optional host hogs) contend for the one
# main Eio domain. This is the faithful keeper-vs-serving reproduction
# (RFC-0204 §5) and the committed-CI form of the keeper-load path.
#
# It boots the server directly (NOT via harness_start_server, which hardcodes
# MASC_KEEPER_BOOTSTRAP_ENABLED off) with autoboot enabled, and confirms turns
# actually fire by watching the mock request log before it trusts the numbers.
#
# Exit codes mirror Mode A: 0 GREEN, 2 RED (starved), 1 ERROR (harness failure).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
# shellcheck source=/dev/null
source "$REPO_ROOT/scripts/harness/lib/server_bootstrap.sh"
set +e  # server_bootstrap.sh sets -e on source; we manage failures explicitly

# ---- configuration (env-overridable) ----------------------------------------
NCPU="$(sysctl -n hw.ncpu 2>/dev/null || echo 4)"
KEEPERS="${KEEPERS:-8}"                          # how many autonomous keepers to seed
PROBE_ENDPOINT="${PROBE_ENDPOINT:-/health}"
PROBES="${PROBES:-30}"
WARMUP_PROBES="${WARMUP_PROBES:-8}"
PROBE_MAX_SEC="${PROBE_MAX_SEC:-15}"
HEARTBEAT_SEC="${HEARTBEAT_SEC:-3}"              # keeper turn cadence (lower = more load)
MOCK_DELAY_MS="${MOCK_DELAY_MS:-150}"           # simulated provider latency (keeps turns in-flight)
MOCK_REPLY_BYTES="${MOCK_REPLY_BYTES:-50000}"   # mock reply size; large => each turn's post-await
                                                # parse/record loads the main domain (the real keeper
                                                # cost; a trivial "ack" barely contends with serving)
WARM_TURNS_SEC="${WARM_TURNS_SEC:-20}"          # let keepers start turning before measuring
# Reactive board injection: load-generating keepers with "do minimal work"
# instructions quiesce after their autoboot burst (no real work => no turn), so
# autonomous cadence alone leaves turns_during=0 during the probe window. Posting
# board activity that @mentions a rotating keeper drives the Board_reactive wake
# path (keeper_world_observation_board_signal.ml) so turns fire continuously.
REACTIVE_INJECT="${REACTIVE_INJECT:-1}"
INJECT_INTERVAL="${INJECT_INTERVAL:-0.3}"       # seconds between board posts
INJECT_AUTHOR="${INJECT_AUTHOR:-operator}"
THRESHOLD_MS="${THRESHOLD_MS:-250}"
MAX_AMP="${MAX_AMP:-8}"
PERSONA="${PERSONA:-analyst}"
# Source root holding config/personas/<PERSONA>. Resolved from an explicit path,
# never home-anchored (SSOT-R6): point it at a populated MASC root.
PERSONA_SOURCE_ROOT="${MASC_PERSONA_SOURCE_ROOT:-}"
BORROW_MODEL="${BORROW_MODEL:-deepseek-v4-flash}"  # must be an oas-models.toml id_prefix
HOG_LEVELS="${HOG_LEVELS:-0 $((NCPU-1))}"       # host CPU hogs to sweep alongside keeper load

RUN_ID="${RUN_ID:-keeperload-$(date +%Y%m%d_%H%M%S)-$$}"
RUN_DIR="${RUN_DIR:-$REPO_ROOT/logs/perf-starvation/$RUN_ID}"

usage() {
  cat <<EOF
Usage: $(basename "$0") [options]
  --keepers N          autonomous keepers to seed (default: $KEEPERS)
  --probes N           /health probes per level (default: $PROBES)
  --levels "0 15"      host hog counts to sweep (default: "$HOG_LEVELS")
  --heartbeat-sec N    keeper turn cadence (default: $HEARTBEAT_SEC)
  --mock-delay-ms N    simulated provider latency (default: $MOCK_DELAY_MS)
  --threshold-ms N     max /health p95 under load before RED (default: $THRESHOLD_MS)
  --max-amp N          max p95 amplification before RED (default: $MAX_AMP)
  -h|--help            this help
Requires: python3, curl, jq, and MASC_PERSONA_SOURCE_ROOT pointing at a
populated MASC root (one that has config/personas/<persona>). Boots a server
with real keeper turns against a network-free mock provider; no cloud
credentials needed.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --keepers) KEEPERS="$2"; shift 2 ;;
    --probes) PROBES="$2"; shift 2 ;;
    --levels) HOG_LEVELS="$2"; shift 2 ;;
    --heartbeat-sec) HEARTBEAT_SEC="$2"; shift 2 ;;
    --mock-delay-ms) MOCK_DELAY_MS="$2"; shift 2 ;;
    --threshold-ms) THRESHOLD_MS="$2"; shift 2 ;;
    --max-amp) MAX_AMP="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown arg: $1" >&2; usage; exit 1 ;;
  esac
done

for tool in python3 curl jq awk sort sysctl; do
  command -v "$tool" >/dev/null 2>&1 || { echo "ERROR: missing required tool: $tool" >&2; exit 1; }
done

mkdir -p "$RUN_DIR"
CSV_FILE="$RUN_DIR/levels.csv"
SUMMARY_FILE="$RUN_DIR/summary.json"
SERVER_LOG="$RUN_DIR/server.log"
MOCK_LOG="$RUN_DIR/mock_requests.jsonl"
MOCK_ERR="$RUN_DIR/mock_stderr.log"
INJECT_LOG="$RUN_DIR/board_inject.log"
BASE_PATH="$(harness_mktemp_dir "masc-keeperload-base")"
echo "level_hogs,probes,p50_ms,p95_ms,max_ms,timeouts,turns_during" > "$CSV_FILE"

MOCK_PID=""
SERVER_PID=""
INJECT_PID=""
HOG_PIDS=()

cleanup() {
  if [[ ${#HOG_PIDS[@]} -gt 0 ]]; then kill "${HOG_PIDS[@]}" 2>/dev/null; wait "${HOG_PIDS[@]}" 2>/dev/null; fi
  [[ -n "$INJECT_PID" ]] && { kill "$INJECT_PID" 2>/dev/null; pkill -P "$INJECT_PID" 2>/dev/null; }
  [[ -n "$SERVER_PID" ]] && harness_stop_server "$SERVER_PID" >/dev/null 2>&1
  [[ -n "$MOCK_PID" ]] && kill "$MOCK_PID" 2>/dev/null
}
trap cleanup EXIT

# Background loop posting board activity that @mentions a rotating keeper, driving
# the reactive wake path so keepers turn continuously (not just the autoboot burst).
# MCP Streamable HTTP is stateful: initialize -> capture Mcp-Session-Id from the
# response headers -> notifications/initialized, then every tools/call carries the
# session header. Without it the server returns -32600 "Mcp-Session-Id required".
# Returns the session id on stdout (empty on failure).
_mcp_open_session() {
  local mcp="$1" hdr sid
  hdr="$(mktemp)"
  curl -sS -m 5 -D "$hdr" -o /dev/null -X POST "$mcp" \
    -H 'Content-Type: application/json' -H 'Accept: application/json, text/event-stream' \
    -d '{"jsonrpc":"2.0","id":0,"method":"initialize","params":{"protocolVersion":"2025-11-25","clientInfo":{"name":"perf-harness","version":"1.0"},"capabilities":{}}}' \
    2>/dev/null || true
  sid="$(awk 'tolower($0) ~ /^mcp-session-id:/ {sub(/^[^:]+:[[:space:]]*/,"",$0); sub(/\r$/,"",$0); print; exit}' "$hdr")"
  rm -f "$hdr"
  [[ -z "$sid" ]] && { printf ''; return 1; }
  curl -sS -m 5 -X POST "$mcp" \
    -H 'Content-Type: application/json' -H 'Accept: application/json, text/event-stream' \
    -H "mcp-session-id: $sid" \
    -d '{"jsonrpc":"2.0","method":"notifications/initialized","params":{}}' >/dev/null 2>&1 || true
  printf '%s' "$sid"
}

start_board_injector() {
  [[ "$REACTIVE_INJECT" == "1" ]] || { echo "[harness] reactive injection disabled" >&2; return 0; }
  local base_url="$1"
  local mcp="${base_url%/}/mcp"
  # Self-healing loop: lazily (re)open a session — the server can be too busy
  # booting the keeper fleet to answer initialize at first, and a session can be
  # dropped under load — so acquire it inside the loop and re-acquire on any
  # session error rather than giving up once.
  (
    sid=""; i=0
    while :; do
      if [[ -z "$sid" ]]; then
        sid="$(_mcp_open_session "$mcp")"
        [[ -z "$sid" ]] && { sleep 1; continue; }
      fi
      i=$((i + 1)); k=$(( (i % KEEPERS) + 1 ))
      resp="$(curl -sS --max-time 4 -X POST "$mcp" \
        -H 'Content-Type: application/json' -H 'Accept: application/json, text/event-stream' \
        -H "mcp-session-id: $sid" \
        -d "{\"jsonrpc\":\"2.0\",\"id\":$i,\"method\":\"tools/call\",\"params\":{\"name\":\"masc_board_post\",\"arguments\":{\"author\":\"$INJECT_AUTHOR\",\"title\":\"burst-$i\",\"content\":\"@perf_keeper_$k status check $i, please take a turn\",\"visibility\":\"internal\"}}}" \
        2>/dev/null)"
      printf '%s\n' "$resp" >>"$INJECT_LOG"
      case "$resp" in *Mcp-Session-Id*|*"session"*required*|*-32600*) sid="" ;; esac
      sleep "$INJECT_INTERVAL"
    done
  ) &
  INJECT_PID=$!
  disown 2>/dev/null || true
  echo "[harness] board injector started (pid=$INJECT_PID, self-healing session, every ${INJECT_INTERVAL}s)" >&2
}

spawn_hogs() { local n="$1" i; HOG_PIDS=(); for ((i=0;i<n;i++)); do yes >/dev/null 2>&1 & HOG_PIDS+=("$!"); done; }
kill_hogs() { if [[ ${#HOG_PIDS[@]} -gt 0 ]]; then kill "${HOG_PIDS[@]}" 2>/dev/null; wait "${HOG_PIDS[@]}" 2>/dev/null; fi; HOG_PIDS=(); }

probe_once() {
  local url="$1" t
  t="$(curl -sS -o /dev/null -w '%{time_starttransfer}' --max-time "$PROBE_MAX_SEC" "$url" 2>/dev/null)" || t="$PROBE_MAX_SEC"
  [[ "$t" =~ ^[0-9]+([.][0-9]+)?$ ]] || t="$PROBE_MAX_SEC"
  printf '%s\n' "$t"
}

measure_level() {
  local out_file="$1" url="$2" i t timeouts=0
  : > "$out_file"
  for ((i=0;i<PROBES;i++)); do
    t="$(probe_once "$url")"
    awk -v v="$t" -v m="$PROBE_MAX_SEC" 'BEGIN{ exit !(v+0 >= m+0) }' && timeouts=$((timeouts+1))
    printf '%s\n' "$t" >> "$out_file"
  done
  sort -n "$out_file" | awk -v to="$timeouts" '
    { v[NR]=$1 } END {
      n=NR; if(n==0){print "0.000 0.000 0.000 " to; exit}
      i50=int((n-1)*0.50)+1; i95=int((n-1)*0.95)+1
      printf "%.3f %.3f %.3f %d", v[i50]*1000, v[i95]*1000, v[n]*1000, to
    }'
}

# ---- seed config ------------------------------------------------------------
mkdir -p "$BASE_PATH/.masc/config/keepers" "$BASE_PATH/.masc/config/personas"
# Disable MCP auth for this ephemeral local harness so the board injector can call
# masc_board_post without a Bearer token. default_auth_config (types_auth.ml) is
# enabled+require_token when no file exists, which 401s the injector. This base
# path is a throwaway temp dir on loopback only.
mkdir -p "$BASE_PATH/.masc/auth"
cat > "$BASE_PATH/.masc/auth/config.json" <<EOF
{"enabled": false, "workspace_secret_hash": null, "require_token": false, "token_expiry_hours": 24}
EOF
if [[ -z "$PERSONA_SOURCE_ROOT" ]]; then
  echo "ERROR: set MASC_PERSONA_SOURCE_ROOT to a populated MASC root (one that has" >&2
  echo "       config/personas/$PERSONA), e.g. MASC_PERSONA_SOURCE_ROOT=<your-masc-root>" >&2
  exit 1
fi
if [[ -d "$PERSONA_SOURCE_ROOT/config/personas/$PERSONA" ]]; then
  cp -R "$PERSONA_SOURCE_ROOT/config/personas/$PERSONA" "$BASE_PATH/.masc/config/personas/$PERSONA"
else
  echo "ERROR: persona dir not found: $PERSONA_SOURCE_ROOT/config/personas/$PERSONA" >&2; exit 1
fi
MOCK_PORT="$(harness_pick_free_port)"
cat > "$BASE_PATH/.masc/config/runtime.toml" <<EOF
# Mock runtime: borrow a catalog-valid model id ($BORROW_MODEL is an
# oas-models.toml id_prefix) so init_default_strict's capability gate passes,
# but route the provider to the local network-free mock.
[runtime]
default = "mock.mockmodel"

[providers.mock]
display-name = "Local Mock"
protocol = "openai-compatible-http"
endpoint = "http://127.0.0.1:$MOCK_PORT"

[models.mockmodel]
api-name = "$BORROW_MODEL"
max-context = 131072
streaming = true

[models.mockmodel.capabilities]
max-output-tokens = 4096
supports-native-streaming = true
emits-usage-tokens = true

[mock.mockmodel]
is-default = true
max-concurrent = 64
EOF

for ((k=1;k<=KEEPERS;k++)); do
  cat > "$BASE_PATH/.masc/config/keepers/perf_keeper_${k}.toml" <<EOF
[keeper]
name = "perf_keeper_${k}"
persona_name = "$PERSONA"
goal = "Generate steady autonomous keeper load for the perf harness."
autoboot_enabled = true
proactive_enabled = true
proactive_idle_sec = 1
proactive_cooldown_sec = 1
sandbox_profile = "local"
instructions = "You are a load-generating test keeper. Each turn, do minimal work."
EOF
done

# ---- start mock + server ----------------------------------------------------
python3 "$SCRIPT_DIR/mock_openai_provider.py" --port "$MOCK_PORT" --log "$MOCK_LOG" --delay-ms "$MOCK_DELAY_MS" --reply-bytes "$MOCK_REPLY_BYTES" >"$MOCK_ERR" 2>&1 &
MOCK_PID=$!
: > "$MOCK_LOG"
sleep 1
curl -fsS --max-time 3 "http://127.0.0.1:$MOCK_PORT/" >/dev/null 2>&1 || { echo "ERROR: mock provider failed to start (see $MOCK_ERR)" >&2; exit 1; }

PORT="$(harness_pick_free_port)"
harness_seed_server_config "$REPO_ROOT" "$BASE_PATH" >/dev/null 2>&1 || true
# our runtime.toml (written above) takes precedence; seed only fills gaps.
(
  export MASC_BASE_PATH="$BASE_PATH"
  export MASC_BASE_PATH_INPUT="$BASE_PATH"
  export MASC_KEEPER_BOOTSTRAP_ENABLED="true"
  export MASC_ORCHESTRATOR_ENABLED="1"
  export MASC_KEEPER_HEARTBEAT_INTERVAL_SEC="$HEARTBEAT_SEC"
  # Sustain turns through the measurement window: disable smart gating (else
  # should_emit Skip_idle's the keeper after a few no-work cycles) and raise the
  # idle-turn cap so autonomous turns keep firing without real backlog.
  export MASC_KEEPER_SMART_HEARTBEAT="false"
  export MASC_KEEPER_MAX_IDLE_TURNS_AUTONOMOUS="50"
  export MASC_KEEPER_MAX_IDLE_TURNS_REACTIVE="50"
  export GRAPHQL_API_KEY=""
  export GRAPHQL_URL="http://127.0.0.1:9/graphql"
  exec "$(harness_find_server_exe "$REPO_ROOT")" --port "$PORT" --base-path "$BASE_PATH"
) >"$SERVER_LOG" 2>&1 &
SERVER_PID=$!

if ! harness_wait_for_health "$PORT" 45; then
  echo "ERROR: server failed health check" >&2; harness_print_log_tail "$SERVER_LOG"; exit 1
fi
BASE_URL="http://127.0.0.1:$PORT"
: > "$INJECT_LOG"
start_board_injector "$BASE_URL"
echo "[harness] server pid=$SERVER_PID port=$PORT, $KEEPERS keeper(s) seeded; warming turns ${WARM_TURNS_SEC}s..." >&2
sleep "$WARM_TURNS_SEC"

turns_total="$(wc -l < "$MOCK_LOG" | tr -d ' ')"
if [[ "${turns_total:-0}" -eq 0 ]]; then
  echo "ERROR: no keeper provider calls observed after ${WARM_TURNS_SEC}s — keepers are not turning." >&2
  echo "  Check $SERVER_LOG for autoboot/rejection errors. This harness is invalid without live turns." >&2
  rg -n -i 'rejected|autoboot|fatal|refus' "$SERVER_LOG" 2>/dev/null | tail -10 >&2
  exit 1
fi
echo "[harness] keepers live: $turns_total provider call(s) during warmup." >&2

PROBE_URL="${BASE_URL%/}${PROBE_ENDPOINT}"
for ((i=0;i<WARMUP_PROBES;i++)); do probe_once "$PROBE_URL" >/dev/null; done

# ---- sweep ------------------------------------------------------------------
printf '\n%-10s %-8s %-10s %-10s %-10s %-9s %-12s\n' "hogs" "probes" "p50_ms" "p95_ms" "max_ms" "timeouts" "turns_during" >&2
printf '%s\n' "---------------------------------------------------------------------------------" >&2
baseline_p95=""; loaded_p95=""
declare -a LEVELS_DONE=()
for level in $HOG_LEVELS; do
  kill_hogs
  [[ "$level" -gt 0 ]] && { spawn_hogs "$level"; sleep 2; }
  turns_before="$(wc -l < "$MOCK_LOG" | tr -d ' ')"
  read -r p50 p95 mx timeouts <<<"$(measure_level "$RUN_DIR/level_${level}.txt" "$PROBE_URL")"
  turns_after="$(wc -l < "$MOCK_LOG" | tr -d ' ')"
  turns_during=$((turns_after - turns_before))
  kill_hogs
  printf '%-10s %-8s %-10s %-10s %-10s %-9s %-12s\n' "$level" "$PROBES" "$p50" "$p95" "$mx" "$timeouts" "$turns_during" >&2
  printf '%s,%s,%s,%s,%s,%s,%s\n' "$level" "$PROBES" "$p50" "$p95" "$mx" "$timeouts" "$turns_during" >> "$CSV_FILE"
  LEVELS_DONE+=("{\"hogs\":$level,\"p95_ms\":$p95,\"max_ms\":$mx,\"timeouts\":$timeouts,\"turns_during\":$turns_during}")
  [[ "$level" == "0" ]] && baseline_p95="$p95"
  loaded_p95="$p95"
done

# ---- verdict ----------------------------------------------------------------
[[ -n "$baseline_p95" ]] || baseline_p95="$loaded_p95"
read -r amplification starved <<<"$(awk -v b="$baseline_p95" -v l="$loaded_p95" -v thr="$THRESHOLD_MS" -v ma="$MAX_AMP" \
  'BEGIN{ amp=(b>0)?l/b:0; printf "%.2f %d", amp, ((l>thr)||(amp>ma))?1:0 }')"

jq -n --arg run_id "$RUN_ID" --argjson keepers "$KEEPERS" --argjson ncpu "$NCPU" \
  --argjson baseline_p95_ms "$baseline_p95" --argjson loaded_p95_ms "$loaded_p95" \
  --argjson amplification "$amplification" --argjson starved "$starved" \
  --argjson warmup_turns "$turns_total" \
  --argjson levels "[$(IFS=,; echo "${LEVELS_DONE[*]}")]" \
  '{run_id:$run_id, mode:"keeper-load", keepers:$keepers, ncpu:$ncpu,
    warmup_provider_calls:$warmup_turns, baseline_p95_ms:$baseline_p95_ms,
    loaded_p95_ms:$loaded_p95_ms, amplification:$amplification,
    starved:($starved==1), levels:$levels}' > "$SUMMARY_FILE"

echo >&2
echo "[harness] keepers=$KEEPERS baseline p95=${baseline_p95}ms loaded p95=${loaded_p95}ms amp=${amplification}x" >&2
echo "[harness] artifacts: $RUN_DIR" >&2

# Self-document the known limitation: keepers do an initial autoboot burst, then
# their scheduled-autonomous cadence outruns the short probe window, so the
# measurement may not overlap an active turn (turns_during=0). When that holds,
# the verdict reflects keepers-resident + host load, NOT mid-turn keeper compute
# competing with serving. A GREEN here is therefore a weak signal.
loaded_turns="$(awk -F, 'NR>1 && $1!="0" {s+=$7} END{print s+0}' "$CSV_FILE")"
if [[ "${loaded_turns:-0}" -eq 0 ]]; then
  echo "[harness] WARN: turns_during=0 at loaded levels — no keeper turn fired during the probe window." >&2
  echo "         The keeper-load axis did not bite; treat the verdict as Mode-A-equivalent." >&2
  echo "         Faithful sustained load needs continuous turns (reactive channel) and a mock that" >&2
  echo "         returns large realistic responses so post-await processing loads the main domain." >&2
fi
if [[ "$starved" == "1" ]]; then
  echo "RED (STARVED): /health p95 ${loaded_p95}ms under keeper+host load (threshold ${THRESHOLD_MS}ms, amp ${amplification}x > ${MAX_AMP}x)" >&2
  exit 2
fi
echo "GREEN: /health p95 ${loaded_p95}ms stays within ${THRESHOLD_MS}ms (amp ${amplification}x <= ${MAX_AMP}x)" >&2
exit 0
