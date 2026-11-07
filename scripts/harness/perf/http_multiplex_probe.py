# /// script
# requires-python = ">=3.11"
# dependencies = ["httpx[http2]==0.28.1"]
# ///
"""Same requests over HTTP/1.1 and HTTP/2, against one owned or attached server.

Run with uv so the HTTP/2 client library is fetched into an ephemeral
environment and nothing is installed on the host:

    uv run scripts/harness/perf/http_multiplex_probe.py \
        --binary ~/.local/bin/masc --output artifacts/http-multiplex/<run>

or attach to a server that is already listening:

    uv run scripts/harness/perf/http_multiplex_probe.py \
        --base-url http://127.0.0.1:8935 --output artifacts/http-multiplex/<run>

Three scenarios, each run once per transport:

- serial: GETs of one path one at a time, the round trip without queueing.
- burst: N GETs of one path with C in flight. Per-request latency includes
  waiting for a connection, as a browser tab waits.
- download: a few concurrent GETs of the dashboard's main bundle, bytes per
  second over the wall time of the whole group.
- sse: S concurrent event streams held open for a window. Counts how many
  streams were established (response headers received) and how many frames
  each received. A transport with a connection cap below S establishes only
  as many streams as it has connections.
- curl: the same bundle downloaded by curl (nghttp2 in C) once per request
  over HTTP/1.1 and over h2c, so a slow Python HTTP/2 client can be told
  apart from a slow server.

Transports:

- h1-6: HTTP/1.1 with at most 6 connections, the per-origin cap browsers apply.
- h1: HTTP/1.1 with one connection per in-flight request.
- h2c: HTTP/2 over cleartext with prior knowledge, one connection, streams
  multiplexed on it.
- tls-h1: HTTP/1.1 over the TLS listener with at most 6 connections; the
  server certificate is not verified.
- tls-h2: HTTP/2 over the TLS listener, negotiated through ALPN, one
  connection; the server certificate is not verified.

The server owned by this script runs the release-evidence runtime fixture: no
Keeper work, no provider reachable, no operator credentials. Measurements
are loopback numbers on one host and say what this path costs here, not what
a remote client sees.
"""
from __future__ import annotations

import argparse
import asyncio
import hashlib
import json
import math
import os
import platform
import re
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import time
from dataclasses import dataclass, field
from pathlib import Path

from importlib import metadata

import httpx

RELEASE_FIXTURE = "scripts/fixtures/release-evidence/runtime.toml"
# The per-client token bucket (Env_config.Rate_bucket: 100 requests/s, burst
# 150) would answer 429 to a burst of 600, measuring the bucket instead of the
# transport. The owned server gets a bucket the probe cannot empty.
RATE_LIMIT_ENV = {"MASC_RATE_LIMIT": "1000000", "MASC_RATE_BURST": "1000000",
                  "MASC_AGENT_RATE_LIMIT": "1000000", "MASC_AGENT_RATE_BURST": "1000000"}
BROWSER_CONNECTIONS = 6
BOOT_WAIT_S = 60.0
READINESS_PATH = "/favicon.svg"
BUNDLE_PATTERN = re.compile(r"/dashboard/assets/index-[A-Za-z0-9_-]+\.js")
TRANSPORTS = ("h1-6", "h1", "h2c", "tls-h1", "tls-h2")
TLS_TRANSPORTS = ("tls-h1", "tls-h2")
SCENARIOS = ("serial", "burst", "download", "sse", "curl")


def percentile(values: list[float], fraction: float) -> float:
    ordered = sorted(values)
    return ordered[max(0, math.ceil(fraction * len(ordered)) - 1)]


def latency_summary(values_ms: list[float]) -> dict:
    if not values_ms:
        return {"n": 0}
    return {
        "n": len(values_ms),
        "min_ms": min(values_ms),
        "p50_ms": percentile(values_ms, 0.50),
        "p95_ms": percentile(values_ms, 0.95),
        "p99_ms": percentile(values_ms, 0.99),
        "max_ms": max(values_ms),
    }


def digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def write_json(path: Path, value) -> None:
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2, sort_keys=True) + "\n")


@dataclass
class Transport:
    name: str
    http1: bool
    http2: bool
    max_connections: int | None

    def client(self, base_url: str, *, timeout: httpx.Timeout) -> httpx.AsyncClient:
        limits = httpx.Limits(
            max_connections=self.max_connections,
            max_keepalive_connections=self.max_connections,
        )
        return httpx.AsyncClient(
            base_url=base_url,
            http1=self.http1,
            http2=self.http2,
            limits=limits,
            timeout=timeout,
            verify=False,
            headers={"accept-encoding": "identity"},
        )


def transport(name: str, concurrency: int) -> Transport:
    match name:
        case "h1-6":
            return Transport(name, http1=True, http2=False, max_connections=BROWSER_CONNECTIONS)
        case "h1":
            return Transport(name, http1=True, http2=False, max_connections=concurrency)
        case "h2c":
            # http1=False with http2=True is httpcore's HTTP/2 prior knowledge
            # over a cleartext connection.
            return Transport(name, http1=False, http2=True, max_connections=1)
        case "tls-h1":
            return Transport(name, http1=True, http2=False, max_connections=BROWSER_CONNECTIONS)
        case "tls-h2":
            # ALPN offers h2 only; the TLS listener answers with h2.
            return Transport(name, http1=False, http2=True, max_connections=1)
    raise SystemExit(f"unknown transport {name}")


@dataclass
class Sample:
    status: int
    http_version: str
    start_ns: int
    end_ns: int
    body_bytes: int
    error: str | None = None

    @property
    def latency_ms(self) -> float:
        return (self.end_ns - self.start_ns) / 1e6


async def timed_get(client: httpx.AsyncClient, path: str, headers: dict | None = None) -> Sample:
    start = time.perf_counter_ns()
    try:
        response = await client.get(path, headers=headers)
        body = response.content
        end = time.perf_counter_ns()
        return Sample(response.status_code, response.http_version, start, end, len(body))
    except httpx.HTTPError as error:
        end = time.perf_counter_ns()
        return Sample(0, "", start, end, 0, error=f"{type(error).__name__}: {error}")


async def run_burst(tr: Transport, base_url: str, path: str, requests: int, concurrency: int,
                    headers: dict | None, scenario: str = "burst") -> dict:
    timeout = httpx.Timeout(connect=10.0, read=60.0, write=10.0, pool=120.0)
    async with tr.client(base_url, timeout=timeout) as client:
        # One request first so connection setup of the first connection is
        # kept apart from the burst, as a page's first request is.
        warm = await timed_get(client, path, headers)
        gate = asyncio.Semaphore(concurrency)

        async def one() -> Sample:
            async with gate:
                return await timed_get(client, path, headers)

        wall_start = time.perf_counter_ns()
        samples = await asyncio.gather(*(one() for _ in range(requests)))
        wall_end = time.perf_counter_ns()
    ok = [s for s in samples if s.error is None and s.status == 200]
    wall_s = (wall_end - wall_start) / 1e9
    return {
        "scenario": scenario,
        "transport": tr.name,
        "path": path,
        "requests": requests,
        "concurrency": concurrency,
        "warmup": {"status": warm.status, "http_version": warm.http_version,
                   "latency_ms": warm.latency_ms, "error": warm.error},
        "ok": len(ok),
        "statuses": sorted({s.status for s in samples}),
        "http_versions": sorted({s.http_version for s in samples}),
        "errors": sorted({s.error for s in samples if s.error})[:5],
        "wall_s": wall_s,
        "requests_per_s": len(ok) / wall_s if wall_s > 0 else None,
        "body_bytes": sorted({s.body_bytes for s in ok})[:3],
        "latency": latency_summary([s.latency_ms for s in ok]),
        "latency_all": latency_summary([s.latency_ms for s in samples]),
    }


async def discover_bundle(base_url: str, headers: dict | None) -> str | None:
    async with httpx.AsyncClient(base_url=base_url, verify=False, timeout=10.0) as client:
        response = await client.get("/dashboard/", headers=headers, follow_redirects=True)
        if response.status_code != 200:
            return None
        match = BUNDLE_PATTERN.search(response.text)
        return match.group(0) if match else None


async def run_download(tr: Transport, base_url: str, path: str, concurrency: int,
                       headers: dict | None) -> dict:
    timeout = httpx.Timeout(connect=10.0, read=120.0, write=10.0, pool=120.0)
    async with tr.client(base_url, timeout=timeout) as client:
        wall_start = time.perf_counter_ns()
        samples = await asyncio.gather(*(timed_get(client, path, headers) for _ in range(concurrency)))
        wall_end = time.perf_counter_ns()
    ok = [s for s in samples if s.error is None and s.status == 200]
    total_bytes = sum(s.body_bytes for s in ok)
    wall_s = (wall_end - wall_start) / 1e9
    return {
        "scenario": "download",
        "transport": tr.name,
        "path": path,
        "concurrency": concurrency,
        "ok": len(ok),
        "statuses": sorted({s.status for s in samples}),
        "http_versions": sorted({s.http_version for s in samples}),
        "errors": sorted({s.error for s in samples if s.error})[:5],
        "body_bytes_each": sorted({s.body_bytes for s in ok}),
        "total_bytes": total_bytes,
        "wall_s": wall_s,
        "megabytes_per_s": (total_bytes / 1e6) / wall_s if wall_s > 0 else None,
        "latency": latency_summary([s.latency_ms for s in ok]),
    }


@dataclass
class StreamRecord:
    index: int
    established_ms: float | None = None
    status: int | None = None
    http_version: str = ""
    frames: int = 0
    bytes: int = 0
    first_frame_ms: float | None = None
    error: str | None = None
    events: list[str] = field(default_factory=list)


async def hold_stream(client: httpx.AsyncClient, path: str, index: int, origin_ns: int,
                      hold_s: float, headers: dict | None) -> StreamRecord:
    record = StreamRecord(index)
    request_headers = {"accept": "text/event-stream", **(headers or {})}
    deadline = origin_ns + int(hold_s * 1e9)

    async def consume() -> None:
        async with client.stream("GET", path, headers=request_headers) as response:
            record.established_ms = (time.perf_counter_ns() - origin_ns) / 1e6
            record.status = response.status_code
            record.http_version = response.http_version
            if response.status_code != 200:
                record.error = f"status {response.status_code}"
                return
            async for chunk in response.aiter_bytes():
                now = time.perf_counter_ns()
                record.bytes += len(chunk)
                frames = chunk.count(b"\n\n")
                if frames and record.first_frame_ms is None:
                    record.first_frame_ms = (now - origin_ns) / 1e6
                record.frames += frames
                if len(record.events) < 3:
                    record.events.append(chunk[:80].decode("utf-8", "replace"))
                if now >= deadline:
                    return

    remaining = max(0.0, (deadline - time.perf_counter_ns()) / 1e9)
    try:
        await asyncio.wait_for(consume(), timeout=remaining + 5.0)
    except asyncio.TimeoutError:
        if record.established_ms is None:
            record.error = "not established within the hold window"
    except httpx.HTTPError as error:
        record.error = f"{type(error).__name__}: {error}"
    return record


async def run_sse(tr: Transport, base_url: str, path: str, streams: int, hold_s: float,
                  headers: dict | None) -> dict:
    # The pool timeout is the hold window: a stream that finds no free
    # connection in that time is recorded as not established, which is what a
    # browser tab sees when its six connections are all busy.
    timeout = httpx.Timeout(connect=10.0, read=hold_s + 10.0, write=10.0, pool=hold_s)
    async with tr.client(base_url, timeout=timeout) as client:
        origin = time.perf_counter_ns()
        records = await asyncio.gather(
            *(hold_stream(client, path, i, origin, hold_s, headers) for i in range(streams)))
    established = [r for r in records if r.established_ms is not None and r.status == 200]
    first_frames: list[float] = [r.first_frame_ms for r in established if r.first_frame_ms is not None]
    established_ms: list[float] = [r.established_ms for r in established if r.established_ms is not None]
    return {
        "scenario": "sse",
        "transport": tr.name,
        "path": path,
        "streams": streams,
        "hold_s": hold_s,
        "established": len(established),
        "statuses": sorted({r.status for r in records if r.status is not None}),
        "http_versions": sorted({r.http_version for r in records if r.http_version}),
        "errors": sorted({r.error for r in records if r.error})[:5],
        "established_ms": latency_summary(established_ms),
        "first_frame_ms": latency_summary(first_frames),
        "frames_per_stream": latency_summary([float(r.frames) for r in established]),
        "bytes_total": sum(r.bytes for r in established),
        "sample_events": established[0].events if established else [],
    }


def last_line(command: list[str]) -> str | None:
    completed = subprocess.run(command, capture_output=True, text=True, timeout=60)
    lines = completed.stdout.strip().splitlines()
    return lines[-1] if lines else None


def run_curl_download(base_url: str, https_base_url: str | None, path: str, samples: int,
                      headers: dict | None) -> list[dict]:
    curl = shutil.which("curl")
    if curl is None:
        return [{"scenario": "curl", "skipped": "curl not installed"}]
    rows = []
    targets = [("--http1.1", "h1", base_url), ("--http2-prior-knowledge", "h2c", base_url)]
    if https_base_url is not None:
        targets.append(("--http2", "tls-h2", https_base_url))
    for flag, label, origin in targets:
        for _ in range(samples):
            command = [curl, "-s", "-o", "/dev/null", "-w", "%{http_version} %{http_code} %{size_download} %{speed_download} %{time_total}",
                       flag, "-k", "-H", "accept-encoding: identity"]
            for key, value in (headers or {}).items():
                command += ["-H", f"{key}: {value}"]
            command.append(origin + path)
            completed = subprocess.run(command, capture_output=True, text=True, timeout=120)
            fields = completed.stdout.split()
            if completed.returncode != 0 or len(fields) != 5:
                rows.append({"scenario": "curl", "transport": label, "path": path, "error": completed.stderr.strip()[:200],
                             "exit_code": completed.returncode})
                continue
            version, code, size, speed, total = fields
            rows.append({"scenario": "curl", "transport": label, "path": path, "http_version": version,
                         "status": int(code), "body_bytes": int(size), "megabytes_per_s": float(speed) / 1e6,
                         "wall_s": float(total)})
    return rows


def free_port() -> int:
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


class OwnedServer:
    """The installed binary on an ephemeral loopback port and a fresh base path."""

    def __init__(self, binary: Path, repo: Path, out: Path, h2_mode: str | None, assets_dir: Path | None):
        self.binary = binary
        self.repo = repo
        self.out = out
        self.h2_mode = h2_mode
        self.assets_dir = assets_dir
        self.process: subprocess.Popen | None = None
        self.temporary: tempfile.TemporaryDirectory | None = None
        self.port = free_port()
        self.https_port = free_port()
        while self.https_port == self.port:
            self.https_port = free_port()
        self.base_url = f"http://127.0.0.1:{self.port}"
        self.https_base_url = f"https://127.0.0.1:{self.https_port}"
        self.log_path = out / "server.log"

    def __enter__(self) -> "OwnedServer":
        self.temporary = tempfile.TemporaryDirectory(prefix="masc-http-multiplex-")
        base = Path(self.temporary.name).resolve()
        config = base / ".masc/config"
        (config / "keepers").mkdir(parents=True)
        (config / "prompts").mkdir()
        fixture = self.repo / RELEASE_FIXTURE
        shutil.copy(fixture, config / "runtime.toml")
        env = {"PATH": os.environ["PATH"], "LANG": "C.UTF-8", "HOME": os.environ.get("HOME", str(base)),
               "MASC_BASE_PATH": str(base), "MASC_CONFIG_DIR": str(config),
               "MASC_CONFIG_BOOTSTRAP": "skip", "MASC_KEEPER_AUTONOMOUS_ENABLED": "false",
               "MASC_GRPC_ENABLED": "0", "MASC_WS_ENABLED": "0",
               # The TLS listener with the self-signed pair the server writes
               # under its base path; clients below do not verify it.
               "MASC_HTTPS_PORT": str(self.https_port), **RATE_LIMIT_ENV}
        if self.h2_mode is not None:
            env["MASC_USE_H2"] = self.h2_mode
        if self.assets_dir is not None:
            # The owned base path holds no dashboard build; without this the
            # dashboard routes answer 503 and the download scenario is skipped.
            env["MASC_ASSETS_DIR"] = str(self.assets_dir)
        self.environment_keys = sorted(env)
        self.fixture_sha256 = digest(fixture)
        log = self.log_path.open("wb")
        self.process = subprocess.Popen(
            [str(self.binary), "--host", "127.0.0.1", "--base-path", str(base), "--port", str(self.port)],
            cwd=base, env=env, stdout=log, stderr=log, start_new_session=True)
        # /health answers before the workspace routes do; a Public_read route
        # answers 503 until the server state is installed, so boot is over
        # when one of them answers 200.
        started = time.monotonic()
        deadline = started + BOOT_WAIT_S
        while time.monotonic() < deadline:
            if self.process.poll() is not None:
                raise SystemExit(f"server exited during boot with {self.process.returncode}; see {self.log_path}")
            try:
                with httpx.Client(timeout=2.0) as client:
                    if (client.get(self.base_url + "/health").status_code == 200
                            and client.get(self.base_url + READINESS_PATH).status_code == 200):
                        self.boot_s = time.monotonic() - started
                        return self
            except httpx.HTTPError:
                pass
            time.sleep(0.25)
        raise SystemExit(f"server did not answer /health and {READINESS_PATH} within {BOOT_WAIT_S}s; see {self.log_path}")

    def __exit__(self, *_: object) -> None:
        if self.process is not None and self.process.poll() is None:
            os.killpg(self.process.pid, signal.SIGTERM)
            try:
                self.process.wait(timeout=30)
            except subprocess.TimeoutExpired:
                os.killpg(self.process.pid, signal.SIGKILL)
                self.process.wait(timeout=10)
        self.exit_code = self.process.returncode if self.process else None
        if self.temporary is not None:
            self.temporary.cleanup()


def health_transport(base_url: str) -> dict:
    with httpx.Client(timeout=10.0, verify=False) as client:
        health = client.get(base_url + "/health").json()
    keep = {key: health.get(key) for key in ("version", "release_version", "build", "http_listener", "transport",
                                             "dashboard_surface")}
    return keep


def dev_token(base_url: str) -> str | None:
    """The loopback dashboard token the owned server issues to its own operator."""
    with httpx.Client(timeout=10.0, verify=False) as client:
        response = client.get(base_url + "/api/v1/dashboard/dev-token", headers={"accept": "application/json"})
    if response.status_code != 200:
        return None
    return response.json().get("token") or None


async def measure(args, base_url: str, https_base_url: str | None, transports: list[str],
                  headers: dict | None) -> list[dict]:
    results: list[dict] = []

    def url_for(name: str) -> str:
        if name in TLS_TRANSPORTS:
            if https_base_url is None:
                raise SystemExit(f"{name} needs an https base URL")
            return https_base_url
        return base_url

    bundle = await discover_bundle(base_url, headers)
    scenarios = set(args.scenarios)
    for repeat in range(args.repeats):
        # The order rotates so no transport always runs first on a server that
        # is still warming up.
        rotated = transports[repeat % len(transports):] + transports[:repeat % len(transports)]
        for name in rotated:
            for path in args.burst_path:
                if "serial" in scenarios:
                    tr = transport(name, 1)
                    row = await run_burst(tr, url_for(name), path, args.serial_requests, 1, headers, scenario="serial")
                    row["repeat"] = repeat
                    results.append(row)
                    print(f"[{repeat}] serial {name:5} {path:28} ok={row['ok']:4} "
                          f"p50={row['latency'].get('p50_ms', float('nan')):7.2f}ms "
                          f"p99={row['latency'].get('p99_ms', float('nan')):7.2f}ms", flush=True)
                if "burst" in scenarios:
                    tr = transport(name, args.concurrency)
                    row = await run_burst(tr, url_for(name), path, args.requests, args.concurrency, headers)
                    row["repeat"] = repeat
                    results.append(row)
                    print(f"[{repeat}] burst {name:5} {path:28} ok={row['ok']:4} "
                          f"p50={row['latency'].get('p50_ms', float('nan')):7.2f}ms "
                          f"p99={row['latency'].get('p99_ms', float('nan')):7.2f}ms "
                          f"{row['requests_per_s'] or 0:8.1f} req/s", flush=True)
            if "download" in scenarios and bundle is not None:
                tr = transport(name, args.download_concurrency)
                row = await run_download(tr, url_for(name), bundle, args.download_concurrency, headers)
                row["repeat"] = repeat
                results.append(row)
                print(f"[{repeat}] download {name:5} ok={row['ok']} "
                      f"{row['megabytes_per_s'] or 0:7.1f} MB/s wall={row['wall_s']:.2f}s", flush=True)
            elif "download" in scenarios:
                results.append({"scenario": "download", "transport": name, "repeat": repeat,
                                "skipped": "no dashboard bundle found at /dashboard/"})
            if "sse" in scenarios and args.sse_streams > 0:
                tr = transport(name, args.sse_streams)
                row = await run_sse(tr, url_for(name), args.sse_path, args.sse_streams, args.sse_hold_s, headers)
                row["repeat"] = repeat
                results.append(row)
                print(f"[{repeat}] sse {name:5} established={row['established']}/{args.sse_streams} "
                      f"frames/stream p50={row['frames_per_stream'].get('p50_ms', 0):.0f} "
                      f"errors={row['errors'][:1]}", flush=True)
        if "curl" in scenarios and bundle is not None:
            for row in run_curl_download(base_url, https_base_url, bundle, args.curl_samples, headers):
                row["repeat"] = repeat
                results.append(row)
                print(f"[{repeat}] curl {row.get('transport', '?'):5} {row.get('http_version', '')} "
                      f"{row.get('megabytes_per_s', 0):7.1f} MB/s {row.get('error', '')}", flush=True)
    return results


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    target = parser.add_mutually_exclusive_group(required=True)
    target.add_argument("--binary", type=Path, help="installed masc binary to own on a loopback port")
    target.add_argument("--base-url", help="attach to a listening server instead of owning one")
    parser.add_argument("--https-base-url", default=None,
                        help="the attached server's TLS listener, for the tls-* transports")
    parser.add_argument("--repo", type=Path, default=Path(__file__).resolve().parents[3],
                        help="repository root holding the release-evidence runtime fixture")
    parser.add_argument("--output", type=Path, required=True, help="new directory for results")
    parser.add_argument("--h2-mode", choices=("0", "1", "auto"), default=None,
                        help="MASC_USE_H2 for the owned server (default: the binary's default)")
    parser.add_argument("--assets-dir", type=Path, default=None,
                        help="MASC_ASSETS_DIR for the owned server, a built assets/ root with dashboard/")
    parser.add_argument("--transports", default="h1-6,h1,h2c",
                        help="comma-separated subset of " + ",".join(TRANSPORTS))
    parser.add_argument("--burst-path", action="append", default=None,
                        help="path for the burst scenario (repeatable; default /health and /favicon.svg)")
    parser.add_argument("--requests", type=int, default=600)
    parser.add_argument("--serial-requests", type=int, default=100,
                        help="requests sent one at a time per path, the round trip without queueing")
    parser.add_argument("--concurrency", type=int, default=100)
    parser.add_argument("--download-concurrency", type=int, default=4)
    parser.add_argument("--sse-path", default="/api/v1/stream/fleet")
    parser.add_argument("--sse-streams", type=int, default=50)
    parser.add_argument("--sse-hold-s", type=float, default=35.0,
                        help="hold window; the fleet stream pings every 30 s when idle")
    parser.add_argument("--repeats", type=int, default=3)
    parser.add_argument("--scenarios", default=",".join(SCENARIOS),
                        help="comma-separated subset of " + ",".join(SCENARIOS))
    parser.add_argument("--curl-samples", type=int, default=5, help="curl downloads per transport per repeat")
    parser.add_argument("--token-env", default=None,
                        help="environment variable holding a bearer token for an attached server")
    args = parser.parse_args()
    if args.burst_path is None:
        args.burst_path = ["/health", "/favicon.svg"]
    transports = [t.strip() for t in args.transports.split(",") if t.strip()]
    for name in transports:
        if name not in TRANSPORTS:
            raise SystemExit(f"unknown transport {name}")
    args.scenarios = [sc.strip() for sc in args.scenarios.split(",") if sc.strip()]
    for name in args.scenarios:
        if name not in SCENARIOS:
            raise SystemExit(f"unknown scenario {name}")
    args.output.mkdir(parents=True, exist_ok=False)

    identity = {
        "host": {"machine": platform.machine(), "system": platform.platform(),
                 "cpu": platform.processor() or None, "python": sys.version.split()[0]},
        "client": {name: metadata.version(name) for name in ("httpx", "httpcore", "h2")},
        "probe_sha256": digest(Path(__file__)),
        "arguments": {key: (str(value) if isinstance(value, Path) else value)
                      for key, value in vars(args).items() if key != "token_env"},
        "started_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
    }

    headers = None
    if args.token_env:
        token = os.environ.get(args.token_env)
        if not token:
            raise SystemExit(f"{args.token_env} is empty")
        headers = {"authorization": f"Bearer {token}"}

    if args.binary is not None:
        binary = args.binary.expanduser().resolve()
        identity["binary"] = {"path": str(binary), "sha256": digest(binary),
                              "version": last_line([str(binary), "--version"]),
                              "build_commit": last_line([str(binary), "build-commit"])}
        assets_dir = args.assets_dir.expanduser().resolve() if args.assets_dir else None
        with OwnedServer(binary, args.repo, args.output, args.h2_mode, assets_dir) as server:
            identity["server"] = {"base_url": server.base_url, "https_base_url": server.https_base_url, "owned": True,
                                  "environment_keys": server.environment_keys,
                                  "fixture_sha256": server.fixture_sha256, "h2_mode_env": args.h2_mode,
                                  "assets_dir": str(assets_dir) if assets_dir else None,
                                  "boot_s": server.boot_s, "rate_limit_env": RATE_LIMIT_ENV}
            identity["health"] = health_transport(server.base_url)
            token = dev_token(server.base_url)
            if token is not None and headers is None:
                headers = {"authorization": f"Bearer {token}"}
                identity["server"]["credential"] = "loopback dashboard dev-token (not recorded)"
            results = asyncio.run(measure(args, server.base_url, server.https_base_url, transports, headers))
        identity["server"]["exit_code"] = server.exit_code
    else:
        identity["server"] = {"base_url": args.base_url, "https_base_url": args.https_base_url, "owned": False}
        identity["health"] = health_transport(args.base_url)
        results = asyncio.run(measure(args, args.base_url, args.https_base_url, transports, headers))

    identity["finished_at"] = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
    write_json(args.output / "identity.json", identity)
    write_json(args.output / "results.json", results)
    print(f"wrote {args.output / 'results.json'}")


if __name__ == "__main__":
    main()
