#!/usr/bin/env python3
"""Auth baseline probe, the paths the router table does not own (plan layer A1).

`/mcp` and its profiles are handled before the router, the H2 gateway has its own
match, and `/ws` and `/api/v1/ide/lsp` upgrade the connection. This sends each a
request with no credential, a bearer that matches no token, and (for the
query-token paths) a bad `token` query, then records status, the
`WWW-Authenticate` header and the first bytes of the body. It also repeats a few
public reads with a `Host` header that is not the server's own, to see whether the
answer depends on the authority, and records which keys the loopback dev-token
answer carries (key paths and the `role` and `actor` values only, never the token).

Point `--base-url` only at an isolated server (see run.sh).
"""

from __future__ import annotations

import argparse
import json
import subprocess
from dataclasses import dataclass
from pathlib import Path

BAD_BEARER = "masc-a1-probe-token-that-matches-nothing"
INIT = json.dumps(
    {"jsonrpc": "2.0", "id": 1, "method": "initialize",
     "params": {"protocolVersion": "2025-11-25", "capabilities": {},
                "clientInfo": {"name": "a1-probe", "version": "0"}}}
)
FOREIGN_HOST = "masc-a1-foreign.example"
QUERY_TOKEN_PATHS = ("/events/presence", "/api/v1/ide/lsp", "/ws")
DEV_TOKEN_PATH = "/api/v1/dashboard/dev-token"
# Values of these keys are safe to record; every other value in the answer may be a credential.
RECORDED_VALUE_KEYS = ("role", "actor")
WS_HEADERS = [
    "Connection: Upgrade", "Upgrade: websocket", "Sec-WebSocket-Version: 13",
    "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==",
]


@dataclass(frozen=True, slots=True)
class Case:
    label: str
    method: str
    path: str
    headers: tuple[str, ...] = ()
    body: str | None = None


def cases() -> list[Case]:
    mcp_headers = ("Content-Type: application/json", "Accept: application/json, text/event-stream",
                   "MCP-Protocol-Version: 2025-11-25")
    out: list[Case] = []
    for path in ("/mcp", "/mcp/managed", "/mcp/operator", "/mcp/seat"):
        out.append(Case(f"POST {path} initialize", "POST", path, mcp_headers, INIT))
        out.append(Case(f"GET {path} stream", "GET", path, ("Accept: text/event-stream",)))
        out.append(Case(f"DELETE {path}", "DELETE", path, mcp_headers))
    out.append(Case("GET /mcp observer stream", "GET", "/mcp?sse_kind=observer", ("Accept: text/event-stream",)))
    out.append(Case("GET /events/presence", "GET", "/events/presence", ("Accept: text/event-stream",)))
    out.append(Case("GET /ws upgrade", "GET", "/ws", tuple(WS_HEADERS)))
    out.append(Case("GET /api/v1/ide/lsp upgrade", "GET", "/api/v1/ide/lsp", tuple(WS_HEADERS)))
    out.append(Case("GET /api/v1/dashboard/namespace-truth", "GET", "/api/v1/dashboard/namespace-truth"))
    return out


def run(base_url: str, protocol: str, case: Case, credential: str, host: str | None, timeout_s: int) -> dict[str, object]:
    path = case.path
    if credential == "bad_query" and ("observer" in path or path in QUERY_TOKEN_PATHS):
        path += ("&" if "?" in path else "?") + f"token={BAD_BEARER}"
    elif credential == "bad_query":
        return {"skipped": True}
    cmd = ["curl", "-s", "-i", "-m", str(timeout_s), "--connect-timeout", "2", "-X", case.method]
    if protocol == "h2":
        cmd.append("--http2-prior-knowledge")
    for header in case.headers:
        cmd += ["-H", header]
    if credential == "bad":
        cmd += ["-H", f"Authorization: Bearer {BAD_BEARER}"]
    if host is not None:
        cmd += ["-H", f"Host: {host}"]
    if case.body is not None:
        cmd += ["-d", case.body]
    cmd.append(base_url + path)
    try:
        raw = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout_s + 3).stdout
    except subprocess.TimeoutExpired:
        return {"status": 0}
    head, _, body = raw.partition("\r\n\r\n")
    lines = head.splitlines()
    status = int(lines[0].split()[1]) if lines and lines[0].split()[1:2] and lines[0].split()[1].isdigit() else 0
    challenge = next((l.split(":", 1)[1].strip() for l in lines[1:] if l.lower().startswith("www-authenticate:")), None)
    return {"status": status, "www_authenticate": challenge, "body_head": body[:140].replace("\n", " ")}


def key_paths(node: object, prefix: str = "") -> list[str]:
    """Dotted paths of every key in a parsed JSON value; values are not recorded."""
    if not isinstance(node, dict):
        return []
    paths: list[str] = []
    for key, value in node.items():
        path = f"{prefix}.{key}" if prefix else str(key)
        paths.append(path)
        paths.extend(key_paths(value, path))
    return paths


def recorded_values(node: object, prefix: str = "") -> dict[str, str]:
    """String values of the keys in RECORDED_VALUE_KEYS, wherever they appear."""
    if not isinstance(node, dict):
        return {}
    found: dict[str, str] = {}
    for key, value in node.items():
        path = f"{prefix}.{key}" if prefix else str(key)
        if key in RECORDED_VALUE_KEYS and isinstance(value, str):
            found[path] = value
        found.update(recorded_values(value, path))
    return found


def dev_token_shape(base_url: str, protocol: str, timeout_s: int) -> dict[str, object]:
    """Status and body shape of the dev-token answer, without any credential in the request."""
    cmd = ["curl", "-s", "-m", str(timeout_s), "--connect-timeout", "2", "-w", "\n%{http_code}"]
    if protocol == "h2":
        cmd.append("--http2-prior-knowledge")
    cmd.append(base_url + DEV_TOKEN_PATH)
    try:
        raw = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout_s + 3).stdout
    except subprocess.TimeoutExpired:
        return {"status": 0}
    body, _, status_text = raw.rpartition("\n")
    status = int(status_text) if status_text.isdigit() else 0
    try:
        parsed = json.loads(body)
    except json.JSONDecodeError:
        return {"status": status, "json": False}
    return {"status": status, "json": True, "keys": sorted(key_paths(parsed)),
            "values": recorded_values(parsed)}


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--base-url", required=True)
    ap.add_argument("--out", type=Path, required=True)
    ap.add_argument("--timeout", type=int, default=3)
    args = ap.parse_args()

    rows: list[dict[str, object]] = []
    for case in cases():
        for protocol in ("http1", "h2"):
            if protocol == "h2" and "upgrade" in case.label:
                continue
            for credential in ("none", "bad", "bad_query"):
                result = run(args.base_url, protocol, case, credential, None, args.timeout)
                if result.get("skipped"):
                    continue
                rows.append({"case": case.label, "protocol": protocol, "credential": credential, **result})
    # The same public reads and one mutating call with a Host that is not the server's own.
    foreign = [
        Case("GET /health", "GET", "/health"),
        Case("GET /api/v1/dashboard/shell", "GET", "/api/v1/dashboard/shell"),
        Case("GET /api/v1/board", "GET", "/api/v1/board"),
        Case("POST /mcp initialize", "POST", "/mcp",
             ("Content-Type: application/json", "Accept: application/json, text/event-stream",
              "MCP-Protocol-Version: 2025-11-25"), INIT),
    ]
    for case in foreign:
        for credential in ("none", "bad"):
            result = run(args.base_url, "http1", case, credential, FOREIGN_HOST, args.timeout)
            rows.append({"case": case.label + f" [Host: {FOREIGN_HOST}]", "protocol": "http1",
                         "credential": credential, **result})

    dev_token = {protocol: dev_token_shape(args.base_url, protocol, args.timeout)
                 for protocol in ("http1", "h2")}

    args.out.mkdir(parents=True, exist_ok=True)
    (args.out / "extra.json").write_text(json.dumps({"rows": rows, "dev_token": dev_token}, ensure_ascii=False, indent=1) + "\n", encoding="utf-8")
    print(json.dumps({"extra_rows": len(rows)}))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
