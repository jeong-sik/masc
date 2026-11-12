#!/bin/sh
# Measures the frame of the console over the answers console-layer.sh saved:
# serves them through console-mock.mjs and runs console-frame.mjs in a real
# browser, then stops the mock.
# usage: console-frame.sh FILES_DIR LABEL OUT PORT
#   FILES_DIR is the run/files directory of console-layer.sh. UX_SPACE names
#   the task space of the browser (default: masc account pages ux).
set -u
FILES="$1"; LABEL="$2"; OUT="$3"; PORT="$4"
HERE="$(cd "$(dirname "$0")" && pwd)"
MOCK="http://127.0.0.1:$PORT"
mkdir -p "$OUT"
node "$HERE/console-mock.mjs" "$FILES" "$PORT" > "$OUT/$LABEL-mock.log" 2>&1 &
MOCK_PID=$!
n=0
until curl -s -m 2 -o /dev/null "$MOCK/" || [ "$n" -ge 20 ]; do n=$((n + 1)); perl -e 'select(undef, undef, undef, 0.25)'; done
python3 "$HERE/console-frame-run.py" "${UX_SPACE:-masc account pages ux}" "$LABEL" "$OUT" "$MOCK" > "$OUT/$LABEL-frame.mjs"
ego-browser nodejs < "$OUT/$LABEL-frame.mjs" > "$OUT/$LABEL-frame.out" 2>&1
echo "frame exit=$? rows=$(grep -c '^{' "$OUT/$LABEL-frame.out")"
kill -TERM "$MOCK_PID" 2>/dev/null
echo "stopped: mock $MOCK_PID"
