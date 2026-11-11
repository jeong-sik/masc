# /// script
# requires-python = ">=3.11"
# dependencies = ["httpx[http2]==0.28.1"]
# ///
"""Does an HTTP/2 SSE stream that stalls past the stall bound get reset?

One TLS h2 connection advertises SETTINGS_INITIAL_WINDOW_SIZE = 0, so the
server can send HEADERS but no DATA on its streams. It opens K log streams.
The server's first frame for each waits on the window. After the stall bound
(sse_stalled_after_s = 90 s) plus a margin, the probe records whether the
server reset any of them, counts the server's stall log lines, then opens each
stream's window and records whether the held frame still arrives and whether
the stream ends. A stream that was reset releases its bytes; one that is still
open holds its frame (and the listener's ledger reservation) until now.
"""
from __future__ import annotations

import argparse
import json
import sys
import time
from pathlib import Path

import h2.events
import h2.settings

sys.path.insert(0, str(Path(__file__).resolve().parent))
from h2_sse_leak_probe import LOGS, H2Conn  # noqa: E402

STALL_BOUND_S = 90.0


class ZeroWindow(H2Conn):
    """An h2 client whose streams start with a zero receive window."""

    def __init__(self, port: int) -> None:
        super().__init__(port, tls=True)
        self.conn.update_settings({h2.settings.SettingCodes.INITIAL_WINDOW_SIZE: 0})
        self.flush()
        self.data: dict[int, int] = {}
        self.ended: set[int] = set()
        self.reset_at: dict[int, float] = {}
        self.pump(lambda: False, 0.5)

    def pump(self, done, timeout: float) -> bool:
        deadline = time.monotonic() + timeout
        while not done() and time.monotonic() < deadline:
            self.sock.settimeout(max(0.05, deadline - time.monotonic()))
            try:
                chunk = self.sock.recv(65536)
            except (TimeoutError, OSError):
                break
            if not chunk:
                raise ConnectionError("server closed the connection")
            for ev in self.conn.receive_data(chunk):
                if isinstance(ev, h2.events.ResponseReceived):
                    self.status[ev.stream_id] = int(dict(ev.headers)[":status"])
                elif isinstance(ev, h2.events.DataReceived):
                    self.data[ev.stream_id] = getattr(self, "data", {}).get(ev.stream_id, 0) + len(ev.data)
                elif isinstance(ev, h2.events.StreamEnded):
                    self.ended.add(ev.stream_id)
                elif isinstance(ev, h2.events.StreamReset):
                    self.server_reset.add(ev.stream_id)
                    self.reset_at.setdefault(ev.stream_id, time.monotonic())
            self.flush()
        return done()


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--repo", type=Path, required=True)
    ap.add_argument("--binary", type=Path, required=True)
    ap.add_argument("--out", type=Path, required=True)
    ap.add_argument("--streams", type=int, default=3)
    ap.add_argument("--margin-s", type=float, default=15.0)
    args = ap.parse_args()
    sys.path.insert(0, str(args.repo / "scripts/harness/perf"))
    import http_multiplex_probe as hmp

    args.out.mkdir(parents=True, exist_ok=True)
    with hmp.OwnedServer(args.binary, args.repo, args.out, None, None) as server:
        token = hmp.dev_token(server.base_url)
        auth = [("authorization", f"Bearer {token}")] if token else []
        conn = ZeroWindow(server.https_port)
        sids = [conn.open(LOGS, auth) for _ in range(args.streams)]
        conn.pump(lambda: all(s in conn.status for s in sids), 10)
        opened = time.monotonic()
        conn.pump(lambda: False, STALL_BOUND_S + args.margin_s)
        waited = time.monotonic() - opened
        log_text = server.log_path.read_text(errors="replace")
        # The wording before RFC-0518 D2, and the one the stream bound logs since.
        stall_lines = log_text.count("accepted no frame")
        reset_lines = log_text.count("resetting the stream")
        reset_while_stalled = sorted(conn.server_reset & set(sids))
        data_while_stalled = {s: conn.data.get(s, 0) for s in sids}
        for s in sids:
            if s not in conn.server_reset:
                conn.conn.increment_flow_control_window(1 << 20, stream_id=s)
        conn.flush()
        conn.pump(lambda: all(s in conn.ended or s in conn.server_reset for s in sids), 10)
        result = {
            "streams": len(sids), "statuses": [conn.status.get(s) for s in sids],
            "waited_s": round(waited, 1), "stall_bound_s": STALL_BOUND_S,
            "server_stall_log_lines": stall_lines,
            "server_reset_log_lines": reset_lines,
            "reset_after_s": {s: round(conn.reset_at[s] - opened, 1) for s in sids if s in conn.reset_at},
            "reset_by_server_while_stalled": reset_while_stalled,
            "data_bytes_while_stalled": data_while_stalled,
            "after_window_opened": {s: {"data_bytes": conn.data.get(s, 0), "ended": s in conn.ended,
                                        "reset": s in conn.server_reset} for s in sids},
            "build": hmp.httpx.get(server.base_url + "/health").json().get("build", {}).get("commit", "?")[:12]
            if hasattr(hmp, "httpx") else None,
        }
        print(json.dumps(result, indent=1))
        (args.out / "stall.json").write_text(json.dumps(result, indent=1))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
