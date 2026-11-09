# /// script
# requires-python = ">=3.11"
# dependencies = ["httpx[http2]==0.28.1"]
# ///
"""Do SSE streams that an HTTP/2 peer resets leave anything behind on the server?

Starts an owned masc server (the bench's OwnedServer: fresh base path, loopback
ports, no keepers, gRPC and WS off, TLS listener on a free port) and keeps one
TLS h2 connection open the way cloudflared does. Each round opens K SSE streams
on that connection, waits for their response headers, then sends RST_STREAM
(CANCEL) for all of them. Between scenarios it reads /health (GC words, resident
bytes, listener connection counts, MCP SSE client count) and the server's open
descriptors. Controls: connection churn, TLS handshake failures, HTTP/1.1.
"""
from __future__ import annotations

import argparse
import json
import socket
import ssl
import subprocess
import sys
import time
from pathlib import Path

import h2.config
import h2.connection
import h2.errors
import h2.events
import h2.exceptions
import httpx

FLEET = "/api/v1/stream/fleet"
LOGS = "/api/v1/dashboard/logs/stream"
PING_S = 30.0  # sse_ping_interval_s: direct producers notice a gone client at their next ping


class H2Conn:
    def __init__(self, port: int, tls: bool) -> None:
        sock = socket.create_connection(("127.0.0.1", port), timeout=10)
        if tls:
            ctx = ssl.create_default_context()
            ctx.check_hostname = False
            ctx.verify_mode = ssl.CERT_NONE
            ctx.set_alpn_protocols(["h2"])
            sock = ctx.wrap_socket(sock, server_hostname="127.0.0.1")
            if sock.selected_alpn_protocol() != "h2":
                raise SystemExit(f"ALPN chose {sock.selected_alpn_protocol()!r}, not h2")
        self.sock = sock
        self.conn = h2.connection.H2Connection(h2.config.H2Configuration(client_side=True, header_encoding="utf-8"))
        self.conn.initiate_connection()
        self.conn.increment_flow_control_window(2**31 - 1 - 65535)
        self.scheme, self.authority = ("https" if tls else "http"), f"127.0.0.1:{port}"
        self.status: dict[int, int] = {}
        self.server_reset: set[int] = set()
        self.flush()
        self.pump(lambda: False, 0.3)

    def flush(self) -> None:
        data = self.conn.data_to_send()
        if data:
            self.sock.sendall(data)

    def open(self, path: str, headers: list[tuple[str, str]]) -> int:
        sid = self.conn.get_next_available_stream_id()
        self.conn.send_headers(sid, [(":method", "GET"), (":path", path), (":scheme", self.scheme),
                                     (":authority", self.authority), ("accept", "text/event-stream"), *headers],
                               end_stream=True)
        self.flush()
        return sid

    def pump(self, done, timeout: float) -> bool:
        deadline = time.monotonic() + timeout
        while not done() and time.monotonic() < deadline:
            self.sock.settimeout(max(0.05, deadline - time.monotonic()))
            try:
                data = self.sock.recv(65536)
            except (socket.timeout, TimeoutError):
                break
            if not data:
                raise ConnectionError("server closed the long-lived connection")
            for ev in self.conn.receive_data(data):
                if isinstance(ev, h2.events.ResponseReceived):
                    self.status[ev.stream_id] = int(dict(ev.headers)[":status"])
                elif isinstance(ev, h2.events.DataReceived):
                    try:
                        self.conn.acknowledge_received_data(ev.flow_controlled_length, ev.stream_id)
                    except h2.exceptions.StreamClosedError:
                        pass
                elif isinstance(ev, h2.events.StreamReset):
                    self.server_reset.add(ev.stream_id)
                elif isinstance(ev, h2.events.ConnectionTerminated):
                    raise ConnectionError(f"GOAWAY error_code={ev.error_code}")
            self.flush()
        return done()

    def reset(self, sids: list[int]) -> None:
        for sid in sids:
            try:
                self.conn.reset_stream(sid, error_code=h2.errors.ErrorCodes.CANCEL)
            except h2.exceptions.StreamClosedError:
                pass
        self.flush()
        self.pump(lambda: False, 0.05)


def churn(conn: H2Conn, path: str, headers_for, rounds: int, k: int) -> dict:
    statuses: dict[int, int] = {}
    started = time.monotonic()
    for _ in range(rounds):
        sids = [conn.open(path, headers_for(i)) for i in range(k)]
        conn.pump(lambda: all(s in conn.status for s in sids), 15)
        for s in sids:
            code = conn.status.get(s, 0)
            statuses[code] = statuses.get(code, 0) + 1
        conn.reset(sids)
    return {"path": path, "streams": rounds * k, "statuses": statuses, "seconds": round(time.monotonic() - started, 1)}


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--repo", type=Path, required=True)
    ap.add_argument("--binary", type=Path, required=True)
    ap.add_argument("--out", type=Path, required=True)
    ap.add_argument("--rounds", type=int, default=50)
    ap.add_argument("--per-round", type=int, default=90)
    args = ap.parse_args()
    sys.path.insert(0, str(args.repo / "scripts/harness/perf"))
    import http_multiplex_probe as hmp

    args.out.mkdir(parents=True, exist_ok=True)
    samples = (args.out / "samples.jsonl").open("w")
    runs: list[dict] = []
    t0 = time.monotonic()
    with hmp.OwnedServer(args.binary, args.repo, args.out, None, None) as server:
        base, pid = server.base_url, server.process.pid
        token = hmp.dev_token(base)
        auth = [("authorization", f"Bearer {token}")] if token else []
        http = httpx.Client(timeout=30, headers=dict(auth))

        def lsof_count(*extra: str) -> int:
            out = subprocess.run(["lsof", "-n", "-P", "-a", "-p", str(pid), *extra], capture_output=True, text=True).stdout
            return max(0, out.count("\n") - 1)

        def drive_gc() -> None:
            for _ in range(40):
                http.get(base + "/api/v1/openapi.json")

        def sample(label: str) -> dict:
            drive_gc()
            h = http.get(base + "/health").json()
            g, https, h1 = h["gc"], h.get("https_listener", {}), h.get("http_listener", {})
            rec = {"label": label, "t_s": round(time.monotonic() - t0, 1),
                   "live_mb": round(g["live_words"] * 8 / 1e6, 1), "heap_mb": round(g["heap_words"] * 8 / 1e6, 1),
                   "rss_mb": round(h.get("process_memory", {}).get("resident_bytes", 0) / 1e6, 1),
                   "major": g["major_collections"], "http_active": h1.get("active_connections"),
                   "https_active": https.get("active_connections"), "https_accepted": https.get("accepted_total"),
                   "tls_handshake_failures": https.get("handshake_failures_total"),
                   "sse_clients": h.get("sse_clients"), "fds": lsof_count(), "tcp_fds": lsof_count("-iTCP")}
            samples.write(json.dumps(rec) + "\n")
            samples.flush()
            print(json.dumps(rec), flush=True)
            return rec

        info = {"build": http.get(base + "/health").json().get("build", {}).get("commit", "?")[:12],
                "openapi_bytes": len(http.get(base + "/api/v1/openapi.json").content), "token": bool(token)}
        print(json.dumps(info), flush=True)
        sample("cold")
        tls = H2Conn(server.https_port, tls=True)
        no_extra = lambda _i: auth  # noqa: E731
        runs.append({"warmup": [churn(tls, FLEET, no_extra, 2, args.per_round), churn(tls, LOGS, no_extra, 2, args.per_round)]})
        time.sleep(PING_S + 5)
        sample("warm")
        sample("warm-repeat")

        runs.append({"fleet_tls": churn(tls, FLEET, no_extra, args.rounds, args.per_round)})
        time.sleep(3)
        sample("after-fleet-tls")
        runs.append({"logs_tls": churn(tls, LOGS, no_extra, args.rounds, args.per_round)})
        sample("after-logs-tls-0s")
        time.sleep(PING_S + 5)
        sample("after-logs-tls-35s")

        # MCP GET streams: one initialized session per stream, counted by sse_clients.
        mcp_rounds, mcp_k, released_s, mcp_status = 10, 30, [], {}
        def mcp_session() -> str | None:
            hdr = {"accept": "application/json, text/event-stream", "content-type": "application/json"}
            r = http.post(base + "/mcp", headers=hdr, json={"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {
                "protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": {"name": "leak-probe", "version": "0"}}})
            sid = r.headers.get("mcp-session-id")
            if r.status_code == 200 and sid:
                http.post(base + "/mcp", headers={**hdr, "mcp-session-id": sid},
                          json={"jsonrpc": "2.0", "method": "notifications/initialized"})
            return sid
        before = http.get(base + "/health").json().get("sse_clients")
        peak = before
        for _ in range(mcp_rounds):
            sessions = [mcp_session() for _ in range(mcp_k)]
            sessions = [s for s in sessions if s]
            sids = [tls.open("/mcp", [*auth, ("mcp-session-id", s), ("mcp-protocol-version", "2025-06-18")]) for s in sessions]
            tls.pump(lambda: all(s in tls.status for s in sids), 15)
            for s in sids:
                mcp_status[tls.status.get(s, 0)] = mcp_status.get(tls.status.get(s, 0), 0) + 1
            peak = max(peak, http.get(base + "/health").json().get("sse_clients"))
            tls.reset(sids)
            t_reset = time.monotonic()
            while time.monotonic() - t_reset < 40:
                if http.get(base + "/health").json().get("sse_clients") <= before:
                    released_s.append(round(time.monotonic() - t_reset, 2))
                    break
                tls.pump(lambda: False, 0.1)
            else:
                released_s.append(None)
        runs.append({"mcp_get_tls": {"sessions_per_round": mcp_k, "rounds": mcp_rounds, "statuses": mcp_status,
                                      "sse_clients_before": before, "sse_clients_peak": peak,
                                      "seconds_until_sse_clients_back": released_s}})
        sample("after-mcp-tls")

        c = H2Conn(server.port, tls=False)
        runs.append({"fleet_h2c": churn(c, FLEET, no_extra, max(1, args.rounds // 2), args.per_round)})
        c.sock.close()
        time.sleep(3)
        sample("after-fleet-h2c")

        statuses: dict[int, int] = {}
        for _ in range(200):
            x = H2Conn(server.https_port, tls=True)
            sids = [x.open(FLEET, auth) for _ in range(5)]
            x.pump(lambda: all(s in x.status for s in sids), 15)
            for s in sids:
                statuses[x.status.get(s, 0)] = statuses.get(x.status.get(s, 0), 0) + 1
            x.sock.close()
        runs.append({"tls_connection_churn": {"connections": 200, "streams_each": 5, "statuses": statuses}})
        time.sleep(3)
        sample("after-tls-conn-churn")

        for _ in range(200):
            s = socket.create_connection(("127.0.0.1", server.https_port), timeout=5)
            s.sendall(b"GET / HTTP/1.1\r\nHost: x\r\n\r\n")
            try:
                s.recv(1024)
            except OSError:
                pass
            s.close()
        runs.append({"tls_handshake_failures_sent": 200})
        time.sleep(3)
        sample("after-handshake-failures")

        h1_ok = 0
        for _ in range(200):
            s = socket.create_connection(("127.0.0.1", server.port), timeout=5)
            s.sendall(f"GET {FLEET} HTTP/1.1\r\nHost: 127.0.0.1\r\nAccept: text/event-stream\r\n{''.join(f'{k}: {v}' for k, v in auth)}\r\n\r\n".encode())
            h1_ok += s.recv(4096).startswith(b"HTTP/1.1 200")
            s.close()
        runs.append({"h1_fleet_close": {"connections": 200, "status_200": h1_ok}})
        time.sleep(PING_S + 5)
        sample("after-h1-35s")

        ledger: dict[int, int] = {}
        for _ in range(6):
            sids = [tls.open("/api/v1/openapi.json", auth) for _ in range(50)]
            tls.pump(lambda: all(s in tls.status for s in sids), 30)
            for s in sids:
                ledger[tls.status.get(s, 0)] = ledger.get(tls.status.get(s, 0), 0) + 1
            tls.pump(lambda: False, 0.5)
        runs.append({"after_all_on_the_same_tls_connection": {"openapi_gets": 300, "statuses": ledger,
                                                              "server_reset_streams": len(tls.server_reset)}})
        tls.sock.close()
        time.sleep(3)
        sample("final")
    (args.out / "runs.json").write_text(json.dumps({"info": info, "runs": runs}, indent=1) + "\n")
    print(json.dumps({"info": info, "runs": runs}), flush=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
