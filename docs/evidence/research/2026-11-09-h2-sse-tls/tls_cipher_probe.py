# /// script
# requires-python = ">=3.11"
# dependencies = ["httpx[http2]==0.28.1"]
# ///
"""Server-side TLS cost per TLS 1.3 cipher suite, against an owned masc server.

Each sample sends N pipelined HTTP/1.1 GETs of the dashboard bundle on one
connection (the last one asks to close) and times the whole read. TLS samples
use the native arm64 openssl s_client restricted to one suite, so the server
must use that suite; the cleartext sample uses a plain socket. One extra AES
and one ChaCha run are sampled with macOS `sample` to see where the server's
time goes. Also times 30 TLS handshakes.
"""
from __future__ import annotations

import argparse
import json
import socket
import ssl
import statistics
import subprocess
import sys
import time
from pathlib import Path

import httpx

SUITES = ("TLS_AES_128_GCM_SHA256", "TLS_AES_256_GCM_SHA384", "TLS_CHACHA20_POLY1305_SHA256")


def requests(path: str, port: int, n: int) -> bytes:
    one = f"GET {path} HTTP/1.1\r\nHost: 127.0.0.1:{port}\r\n\r\n"
    last = f"GET {path} HTTP/1.1\r\nHost: 127.0.0.1:{port}\r\nConnection: close\r\n\r\n"
    return (one * (n - 1) + last).encode()


def clear_sample(port: int, path: str, n: int) -> tuple[int, float]:
    started = time.monotonic()
    s = socket.create_connection(("127.0.0.1", port), timeout=60)
    s.sendall(requests(path, port, n))
    got = 0
    while chunk := s.recv(1 << 20):
        got += len(chunk)
    s.close()
    return got, time.monotonic() - started


def tls_sample(port: int, path: str, n: int, suite: str) -> tuple[int, float]:
    started = time.monotonic()
    p = subprocess.run(["openssl", "s_client", "-quiet", "-connect", f"127.0.0.1:{port}", "-alpn", "http/1.1",
                        "-ciphersuites", suite, "-tls1_3"], input=requests(path, port, n), capture_output=True,
                       timeout=120)
    return len(p.stdout), time.monotonic() - started


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--repo", type=Path, required=True)
    ap.add_argument("--binary", type=Path, required=True)
    ap.add_argument("--assets", type=Path, required=True)
    ap.add_argument("--out", type=Path, required=True)
    ap.add_argument("--n", type=int, default=60)
    ap.add_argument("--repeats", type=int, default=5)
    args = ap.parse_args()
    sys.path.insert(0, str(args.repo / "scripts/harness/perf"))
    import http_multiplex_probe as hmp

    args.out.mkdir(parents=True, exist_ok=True)
    bundles = sorted((args.assets / "dashboard/assets").glob("index-*.js"), key=lambda p: p.stat().st_size, reverse=True)
    result: dict = {}
    with hmp.OwnedServer(args.binary, args.repo, args.out, None, args.assets) as server:
        pid, port, tport = server.process.pid, server.port, server.https_port
        path = next(f"/dashboard/assets/{b.name}" for b in bundles
                    if httpx.get(f"{server.base_url}/dashboard/assets/{b.name}").status_code == 200)
        size = len(httpx.get(server.base_url + path).content)
        result["bundle"] = {"path": path, "bytes": size, "requests_per_sample": args.n}
        result["build"] = httpx.get(server.base_url + "/health").json()["build"]["commit"][:12]
        # Which suite does the server pick when the client offers all three?
        default = subprocess.run(["openssl", "s_client", "-connect", f"127.0.0.1:{tport}", "-alpn", "h2"],
                                 input=b"", capture_output=True, timeout=30).stdout.decode(errors="replace")
        result["picked_when_all_offered"] = next((l.strip() for l in default.splitlines() if "Cipher is" in l), "?")
        rows = {}
        for mode in ("cleartext-h1", *SUITES):
            mbps = []
            for _ in range(args.repeats):
                got, secs = clear_sample(port, path, args.n) if mode == "cleartext-h1" else tls_sample(tport, path, args.n, mode)
                if got < size * args.n:
                    raise SystemExit(f"{mode}: got {got} bytes, expected at least {size * args.n}")
                mbps.append(got / secs / 1e6)
            rows[mode] = {"MB_s_median": round(statistics.median(mbps), 1), "MB_s_min": round(min(mbps), 1),
                          "MB_s_max": round(max(mbps), 1)}
            print(mode, rows[mode], flush=True)
        result["throughput"] = rows
        for suite, tag in (("TLS_AES_128_GCM_SHA256", "aes128gcm"), ("TLS_CHACHA20_POLY1305_SHA256", "chacha")):
            prof = args.out / f"sample-{tag}.txt"
            sampler = subprocess.Popen(["sample", str(pid), "3", "-mayDie", "-file", str(prof)],
                                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            time.sleep(0.3)
            deadline = time.monotonic() + 3.2
            while time.monotonic() < deadline:
                tls_sample(tport, path, args.n, suite)
            sampler.wait(timeout=60)
        hs = []
        ctx = ssl.create_default_context()
        ctx.check_hostname, ctx.verify_mode = False, ssl.CERT_NONE
        for _ in range(30):
            raw = socket.create_connection(("127.0.0.1", tport), timeout=10)
            t = time.monotonic()
            tls = ctx.wrap_socket(raw, server_hostname="127.0.0.1")
            hs.append((time.monotonic() - t) * 1000)
            tls.close()
        result["handshake_ms"] = {"median": round(statistics.median(hs), 2), "p90": round(sorted(hs)[26], 2),
                                  "max": round(max(hs), 2)}
    (args.out / "tls.json").write_text(json.dumps(result, indent=1) + "\n")
    print(json.dumps(result), flush=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
