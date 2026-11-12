#!/bin/sh
# Opens invitation links in one tab of a real browser, against the account
# server of one binary, and records what the page shows after each step.
#   1. boots a temporary multi-account installation with that binary;
#   2. saves the invitation page it answers (headers and bytes);
#   3. runs invite-reopen.mjs and stops the server.
# usage: invite-reopen.sh BIN LABEL OUT PORT
set -u
BIN="$1"; LABEL="$2"; OUT="$3"; PORT="$4"
HERE="$(cd "$(dirname "$0")" && pwd)"
T="$OUT/run-$LABEL"
BASE="http://127.0.0.1:$PORT"
mkdir -p "$T"

sh "$HERE/ux-serve.sh" "$BIN" "$T/a" "$PORT"
curl -s -m 10 -D "$T/invite.hdr" -o "$T/invite.body" "$BASE/accounts/invite"
echo "saved: $(wc -c < "$T/invite.body" | tr -d ' ') bytes of /accounts/invite"

python3 - "$HERE/invite-reopen.mjs" "masc account pages ux" "$LABEL" "$OUT" "$BASE" > "$T/run.mjs" <<'PY'
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

pid="$(cat "$T/a/pid" 2>/dev/null)"
[ -n "$pid" ] && kill -TERM "$pid" 2>/dev/null
echo "stopped: server $pid"
