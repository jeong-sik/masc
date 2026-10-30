#!/usr/bin/env python3
"""Requests that tell apart the two orders of the /dashboard page checks.

Before A4b the three /dashboard registrations ran `with_canonical_loopback_host`
(a request for another host is redirected) and then `with_public_read`. Now they run
`with_public_read` and then the host check. This sends the requests where the two
orders answer differently, to one server, and records what came back.

  dashboard_host_probe.py probe --port N --work-dir DIR --out FILE
  dashboard_host_probe.py compare BEFORE.json AFTER.json

`probe` polls the dashboard with a non-canonical Host while the server boots (the
window in which `with_public_read` answers 503), then, once /health/ready is 200, sends
every combination of host, page and workspace precondition. The server must be one
`dashboard_host_probe.sh` started: isolated, on loopback.
"""

from __future__ import annotations

import argparse
import http.client
import json
import re
import time
from collections import Counter
from pathlib import Path

PAGES = ("/dashboard", "/dashboard/", "/dashboard/settings")
BOOT_TIMEOUT_S = 180
BOOT_POLL_S = 0.05
# Each server runs in its own base path, and a redirect carries it in the query.
BASE_PLACEHOLDER = "<BASE>"
# The readiness answer of a server that is still booting.
NOT_READY = 503


def get(port: int, path: str, host: str) -> tuple[int, dict[str, str]]:
    """Status and response headers; status 0 when nothing answered."""
    connection = http.client.HTTPConnection("127.0.0.1", port, timeout=3)
    try:
        connection.request("GET", path, headers={"Host": host})
        response = connection.getresponse()
        response.read()
        return response.status, {name.lower(): value for name, value in response.getheaders()}
    except (OSError, http.client.HTTPException):
        return 0, {}
    finally:
        connection.close()


def workspace_roots(work_dir: Path) -> tuple[str, str]:
    """The base path and masc root the server reports, read from its log."""
    log = (work_dir / "server.log").read_text(encoding="utf-8", errors="replace")
    match = re.search(r"\[Workspace\] MASC base: (\S+)", log)
    base = match.group(1) if match else str(work_dir.resolve())
    return base, f"{base}/.masc"


def queries(base: str, root: str) -> dict[str, str]:
    return {
        "none": "",
        "one_parameter": "?expected_base_path=" + base,
        "mismatch": "?expected_base_path=/nowhere&expected_masc_root=/nowhere/.masc",
        "match": f"?expected_base_path={base}&expected_masc_root={root}",
    }


def probe(port: int, work_dir: Path, out: Path) -> None:
    non_canonical = f"localhost:{port}"
    canonical = f"127.0.0.1:{port}"

    # While the server boots: what does /dashboard answer for another host?
    boot: Counter[tuple[int, int]] = Counter()
    deadline = time.monotonic() + BOOT_TIMEOUT_S
    ready = 0
    while ready != 200 and time.monotonic() < deadline:
        dashboard, _ = get(port, "/dashboard", non_canonical)
        ready, _ = get(port, "/health/ready", canonical)
        if dashboard != 0 or ready != 0:
            boot[(dashboard, ready)] += 1
        time.sleep(BOOT_POLL_S)
    if ready != 200:
        raise SystemExit("the server did not become ready")

    base, root = workspace_roots(work_dir)
    rows: list[dict[str, object]] = []
    for host_label, host in (("other_host", non_canonical), ("canonical_host", canonical)):
        for page in PAGES:
            for label, query in queries(base, root).items():
                status, headers = get(port, page + query, host)
                rows.append(
                    {
                        "host": host_label,
                        "page": page,
                        "query": label,
                        "status": status,
                        "location": re.sub(r":\d+", ":PORT", headers.get("location", "")).replace(base, BASE_PLACEHOLDER),
                    }
                )
    result = {
        "boot": [
            {"dashboard_status": dashboard, "ready_status": ready_status, "samples": count}
            for (dashboard, ready_status), count in sorted(boot.items())
        ],
        "rows": rows,
    }
    out.write_text(json.dumps(result, ensure_ascii=False, indent=1) + "\n", encoding="utf-8")
    print(json.dumps({"boot": result["boot"], "rows": len(rows)}, ensure_ascii=False))


def compare(before_file: Path, after_file: Path) -> int:
    """Print both runs side by side. Returns the number of differences found."""
    before = json.loads(before_file.read_text(encoding="utf-8"))
    after = json.loads(after_file.read_text(encoding="utf-8"))
    differences = 0

    def keyed(data: dict[str, list[dict[str, object]]]) -> dict[tuple[str, str, str], dict[str, object]]:
        return {(str(r["host"]), str(r["page"]), str(r["query"])): r for r in data["rows"]}

    def answers(data: dict[str, list[dict[str, object]]]) -> set[tuple[object, object]]:
        return {(b["dashboard_status"], b["ready_status"]) for b in data["boot"]}

    old, new = keyed(before), keyed(after)
    print("boot window, dashboard status for another Host / readiness status: samples")
    for side, data in (("before", before), ("after", after)):
        cells = ", ".join(f"{b['dashboard_status']}/{b['ready_status']}: {b['samples']}" for b in data["boot"])
        print(f"  {side:6s} {cells}")
        # A window with no sample taken while the server was not ready shows nothing about the order.
        if not any(ready == NOT_READY for _, ready in answers(data)):
            differences += 1
            print(f"  {side}: no sample was taken while the server was not ready")
    # The number of samples depends on how long the boot took; the answers do not.
    if answers(before) != answers(after):
        differences += 1
        print("  the set of answers during boot differs")
    print()
    print(f"{'host':15s} {'page':22s} {'query':14s} {'before':28s} after")
    for key in sorted(old.keys() | new.keys()):
        if key not in old or key not in new:
            differences += 1
            print(f"{key[0]:15s} {key[1]:22s} {key[2]:14s} only on the {'before' if key in old else 'after'} side")
            continue
        a, b = old[key], new[key]

        def cell(row: dict[str, object]) -> str:
            where = f" -> {row['location']}" if row["location"] else ""
            return f"{row['status']}{where}"

        marker = "" if cell(a) == cell(b) else "  <-- differs"
        differences += bool(marker)
        print(f"{key[0]:15s} {key[1]:22s} {key[2]:14s} {cell(a):28s} {cell(b)}{marker}")
    print(f"\n{len(old.keys() | new.keys())} requests, {differences} differences")
    return differences


def main() -> int:
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="command", required=True)
    probe_ap = sub.add_parser("probe")
    probe_ap.add_argument("--port", type=int, required=True)
    probe_ap.add_argument("--work-dir", type=Path, required=True)
    probe_ap.add_argument("--out", type=Path, required=True)
    compare_ap = sub.add_parser("compare")
    compare_ap.add_argument("before", type=Path)
    compare_ap.add_argument("after", type=Path)
    args = ap.parse_args()
    if args.command == "probe":
        probe(args.port, args.work_dir, args.out)
        return 0
    return 1 if compare(args.before, args.after) else 0


if __name__ == "__main__":
    raise SystemExit(main())
