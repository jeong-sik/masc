#!/bin/bash
# Auth baseline (plan layer A1): start an isolated server, probe every route, stop it.
#
#   run.sh <main_eio.exe> <auth_route_inventory.exe> <port> <work-dir> <out-dir> [NAME=value ...]
#
# <work-dir> must be an absolute path that does not exist yet or was made by an earlier run
# of this script (it holds a marker file). Extra NAME=value arguments become environment
# variables of the server (for example MASC_HTTP_AUTH_STRICT=true). With none, the server
# runs on its defaults.
#
# The server runs with an empty environment (no provider or chat tokens), a fresh base
# path under <work-dir>, no keepers and loopback only. Probes send POST, PUT and DELETE to
# every route, so the script refuses to run when <port> already has a listener, checks
# that the listener is the server it started, and stops only that process.
#
# With AUTH_BASELINE_CREDENTIALS=1 in the script's own environment, it mints a Worker and
# an Admin token with `login` in the fresh base path before the server starts, and probe.py
# also sends them and keeps the scrubbed response bodies in <out-dir>/bodies (see probe.py).
# The tokens live under <work-dir> and are not copied to <out-dir>.
set -u

abspath() { echo "$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"; }
fail() { echo "$1" >&2; exit 1; }

[ $# -ge 5 ] || fail "usage: run.sh <main_eio.exe> <auth_route_inventory.exe> <port> <work-dir> <out-dir> [NAME=value ...]"
SERVER=$(abspath "$1"); INVENTORY=$(abspath "$2"); PORT=$3; WORK=$4; OUT=$5; shift 5
EXTRA=("$@")
HERE=$(cd "$(dirname "$0")" && pwd)
URL=http://127.0.0.1:$PORT
MARKER=.auth-route-baseline

case "$WORK" in
  /*) ;;
  *) fail "work dir must be an absolute path: $WORK" ;;
esac
[ "$WORK" != "/" ] && [ "$WORK" != "${HOME:-}" ] || fail "refusing work dir: $WORK"
if [ -e "$WORK" ] && [ ! -f "$WORK/$MARKER" ]; then
  fail "refusing to delete $WORK: it has no $MARKER marker, so this script did not make it"
fi
[ -z "$(lsof -nP -iTCP:"$PORT" -sTCP:LISTEN -t)" ] || fail "port $PORT already has a listener; pick a free port"

rm -rf "$WORK"; mkdir -p "$WORK/home" "$OUT"; touch "$WORK/$MARKER"

PROBE_ARGS=()
if [ "${AUTH_BASELINE_CREDENTIALS:-0}" = 1 ]; then
  mint() {
    (cd "$WORK/home" && env -i PATH=/usr/bin:/bin HOME="$WORK/home" "$SERVER" login --agent "a1-$1" --role "$1" \
       --base-path "$WORK" --client-env A1_TOKEN --no-expiry --json 2> "$WORK/login-$1.err") \
      | python3 -I -c 'import json, sys; print(json.load(sys.stdin)["bearer_token"])'
  }
  worker=$(mint worker) && admin=$(mint admin) || fail "could not mint the Worker and Admin tokens; see $WORK/login-*.err"
  (umask 077; printf '{"worker": "%s", "admin": "%s"}\n' "$worker" "$admin" > "$WORK/tokens.json")
  PROBE_ARGS=(--tokens "$WORK/tokens.json" --work-dir "$WORK" --keep-bodies)
fi

(cd "$WORK/home" && env -i PATH=/usr/bin:/bin HOME="$WORK/home" MASC_BASE_PATH="$WORK" "$INVENTORY") \
  > "$WORK/routes.json" 2> "$WORK/routes.err" || fail "inventory failed; see $WORK/routes.err"

(cd "$WORK/home" && exec env -i PATH=/usr/bin:/bin HOME="$WORK/home" MASC_HTTP_BASE_URL="$URL" MASC_URL="$URL/mcp" MASC_BASE_PATH="$WORK" \
  ${EXTRA[@]+"${EXTRA[@]}"} nohup "$SERVER" start --host 127.0.0.1 --port "$PORT" --base-path "$WORK") \
  > "$WORK/server.log" 2>&1 &
PID=$!
trap 'kill -TERM "$PID" 2>/dev/null' EXIT

ready=0
for _ in $(seq 1 40); do
  kill -0 "$PID" 2>/dev/null || fail "server exited before it was ready; see $WORK/server.log"
  if [ "$(curl -s -m 2 -o /dev/null -w '%{http_code}' "$URL/health/ready")" = 200 ]; then ready=1; break; fi
  sleep 3
done
[ "$ready" = 1 ] || fail "server did not become ready; see $WORK/server.log"

LISTENER=$(lsof -nP -iTCP:"$PORT" -sTCP:LISTEN -t | head -1)
[ "$LISTENER" = "$PID" ] || fail "the listener on port $PORT (pid ${LISTENER:-none}) is not the server this script started (pid $PID)"

python3 -I "$HERE/probe.py" --routes "$WORK/routes.json" --base-url "$URL" --out "$OUT" ${PROBE_ARGS[@]+"${PROBE_ARGS[@]}"}
python3 -I "$HERE/probe_extra.py" --base-url "$URL" --out "$OUT"
cp "$WORK/routes.json" "$OUT/routes.json"

# AUTH_BASELINE_AFTER names a shell command to run while the server is still up, for a probe a
# layer brings along. It sees AUTH_BASELINE_URL, AUTH_BASELINE_ROUTES, AUTH_BASELINE_TOKENS (the
# file exists only with AUTH_BASELINE_CREDENTIALS=1) and AUTH_BASELINE_OUT.
if [ -n "${AUTH_BASELINE_AFTER:-}" ]; then
  AUTH_BASELINE_URL="$URL" AUTH_BASELINE_ROUTES="$WORK/routes.json" AUTH_BASELINE_TOKENS="$WORK/tokens.json" \
    AUTH_BASELINE_OUT="$OUT" bash -c "$AUTH_BASELINE_AFTER" || fail "AUTH_BASELINE_AFTER failed"
fi
