#!/usr/bin/env python3
"""Which `Public_read` registrations strict auth leaves open (A4d back half).

  python3 -I public_read_open_in_strict.py <repo>

Reads every `Server_route.<fn> <kind> <path>` registration in <repo>/lib/server
whose kind is `Public_read` or `Public_read_on_canonical_host`, and applies the
rules of `Server_auth.is_public_read_path` to its path. Under strict auth
`with_public_read` opens a request only when that function holds for its path,
so a registration is open when the function holds for its exact path, or for
every path under its prefix. The rules are copied from main 82ef0dcb730
(`lib/server/server_auth.ml` `is_public_read_path`, `Server_health_paths`);
the play page, the agent guide and the health paths are registered
`Always_public` and do not reach `with_public_read`.
"""

import os
import re
import sys

REGISTRATION = re.compile(
    r'Server_route\.(get|post|add|prefix_get|prefix_post|prefix_put|prefix_delete)\s+\(?\s*'
    r'(Server_route\.Public_read(?:_on_canonical_host\s*\{[^}]*\})?)\s*\)?\s+(?:~path:)?\s*'
    r'("[^"]*"|[A-Z][\w.]*|[a-z_]\w*)',
    re.S,
)
# Path constants a registration names, with their values at 82ef0dcb730.
CONSTANTS = {
    "board_sub_board_detail_prefix": "/api/v1/board/sub-boards/",
    "Fleet_stream.stream_path": "/api/v1/stream/fleet",
    "stream_path": "/api/v1/dashboard/logs/stream",
    "repositories_prefix": "/api/v1/repositories/",
    "Server_dashboard_fusion_run_projection.detail_prefix": "/api/v1/dashboard/fusion-runs/",
    "Masc_network_defaults.voice_audio_path_prefix": "/api/v1/voice/audio/",
}
EXACT = {
    "/health", "/api/v1/gate/health", "/api/v1/gate/status", "/api/v1/gate/connectors",
    "/api/v1/gate/connector/status", "/api/v1/gate/events", "/", "/dashboard", "/dashboard/",
    "/favicon.ico", "/favicon.svg", "/play", "/play/agent.md", "/api/v1/msx/carts",
}
PREFIXES = ["/dashboard/", "/static/", "/graphiql/", "/api/v1/voice/audio/"]
VALID_ID_ONLY = "/api/v1/published-artifacts/"


def blank_comments(text):
    """Comments become spaces, newlines kept, so offsets and lines stay."""
    return re.sub(r'\(\*.*?\*\)', lambda m: re.sub(r'[^\n]', ' ', m.group(0)), text, flags=re.S)


def verdict(fn, path):
    if not fn.startswith("prefix_"):
        return "open" if path in EXACT or any(path.startswith(p) for p in PREFIXES) else None
    if any(path.startswith(p) for p in PREFIXES):
        return "open under the whole prefix"
    if path == VALID_ID_ONLY:
        return "open for a well-formed artifact id"
    if any(e.startswith(path) for e in EXACT) or any(p.startswith(path) for p in PREFIXES):
        return "open under part of the prefix"
    return None


def main(repo):
    server = os.path.join(repo, "lib", "server")
    rows, mentions = [], 0
    for name in sorted(os.listdir(server)):
        if not name.endswith(".ml"):
            continue
        text = blank_comments(open(os.path.join(server, name), encoding="utf-8").read())
        mentions += len(re.findall(r'Server_route\.Public_read', text))
        for m in REGISTRATION.finditer(text):
            token = m.group(3)
            if not token.startswith('"') and token not in CONSTANTS:
                sys.exit(f"{name}: the path {token} is not a known constant")
            path = CONSTANTS.get(token, token.strip('"'))
            line = text.count("\n", 0, m.start()) + 1
            rows.append((name, line, m.group(1), re.sub(r"\s+", " ", m.group(2)), path))
    if len(rows) != mentions:
        sys.exit(f"read {len(rows)} registrations but Server_route.Public_read appears {mentions} times")
    opened = [(r, v) for r in rows for v in [verdict(r[2], r[4])] if v]
    print(f"Public_read registrations: {len(rows)}; open under strict auth: {len(opened)}")
    for (name, line, fn, kind, path), v in opened:
        print(f"  {fn:10} {path:32} {kind.removeprefix('Server_route.'):40} {name}:{line}  {v}")


if __name__ == "__main__":
    main(sys.argv[1])
