#!/bin/sh
# Presses the button of the invitation page while the page loads a second
# link, in one tab of a real browser, against the account server of one binary
# behind the stand-in of invite-delay.mjs, and records what each press sent.
#   1. boots a temporary multi-account installation with that binary;
#   2. saves the invitation page it answers (headers and bytes);
#   3. starts the stand-in on the next port, runs invite-press.mjs, and stops
#      both.
# usage: invite-press.sh BIN LABEL OUT PORT
#   PORT and PORT+1 are used. UX_SPACE names the task space of the browser
#   (default: masc account pages ux). The script ends with the status of the
#   measure, and writes the invitation page the server answered to
#   OUT/LABEL-invite-page.html.
set -u
BIN="$1"; LABEL="$2"; OUT="$3"; PORT="$4"
HERE="$(cd "$(dirname "$0")" && pwd)"
T="$OUT/run-$LABEL"
STAND_PORT=$((PORT + 1))
BASE="http://127.0.0.1:$STAND_PORT"
mkdir -p "$T"
BINARY="$(shasum -a 256 "$BIN" | cut -c1-12)"
# A stand-in left from a run before would answer in place of the new one.
if curl -s -m 1 -o /dev/null "$BASE/__stand_in"; then
  echo "port $STAND_PORT already answers; stop what listens there first" >&2
  exit 1
fi
STAND=""
# A job that a script starts in the background ignores Ctrl-C, so the script
# stops the stand-in and the server itself however it ends.
stop() {
  [ -n "$STAND" ] && kill "$STAND" 2>/dev/null
  pid="$(cat "$T/a/pid" 2>/dev/null)"
  [ -n "$pid" ] && kill -TERM "$pid" 2>/dev/null
}
trap stop EXIT INT TERM

sh "$HERE/ux-serve.sh" "$BIN" "$T/a" "$PORT"
curl -s -m 10 -D "$T/invite.hdr" -o "$T/invite.body" "http://127.0.0.1:$PORT/accounts/invite"
echo "saved: $(wc -c < "$T/invite.body" | tr -d ' ') bytes of /accounts/invite"
cp "$T/invite.body" "$OUT/$LABEL-invite-page.html"
node "$HERE/invite-delay.mjs" "$PORT" "$STAND_PORT" > "$T/stand-in.out" 2>&1 &
STAND=$!
curl -s -m 2 --retry 10 --retry-connrefused --retry-delay 1 -o /dev/null -w 'stand-in=%{http_code}\n' "$BASE/__stand_in"

python3 - "$HERE/invite-press.mjs" "${UX_SPACE:-masc account pages ux}" "$LABEL" "$OUT" "$BASE" "$BINARY" > "$T/run.mjs" <<'PY'
import json, pathlib, sys
path, space, label, out, base, binary = sys.argv[1:7]
script = pathlib.Path(path).read_text()
for key, value in (
    ("const SPACE = __SPACE__;", f"const SPACE = {json.dumps(space)};"),
    ('const LABEL = "__LABEL__";', f"const LABEL = {json.dumps(label)};"),
    ('const OUT = "__OUT__";', f"const OUT = {json.dumps(out)};"),
    ('const BASE = "__BASE__";', f"const BASE = {json.dumps(base)};"),
    ('const BINARY = "__BINARY__";', f"const BINARY = {json.dumps(binary)};"),
):
    assert script.count(key) == 1, key
    script = script.replace(key, value)
sys.stdout.write(script)
PY
ego-browser nodejs < "$T/run.mjs" > "$T/measure.out" 2>&1
measured=$?
echo "measure exit=$measured rows=$(grep -c '^{' "$T/measure.out")"

echo "stopping: server $(cat "$T/a/pid" 2>/dev/null), stand-in $STAND"
exit "$measured"
