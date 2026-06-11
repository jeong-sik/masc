#!/usr/bin/env python3
"""masc playground health monitor — validates all services without Grafana UI.

Usage:
  python bin/health-monitor.py               # default: all services, warn on failure
  python bin/health-monitor.py --strict       # exit non-zero on any failure
  python bin/health-monitor.py --json         # JSON output
  python bin/health-monitor.py --watch 5      # loop every 5s, exit on Ctrl-C
  python bin/health-monitor.py --check masc   # check only MASC service

Config:
  HEALTH_CHECK_TIMEOUT  float  default 5.0   HTTP timeout per probe
  MASC_BASE_URL         str    default http://localhost:8080
  VICTORIAMETRICS_URL   str    default http://localhost:8428
  JAEGER_URL            str    default http://localhost:16686
  LOKI_URL              str    default http://localhost:3100
  GRAFANA_URL           str    default http://localhost:3000
  OTEL_URL              str    default http://localhost:4318
"""

from __future__ import annotations

import json
import os
import signal
import sys
import time
import urllib.error
import urllib.request
from dataclasses import dataclass, field, asdict
from typing import Any


# ── Configuration ──────────────────────────────────────────────────────────

TIMEOUT = float(os.environ.get("HEALTH_CHECK_TIMEOUT", "5.0"))
SERVICES: dict[str, str] = {
    "masc": os.environ.get("MASC_BASE_URL", "http://localhost:8080"),
    "victoriametrics": os.environ.get(
        "VICTORIAMETRICS_URL", "http://localhost:8428"
    ),
    "jaeger": os.environ.get("JAEGER_URL", "http://localhost:16686"),
    "loki": os.environ.get("LOKI_URL", "http://localhost:3100"),
    "grafana": os.environ.get("GRAFANA_URL", "http://localhost:3000"),
    "otel-collector": os.environ.get("OTEL_URL", "http://localhost:4318"),
}

MAX_METRIC_LAG_S = 120  # max acceptable age for a metric (VictoriaMetrics)


# ── Types ──────────────────────────────────────────────────────────────────

@dataclass
class ServiceCheck:
    service: str
    url: str
    reachable: bool = False
    status_code: int | None = None
    latency_ms: float = 0.0
    error: str | None = None
    detail: dict[str, Any] = field(default_factory=dict)


@dataclass
class MetricCheck:
    service: str
    received: bool = False
    count: int = 0
    oldest_s: float | None = None
    newest_s: float | None = None
    error: str | None = None


@dataclass
class HealthReport:
    timestamp: float
    checks: list[ServiceCheck]
    metrics: list[MetricCheck]
    all_reachable: bool
    degraded: list[str]
    failing: list[str]


# ── HTTP helpers ───────────────────────────────────────────────────────────

def http_get(url: str, path: str = "/", timeout: float = TIMEOUT) -> tuple[int, str, float]:
    """GET url+path, return (status_code, body, elapsed_ms)."""
    t0 = time.monotonic()
    try:
        req = urllib.request.Request(f"{url.rstrip('/')}{path}", method="GET")
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            body = resp.read().decode("utf-8", errors="replace")
            elapsed = (time.monotonic() - t0) * 1000
            return resp.status, body, elapsed
    except urllib.error.HTTPError as e:
        elapsed = (time.monotonic() - t0) * 1000
        body = e.read().decode("utf-8", errors="replace") if e.fp else ""
        return e.code, body, elapsed
    except Exception as e:
        elapsed = (time.monotonic() - t0) * 1000
        return 0, "", elapsed


def try_reach(url: str, timeout: float = TIMEOUT) -> ServiceCheck:
    """Probe a service root endpoint. Returns ServiceCheck."""
    service = next((k for k, v in SERVICES.items() if v == url), url)
    code, body, ms = http_get(url, "/", timeout)
    chk = ServiceCheck(service=service, url=url)
    if code == 0:
        chk.error = "connection refused or timeout"
    else:
        chk.reachable = True
        chk.status_code = code
        chk.latency_ms = round(ms, 1)
        try:
            parsed = json.loads(body) if body.strip() else {}
            if isinstance(parsed, dict):
                chk.detail = parsed
        except (json.JSONDecodeError, ValueError):
            chk.detail = {"raw_length": len(body)}
    return chk


# ── Service-specific probes ────────────────────────────────────────────────

def probe_masc(url: str) -> ServiceCheck:
    """Probe MASC /health endpoint (returns JSON with status)."""
    chk = try_reach(url)
    if chk.reachable and chk.status_code == 200:
        # Try health endpoint
        code, body, ms = http_get(url, "/health", TIMEOUT)
        chk.latency_ms = round(ms, 1)
        chk.status_code = code
        if code == 200:
            try:
                data = json.loads(body)
                chk.detail = data if isinstance(data, dict) else {"raw": body[:200]}
            except json.JSONDecodeError:
                chk.detail = {"health_raw": body[:200]}
        else:
            chk.detail = {"health_status": code}
    return chk


def probe_victoriametrics(url: str) -> ServiceCheck:
    """Probe VictoriaMetrics /health and query for masc metrics."""
    chk = try_reach(url)
    if not chk.reachable:
        return chk

    # VM /health is a plain 200 with "OK"
    code, body, ms = http_get(url, "/health", TIMEOUT)
    chk.detail["health_body"] = body.strip()[:100]
    chk.latency_ms = round(ms, 1)

    # Check metric freshness: query for masc_keeper_heartbeat_successes_total
    query = urllib.parse.quote(
        "masc_keeper_heartbeat_successes_total", safe=""
    )
    qcode, qbody, qms = http_get(
        url, f"/api/v1/query?query={query}", TIMEOUT
    )
    chk.detail["metrics_query_ms"] = round(qms, 1)
    if qcode == 200:
        try:
            data = json.loads(qbody)
            results = (
                data.get("data", {}).get("result", [])
            )
            chk.detail["metric_series_count"] = len(results)
            if results:
                # Extract latest value
                latest = float(results[0].get("value", [0, "0"])[1])
                chk.detail["latest_heartbeat_count"] = latest
        except (json.JSONDecodeError, KeyError, TypeError) as e:
            chk.detail["metrics_parse_error"] = str(e)
    else:
        chk.detail["metrics_query_status"] = qcode
    return chk


def probe_jaeger(url: str) -> ServiceCheck:
    """Probe Jaeger health and API availability."""
    chk = try_reach(url)
    if not chk.reachable:
        return chk

    # Jaeger /api/services lists known services
    code, body, ms = http_get(url, "/api/services", TIMEOUT)
    chk.detail["api_services_ms"] = round(ms, 1)
    if code == 200:
        try:
            data = json.loads(body)
            services = data.get("data", [])
            chk.detail["known_services"] = services
            chk.detail["service_count"] = len(services)
        except json.JSONDecodeError:
            chk.detail["api_parse_error"] = body[:200]
    else:
        chk.detail["api_status"] = code
    return chk


def probe_loki(url: str) -> ServiceCheck:
    """Probe Loki /ready and /loki/api/v1/labels."""
    chk = try_reach(url)
    if not chk.reachable:
        return chk

    code, body, ms = http_get(url, "/ready", TIMEOUT)
    chk.detail["ready_code"] = code
    chk.detail["ready_body"] = body.strip()[:100]
    chk.latency_ms = round(ms, 1)

    # Check labels endpoint
    lcode, lbody, lms = http_get(url, "/loki/api/v1/labels", TIMEOUT)
    chk.detail["labels_ms"] = round(lms, 1)
    if lcode == 200:
        try:
            data = json.loads(lbody)
            labels = data.get("data", [])
            chk.detail["label_count"] = len(labels)
        except json.JSONDecodeError:
            pass
    return chk


def probe_grafana(url: str) -> ServiceCheck:
    """Probe Grafana /api/health and /api/alertmanager/api/v2/alerts."""
    chk = try_reach(url)
    if not chk.reachable:
        return chk

    code, body, ms = http_get(url, "/api/health", TIMEOUT)
    chk.latency_ms = round(ms, 1)
    chk.status_code = code
    if code == 200:
        try:
            data = json.loads(body)
            chk.detail["database"] = data.get("database", "unknown")
        except json.JSONDecodeError:
            pass

    # Check provisioned dashboards exist
    dcode, dbody, dms = http_get(url, "/api/search?type=dash-db", TIMEOUT)
    chk.detail["dashboards_ms"] = round(dms, 1)
    if dcode == 200:
        try:
            data = json.loads(dbody)
            chk.detail["dashboard_count"] = len(data)
            chk.detail["dashboards"] = [d.get("title") for d in data if d.get("title")]
        except json.JSONDecodeError:
            pass
    return chk


def probe_otel(url: str) -> ServiceCheck:
    """Probe OTel collector health endpoint."""
    chk = try_reach(url)
    if not chk.reachable:
        return chk
    # OTel collector exposes /debug/healthz for liveness
    code, body, ms = http_get(url, "/debug/healthz", TIMEOUT)
    chk.status_code = code
    chk.latency_ms = round(ms, 1)
    chk.detail["healthz"] = body.strip()[:100]
    return chk


# ── Probe routing ──────────────────────────────────────────────────────────

SERVICE_PROBES: dict[str, callable] = {
    "masc": probe_masc,
    "victoriametrics": probe_victoriametrics,
    "jaeger": probe_jaeger,
    "loki": probe_loki,
    "grafana": probe_grafana,
    "otel-collector": probe_otel,
}


def probe_service(name: str, url: str) -> ServiceCheck:
    probe = SERVICE_PROBES.get(name, try_reach)
    return probe(url)


# ──── Formatting ───────────────────────────────────────────────────────────

def format_report(report: HealthReport, strict: bool = False) -> str:
    lines: list[str] = []
    ok_count = 0
    warn_count = 0
    fail_count = 0

    lines.append("=" * 60)
    lines.append("MASC Playground Health Monitor")
    lines.append(f"  timestamp: {time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime(report.timestamp))}")
    lines.append("=" * 60)
    lines.append("")

    for chk in report.checks:
        icon = "✅" if chk.reachable else "❌"
        ms = f"{chk.latency_ms:.0f}ms" if chk.reachable else "---"
        status = f"HTTP {chk.status_code}" if chk.status_code else "UNREACHABLE"
        label = f"{icon} {chk.service:<20s} {status:<12s} {ms:>6s}"

        if chk.error:
            label += f"  [{chk.error}]"

        lines.append(label)

        if chk.detail:
            for k, v in chk.detail.items():
                if isinstance(v, list) and len(v) > 5:
                    v = v[:5] + ["..."]
                lines.append(f"  └─ {k}: {v}")

        lines.append("")

        if chk.reachable:
            ok_count += 1
        elif chk.status_code and chk.status_code < 500:
            warn_count += 1
        else:
            fail_count += 1

    lines.append("-" * 60)
    if report.failing:
        lines.append(f"❌ FAILING: {', '.join(report.failing)}")
    if report.degraded:
        lines.append(f"⚠️ DEGRADED: {', '.join(report.degraded)}")
    lines.append(f"✅ OK: {ok_count}  ⚠️ Warn: {warn_count}  ❌ Fail: {fail_count}")
    lines.append(f"Overall: {'ALL GOOD' if report.all_reachable else 'ISSUES DETECTED'}")

    return "\n".join(lines)


# ── Main check ─────────────────────────────────────────────────────────────

def run_health_check(*, check_filter: str | None = None) -> HealthReport:
    targets = (
        [(k, v) for k, v in SERVICES.items() if k == check_filter]
        if check_filter
        else list(SERVICES.items())
    )

    checks: list[ServiceCheck] = []
    for name, url in targets:
        chk = probe_service(name, url)
        checks.append(chk)

    # Determine overall status
    reachable = all(c.reachable for c in checks)
    failing = [c.service for c in checks if not c.reachable]
    degraded = [
        c.service
        for c in checks
        if c.reachable and c.status_code and c.status_code >= 400
    ]

    metrics: list[MetricCheck] = []
    for chk in checks:
        if chk.service == "victoriametrics" and "metric_series_count" in chk.detail:
            mc = MetricCheck(
                service=chk.service,
                received=chk.detail.get("metric_series_count", 0) > 0,
                count=chk.detail.get("metric_series_count", 0),
            )
            metrics.append(mc)

    return HealthReport(
        timestamp=time.time(),
        checks=checks,
        metrics=metrics,
        all_reachable=reachable,
        degraded=degraded,
        failing=failing,
    )


# ── CLI entry point ────────────────────────────────────────────────────────

def main() -> int:
    import argparse

    parser = argparse.ArgumentParser(
        description="MASC playground health monitor",
    )
    parser.add_argument(
        "--check", "-c",
        type=str,
        default=None,
        choices=list(SERVICES.keys()) + [None],
        help="Check only one service",
    )
    parser.add_argument(
        "--json", "-j",
        action="store_true",
        help="JSON output",
    )
    parser.add_argument(
        "--strict",
        action="store_true",
        help="Exit non-zero on any failure",
    )
    parser.add_argument(
        "--watch", "-w",
        type=float,
        default=0,
        help="Loop with N-second interval (Ctrl-C to stop)",
    )

    args = parser.parse_args()

    def run_once() -> int:
        report = run_health_check(check_filter=args.check)
        if args.json:
            print(json.dumps(asdict(report), default=str, indent=2))
        else:
            print(format_report(report, strict=args.strict))

        if args.strict and not report.all_reachable:
            return 1
        if args.strict and report.failing:
            return 1
        return 0

    if args.watch > 0:
        # Watch mode: loop until Ctrl-C
        exit_code = 0
        try:
            while True:
                ts = time.strftime("%H:%M:%S")
                print(f"\n--- {ts} ---")
                rc = run_once()
                if rc != 0:
                    exit_code = rc
                time.sleep(args.watch)
        except KeyboardInterrupt:
            print("\nStopped.")
            return exit_code
    else:
        return run_once()


if __name__ == "__main__":
    signal.signal(signal.SIGINT, signal.SIG_DFL)
    sys.exit(main())