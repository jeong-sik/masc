#!/usr/bin/env python3
"""Auth baseline probe (plan layer A1).

Sends every route of the HTTP/1 router two requests, one with no credential and
one with a bearer that matches no token, over HTTP/1.1 and over HTTP/2 (h2c prior
knowledge), and records the status of each. It changes nothing in the server.

The route list comes from `tools/auth_route_inventory`. Point `--base-url` only at
a server started on an isolated base path with no keepers and no provider
credentials; several routes mutate state when they accept the request.
"""

from __future__ import annotations

import argparse
import json
import subprocess
from collections import Counter
from dataclasses import dataclass
from pathlib import Path
from typing import Literal

BAD_BEARER = "masc-a1-probe-token-that-matches-nothing"
Protocol = Literal["http1", "h2"]
Credential = Literal["none", "bad"]


@dataclass(frozen=True, slots=True)
class Probe:
    method: str
    route_path: str
    probed_path: str
    kind: str
    target: str


def probed_path(route_path: str, kind: str) -> str:
    """Exact routes are hit as registered; a prefix route gets one well-formed
    segment that names nothing."""
    return route_path if kind == "exact" else route_path.rstrip("/") + "/probe-a1"


def load_probes(routes_file: Path) -> list[Probe]:
    data = json.loads(routes_file.read_text(encoding="utf-8"))
    probes: list[Probe] = []
    for route in data["routes"]:
        for method in route["methods"]:
            probes.append(
                Probe(
                    method=method,
                    route_path=route["path"],
                    probed_path=probed_path(route["path"], route["kind"]),
                    kind=route["kind"],
                    target=route["target"],
                )
            )
    return probes


def status_of(
    base_url: str,
    probe: Probe,
    protocol: Protocol,
    credential: Credential,
    timeout_s: int,
) -> int:
    """HTTP status, or 0 when no status line arrived within the timeout."""
    cmd = [
        "curl", "-s", "-o", "/dev/null", "-w", "%{http_code}",
        "-m", str(timeout_s), "--connect-timeout", "2",
        "-X", probe.method,
    ]
    if protocol == "h2":
        cmd.append("--http2-prior-knowledge")
    if credential == "bad":
        cmd += ["-H", f"Authorization: Bearer {BAD_BEARER}"]
    if probe.method in ("POST", "PUT"):
        cmd += ["-H", "content-type: application/json", "-d", "{}"]
    cmd.append(base_url + probe.probed_path)
    try:
        out = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout_s + 3).stdout
        return int(out.strip() or 0)
    except (subprocess.TimeoutExpired, ValueError):
        return 0


def bucket(status: int) -> str:
    if status == 0:
        return "no_response"
    if status in (401, 403):
        return "reject"
    if status == 404:
        return "not_found"
    if status == 405:
        return "method_not_allowed"
    if 200 <= status < 300:
        return "ok"
    if 300 <= status < 400:
        return "redirect"
    if 400 <= status < 500:
        return "client_error"
    return "server_error"


def healthy(base_url: str) -> bool:
    out = subprocess.run(
        ["curl", "-s", "-o", "/dev/null", "-w", "%{http_code}", "-m", "3", base_url + "/health"],
        capture_output=True, text=True,
    ).stdout.strip()
    return out == "200"


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--routes", type=Path, required=True)
    ap.add_argument("--base-url", required=True)
    ap.add_argument("--out", type=Path, required=True)
    ap.add_argument("--timeout", type=int, default=3)
    args = ap.parse_args()

    probes = load_probes(args.routes)
    rows: list[dict[str, object]] = []
    died_at: list[str] = []
    for probe in probes:
        row: dict[str, object] = {
            "method": probe.method,
            "route_path": probe.route_path,
            "probed_path": probe.probed_path,
            "kind": probe.kind,
            "target": probe.target,
        }
        for protocol in ("http1", "h2"):
            for credential in ("none", "bad"):
                row[f"{protocol}_{credential}"] = status_of(
                    args.base_url, probe, protocol, credential, args.timeout
                )
        rows.append(row)
        if not healthy(args.base_url):
            died_at.append(f"{probe.method} {probe.probed_path}")
            row["server_stopped_after_this_probe"] = True
            break

    args.out.mkdir(parents=True, exist_ok=True)
    (args.out / "results.json").write_text(
        json.dumps({"probes": len(probes), "answered": len(rows), "server_stopped_at": died_at, "rows": rows},
                   ensure_ascii=False, indent=1) + "\n",
        encoding="utf-8",
    )

    counts: Counter[str] = Counter()
    for row in rows:
        for key in ("http1_none", "http1_bad", "h2_none", "h2_bad"):
            counts[f"{key}:{bucket(int(row[key]))}"] += 1  # type: ignore[arg-type]
    print(json.dumps({"probes": len(probes), "answered": len(rows),
                      "server_stopped_at": died_at, "counts": dict(sorted(counts.items()))},
                     ensure_ascii=False, indent=1))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
