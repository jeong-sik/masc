# /// script
# requires-python = ">=3.11"
# dependencies = ["httpx[http2]==0.28.1"]
# ///
"""Can one HTTP/2 client that does not read make other connections get 503?

The HTTPS listener's response ledger (64 MiB by default) is shared by every h2
connection of that listener. A "slow" client opens S streams for the dashboard
bundle and never sends WINDOW_UPDATE, so the server can send only the initial
65,535-byte connection window and keeps the rest reserved. Meanwhile a second,
normal h2 connection asks for the bundle and for /health. Then the slow client
closes and the normal one asks again.
"""
from __future__ import annotations

import argparse
import json
import sys
import time
from pathlib import Path

import h2.config
import h2.connection

sys.path.insert(0, str(Path(__file__).resolve().parent))
from h2_sse_leak_probe import H2Conn  # noqa: E402


class SlowConn(H2Conn):
    """An h2 client that keeps the default windows and never acknowledges data."""

    def __init__(self, port: int) -> None:  # noqa: D107
        import socket, ssl  # noqa: E401
        sock = socket.create_connection(("127.0.0.1", port), timeout=10)
        ctx = ssl.create_default_context()
        ctx.check_hostname, ctx.verify_mode = False, ssl.CERT_NONE
        ctx.set_alpn_protocols(["h2"])
        self.sock = ctx.wrap_socket(sock, server_hostname="127.0.0.1")
        self.conn = h2.connection.H2Connection(h2.config.H2Configuration(client_side=True, header_encoding="utf-8"))
        self.conn.initiate_connection()
        self.scheme, self.authority = "https", f"127.0.0.1:{port}"
        self.status, self.server_reset = {}, set()
        self.flush()

    def pump(self, done, timeout: float) -> bool:
        import socket
        import h2.events
        deadline = time.monotonic() + timeout
        while not done() and time.monotonic() < deadline:
            self.sock.settimeout(max(0.05, deadline - time.monotonic()))
            try:
                data = self.sock.recv(65536)
            except (socket.timeout, TimeoutError):
                break
            if not data:
                raise ConnectionError("closed")
            for ev in self.conn.receive_data(data):
                if isinstance(ev, h2.events.ResponseReceived):
                    self.status[ev.stream_id] = int(dict(ev.headers)[":status"])
                elif isinstance(ev, h2.events.StreamReset):
                    self.server_reset.add(ev.stream_id)
            self.flush()
        return done()


def count(conn: H2Conn, sids: list[int]) -> dict[str, int]:
    out: dict[str, int] = {}
    for s in sids:
        k = str(conn.status.get(s, "none"))
        out[k] = out.get(k, 0) + 1
    return out


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--repo", type=Path, required=True)
    ap.add_argument("--binary", type=Path, required=True)
    ap.add_argument("--assets", type=Path, required=True)
    ap.add_argument("--out", type=Path, required=True)
    ap.add_argument("--slow-streams", type=int, default=90)
    args = ap.parse_args()
    sys.path.insert(0, str(args.repo / "scripts/harness/perf"))
    import http_multiplex_probe as hmp
    import httpx

    args.out.mkdir(parents=True, exist_ok=True)
    bundles = sorted((args.assets / "dashboard/assets").glob("index-*.js"), key=lambda p: p.stat().st_size, reverse=True)
    result: dict = {}
    with hmp.OwnedServer(args.binary, args.repo, args.out, None, args.assets) as server:
        bundle = next(f"/dashboard/assets/{b.name}" for b in bundles
                      if httpx.get(f"{server.base_url}/dashboard/assets/{b.name}").status_code == 200)
        result["build"] = httpx.get(server.base_url + "/health").json()["build"]["commit"][:12]
        result["bundle_bytes"] = len(httpx.get(server.base_url + bundle).content)

        def normal_round(label: str) -> None:
            n = H2Conn(server.https_port, tls=True)
            big = [n.open(bundle, []) for _ in range(3)]
            small = [n.open("/health", []) for _ in range(3)]
            n.pump(lambda: all(s in n.status for s in big + small), 20)
            result[label] = {"bundle": count(n, big), "health": count(n, small)}
            n.sock.close()

        normal_round("normal_before")
        slow = SlowConn(server.https_port)
        sids = [slow.open(bundle, []) for _ in range(args.slow_streams)]
        slow.pump(lambda: all(s in slow.status for s in sids), 20)
        result["slow_client"] = {"streams": args.slow_streams, "statuses": count(slow, sids),
                                 "server_reset": len(slow.server_reset)}
        time.sleep(1)
        normal_round("normal_while_slow_client_holds")
        time.sleep(5)
        normal_round("normal_while_slow_client_holds_5s_later")
        slow.sock.close()
        time.sleep(1)
        normal_round("normal_after_slow_client_left")
    (args.out / "ledger.json").write_text(json.dumps(result, indent=1) + "\n")
    print(json.dumps(result, indent=1), flush=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
