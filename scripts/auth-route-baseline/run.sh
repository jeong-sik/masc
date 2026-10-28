#!/bin/bash
# Auth baseline (plan layer A1): start an isolated server, probe every route, stop it.
#
#   run.sh <main_eio.exe> <auth_route_inventory.exe> <port> <work-dir> <out-dir> [NAME=value ...]
#
# Extra NAME=value arguments become environment variables of the server (for example
# MASC_HTTP_AUTH_STRICT=true). With none, the server runs on its defaults.
#
# The server runs with an empty environment (no provider or chat tokens), a fresh base
# path under <work-dir>, no keepers and loopback only. It never touches the workspace
# that is serving real traffic.
set -u
SERVER=$1; INVENTORY=$2; PORT=$3; WORK=$4; OUT=$5; shift 5
EXTRA=("$@")
HERE=$(cd "$(dirname "$0")" && pwd)
URL=http://127.0.0.1:$PORT

rm -rf "$WORK"; mkdir -p "$WORK/home" "$OUT"
env -i PATH=/usr/bin:/bin HOME="$WORK/home" "$INVENTORY" > "$WORK/routes.json" 2> "$WORK/routes.err" || { echo "inventory failed"; exit 1; }

env -i PATH=/usr/bin:/bin HOME="$WORK/home" MASC_HTTP_BASE_URL="$URL" MASC_URL="$URL/mcp" MASC_BASE_PATH="$WORK" \
  ${EXTRA[@]+"${EXTRA[@]}"} nohup "$SERVER" start --host 127.0.0.1 --port "$PORT" --base-path "$WORK" > "$WORK/server.log" 2>&1 &
for _ in $(seq 1 40); do
  [ "$(curl -s -m 2 -o /dev/null -w '%{http_code}' "$URL/health/ready")" = 200 ] && break
  sleep 3
done
[ "$(curl -s -m 2 -o /dev/null -w '%{http_code}' "$URL/health/ready")" = 200 ] || { echo "server did not become ready"; exit 1; }

python3 -I "$HERE/probe.py" --routes "$WORK/routes.json" --base-url "$URL" --out "$OUT"
python3 -I "$HERE/probe_extra.py" --base-url "$URL" --out "$OUT"

PID=$(lsof -nP -iTCP:"$PORT" -sTCP:LISTEN -t | head -1)
[ -n "$PID" ] && kill -TERM "$PID"
cp "$WORK/routes.json" "$OUT/routes.json"
