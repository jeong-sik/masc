#!/bin/sh
# Shows the home page of one binary in a real browser for what the session
# routes can answer, and presses its sign-out button.
#   1. boots a temporary multi-account installation with that binary;
#   2. saves the pages it answers (headers and bytes);
#   3. serves those saved bytes through the JSON stand-in (ux-mock.mjs), which
#      plays the session routes of each case;
#   4. runs session-views.mjs and stops everything it started.
# usage: session-views.sh BIN LABEL OUT PORT
#   PORT and PORT+1 are used.
set -u
BIN="$1"; LABEL="$2"; OUT="$3"; PORT="$4"
HERE="$(cd "$(dirname "$0")" && pwd)"
T="$OUT/run-$LABEL"
REAL="http://127.0.0.1:$PORT"
MOCK="http://127.0.0.1:$((PORT + 1))"
mkdir -p "$T/pages"

sh "$HERE/ux-serve.sh" "$BIN" "$T/a" "$PORT"
for name in home invite; do
  path=/; [ "$name" = invite ] && path=/accounts/invite
  curl -s -m 10 -D "$T/pages/$name.hdr" -o "$T/pages/$name.body" "$REAL$path"
done
echo "saved: $(wc -c < "$T/pages/home.body" | tr -d ' ') bytes of /"

node "$HERE/ux-mock.mjs" "$T/pages" "$((PORT + 1))" > "$T/mock.log" 2>&1 &
MOCK_PID=$!
n=0
until curl -s -m 2 -o /dev/null "$MOCK/" || [ "$n" -ge 20 ]; do n=$((n + 1)); perl -e 'select(undef, undef, undef, 0.25)'; done

python3 - "$HERE/session-views.mjs" "masc account pages ux" "$LABEL" "$OUT" "$MOCK" > "$T/run.mjs" <<'PY'
import json, pathlib, sys
path, space, label, out, base = sys.argv[1:6]
script = pathlib.Path(path).read_text()
for key, value in (
    ("const SPACE = __SPACE__;", f"const SPACE = {json.dumps(space)};"),
    ('const LABEL = "__LABEL__";', f"const LABEL = {json.dumps(label)};"),
    ('const OUT = "__OUT__";', f"const OUT = {json.dumps(out)};"),
    ('const BASE = "__BASE__";', f"const BASE = {json.dumps(base)};"),
):
    assert script.count(key) == 1, key
    script = script.replace(key, value)
sys.stdout.write(script)
PY
ego-browser nodejs < "$T/run.mjs" > "$T/measure.out" 2>&1
echo "measure exit=$? rows=$(grep -c '^{' "$T/measure.out")"

kill -TERM "$MOCK_PID" 2>/dev/null
pid="$(cat "$T/a/pid" 2>/dev/null)"
[ -n "$pid" ] && kill -TERM "$pid" 2>/dev/null
echo "stopped: mock $MOCK_PID, server $pid"
