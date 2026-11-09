# /// script
# requires-python = ">=3.11"
# dependencies = ["httpx[http2]==0.28.1"]
# ///
"""HTTP/1.1 control: SSE connections that the client closes, against an owned masc server.

Opens N HTTP/1.1 connections to an SSE route, reads the status line, closes the
socket, and checks the listener's active connections and the server's
descriptors right after and after one SSE ping interval.
"""
from __future__ import annotations

import argparse
import json
import socket
import subprocess
import sys
import time
from pathlib import Path

import httpx

PING_S = 30.0


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--repo", type=Path, required=True)
    ap.add_argument("--binary", type=Path, required=True)
    ap.add_argument("--out", type=Path, required=True)
    ap.add_argument("--connections", type=int, default=2000)
    args = ap.parse_args()
    sys.path.insert(0, str(args.repo / "scripts/harness/perf"))
    import http_multiplex_probe as hmp

    args.out.mkdir(parents=True, exist_ok=True)
    with hmp.OwnedServer(args.binary, args.repo, args.out, None, None) as server:
        base, pid, port = server.base_url, server.process.pid, server.port
        token = hmp.dev_token(base)
        http = httpx.Client(timeout=30, headers={"authorization": f"Bearer {token}"} if token else {})

        def sample(label: str) -> dict:
            h = http.get(base + "/health").json()
            out = subprocess.run(["lsof", "-n", "-P", "-p", str(pid)], capture_output=True, text=True).stdout
            rec = {"label": label, "http_active": h["http_listener"]["active_connections"],
                   "rss_mb": round(h["process_memory"]["resident_bytes"] / 1e6, 1),
                   "live_mb": round(h["gc"]["live_words"] * 8 / 1e6, 1), "fds": max(0, out.count("\n") - 1)}
            print(json.dumps(rec), flush=True)
            return rec

        sample("cold")
        results: dict[str, dict[str, int]] = {}
        for path in ("/api/v1/stream/fleet", "/api/v1/dashboard/logs/stream"):
            statuses: dict[str, int] = {}
            for _ in range(args.connections):
                s = socket.create_connection(("127.0.0.1", port), timeout=10)
                auth = f"authorization: Bearer {token}\r\n" if token else ""
                s.sendall(f"GET {path} HTTP/1.1\r\nHost: 127.0.0.1:{port}\r\nAccept: text/event-stream\r\n{auth}\r\n".encode())
                head = s.recv(4096).split(b"\r\n", 1)[0].decode(errors="replace")
                statuses[head] = statuses.get(head, 0) + 1
                s.close()
            results[path] = statuses
            print(json.dumps({path: statuses}), flush=True)
            sample(f"after-{path.rsplit('/', 1)[-1]}-0s")
            time.sleep(PING_S + 5)
            sample(f"after-{path.rsplit('/', 1)[-1]}-35s")
        (args.out / "h1.json").write_text(json.dumps(results, indent=1) + "\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
