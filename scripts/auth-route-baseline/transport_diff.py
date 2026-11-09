#!/usr/bin/env python3
"""Transport parity of one auth-baseline run (RFC-0512 §5).

`run.sh` probes every route over HTTP/1.1 and over HTTP/2 (h2c) and writes
`<out-dir>/<mode>/results.json` for the `default` and the `strict` configuration.
Both transports go through the same route table, so for every route and
credential the two statuses must be equal. This prints every row where they
differ, as a Markdown table per mode, and exits 1 when any row differs.

  python3 scripts/auth-route-baseline/transport_diff.py <out-dir>
"""

from __future__ import annotations

import argparse
import json
import sys
from dataclasses import dataclass
from pathlib import Path

MODES = ("default", "strict")
CREDENTIALS = ("none", "bad")


@dataclass(frozen=True, slots=True)
class Difference:
    """One route and credential whose HTTP/1.1 and HTTP/2 statuses differ."""

    mode: str
    method: str
    route_path: str
    probed_path: str
    credential: str
    http1: int
    h2: int


def status(row: dict[str, object], key: str) -> int:
    """The status the probe recorded under `key`; an int, or its decimal text."""
    value = row[key]
    if isinstance(value, bool):
        raise ValueError(f"{key} is a bool, not a status: {value!r}")
    if isinstance(value, int):
        return value
    if isinstance(value, str) and value.isdigit():
        return int(value)
    raise ValueError(f"{key} is not a status: {value!r}")


def differences(rows: list[dict[str, object]], mode: str) -> tuple[Difference, ...]:
    found: list[Difference] = []
    for row in rows:
        for credential in CREDENTIALS:
            http1 = status(row, f"http1_{credential}")
            h2 = status(row, f"h2_{credential}")
            if http1 != h2:
                found.append(
                    Difference(
                        mode,
                        str(row["method"]),
                        str(row["route_path"]),
                        str(row["probed_path"]),
                        credential,
                        http1,
                        h2,
                    )
                )
    return tuple(found)


def load_rows(out_dir: Path, mode: str) -> list[dict[str, object]]:
    data = json.loads((out_dir / mode / "results.json").read_text(encoding="utf-8"))
    rows = data["rows"]
    if not isinstance(rows, list):
        raise ValueError(f"{mode}/results.json: rows is not a list")
    return [row for row in rows if isinstance(row, dict)]


def render(mode: str, rows: int, found: tuple[Difference, ...]) -> str:
    lines = [f"### {mode}: {rows} routes, {len(found)} transport differences", ""]
    if found:
        lines.append("| method | route | probed | credential | http1 | h2 |")
        lines.append("|---|---|---|---|---|---|")
        lines.extend(
            f"| {d.method} | `{d.route_path}` | `{d.probed_path}` | {d.credential} | {d.http1} | {d.h2} |"
            for d in found
        )
        lines.append("")
    return "\n".join(lines)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("out_dir", type=Path, help="out-dir holding <mode>/results.json for default and strict")
    args = ap.parse_args()
    total = 0
    for mode in MODES:
        if not (args.out_dir / mode / "results.json").is_file():
            print(f"{mode}/results.json is missing under {args.out_dir}", file=sys.stderr)
            return 2
        rows = load_rows(args.out_dir, mode)
        found = differences(rows, mode)
        total += len(found)
        print(render(mode, len(rows), found))
    return 1 if total else 0


if __name__ == "__main__":
    raise SystemExit(main())
