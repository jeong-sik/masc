#!/usr/bin/env bash
# The turn-records response key set, as the server writes it and as the
# dashboard accepts it, must be the same set.
#
# The decoder calls hasExactKeys: a response carrying one key the allowlist
# does not name decodes to null, and the turn-records and Memory OS panels
# render "유효하지 않은 keeper turn record payload" instead of anything. It has
# happened twice — four wire fields (#26799) and the three live_turn_* fields
# (#28216) — and both times the repair was to add the missing key afterwards.
# dashboard/docs/API_CONTRACT.md already says the two must land together; this
# is what makes that true rather than written down (#28394).
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

server="lib/server/server_dashboard_http_keeper_api.ml"
client="dashboard/src/api/dashboard-turn-records.ts"

for f in "$server" "$client"; do
  [ -f "$f" ] || { echo "[turn-records-envelope] FAIL - missing $f"; exit 2; }
done

python3 - "$server" "$client" <<'PY'
import re, sys

server_path, client_path = sys.argv[1:3]
server = open(server_path, encoding="utf-8").read()
client = open(client_path, encoding="utf-8").read()

begin = "turn-records envelope: keys begin"
end = "turn-records envelope: keys end"
if begin not in server or end not in server:
    print(
        "[turn-records-envelope] FAIL - the anchors are gone from %s.\n"
        "  The response literal has to stay between\n"
        "    (* %s ... *)\n"
        "  and\n"
        "    (* %s *)\n"
        "  or this check cannot find it." % (server_path, begin, end)
    )
    sys.exit(2)

block = server[server.index(begin) : server.index(end)]
# One key per element: ("name", ...  — the opening paren may be on its own line.
server_keys = set(re.findall(r'\(\s*"([a-z0-9_]+)"\s*,', block))

# The file has several hasExactKeys calls; anchor on the decoder that owns this
# envelope rather than taking whichever one comes first.
decoder = "function decodeTurnRecordsResponse"
if decoder not in client:
    print("[turn-records-envelope] FAIL - no %s in %s" % (decoder, client_path))
    sys.exit(2)
m = re.search(
    r"hasExactKeys\(raw,\s*\[(.*?)\]\)", client[client.index(decoder) :], re.S
)
if not m:
    print(
        "[turn-records-envelope] FAIL - no hasExactKeys allowlist inside %s"
        % decoder
    )
    sys.exit(2)
client_keys = set(re.findall(r"'([a-z0-9_]+)'", m.group(1)))

only_server = sorted(server_keys - client_keys)
only_client = sorted(client_keys - server_keys)

if only_server or only_client:
    print("[turn-records-envelope] FAIL - the two key sets differ")
    if only_server:
        print(
            "  the server sends these and the decoder rejects the whole payload "
            "for them:\n    %s" % "\n    ".join(only_server)
        )
    if only_client:
        print(
            "  the decoder requires these and the server does not send them:\n"
            "    %s" % "\n    ".join(only_client)
        )
    print(
        "  Both sides land together — dashboard/docs/API_CONTRACT.md, #28394."
    )
    sys.exit(2)

print(
    "[turn-records-envelope] OK - %d keys, server and dashboard agree"
    % len(server_keys)
)
PY
