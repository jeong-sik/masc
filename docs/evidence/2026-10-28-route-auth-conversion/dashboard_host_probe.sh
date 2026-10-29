#!/bin/bash
# Start one isolated server and send it the requests of dashboard_host_probe.py.
#
#   dashboard_host_probe.sh <main_eio.exe> <port> <work-dir> <out-file>
#
# The server runs as in scripts/auth-route-baseline/run.sh: an empty environment, a fresh
# base path under <work-dir>, no keepers, loopback only. The script refuses to run when
# <port> already has a listener, and stops only the process it started. <work-dir> must
# be an absolute path that does not exist yet or was made by an earlier run of this script.
set -u

fail() { echo "$1" >&2; exit 1; }
[ $# -eq 4 ] || fail "usage: dashboard_host_probe.sh <main_eio.exe> <port> <work-dir> <out-file>"
SERVER=$(cd "$(dirname "$1")" && pwd)/$(basename "$1"); PORT=$2; WORK=$3; OUT=$4
HERE=$(cd "$(dirname "$0")" && pwd)
MARKER=.dashboard-host-probe

case "$WORK" in /*) ;; *) fail "work dir must be an absolute path: $WORK" ;; esac
[ "$WORK" != "/" ] && [ "$WORK" != "${HOME:-}" ] || fail "refusing work dir: $WORK"
if [ -e "$WORK" ] && [ ! -f "$WORK/$MARKER" ]; then
  fail "refusing to delete $WORK: it has no $MARKER marker, so this script did not make it"
fi
[ -z "$(lsof -nP -iTCP:"$PORT" -sTCP:LISTEN -t)" ] || fail "port $PORT already has a listener; pick a free port"

rm -rf "$WORK"; mkdir -p "$WORK/home"; touch "$WORK/$MARKER"
URL=http://127.0.0.1:$PORT

(cd "$WORK/home" && exec env -i PATH=/usr/bin:/bin HOME="$WORK/home" MASC_HTTP_BASE_URL="$URL" MASC_URL="$URL/mcp" MASC_BASE_PATH="$WORK" \
  nohup "$SERVER" start --host 127.0.0.1 --port "$PORT" --base-path "$WORK") > "$WORK/server.log" 2>&1 &
PID=$!
trap 'kill -TERM "$PID" 2>/dev/null' EXIT

python3 -I "$HERE/dashboard_host_probe.py" probe --port "$PORT" --work-dir "$WORK" --out "$OUT"
