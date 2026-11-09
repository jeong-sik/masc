#!/usr/bin/env python3
"""Transport parity of one auth-baseline run (RFC-0512 §5 and D5).

`run.sh` probes every route over HTTP/1.1 and over HTTP/2 (h2c) and writes
`<out-dir>/<mode>/results.json` for the `default` and the `strict` configuration.
One route table serves both transports, so the expected statuses are:

- `plain` routes: for every credential the HTTP/2 status equals the HTTP/1.1 status.
- `GET /ws` is a discovery request here: probe.py sends no WebSocket Upgrade
  headers, so it must answer the same status on both transports.
- Other `ws` routes are WebSocket-only (`GET /api/v1/ide/lsp` today): their
  handler gets no upgrade on HTTP/2 and answers 426 (RFC-0512 D5). HTTP/1.1
  reaches the handler, which answers on its own. Actual HTTP/1.1 Upgrade
  attempts are separate probe_extra.py cases and are not compared here.
- A status of 0 means the probe got no status line in time (probe.py). It is a finding on
  either side: parity cannot be read from a missing answer.

A run whose server stopped part-way (`answered` below `probes`, or `server_stopped_at`
not empty) cannot be used, and neither can a row this script does not understand. Both
end with exit 2 and a message on stderr. Exit 1 when any finding was printed, 0 when none.

  python3 scripts/auth-route-baseline/transport_diff.py <out-dir>
"""

from __future__ import annotations

import argparse
import json
import sys
from collections.abc import Sequence
from dataclasses import dataclass
from pathlib import Path
from typing import Literal, assert_never, cast

Mode = Literal["default", "strict"]
MODES: tuple[Mode, ...] = ("default", "strict")
Credential = Literal["none", "bad"]
CREDENTIALS: tuple[Credential, ...] = ("none", "bad")
Target = Literal["plain", "ws"]
Reason = Literal["differs", "h2_not_426", "no_answer"]

# A WebSocket-only handler answers this when the transport offers no upgrade.
UPGRADE_REQUIRED = 426
# probe.py records this when no status line arrived within its timeout.
NO_ANSWER = 0


@dataclass(frozen=True, slots=True)
class Row:
    """One route as probe.py wrote it: four statuses, one per transport and credential."""

    method: str
    route_path: str
    probed_path: str
    target: Target
    http1_none: int
    http1_bad: int
    h2_none: int
    h2_bad: int

    def statuses(self, credential: Credential) -> tuple[int, int]:
        """(HTTP/1.1 status, HTTP/2 status) for the credential."""
        match credential:
            case "none":
                return (self.http1_none, self.h2_none)
            case "bad":
                return (self.http1_bad, self.h2_bad)
            case _:
                assert_never(credential)


@dataclass(frozen=True, slots=True)
class Run:
    mode: Mode
    rows: tuple[Row, ...]


@dataclass(frozen=True, slots=True)
class Problem:
    """Why `<mode>/results.json` cannot be read as a complete run."""

    mode: Mode
    message: str


@dataclass(frozen=True, slots=True)
class Malformed:
    """Why one JSON row is not a Row."""

    message: str


@dataclass(frozen=True, slots=True)
class Finding:
    """One route and credential whose statuses are not what the route table predicts."""

    mode: Mode
    method: str
    route_path: str
    probed_path: str
    target: Target
    credential: Credential
    http1: int
    h2: int
    reason: Reason


def integer(value: object) -> int | None:
    """A count or status as probe.py writes it: an int, or its decimal text."""
    if isinstance(value, bool):
        return None
    if isinstance(value, int):
        return value
    if isinstance(value, str) and value.isdigit():
        return int(value)
    return None


def target(value: object) -> Target | None:
    match value:
        case "plain":
            return "plain"
        case "ws":
            return "ws"
        case _:
            return None


def as_object(value: object) -> dict[str, object] | None:
    if not isinstance(value, dict):
        return None
    return cast("dict[str, object]", value)


def parse_row(value: object) -> Row | Malformed:
    obj = as_object(value)
    if obj is None:
        return Malformed(f"not an object: {value!r}")
    texts: list[str] = []
    for key in ("method", "route_path", "probed_path"):
        text = obj.get(key)
        if not isinstance(text, str):
            return Malformed(f"{key} is not a string: {text!r}")
        texts.append(text)
    kind = target(obj.get("target"))
    if kind is None:
        return Malformed(f"target is not plain or ws: {obj.get('target')!r}")
    codes: list[int] = []
    for key in ("http1_none", "http1_bad", "h2_none", "h2_bad"):
        code = integer(obj.get(key))
        if code is None:
            return Malformed(f"{key} is not a status: {obj.get(key)!r}")
        codes.append(code)
    return Row(texts[0], texts[1], texts[2], kind, codes[0], codes[1], codes[2], codes[3])


def parse_run(out_dir: Path, mode: Mode) -> Run | Problem:
    """The complete run under `<out-dir>/<mode>/results.json`, or why it is not one."""
    path = out_dir / mode / "results.json"
    if not path.is_file():
        return Problem(mode, f"{path} is missing")
    try:
        data: object = json.loads(path.read_text(encoding="utf-8"))
    except json.JSONDecodeError as error:
        return Problem(mode, f"{path}: {error}")
    doc = as_object(data)
    if doc is None:
        return Problem(mode, f"{path}: the top level is not an object")
    probes = integer(doc.get("probes"))
    answered = integer(doc.get("answered"))
    stopped = doc.get("server_stopped_at")
    if probes is None or answered is None or not isinstance(stopped, list):
        return Problem(mode, f"{path}: probes, answered or server_stopped_at is missing")
    stopped_at = cast("list[object]", stopped)
    if answered != probes or stopped_at:
        return Problem(
            mode,
            f"{path}: the server stopped part-way ({answered} of {probes} routes answered,"
            f" stopped at {stopped_at!r}), so the run cannot be used",
        )
    raw_rows = doc.get("rows")
    if not isinstance(raw_rows, list):
        return Problem(mode, f"{path}: rows is not a list")
    rows: list[Row] = []
    for index, raw in enumerate(cast("list[object]", raw_rows)):
        parsed = parse_row(raw)
        match parsed:
            case Malformed():
                return Problem(mode, f"{path}: rows[{index}]: {parsed.message}")
            case Row():
                rows.append(parsed)
    return Run(mode, tuple(rows))


def reason(row: Row, http1: int, h2: int) -> Reason | None:
    """Why the pair is a finding, or None when it is what the route table predicts."""
    if http1 == NO_ANSWER or h2 == NO_ANSWER:
        return "no_answer"
    match row.target:
        case "plain":
            return None if http1 == h2 else "differs"
        case "ws":
            # This exact endpoint serves discovery for an ordinary GET; a
            # Ws registration alone does not make this an Upgrade attempt.
            if (row.method, row.route_path) == ("GET", "/ws"):
                return None if http1 == h2 else "differs"
            return None if h2 == UPGRADE_REQUIRED else "h2_not_426"
        case _:
            assert_never(row.target)


def findings(run: Run) -> tuple[Finding, ...]:
    found: list[Finding] = []
    for row in run.rows:
        for credential in CREDENTIALS:
            http1, h2 = row.statuses(credential)
            why = reason(row, http1, h2)
            if why is not None:
                found.append(
                    Finding(
                        run.mode,
                        row.method,
                        row.route_path,
                        row.probed_path,
                        row.target,
                        credential,
                        http1,
                        h2,
                        why,
                    )
                )
    return tuple(found)


def render(run: Run, found: tuple[Finding, ...]) -> str:
    """Markdown for the step summary: the findings, then the ws rows with their statuses."""
    ws_rows = [row for row in run.rows if row.target == "ws"]
    plain = len(run.rows) - len(ws_rows)
    lines = [
        f"### {run.mode}: {len(run.rows)} routes ({plain} plain, {len(ws_rows)} ws), {len(found)} findings",
        "",
    ]
    if found:
        lines.append("| method | route | probed | target | credential | http1 | h2 | reason |")
        lines.append("|---|---|---|---|---|---|---|---|")
        lines.extend(
            f"| {f.method} | `{f.route_path}` | `{f.probed_path}` | {f.target} | {f.credential}"
            f" | {f.http1} | {f.h2} | {f.reason} |"
            for f in found
        )
        lines.append("")
    if ws_rows:
        lines.append(
            "Ordinary GET /ws serves discovery on both transports; WebSocket-only"
            f" routes answer {UPGRADE_REQUIRED} on HTTP/2 (RFC-0512 D5)."
            " Actual Upgrade probes are separate in extra.json:"
        )
        lines.append("")
        lines.append("| method | route | http1 none | http1 bad | h2 none | h2 bad |")
        lines.append("|---|---|---|---|---|---|")
        lines.extend(
            f"| {r.method} | `{r.route_path}` | {r.http1_none} | {r.http1_bad} | {r.h2_none} | {r.h2_bad} |"
            for r in ws_rows
        )
        lines.append("")
    return "\n".join(lines)


def main(argv: Sequence[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("out_dir", type=Path, help="out-dir holding <mode>/results.json for default and strict")
    out_dir: Path = ap.parse_args(argv).out_dir
    runs: list[Run] = []
    for mode in MODES:
        run = parse_run(out_dir, mode)
        match run:
            case Problem():
                print(run.message, file=sys.stderr)
                return 2
            case Run():
                runs.append(run)
    total = 0
    for run in runs:
        found = findings(run)
        total += len(found)
        print(render(run, found))
    return 1 if total else 0


if __name__ == "__main__":
    raise SystemExit(main())
