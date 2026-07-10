#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

pick_free_port() {
  node <<'NODE'
const net = require('net');
const server = net.createServer();
server.listen(0, '127.0.0.1', () => {
  const address = server.address();
  console.log(address && typeof address === 'object' ? address.port : 8961);
  server.close();
});
NODE
}

log() {
  printf '[keeper-chat-contract-smoke] %s\n' "$*" >&2
}

run_with_timeout() {
  local timeout_sec="$1"
  local label="$2"
  shift 2

  "$@" &
  local cmd_pid=$!

  (
    sleep "$timeout_sec"
    if kill -0 "$cmd_pid" >/dev/null 2>&1; then
      printf '[keeper-chat-contract-smoke] timeout after %ss: %s\n' "$timeout_sec" "$label" >&2
      kill "$cmd_pid" >/dev/null 2>&1 || true
    fi
  ) &
  local watchdog_pid=$!

  local status=0
  wait "$cmd_pid" || status=$?
  kill "$watchdog_pid" >/dev/null 2>&1 || true
  wait "$watchdog_pid" 2>/dev/null || true
  return "$status"
}

PORT="${PORT:-$(pick_free_port)}"
HOST="${HOST:-127.0.0.1}"
BASE_URL="${BASE_URL:-http://${HOST}:${PORT}/dashboard/}"
BASE_PATH="${BASE_PATH:-$(mktemp -d "${TMPDIR:-/tmp}/masc-keeper-chat-contract.XXXXXX")}"
KEEP_SERVER="${KEEP_SERVER:-0}"
KEEP_BASE_PATH="${KEEP_BASE_PATH:-0}"
KEEPER_NAME="${KEEPER_NAME:-chat-contract-smoke}"
SERVER_LOG="${SERVER_LOG:-${BASE_PATH}/keeper-chat-contract-server.log}"
SERVER_EXE="${SERVER_EXE:-$REPO_ROOT/_build/default/bin/main_eio.exe}"
SERVER_WAIT_SEC="${SERVER_WAIT_SEC:-45}"
CONTRACT_TIMEOUT_SEC="${CONTRACT_TIMEOUT_SEC:-30}"
CONTRACT_SCRIPT="${CONTRACT_SCRIPT:-${BASE_PATH}/keeper-chat-contract.smoke.js}"
RUNTIME_CONFIG_SOURCE="${RUNTIME_CONFIG_SOURCE:-$REPO_ROOT/config/runtime.toml}"

SERVER_PID=""

cleanup() {
  if [ -n "$SERVER_PID" ] && kill -0 "$SERVER_PID" >/dev/null 2>&1; then
    if [ "$KEEP_SERVER" = "1" ]; then
      echo "Keeping server running: pid=$SERVER_PID log=$SERVER_LOG"
    else
      kill "$SERVER_PID" >/dev/null 2>&1 || true
      wait "$SERVER_PID" 2>/dev/null || true
    fi
  fi
  if [ "$KEEP_BASE_PATH" != "1" ]; then
    rm -rf "$BASE_PATH"
  else
    echo "Keeping fixture base path: $BASE_PATH"
  fi
}

trap cleanup EXIT

if [ ! -f "$RUNTIME_CONFIG_SOURCE" ]; then
  echo "Runtime config seed missing: $RUNTIME_CONFIG_SOURCE" >&2
  exit 1
fi

mkdir -p "$BASE_PATH/.masc/config/keepers" "$BASE_PATH/.masc/keepers" "$BASE_PATH/.masc/keeper_chat"
cp "$RUNTIME_CONFIG_SOURCE" "$BASE_PATH/.masc/config/runtime.toml"

cat >"$BASE_PATH/.masc/config/keepers/${KEEPER_NAME}.toml" <<EOF_TOML
[keeper]
autoboot_enabled = false
EOF_TOML

KEEPER_NAME="$KEEPER_NAME" BASE_PATH="$BASE_PATH" node <<'NODE'
const fs = require('fs');
const path = require('path');

const basePath = process.env.BASE_PATH;
const keeper = process.env.KEEPER_NAME;
const chatPath = path.join(basePath, '.masc', 'keeper_chat', `${keeper}.jsonl`);
const metaPath = path.join(basePath, '.masc', 'keepers', `${keeper}.json`);
const turnRef = 'trace-chat-contract-smoke#7';
const errorTurnRef = 'trace-chat-contract-smoke#8';

const rows = [
  {
    id: 'smoke-legacy-user',
    role: 'user',
    content: 'legacy row without turn ref',
    ts: 1783299999.999,
    source: 'dashboard',
  },
  {
    id: 'smoke-user',
    role: 'user',
    content: 'prove server lifecycle replay',
    ts: 1783300000.001,
    source: 'dashboard',
    turn_ref: turnRef,
  },
  {
    id: 'smoke-tool',
    role: 'tool',
    content: '{}',
    ts: 1783300000.002,
    source: 'dashboard',
    tool_call_id: 'toolu_smoke_contract',
    tool_call_name: 'keeper_context_status',
    turn_ref: turnRef,
  },
  {
    id: 'smoke-assistant',
    role: 'assistant',
    content: 'contract replay complete',
    ts: 1783300000.003,
    source: 'dashboard',
    turn_ref: turnRef,
    stream_lifecycle: [
      'RUN_STARTED',
      'TEXT_MESSAGE_START',
      'TEXT_MESSAGE_END',
      'RUN_FINISHED',
    ],
  },
  {
    id: 'smoke-error-assistant',
    role: 'assistant',
    content: 'Keeper request failed: Timeout after 630.0s',
    ts: 1783300000.004,
    source: 'dashboard',
    kind: 'transport_failure',
    turn_ref: errorTurnRef,
    stream_lifecycle: [
      'RUN_STARTED',
      'RUN_ERROR',
    ],
  },
];

fs.writeFileSync(chatPath, `${rows.map(row => JSON.stringify(row)).join('\n')}\n`);
fs.writeFileSync(metaPath, `${JSON.stringify({
  name: keeper,
  agent_name: `${keeper}-agent`,
  trace_id: 'trace-chat-contract-smoke',
  goal: 'fixture keeper for dashboard chat contract smoke',
  tool_access: [],
})}\n`);
NODE

log "base_path=$BASE_PATH port=$PORT keeper=$KEEPER_NAME"

wait_for_http() {
  local url="$1"
  local attempts="${2:-45}"
  local i=1
  while [ "$i" -le "$attempts" ]; do
    if curl -fsS "$url" >/dev/null 2>&1; then
      log "http ready: $url"
      return 0
    fi
    if [ $((i % 5)) -eq 0 ]; then
      log "waiting for http ($i/$attempts): $url"
    fi
    sleep 1
    i=$((i + 1))
  done
  return 1
}

log "starting server"
if [ -x "$SERVER_EXE" ]; then
  nohup env \
    MASC_BASE_PATH="$BASE_PATH" \
    MASC_CONFIG_DIR="$BASE_PATH/.masc/config" \
    MASC_ORCHESTRATOR_ENABLED=false \
    MASC_AUTONOMY_ENABLED=false \
    MASC_DASHBOARD_BRIEFING_MODELS=disabled \
    "$SERVER_EXE" --port "$PORT" --base-path "$BASE_PATH" >"$SERVER_LOG" 2>&1 &
else
  nohup env \
    MASC_BASE_PATH="$BASE_PATH" \
    MASC_CONFIG_DIR="$BASE_PATH/.masc/config" \
    MASC_ORCHESTRATOR_ENABLED=false \
    MASC_AUTONOMY_ENABLED=false \
    MASC_DASHBOARD_BRIEFING_MODELS=disabled \
    "$REPO_ROOT/start-masc.sh" --port "$PORT" --base-path "$BASE_PATH" >"$SERVER_LOG" 2>&1 &
fi
SERVER_PID=$!
log "server_pid=$SERVER_PID log=$SERVER_LOG"

if ! wait_for_http "http://${HOST}:${PORT}/health" "$SERVER_WAIT_SEC"; then
  echo "MASC server did not become healthy. See $SERVER_LOG" >&2
  exit 1
fi

cat >"$CONTRACT_SCRIPT" <<'NODE'
const base = process.env.BASE_URL;
const keeper = process.env.KEEPER_NAME;
const checks = [];

function record(name, pass, details = {}) {
  checks.push({ name, pass, details });
}

function requireContract(row, id) {
  if (!row || !row.stream_contract) {
    throw new Error(`missing stream_contract for ${id}`);
  }
  return row.stream_contract;
}

(async () => {
  const historyUrl = new URL(`/api/v1/keepers/${encodeURIComponent(keeper)}/chat/history`, base);
  const res = await fetch(historyUrl);
  record('history endpoint returns 200', res.ok, { status: res.status });
  if (!res.ok) throw new Error(`history endpoint failed: ${res.status} ${res.statusText}`);

  const rows = await res.json();
  record('history response is an array', Array.isArray(rows), { length: Array.isArray(rows) ? rows.length : null });
  if (!Array.isArray(rows)) throw new Error('history response is not an array');

  const byId = new Map(rows.map(row => [row.id, row]));
  const legacyContract = requireContract(byId.get('smoke-legacy-user'), 'smoke-legacy-user');
  const userContract = requireContract(byId.get('smoke-user'), 'smoke-user');
  const toolContract = requireContract(byId.get('smoke-tool'), 'smoke-tool');
  const assistantContract = requireContract(byId.get('smoke-assistant'), 'smoke-assistant');
  const errorRow = byId.get('smoke-error-assistant');
  const errorContract = requireContract(errorRow, 'smoke-error-assistant');

  record('assistant row replays durable server lifecycle first', assistantContract.source === 'backend_stream_lifecycle' && assistantContract.status === 'backend_lifecycle_replay', assistantContract);
  record('assistant row labels replay as server-only receipt', assistantContract.delivery_receipt === 'server_lifecycle_replay_only', assistantContract);
  record('assistant row exposes terminal lifecycle event', assistantContract.event_name === 'RUN_FINISHED', assistantContract);
  record(
    'assistant row preserves closed lifecycle sequence',
    JSON.stringify(assistantContract.lifecycle_events) === JSON.stringify([
      'RUN_STARTED',
      'TEXT_MESSAGE_START',
      'TEXT_MESSAGE_END',
      'RUN_FINISHED',
    ]),
    assistantContract,
  );
  record('user row has no client delivery receipt', userContract.delivery_receipt === 'no_delivery_receipt', userContract);
  record('tool row has no client delivery receipt', toolContract.delivery_receipt === 'no_delivery_receipt', toolContract);
  record(
    'legacy row without turn_ref is explicit no-receipt history gap',
    legacyContract.source === 'keeper_chat_store'
      && legacyContract.status === 'history_without_turn_ref'
      && legacyContract.delivery_receipt === 'no_delivery_receipt',
    legacyContract,
  );
  record('error assistant keeps typed transport-failure row kind', errorRow?.kind === 'transport_failure', errorRow);
  record(
    'error assistant row replays RUN_ERROR as server-only receipt',
    errorContract.source === 'backend_stream_lifecycle'
      && errorContract.status === 'backend_lifecycle_replay'
      && errorContract.event_name === 'RUN_ERROR'
      && errorContract.delivery_receipt === 'server_lifecycle_replay_only',
    errorContract,
  );
  record(
    'error assistant row preserves closed error lifecycle sequence',
    JSON.stringify(errorContract.lifecycle_events) === JSON.stringify([
      'RUN_STARTED',
      'RUN_ERROR',
    ]),
    errorContract,
  );
  record(
    'server history never claims dashboard client-observed SSE delivery',
    rows.every(row => row.stream_contract?.delivery_receipt !== 'client_observed_sse_event'),
    rows.map(row => ({ id: row.id, delivery_receipt: row.stream_contract?.delivery_receipt })),
  );

  console.log(JSON.stringify({ base, keeper, checks }, null, 2));
  const failed = checks.filter(check => !check.pass);
  if (failed.length > 0) process.exit(1);
})().catch(err => {
  console.error(err);
  process.exit(1);
});
NODE

log "running contract smoke"
if ! run_with_timeout "$CONTRACT_TIMEOUT_SEC" "keeper chat contract smoke" \
  env BASE_URL="$BASE_URL" KEEPER_NAME="$KEEPER_NAME" node "$CONTRACT_SCRIPT"; then
  echo "Keeper chat contract smoke failed. See $SERVER_LOG" >&2
  exit 1
fi

log "keeper chat contract smoke passed"
