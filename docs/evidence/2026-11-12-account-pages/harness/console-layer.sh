#!/bin/sh
# Measures the console of a signed-in person as one binary serves it, in a
# real browser.
#   1. boots two temporary multi-account installations with that binary: one
#      whose dashboard bundle holds the build of the console (ASSETS), one
#      whose bundle is an empty directory;
#   2. asks both for the routes of the console over HTTP and writes down what
#      they answer (console-answers.py);
#   3. saves what the first one answers at the address of the console, of its
#      base sheet, of every file its page names and of its home page (headers
#      and bytes);
#   4. serves those saved bytes through console-mock.mjs, which plays the
#      session routes, so a browser can show the console of a signed-in
#      person without a GitHub login;
#   5. runs ux-measure3.mjs over every state and stops everything it started.
# usage: console-layer.sh BIN LABEL OUT PORT ASSETS [SET]
#   PORT..PORT+2 are used. ASSETS is the directory that holds dashboard/, as
#   the assets directory of a checkout whose dashboard was built does.
#   SET picks the states of a signed-in person: `frame` (the default; the
#   frame of the console, console/README.md and frame/README.md) or `panel`
#   (the subscriptions panel, panel/README.md).
#   UX_SPACE names the task space of the browser (default: masc account pages ux).
set -u
BIN="$1"; LABEL="$2"; OUT="$3"; PORT="$4"; ASSETS="$5"; SET="${6:-frame}"
case "$SET" in
  frame|panel) ;;
  *) echo "SET is frame or panel, not $SET" >&2; exit 2 ;;
esac
HERE="$(cd "$(dirname "$0")" && pwd)"
T="$OUT/run"
REAL="http://127.0.0.1:$PORT"
NOBUNDLE="http://127.0.0.1:$((PORT + 1))"
MOCK="http://127.0.0.1:$((PORT + 2))"
mkdir -p "$T/files" "$T/no-bundle/dashboard"

UX_SERVE_ENV="MASC_ASSETS_DIR=$ASSETS" sh "$HERE/ux-serve.sh" "$BIN" "$T/a" "$PORT"
UX_SERVE_ENV="MASC_ASSETS_DIR=$T/no-bundle" sh "$HERE/ux-serve.sh" "$BIN" "$T/b" "$((PORT + 1))"

python3 "$HERE/console-answers.py" "$REAL" "$NOBUNDLE" > "$OUT/$LABEL-answers.json"
echo "answers: $(grep -c '"path"' "$OUT/$LABEL-answers.json") rows"

save() { curl -s -m 10 -D "$T/files/$1.hdr" -o "$T/files/$1.body" "$REAL$2"; }
save console /accounts/console
save base /accounts/console/base.css
save home /
python3 - "$T/files" <<'PY' > "$T/files/names.txt"
import json, pathlib, re, sys
files = pathlib.Path(sys.argv[1])
page = (files / "console.body").read_text()
routes = {"/accounts/console": "console", "/accounts/console/base.css": "base", "/": "home"}
named = sorted(set(re.findall(r'"(/accounts/console/assets/[^"]+)"', page)))
for index, address in enumerate(named):
    routes[address] = f"asset-{index}"
    print(f"asset-{index} {address}")
(files / "routes.json").write_text(json.dumps(routes, indent=2) + "\n")
PY
while read -r name address; do save "$name" "$address"; done < "$T/files/names.txt"
echo "saved: $(wc -l < "$T/files/names.txt" | tr -d ' ') files of the build, $(wc -c < "$T/files/console.body" | tr -d ' ') bytes of the page"

node "$HERE/console-mock.mjs" "$T/files" "$((PORT + 2))" > "$T/mock.log" 2>&1 &
MOCK_PID=$!
n=0
until curl -s -m 2 -o /dev/null "$MOCK/" || [ "$n" -ge 20 ]; do n=$((n + 1)); perl -e 'select(undef, undef, undef, 0.25)'; done

STATES=$(python3 - "$REAL" "$NOBUNDLE" "$MOCK" "$SET" <<'PY'
import json, sys
real, nobundle, mock, which = sys.argv[1:5]
console = "/accounts/console"
signed_in = {
    "frame": [
        ["console_member", mock, "member", console],
        ["console_admin", mock, "admin", console],
        ["console_session_unread", mock, "session_unread", console],
        ["console_account_changed", mock, "account_changed", console],
        ["control_no_style_source", mock, "member", console + "?control"],
    ],
    "panel": [
        ["panel_none", mock, "member_panel_none", console],
        ["panel_each", mock, "member_panel_each", console],
        ["panel_each_admin", mock, "admin_panel_each", console],
        ["panel_unread", mock, "member_panel_unread", console],
        ["control_no_style_source", mock, "member_panel_each", console + "?control"],
    ],
}
print(json.dumps([
    ["console_signed_out", real, None, console],
    ["console_no_bundle", nobundle, None, console],
] + signed_in[which]))
PY
)
python3 "$HERE/ux-run.py" "${UX_SPACE:-masc account pages ux}" "$LABEL" "$OUT" "$STATES" > "$T/run.mjs"
ego-browser nodejs < "$T/run.mjs" > "$T/measure.out" 2>&1
echo "measure exit=$? rows=$(grep -c '^{' "$T/measure.out")"

kill -TERM "$MOCK_PID" 2>/dev/null
for d in a b; do
  pid="$(cat "$T/$d/pid" 2>/dev/null)"
  [ -n "$pid" ] && kill -TERM "$pid" 2>/dev/null
done
echo "stopped: mock $MOCK_PID, servers $(cat "$T/a/pid" 2>/dev/null) $(cat "$T/b/pid" 2>/dev/null)"
