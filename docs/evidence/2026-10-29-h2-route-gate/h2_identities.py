#!/usr/bin/env python3
"""Status of every route over h2c for four identities, and the comparison of two such runs (A4c).

`scripts/auth-route-baseline/probe.py` sends the requests that carry a Worker or Admin token over
HTTP/1.1 only. This sends them over h2c, so a change to the HTTP/2 gateway can be compared where
the credential is valid.

  h2_identities.py probe --routes routes.json --base-url URL --tokens tokens.json --out DIR
  h2_identities.py compare BEFORE_DIR AFTER_DIR

`probe` is meant to run as AUTH_BASELINE_AFTER of `run.sh` with AUTH_BASELINE_CREDENTIALS=1. Every
route gets `none`, `bad` (a bearer that matches nothing) and `worker`; `admin` is sent on GET only,
as in probe.py. A few paths the HTTP/2 gateway picks with a `when` guard, which the route table does
not list, are probed too. The server runs on a fresh base path with no keepers.
`compare` exits 1 when a status differs or a probe exists on one side only.
"""

from __future__ import annotations

import argparse
import importlib.util
import json
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
_spec = importlib.util.spec_from_file_location("a1_probe", ROOT / "scripts/auth-route-baseline/probe.py")
assert _spec is not None and _spec.loader is not None
a1 = importlib.util.module_from_spec(_spec)
sys.modules["a1_probe"] = a1  # its dataclass reads the module by name while it is being defined
_spec.loader.exec_module(a1)

# Paths the gateway matches with a `when` guard. A table row may cover them (a prefix), or
# not; the point is that the gateway and the table answer alike.
GUARD_PATHS: tuple[tuple[str, str], ...] = (
    ("GET", "/health/live"),
    ("GET", "/health/ready"),
    ("GET", "/dashboard/keepers"),
    ("GET", "/dashboard/assets/probe-a1.js"),
    ("GET", "/api/v1/keepers/hitl/late-approval-attempts"),
    ("GET", "/api/v1/keepers/probe-a1/child-content/receivers"),
    ("GET", "/api/v1/keepers/probe-a1/child-content/records"),
    ("GET", "/api/v1/keepers/probe-a1/native-tasks/receivers"),
    ("GET", "/api/v1/keepers/probe-a1/github-identity"),
    ("POST", "/api/v1/keepers/probe-a1/github-login"),
    ("GET", "/api/v1/dashboard/fusion-runs/probe-a1"),
    ("GET", "/api/v1/play/room"),
    ("POST", "/api/v1/play/room"),
    ("GET", "/api/v1/artifact-bytes/probe-a1"),
    ("GET", "/api/v1/board/sub-boards/probe-a1"),
    ("GET", "/api/v1/board/probe-a1"),
    ("GET", "/play/agent.md"),
    ("GET", "/static/css/middleware.css"),
    ("GET", "/api/v1/dashboard/namespace-truth"),
)


def h2_status(base_url: str, method: str, path: str, token: str | None, timeout_s: int) -> int:
    """HTTP status over h2c, or 0 when no status line arrived within the timeout."""
    cmd = [
        "curl", "-s", "-o", "/dev/null", "-w", "%{http_code}",
        "-m", str(timeout_s), "--connect-timeout", "2", "--http2-prior-knowledge",
        "-X", method,
    ]
    if token is not None:
        cmd += ["-H", f"Authorization: Bearer {token}"]
    if method in ("POST", "PUT"):
        cmd += ["-H", "content-type: application/json", "-d", "{}"]
    cmd.append(base_url + path)
    try:
        out = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout_s + 3).stdout
        return int(out.strip() or 0)
    except (subprocess.TimeoutExpired, ValueError):
        return 0


def probe(args: argparse.Namespace) -> int:
    tokens: dict[str, str] = json.loads(args.tokens.read_text(encoding="utf-8"))
    targets = [(p.method, p.probed_path) for p in a1.load_probes(args.routes)]
    seen = set(targets)
    targets += [t for t in GUARD_PATHS if t not in seen]
    credentials: dict[str, str | None] = {
        "none": None,
        "bad": a1.BAD_BEARER,
        "worker": tokens["worker"],
        "admin": tokens["admin"],
    }
    rows: list[dict[str, object]] = []
    died_at: list[str] = []
    for method, path in targets:
        row: dict[str, object] = {"method": method, "path": path}
        for identity, token in credentials.items():
            if identity == "admin" and method != "GET":
                row[identity] = None
                continue
            row[identity] = h2_status(args.base_url, method, path, token, args.timeout)
        rows.append(row)
        if not a1.healthy(args.base_url):
            died_at.append(f"{method} {path}")
            break
    args.out.mkdir(parents=True, exist_ok=True)
    (args.out / "h2_identities.json").write_text(
        json.dumps({"probes": len(targets), "answered": len(rows), "server_stopped_at": died_at, "rows": rows},
                   ensure_ascii=False, indent=1) + "\n",
        encoding="utf-8",
    )
    print(json.dumps({"h2_identities": {"probes": len(targets), "answered": len(rows), "server_stopped_at": died_at}}))
    return 0


def load(directory: Path) -> dict[tuple[str, str], dict[str, object]]:
    data = json.loads((directory / "h2_identities.json").read_text(encoding="utf-8"))
    if data["server_stopped_at"]:
        print(f"{directory}: the server stopped at {data['server_stopped_at']}", file=sys.stderr)
    return {(r["method"], r["path"]): r for r in data["rows"]}


def compare(args: argparse.Namespace) -> int:
    problems = 0
    total = 0
    for config in ("default", "strict"):
        before = load(args.before / config)
        after = load(args.after / config)
        for key in sorted(set(before) | set(after)):
            if key not in before or key not in after:
                print(f"[{config}] {key[0]:6} {key[1]}  on one side only")
                problems += 1
                continue
            b, a = before[key], after[key]
            total += sum(1 for i in ("none", "bad", "worker", "admin") if b[i] is not None)
            if any(b[i] != a[i] for i in ("none", "bad", "worker", "admin")):
                changes = ", ".join(f"{i} {b[i]}->{a[i]}" for i in ("none", "bad", "worker", "admin") if b[i] != a[i])
                print(f"[{config}] {key[0]:6} {key[1]}  {changes}")
                problems += 1
    print(f"compared {total} statuses, {problems} problems")
    return 1 if problems else 0


def main() -> int:
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="command", required=True)
    p = sub.add_parser("probe")
    p.add_argument("--routes", type=Path, required=True)
    p.add_argument("--base-url", required=True)
    p.add_argument("--tokens", type=Path, required=True)
    p.add_argument("--out", type=Path, required=True)
    p.add_argument("--timeout", type=int, default=3)
    p.set_defaults(run=probe)
    c = sub.add_parser("compare")
    c.add_argument("before", type=Path)
    c.add_argument("after", type=Path)
    c.set_defaults(run=compare)
    args = ap.parse_args()
    return args.run(args)


if __name__ == "__main__":
    raise SystemExit(main())
