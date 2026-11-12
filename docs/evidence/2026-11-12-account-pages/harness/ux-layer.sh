#!/bin/sh
# Measures the account pages one binary serves, in a real browser.
#   1. boots two temporary multi-account installations with that binary: one
#      with a GitHub login client, one without;
#   2. saves the pages the first one answers (headers and bytes);
#   3. serves those saved bytes through the JSON stand-in (ux-mock.mjs), so a
#      browser can show the signed-in states without a GitHub login;
#   4. serves one more copy whose policy names another style nonce: the
#      control that shows the measurement sees a refused sheet;
#   5. runs ux-measure3.mjs over every state and stops everything it started.
# usage: ux-layer.sh BIN LABEL OUT PORT [EXTRA_STATES_JSON]
#   PORT..PORT+3 are used. EXTRA_STATES_JSON adds [name, base, scenario, path]
#   rows; in it REAL, NOCLIENT and MOCK stand for the three bases.
set -u
BIN="$1"; LABEL="$2"; OUT="$3"; PORT="$4"; EXTRA="${5:-[]}"
HERE="$(cd "$(dirname "$0")" && pwd)"
T="$OUT/run"
REAL="http://127.0.0.1:$PORT"
NOCLIENT="http://127.0.0.1:$((PORT + 1))"
MOCK="http://127.0.0.1:$((PORT + 2))"
CONTROL="http://127.0.0.1:$((PORT + 3))"
mkdir -p "$T/pages" "$T/control"

sh "$HERE/ux-serve.sh" "$BIN" "$T/a" "$PORT"
sh "$HERE/ux-serve.sh" "$BIN" "$T/b" "$((PORT + 1))" no-client

for name in home invite; do
  path=/; [ "$name" = invite ] && path=/accounts/invite
  curl -s -m 10 -D "$T/pages/$name.hdr" -o "$T/pages/$name.body" "$REAL$path"
  cp "$T/pages/$name.body" "$T/control/$name.body"
  sed "s/style-src 'nonce-[0-9a-f]*'/style-src 'nonce-0000000000000000000000000000000000000000000000000000000000000000'/" \
    "$T/pages/$name.hdr" > "$T/control/$name.hdr"
done
echo "saved: $(grep -c . "$T/pages/home.hdr") header lines, $(wc -c < "$T/pages/home.body" | tr -d ' ') bytes of /"

node "$HERE/ux-mock.mjs" "$T/pages" "$((PORT + 2))" > "$T/mock.log" 2>&1 &
MOCK_PID=$!
node "$HERE/ux-mock.mjs" "$T/control" "$((PORT + 3))" > "$T/control.log" 2>&1 &
CONTROL_PID=$!
for base in "$MOCK" "$CONTROL"; do
  n=0
  until curl -s -m 2 -o /dev/null "$base/" || [ "$n" -ge 20 ]; do n=$((n + 1)); perl -e 'select(undef, undef, undef, 0.25)'; done
done

STATES=$(python3 - "$REAL" "$NOCLIENT" "$MOCK" "$CONTROL" "$EXTRA" <<'PY'
import json, sys
real, noclient, mock, control, extra = sys.argv[1:6]
token = "#example-invitation-token"
states = [
    ["home_signed_out", real, None, "/"],
    ["home_no_client", noclient, None, "/"],
    ["invite_token", real, None, "/accounts/invite" + token],
    ["invite_no_token", real, None, "/accounts/invite"],
    ["invite_no_client", noclient, None, "/accounts/invite" + token],
    ["member_new", mock, "member_new", "/"],
    ["member_full", mock, "member_full", "/"],
    ["admin_full", mock, "admin_full", "/"],
]
bases = {"REAL": real, "NOCLIENT": noclient, "MOCK": mock}
for name, base, scenario, path in json.loads(extra):
    states.append([name, bases.get(base, base), scenario, path])
states.append(["control_other_style_nonce", control, "signed_out", "/"])
print(json.dumps(states))
PY
)
python3 "$HERE/ux-run.py" "masc account pages ux" "$LABEL" "$OUT" "$STATES" > "$T/run.mjs"
ego-browser nodejs < "$T/run.mjs" > "$T/measure.out" 2>&1
echo "measure exit=$? rows=$(grep -c '^{' "$T/measure.out")"

kill -TERM "$MOCK_PID" "$CONTROL_PID" 2>/dev/null
for d in a b; do
  pid="$(cat "$T/$d/pid" 2>/dev/null)"
  [ -n "$pid" ] && kill -TERM "$pid" 2>/dev/null
done
echo "stopped: mocks $MOCK_PID $CONTROL_PID, servers $(cat "$T/a/pid" 2>/dev/null) $(cat "$T/b/pid" 2>/dev/null)"
