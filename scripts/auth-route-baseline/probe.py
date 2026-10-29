#!/usr/bin/env python3
"""Auth baseline probe (plan layer A1).

Sends every route of the HTTP/1 router two requests, one with no credential and
one with a bearer that matches no token, over HTTP/1.1 and over HTTP/2 (h2c prior
knowledge), and records the status of each. It changes nothing in the server.

With `--tokens` it also sends each route, over HTTP/1.1, a request with no
credential, with the unmatched bearer, with a Worker token and with an Admin token,
and records for each the status, the response headers and a hash of the body.
Worker shows which routes refuse a token that lacks the permission, Admin which
routes let a permitted token through. Admin goes to GET routes only: with a
permitted token a POST, PUT or DELETE does its work, and this probe must not do that.
`--keep-bodies` also keeps the body of each, with run-specific text and the tokens blanked.

The route list comes from `tools/auth_route_inventory`. Point `--base-url` only at
a server started on an isolated base path with no keepers and no provider
credentials; several routes mutate state when they accept the request.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import subprocess
import tempfile
from collections import Counter
from collections.abc import Callable
from dataclasses import dataclass
from pathlib import Path
from typing import Literal

BAD_BEARER = "masc-a1-probe-token-that-matches-nothing"
Protocol = Literal["http1", "h2"]
Credential = Literal["none", "bad"]
Identity = Literal["none", "bad", "worker", "admin"]
IDENTITIES: tuple[Identity, ...] = ("none", "bad", "worker", "admin")
# Headers that differ between two requests of the same server for no reason of ours.
VOLATILE_HEADERS = frozenset({"date", "content-length", "server-timing"})
BODY_LIMIT = 262144
# Text that differs between two runs of the same build: the port, times, ids.
RUN_SPECIFIC = (
    (re.compile(r"127\.0\.0\.1:\d+"), "127.0.0.1:PORT"),
    (re.compile(r"\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}:\d{2}(\.\d+)?(Z|[+-]\d{2}:?\d{2})?"), "TIMESTAMP"),
    (re.compile(r"\b1[5-9]\d{8}(\.\d+)?\b|\b1[5-9]\d{11}\b"), "EPOCH"),
    (re.compile(r"\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b"), "UUID"),
    (re.compile(r"\b[0-9a-f]{24,}\b"), "HEX"),
)


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


def make_scrubber(work_dir: Path | None, tokens: dict[str, str]) -> Callable[[str], str]:
    """Blank what differs between runs, and every token, in a response before it is kept."""
    literals = [str(work_dir), str(work_dir.resolve())] if work_dir is not None else []

    def scrub(text: str) -> str:
        for token in tokens.values():
            text = text.replace(token, "<TOKEN>")
        for literal in literals:
            text = text.replace(literal, "<WORK>")
        for pattern, replacement in RUN_SPECIFIC:
            text = pattern.sub(replacement, text)
        return text

    return scrub


def parse_headers(raw: str, scrub: Callable[[str], str]) -> dict[str, str]:
    headers: dict[str, str] = {}
    for line in raw.splitlines():
        name, separator, value = line.partition(":")
        key = name.strip().lower()
        if not separator or line.startswith("HTTP/") or key in VOLATILE_HEADERS:
            continue
        cleaned = scrub(value.strip())
        headers[key] = f"{headers[key]}, {cleaned}" if key in headers else cleaned
    return headers


def body_file_name(probe: Probe, identity: Identity) -> str:
    key = f"{probe.method} {probe.route_path} {probe.probed_path}"
    return f"{hashlib.sha1(key.encode('utf-8')).hexdigest()[:16]}.{identity}.txt"


def fingerprint_of(
    base_url: str,
    probe: Probe,
    identity: Identity,
    tokens: dict[str, str],
    timeout_s: int,
    scrub: Callable[[str], str],
    body_dir: Path | None,
) -> dict[str, object]:
    """Status, response headers and a hash of the body, with run-specific text blanked.

    A status of 0 means no status line arrived within the timeout. With a `body_dir` the
    scrubbed body is also kept there, under the name `body_file` gives."""
    with tempfile.TemporaryDirectory() as scratch:
        header_file = Path(scratch) / "headers"
        body_file = Path(scratch) / "body"
        cmd = [
            "curl", "-s", "-D", str(header_file), "-o", str(body_file), "-w", "%{http_code}",
            "-m", str(timeout_s), "--connect-timeout", "2",
            "-X", probe.method,
        ]
        if identity == "bad":
            cmd += ["-H", f"Authorization: Bearer {BAD_BEARER}"]
        elif identity in tokens:
            cmd += ["-H", f"Authorization: Bearer {tokens[identity]}"]
        if probe.method in ("POST", "PUT"):
            cmd += ["-H", "content-type: application/json", "-d", "{}"]
        cmd.append(base_url + probe.probed_path)
        try:
            out = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout_s + 3).stdout
            status = int(out.strip() or 0)
        except (subprocess.TimeoutExpired, ValueError):
            status = 0
        raw_headers = header_file.read_text(encoding="utf-8", errors="replace") if header_file.exists() else ""
        body = body_file.read_bytes()[:BODY_LIMIT] if body_file.exists() else b""
    text = scrub(body.decode("utf-8", errors="replace"))
    fingerprint: dict[str, object] = {
        "status": status,
        "headers": parse_headers(raw_headers, scrub),
        "body_sha256": hashlib.sha256(text.encode("utf-8")).hexdigest(),
        "body_len": len(body),
    }
    if body_dir is not None:
        name = body_file_name(probe, identity)
        (body_dir / name).write_text(text, encoding="utf-8")
        fingerprint["body_file"] = name
    return fingerprint


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
    ap.add_argument("--tokens", type=Path, help='JSON {"worker": "...", "admin": "..."}; adds the credentialed requests')
    ap.add_argument("--work-dir", type=Path, help="the server's base path; blanked in the responses that are kept")
    ap.add_argument("--keep-bodies", action="store_true", help="keep each scrubbed response body under <out>/bodies/")
    args = ap.parse_args()

    tokens: dict[str, str] = json.loads(args.tokens.read_text(encoding="utf-8")) if args.tokens else {}
    scrub = make_scrubber(args.work_dir, tokens)
    body_dir: Path | None = args.out / "bodies" if args.keep_bodies else None
    if body_dir is not None:
        body_dir.mkdir(parents=True, exist_ok=True)
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
        if tokens:
            row["http1_responses"] = {
                identity: fingerprint_of(args.base_url, probe, identity, tokens, args.timeout, scrub, body_dir)
                for identity in IDENTITIES
                if identity != "admin" or probe.method == "GET"
            }
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
