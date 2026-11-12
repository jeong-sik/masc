#!/bin/sh
# Boots a multi-account installation in a new empty directory on a loopback
# port, with an emptied environment and a GitHub login client that names a
# dummy client id. The first invitation link goes to a file and is not shown.
# usage: ux-serve.sh BIN T PORT [no-client]
#   no-client leaves the GitHub login client out of the configuration.
set -u
BIN="$1"; T="$2"; PORT="$3"; CLIENT="${4:-client}"
M="$T/multi"
mkdir -p "$T/home" "$T/tmp" "$M/base/.masc/auth" "$M/ext"
CONFIG="$M/base/.masc/auth/config.json"
echo "binary=$(shasum -a 256 "$BIN" | cut -c1-12) port=$PORT"
printf '%s\n' '{"enabled":true,"require_token":true,"account_mode":"Multi_account"}' > "$CONFIG"
env -i PATH="$PATH" HOME="$T/home" TMPDIR="$T/tmp" MASC_HTTP_BASE_URL="http://127.0.0.1:$PORT" \
  "$BIN" auth bootstrap --base-path "$M/base" --external-store "$M/ext/external.jsonl" > "$T/bootstrap.out" 2>&1
echo "bootstrap exit=$?"
[ "$CLIENT" = no-client ] || python3 - "$CONFIG" <<'PY'
import json, sys
path = sys.argv[1]
config = json.load(open(path))
config["github"] = {
    "client_id": "ux-harness-client-id",
    "redirect_uri": "https://masc.example/auth/github/callback",
    "client_secret_env": "MASC_UX_GITHUB_SECRET",
}
json.dump(config, open(path, "w"))
PY
perl -e 'alarm shift; exec @ARGV' 120 env -i PATH="$PATH" HOME="$T/home" TMPDIR="$T/tmp" MASC_HTTPS_PORT=0 \
  MASC_UX_GITHUB_SECRET=not-a-secret \
  "$BIN" restart --base-path "$M/base" --port "$PORT" --host 127.0.0.1 > "$T/restart.out" 2> "$T/restart.err" < /dev/null
echo "restart exit=$?"
sed -n 's/^Started pid \([0-9][0-9]*\)\..*/\1/p' "$T/restart.out" | head -1 > "$T/pid"
echo "pid=$(cat "$T/pid")"
curl -s -m 10 -o /dev/null -w 'ready=%{http_code}\n' "http://127.0.0.1:$PORT/health/ready"
