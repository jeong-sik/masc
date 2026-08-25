#!/usr/bin/env python3
"""Report what is actually in the AGENT_CORE request payloads MASC sends.

Every keeper turn writes its exact request to
``<base>/.masc/traces/<trace>/agent-core-snapshot-*.json``: system_prompt, tools and
messages verbatim. Nothing reads them. This walks that directory and answers
the questions the files already contain:

  - how the payload splits across system_prompt / tools / messages
  - how many offered tools are ever called, and how many schema bytes are spent
    on ones that are not
  - whether one tool dominates the conversation, which is what a polling loop
    looks like from the outside
  - whether consecutive calls to a tool carry identical input, which is what a
    loop that learns nothing looks like

Exit status is 0 for a report and 1 when a threshold is exceeded, so this can
become a gate without changing the output format.

Traces live under ``<base-path>/.masc/traces``. RFC-0121 makes MASC_BASE_PATH
the sole canonical source for that base path; there is no home-directory or cwd
fallback. Pass --traces-dir to point at an exported copy instead.

Usage:
    MASC_BASE_PATH=<base> scripts/audit-agent-core-payload.py [--json] [--limit N]
                                 [--traces-dir DIR]
                                 [--max-top-tool-share PCT]
                                 [--max-repeat-run N]
                                 [--min-tool-usage PCT]
"""

from __future__ import annotations

import argparse
import json
import os
import sys
from collections import Counter
from dataclasses import dataclass
from pathlib import Path
from typing import Final

# A single tool holding more of the turn budget than this is a loop, not work.
DEFAULT_MAX_TOP_TOOL_SHARE: Final[float] = 60.0
# Consecutive identical calls to one tool. Two is a retry; twenty is a loop.
DEFAULT_MAX_REPEAT_RUN: Final[int] = 10
# Offered tools that are never called still cost their schema bytes every turn.
DEFAULT_MIN_TOOL_USAGE: Final[float] = 25.0

SNAPSHOT_GLOB: Final[str] = "agent-core-snapshot-*.json"
MASC_DIRNAME: Final[str] = ".masc"
TRACES_DIRNAME: Final[str] = "traces"


def default_traces_dir() -> Path | None:
    """Resolve <base-path>/.masc/traces from MASC_BASE_PATH.

    RFC-0121: MASC_BASE_PATH is the sole canonical source. No home-directory or
    cwd fallback — a wrong base path would silently audit someone else's
    workspace and report confident numbers about it.
    """
    value = os.environ.get("MASC_BASE_PATH", "").strip()
    if not value:
        return None
    return Path(value) / MASC_DIRNAME / TRACES_DIRNAME


@dataclass(frozen=True, slots=True)
class ToolUse:
    name: str
    payload: str


@dataclass(frozen=True, slots=True)
class Snapshot:
    path: Path
    total_bytes: int
    system_bytes: int
    tools_bytes: int
    messages_bytes: int
    message_count: int
    offered: tuple[str, ...]
    unused_schema_bytes: int
    calls: tuple[ToolUse, ...]
    tool_choice: str | None

    @property
    def call_counts(self) -> Counter[str]:
        return Counter(call.name for call in self.calls)

    @property
    def top_tool(self) -> tuple[str, int] | None:
        counts = self.call_counts.most_common(1)
        return counts[0] if counts else None

    @property
    def top_tool_share(self) -> float:
        top = self.top_tool
        if top is None or not self.calls:
            return 0.0
        return 100.0 * top[1] / len(self.calls)

    @property
    def tool_usage_ratio(self) -> float:
        if not self.offered:
            return 0.0
        return 100.0 * len(self.call_counts) / len(self.offered)

    @property
    def longest_repeat_run(self) -> tuple[str, int]:
        """Longest run of consecutive calls to one tool carrying identical input."""
        best_name, best_len = "", 0
        run_name, run_payload, run_len = "", "", 0
        for call in self.calls:
            if call.name == run_name and call.payload == run_payload:
                run_len += 1
            else:
                run_name, run_payload, run_len = call.name, call.payload, 1
            if run_len > best_len:
                best_name, best_len = run_name, run_len
        return best_name, best_len


def _encoded_length(value: object) -> int:
    if isinstance(value, str):
        return len(value)
    return len(json.dumps(value, ensure_ascii=False))


def _tool_uses(messages: list[object]) -> tuple[ToolUse, ...]:
    uses: list[ToolUse] = []
    for message in messages:
        if not isinstance(message, dict):
            continue
        content = message.get("content")
        if not isinstance(content, list):
            continue
        for block in content:
            if not isinstance(block, dict) or block.get("type") != "tool_use":
                continue
            name = block.get("name")
            if not isinstance(name, str):
                continue
            uses.append(
                ToolUse(
                    name=name,
                    payload=json.dumps(block.get("input"), sort_keys=True),
                )
            )
    return tuple(uses)


def load_snapshot(path: Path) -> Snapshot | None:
    try:
        raw = json.loads(path.read_text())
    except (OSError, json.JSONDecodeError):
        return None
    if not isinstance(raw, dict):
        return None

    system = raw.get("system_prompt")
    tools = raw.get("tools")
    messages = raw.get("messages")
    tools_list: list[object] = tools if isinstance(tools, list) else []
    messages_list: list[object] = messages if isinstance(messages, list) else []

    calls = _tool_uses(messages_list)
    called = {call.name for call in calls}

    offered: list[str] = []
    unused_bytes = 0
    for tool in tools_list:
        if not isinstance(tool, dict):
            continue
        name = tool.get("name")
        if not isinstance(name, str):
            continue
        offered.append(name)
        if name not in called:
            unused_bytes += _encoded_length(tool)

    choice = raw.get("tool_choice")
    return Snapshot(
        path=path,
        total_bytes=_encoded_length(raw),
        system_bytes=_encoded_length(system) if system is not None else 0,
        tools_bytes=_encoded_length(tools_list),
        messages_bytes=_encoded_length(messages_list),
        message_count=len(messages_list),
        offered=tuple(offered),
        unused_schema_bytes=unused_bytes,
        calls=calls,
        tool_choice=None if choice is None else json.dumps(choice),
    )


def _pct(part: int, whole: int) -> float:
    return 100.0 * part / whole if whole else 0.0


def render_text(snapshots: list[Snapshot], violations: list[str]) -> str:
    lines: list[str] = []
    header = (
        f"{'snapshot':26s} {'total':>10s} {'sys%':>5s} {'tool%':>6s} {'msg%':>5s} "
        f"{'calls':>6s} {'used/offered':>13s} {'top tool':>34s}"
    )
    lines.append(header)
    lines.append("-" * len(header))
    for snap in snapshots:
        top = snap.top_tool
        top_text = f"{top[0]}x{top[1]} ({snap.top_tool_share:.0f}%)" if top else "-"
        used_offered = f"{len(snap.call_counts)}/{len(snap.offered)}"
        lines.append(
            f"{snap.path.name[-26:]:26s} {snap.total_bytes:10,d} "
            f"{_pct(snap.system_bytes, snap.total_bytes):5.1f} "
            f"{_pct(snap.tools_bytes, snap.total_bytes):6.1f} "
            f"{_pct(snap.messages_bytes, snap.total_bytes):5.1f} "
            f"{len(snap.calls):6d} "
            f"{used_offered:>13s} "
            f"{top_text:>34s}"
        )

    total = sum(s.total_bytes for s in snapshots)
    unused = sum(s.unused_schema_bytes for s in snapshots)
    tools_bytes = sum(s.tools_bytes for s in snapshots)
    lines.append("")
    lines.append(f"snapshots            : {len(snapshots)}")
    lines.append(f"payload total        : {total:,d} bytes")
    lines.append(
        f"unused tool schemas  : {unused:,d} of {tools_bytes:,d} tool bytes "
        f"({_pct(unused, tools_bytes):.1f}%), {_pct(unused, total):.1f}% of payload"
    )

    runs = [s.longest_repeat_run for s in snapshots]
    worst = max(runs, key=lambda r: r[1], default=("", 0))
    lines.append(f"longest identical run: {worst[0] or '-'} x{worst[1]}")

    choices = Counter(
        s.tool_choice for s in snapshots if s.tool_choice not in (None, "null")
    )
    if choices:
        lines.append(f"tool_choice set      : {dict(choices)}")

    if violations:
        lines.append("")
        lines.append("THRESHOLDS EXCEEDED:")
        lines.extend(f"  - {v}" for v in violations)
    return "\n".join(lines)


def collect_violations(
    snapshots: list[Snapshot],
    *,
    max_top_tool_share: float,
    max_repeat_run: int,
    min_tool_usage: float,
) -> list[str]:
    violations: list[str] = []
    for snap in snapshots:
        top = snap.top_tool
        if top is not None and snap.top_tool_share > max_top_tool_share:
            violations.append(
                f"{snap.path.name}: {top[0]} is {snap.top_tool_share:.0f}% of "
                f"{len(snap.calls)} calls (limit {max_top_tool_share:.0f}%)"
            )
        name, run = snap.longest_repeat_run
        if run > max_repeat_run:
            violations.append(
                f"{snap.path.name}: {name} called {run} times consecutively with "
                f"identical input (limit {max_repeat_run})"
            )
        if snap.offered and snap.tool_usage_ratio < min_tool_usage:
            violations.append(
                f"{snap.path.name}: {len(snap.call_counts)} of {len(snap.offered)} "
                f"offered tools used ({snap.tool_usage_ratio:.0f}%, "
                f"floor {min_tool_usage:.0f}%)"
            )
    return violations


def snapshot_to_json(snap: Snapshot) -> dict[str, object]:
    top = snap.top_tool
    run_tool, run_len = snap.longest_repeat_run
    return {
        "path": str(snap.path),
        "total_bytes": snap.total_bytes,
        "system_bytes": snap.system_bytes,
        "tools_bytes": snap.tools_bytes,
        "messages_bytes": snap.messages_bytes,
        "message_count": snap.message_count,
        "offered_tools": len(snap.offered),
        "used_tools": len(snap.call_counts),
        "unused_schema_bytes": snap.unused_schema_bytes,
        "tool_calls": len(snap.calls),
        "top_tool": top[0] if top else None,
        "top_tool_calls": top[1] if top else 0,
        "top_tool_share_pct": round(snap.top_tool_share, 1),
        "longest_identical_run": run_len,
        "longest_identical_run_tool": run_tool or None,
        "tool_choice": snap.tool_choice,
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--traces-dir",
        default=None,
        help=(
            "directory holding <trace>/agent-core-snapshot-*.json "
            "(default: $MASC_BASE_PATH/.masc/traces)"
        ),
    )
    parser.add_argument("--json", action="store_true", help="emit machine-readable JSON")
    parser.add_argument(
        "--limit", type=int, default=20, help="newest N snapshots (default 20)"
    )
    parser.add_argument(
        "--max-top-tool-share", type=float, default=DEFAULT_MAX_TOP_TOOL_SHARE
    )
    parser.add_argument("--max-repeat-run", type=int, default=DEFAULT_MAX_REPEAT_RUN)
    parser.add_argument("--min-tool-usage", type=float, default=DEFAULT_MIN_TOOL_USAGE)
    args = parser.parse_args()

    root = Path(args.traces_dir) if args.traces_dir else default_traces_dir()
    if root is None:
        print(
            "MASC_BASE_PATH is required (RFC-0121: sole canonical source, no "
            "home/cwd fallback). Export it, or pass --traces-dir explicitly.",
            file=sys.stderr,
        )
        return 2
    if not root.is_dir():
        print(f"no traces directory: {root}", file=sys.stderr)
        return 2

    paths = sorted(root.glob(f"*/{SNAPSHOT_GLOB}"), key=lambda p: p.stat().st_mtime)
    if args.limit > 0:
        paths = paths[-args.limit :]
    if not paths:
        print(f"no {SNAPSHOT_GLOB} under {root}", file=sys.stderr)
        return 2

    snapshots = [snap for snap in (load_snapshot(p) for p in paths) if snap is not None]
    if not snapshots:
        print(f"every snapshot under {root} failed to parse", file=sys.stderr)
        return 2

    violations = collect_violations(
        snapshots,
        max_top_tool_share=args.max_top_tool_share,
        max_repeat_run=args.max_repeat_run,
        min_tool_usage=args.min_tool_usage,
    )

    if args.json:
        print(
            json.dumps(
                {
                    "snapshots": [snapshot_to_json(s) for s in snapshots],
                    "violations": violations,
                },
                indent=2,
            )
        )
    else:
        print(render_text(snapshots, violations))

    return 1 if violations else 0


if __name__ == "__main__":
    sys.exit(main())
