#!/usr/bin/env python3
"""Report registered tools that recorded no call in a trailing window.

Why this file exists
====================

#49174: 37 of 188 server tools were never called in 30 days and nothing in CI
looked for that. `scripts/audit-dead-surface.py` covers OCaml modules only and
was never wired into CI. This script covers the tool inventory half, and it is
deliberately louder about *what it does not know* than about the tools it
calls unused.

Denominator
-----------

`config/tools/*.toml`, one tool per file, `name = "<wire name>"`. The count is
read from the tree being audited, so a tool deleted on main never shows up in
the numerator of a later run.

Numerator, and why one source is not enough
-------------------------------------------

The runtime records tool calls in more than one place, and they do not all
record the same families. That gap is exactly what #49174 measured: 30-day
`tool_metric_events` rows for `keeper_compose_*`, `keeper_job_*` and
`masc_fusion` were 0 while `.masc/tool_calls` held 3,173 calls in the same
window. Treating a sqlite 0 as "never called" produces false positives.

Two sources are understood here:

  * ``tool_calls`` ledger — ``<base>/.masc/tool_calls/YYYY-MM/DD.jsonl``.
    Written by the Agent Core post-tool hook for every keeper tool call, plus
    the composition surface for composition children
    (``lib/keeper_hooks_agent_core.ml``, ``lib/keeper_tool_composition_surface.ml``
    per #38824). Declared to record every family.

  * ``tool_metric_events`` — ``<base>/.masc/tool-metrics.sqlite3``, written by
    ``Tool_registry.record_call``, which the Keeper side reaches only from the
    descriptor execution path (``lib/keeper/keeper_tools_agent_core_handler_exec.ml``
    per #38824). Skill, search and composition calls are absent.

A tool is reported ``unused`` only when at least one *available* source
declares that it records the tool's family and that source counted zero. When
every available source is silent about the family, the tool is ``unverified``
with the reason attached — never ``unused``. Silence is not zero calls.

The coverage declaration is data (see ``DEFAULT_COVERAGE``) and can be
replaced with ``--coverage-json`` so a future fix (#38824) can widen it
without touching this file.

Output
------

Markdown (default) or ``--format json``. Always carries: the registry count,
the exact window, every source's availability and coverage, the unused list,
the unverified list, and observed names that do not map to any registered
tool (removed tools and external MCP names).

Exit status is 0 even when unused tools are found: the issue's `must-do` is
false, so this is a report, not a gate. ``--strict`` opts into a non-zero exit
for a caller that wants one.
"""

from __future__ import annotations

import argparse
import json
import re
import sqlite3
import sys
import tomllib
from dataclasses import dataclass, field
from datetime import datetime, timedelta, timezone
from pathlib import Path

# ---------------------------------------------------------------------------
# Families and coverage
# ---------------------------------------------------------------------------

# Order matters: the first matching prefix wins. `keeper_compose_*` (a
# composition child) and `keeper_composition_*` (a composition run/status
# call) are different families even though the words look alike.
FAMILY_RULES: tuple[tuple[str, tuple[str, ...]], ...] = (
    ("composition", ("keeper_compose_",)),
    ("skill", ("keeper_skill",)),
    ("async_job", ("keeper_job_",)),
    ("composition_control", ("keeper_composition_",)),
    ("fusion", ("masc_fusion",)),
)
DEFAULT_FAMILY = "direct"

ALL_FAMILIES = (DEFAULT_FAMILY,) + tuple(name for name, _ in FAMILY_RULES)

# Declared per-source coverage. `recorded` means "this source writes a row for
# every call of this family"; `not_recorded` means "this source cannot see the
# family"; `unknown` means "nobody has proven either way".
#
# Evidence for the `tool_metric_events` row: #38824 body — the Keeper side
# calls `Tool_registry.record_call` only from the descriptor execution path, so
# Skill / search / composition never reach it. #49174 confirms the practical
# consequence (0 sqlite rows vs 3,173 ledger rows for the same families).
DEFAULT_COVERAGE: dict[str, dict[str, str]] = {
    "tool_calls": {family: "recorded" for family in ALL_FAMILIES},
    "tool_metric_events": {
        DEFAULT_FAMILY: "recorded",
        "composition": "not_recorded",
        "skill": "not_recorded",
        "async_job": "not_recorded",
        "fusion": "not_recorded",
        # A composition run/status call is a plain descriptor tool, so it
        # probably is recorded — but #49174 saw 0 rows and nobody separated
        # "never used" from "not recorded". Leave it unknown on purpose.
        "composition_control": "unknown",
    },
    "dashboard_snapshot": {family: "unknown" for family in ALL_FAMILIES},
}


# ---------------------------------------------------------------------------
# Small helpers
# ---------------------------------------------------------------------------


def norm(name: str) -> str:
    """Matching key that survives the two spellings both sources use.

    The registry says `masc_board_list`; `tool_metric_events` has rows written
    as `MascBoardComment` (#49482 evidence). Lowercase alphanumerics only is
    the narrowest bridge that covers both; it is intentionally not a fuzzy
    match, so two different tools cannot collide by suffix.
    """
    return re.sub(r"[^a-z0-9]", "", name.lower())


def family_of(name: str) -> str:
    lowered = name.lower()
    for family, prefixes in FAMILY_RULES:
        if any(lowered.startswith(prefix) for prefix in prefixes):
            return family
    return DEFAULT_FAMILY


def parse_now(value: str | None) -> datetime:
    if not value:
        return datetime.now(timezone.utc)
    if re.fullmatch(r"\d+(\.\d+)?", value):
        return datetime.fromtimestamp(float(value), tz=timezone.utc)
    text = value.strip()
    if text.endswith("Z"):
        text = text[:-1] + "+00:00"
    parsed = datetime.fromisoformat(text)
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=timezone.utc)
    return parsed.astimezone(timezone.utc)


def iso(ts: float) -> str:
    return datetime.fromtimestamp(ts, tz=timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


# ---------------------------------------------------------------------------
# Registry
# ---------------------------------------------------------------------------

NAME_RE = re.compile(r'^\s*name\s*=\s*"([^"]+)"', re.MULTILINE)


@dataclass
class Registry:
    directory: str
    files: int
    tools: dict[str, str] = field(default_factory=dict)  # norm -> wire name
    duplicates: list[str] = field(default_factory=list)
    errors: list[str] = field(default_factory=list)
    # A second registry: `addons/<id>/lane.toml` declares its exported tool
    # names under `[world.tools].export`. Those names are real tools, but they
    # live in a per-addon contract rather than in `config/tools`, so a report
    # that reads only `config/tools` calls each of them "outside the registry"
    # (#3446). Kept separate from `tools` so the config/tools population and
    # its count do not move.
    addon_directory: str = ""
    addon_files: int = 0
    addons: dict[str, str] = field(default_factory=dict)  # norm -> addon id
    addon_errors: list[str] = field(default_factory=list)

    @property
    def count(self) -> int:
        return len(self.tools)

    @property
    def addon_count(self) -> int:
        return len(self.addons)


def load_addon_exports(directory: Path) -> tuple[dict[str, str], int, list[str]]:
    """Read `[world.tools].export` from every `addons/*/lane.toml`.

    Returns (norm -> addon id, files read, errors). A missing directory is not
    an error: callers that pass `--no-addons` never get here, and a checkout
    without addons is legitimate.
    """
    exports: dict[str, str] = {}
    errors: list[str] = []
    files = 0
    if not directory.is_dir():
        return exports, files, errors
    for path in sorted(directory.glob("*/lane.toml")):
        files += 1
        try:
            data = tomllib.loads(path.read_text(encoding="utf-8"))
        except (OSError, tomllib.TOMLDecodeError) as exc:
            errors.append(f"{path}: {exc}")
            continue
        world = data.get("world")
        tools = world.get("tools") if isinstance(world, dict) else None
        names = tools.get("export") if isinstance(tools, dict) else None
        if not isinstance(names, list):
            continue
        addon_id = path.parent.name
        for name in names:
            if not isinstance(name, str) or not name:
                continue
            key = norm(name)
            if key in exports and exports[key] != addon_id:
                errors.append(f"{path}: {name} already exported by {exports[key]}")
                continue
            exports[key] = addon_id
    return exports, files, errors


def load_registry(directory: Path) -> Registry:
    registry = Registry(directory=str(directory), files=0)
    if not directory.is_dir():
        registry.errors.append(f"registry directory not found: {directory}")
        return registry
    for path in sorted(directory.glob("*.toml")):
        registry.files += 1
        try:
            text = path.read_text(encoding="utf-8")
        except OSError as exc:  # pragma: no cover - unreadable file
            registry.errors.append(f"{path.name}: {exc}")
            continue
        match = NAME_RE.search(text)
        if not match:
            registry.errors.append(f"{path.name}: no `name = \"...\"` line")
            continue
        name = match.group(1)
        key = norm(name)
        if key in registry.tools and registry.tools[key] != name:
            registry.duplicates.append(f"{path.name}: {name} ~ {registry.tools[key]}")
            continue
        registry.tools[key] = name
    return registry


# ---------------------------------------------------------------------------
# Sources
# ---------------------------------------------------------------------------


@dataclass
class SourceResult:
    name: str
    location: str
    available: bool
    detail: str
    counts: dict[str, int] = field(default_factory=dict)  # norm -> calls
    raw_names: dict[str, str] = field(default_factory=dict)  # norm -> observed
    # norm -> every norm that named the same calls. A single tool can appear as
    # `tool_write_file` in the registry and `Write` in the ledger; this records
    # the union so the report can tell "never called" from "called under the
    # other spelling" (#49174 P1).
    alias_groups: dict[str, set[str]] = field(default_factory=dict)
    rows: int = 0
    files: int = 0
    first_ts: float | None = None
    last_ts: float | None = None
    # Newest timestamp seen anywhere in the source, including rows outside the
    # window. A ledger whose newest row predates the window is a stale copy, and
    # its silence is not evidence that nothing was called (#50504).
    newest_ts: float | None = None
    # Cumulative sources (a dashboard snapshot) have no window, so staleness is
    # not defined for them.
    windowed: bool = True


def load_ledger(directory: Path, start: float, end: float) -> SourceResult:
    result = SourceResult(
        name="tool_calls",
        location=str(directory),
        available=False,
        detail="",
    )
    if not directory.is_dir():
        result.detail = "ledger directory not found"
        return result
    jsonl_files = sorted(directory.glob("**/*.jsonl"))
    if not jsonl_files:
        result.detail = "no *.jsonl files under the ledger directory"
        return result
    result.available = True
    result.files = len(jsonl_files)
    for path in jsonl_files:
        try:
            handle = path.open("r", encoding="utf-8", errors="replace")
        except OSError as exc:
            result.detail = f"unreadable {path}: {exc}"
            continue
        with handle:
            for line in handle:
                line = line.strip()
                if not line:
                    continue
                try:
                    record = json.loads(line)
                except json.JSONDecodeError:
                    continue
                ts = record.get("ts")
                if not isinstance(ts, (int, float)):
                    continue
                # Remember the newest row even when it falls outside the window.
                # That single number is what tells a live-but-quiet ledger from
                # a stale copy (#50504).
                if result.newest_ts is None or ts > result.newest_ts:
                    result.newest_ts = ts
                if ts < start or ts >= end:
                    continue
                tool = record.get("tool") or record.get("tool_name")
                if not isinstance(tool, str) or not tool:
                    continue
                result.rows += 1
                # One call can be known by more than one name. The registry
                # spells five tools `tool_write_file` style while the ledger's
                # `tool` field carries the public name (`Write`); norm() alone
                # never joins them, so the registry entry would look like it
                # was never called (#49174 P1). The same row usually states
                # both names under route_evidence, so credit every name the
                # row itself declares. No hardcoded alias table: a row without
                # route_evidence still counts only its own `tool` value.
                names = [tool]
                route = record.get("route_evidence")
                if isinstance(route, dict):
                    seen = {norm(tool)}
                    for field in ("canonical_name", "public_name", "runtime_handler"):
                        alias = route.get(field)
                        if not isinstance(alias, str) or not alias:
                            continue
                        alias_key = norm(alias)
                        if alias_key and alias_key not in seen:
                            seen.add(alias_key)
                            names.append(alias)
                group = result.alias_groups.setdefault(norm(tool), set())
                for name in names:
                    key = norm(name)
                    group.add(key)
                    result.counts[key] = result.counts.get(key, 0) + 1
                    result.raw_names.setdefault(key, name)
                result.first_ts = ts if result.first_ts is None else min(result.first_ts, ts)
                result.last_ts = ts if result.last_ts is None else max(result.last_ts, ts)
    if not result.detail:
        result.detail = f"{result.rows} rows in window from {result.files} files"
    return result


def load_metric_events(db_path: Path, start: float, end: float) -> SourceResult:
    result = SourceResult(
        name="tool_metric_events",
        location=str(db_path),
        available=False,
        detail="",
    )
    if not db_path.is_file():
        result.detail = "sqlite database not found"
        return result
    uri = f"file:{db_path}?mode=ro"
    try:
        conn = sqlite3.connect(uri, uri=True, timeout=5)
    except sqlite3.Error as exc:
        result.detail = f"sqlite open failed: {exc}"
        return result
    try:
        try:
            rows = conn.execute(
                "SELECT tool_name, COUNT(*), MIN(ts), MAX(ts) "
                "FROM tool_metric_events WHERE ts >= ? AND ts < ? "
                "GROUP BY tool_name",
                (start, end),
            ).fetchall()
        except sqlite3.Error as exc:
            result.detail = f"tool_metric_events unreadable: {exc}"
            return result
        result.available = True
        for tool_name, count, first_ts, last_ts in rows:
            if not isinstance(tool_name, str) or not tool_name:
                continue
            key = norm(tool_name)
            result.counts[key] = result.counts.get(key, 0) + int(count)
            result.raw_names.setdefault(key, tool_name)
            result.rows += int(count)
            if first_ts is not None:
                result.first_ts = first_ts if result.first_ts is None else min(result.first_ts, first_ts)
            if last_ts is not None:
                result.last_ts = last_ts if result.last_ts is None else max(result.last_ts, last_ts)
        result.detail = f"{result.rows} rows in window across {len(rows)} tools"
    finally:
        conn.close()
    return result


def load_snapshot(path: Path) -> SourceResult:
    """Cumulative dashboard projection (no window).

    `dashboard/src/components/tools/fixtures/tool-usage-53203.json` is the
    allowlisted shape this reads: `inventory` plus `original_metrics.top_20`
    when present. It is a fallback for a machine with no runtime state, and
    the report says the window does not apply so nobody mistakes it for a
    30-day count. Only `top_20` carries per-tool counts, so tools outside it
    are `unknown`, not `unused`.
    """
    result = SourceResult(
        name="dashboard_snapshot",
        location=str(path),
        available=False,
        detail="",
    )
    if not path.is_file():
        result.detail = "snapshot json not found"
        return result
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        result.detail = f"snapshot unreadable: {exc}"
        return result
    result.available = True
    # Cumulative projection: it carries no timestamps, so the window and its
    # staleness rule do not apply to it (#50504).
    result.windowed = False
    metrics = payload.get("original_metrics") or {}
    top = metrics.get("top_20") or []
    for row in top:
        name = row.get("name")
        count = row.get("call_count")
        if not isinstance(name, str) or not isinstance(count, int):
            continue
        key = norm(name)
        result.counts[key] = count
        result.raw_names.setdefault(key, name)
        result.rows += count
    inventory = payload.get("inventory") or []
    result.detail = (
        f"cumulative projection (no window); inventory {len(inventory)} names, "
        f"{len(top)} tools with counts, {result.rows} calls total"
    )
    return result


# ---------------------------------------------------------------------------
# Report
# ---------------------------------------------------------------------------


@dataclass
class ToolRow:
    name: str
    family: str
    status: str  # used | unused | unverified
    calls: dict[str, int] = field(default_factory=dict)
    reasons: list[str] = field(default_factory=list)


@dataclass
class Report:
    registry: Registry
    window_start: float
    window_end: float
    window_days: int
    window_kind: str
    sources: list[SourceResult]
    coverage: dict[str, dict[str, str]]
    rows: list[ToolRow]
    unregistered_observed: list[tuple[str, dict[str, int]]]
    # Names the ledger saw that `config/tools` does not declare but an
    # `addons/<id>/lane.toml` export does. Split out so "outside the registry"
    # keeps meaning what it says (#3446): (name, addon id, per-source counts).
    unregistered_addon: list[tuple[str, str, dict[str, int]]] = field(default_factory=list)
    retired: list[str] = field(default_factory=list)

    def by_status(self, status: str) -> list[ToolRow]:
        return [row for row in self.rows if row.status == status]


def can_judge_zero(source: SourceResult, window_start: float) -> bool:
    """Whether this source may turn its silence into a `0회` verdict.

    A ledger directory can exist with files whose rows all predate the window:
    that copy stopped being written, so "no row for this tool" says nothing
    about whether the tool is used (#50504). Only a row at or after the window
    start proves the source was watching. Cumulative sources have no window and
    are judged by having produced observations at all.
    """
    if not source.available:
        return False
    if not source.windowed:
        return bool(source.counts)
    newest = source.newest_ts if source.newest_ts is not None else source.last_ts
    return newest is not None and newest >= window_start


def build_report(
    registry: Registry,
    sources: list[SourceResult],
    coverage: dict[str, dict[str, str]],
    window_start: float,
    window_end: float,
    window_days: int,
    window_kind: str,
    retired_names: list[str],
) -> Report:
    rows: list[ToolRow] = []
    for key, name in sorted(registry.tools.items(), key=lambda item: item[1]):
        family = family_of(name)
        row = ToolRow(name=name, family=family, status="unverified")
        recording_sources = 0
        silent_families: list[str] = []
        for source in sources:
            if not source.available:
                continue
            if not can_judge_zero(source, window_start):
                silent_families.append(
                    f"{source.name} has no row inside the window "
                    f"(newest row: {iso(source.newest_ts) if source.newest_ts else 'none'}) "
                    "so its silence is not evidence of absence (#50504)"
                )
                continue
            # An observed call beats a coverage declaration: if a source wrote
            # rows for this tool, the tool was called no matter what the family
            # declaration says. The declaration only decides whether a zero is
            # evidence of absence.
            count = source.counts.get(key, 0)
            if count:
                row.calls[source.name] = count
            declared = coverage.get(source.name, {}).get(family, "unknown")
            if declared == "recorded":
                recording_sources += 1
            elif declared == "not_recorded":
                silent_families.append(f"{source.name} does not record {family} (#38824)")
            else:
                silent_families.append(f"{source.name} coverage for {family} is unknown")
        if row.calls:
            row.status = "used"
        elif recording_sources:
            row.status = "unused"
        else:
            row.reasons = silent_families or ["no usable source is available"]
        rows.append(row)

    observed_keys: set[str] = set()
    for source in sources:
        observed_keys.update(source.counts)
    # A name that the ledger spells differently from the registry is not an
    # unknown tool when the same rows name a registered tool. Report only the
    # names whose whole alias group is absent from the registry.
    registered = set(registry.tools)
    alias_of: dict[str, set[str]] = {}
    for source in sources:
        for key, group in source.alias_groups.items():
            merged = alias_of.setdefault(key, set())
            merged |= group
            for member in group:
                alias_of.setdefault(member, set()).update(group)
    unregistered: list[tuple[str, dict[str, int]]] = []
    addon_explained: list[tuple[str, str, dict[str, int]]] = []
    for key in sorted(observed_keys - registered):
        group = alias_of.get(key) or {key}
        if group & registered:
            continue
        per_source = {
            source.name: source.counts[key]
            for source in sources
            if key in source.counts
        }
        addon_id = next(
            (registry.addons[member] for member in sorted(group) if member in registry.addons),
            None,
        )
        if addon_id is not None:
            addon_explained.append((source_label(key, sources), addon_id, per_source))
        else:
            unregistered.append((source_label(key, sources), per_source))

    retired = [name for name in retired_names if norm(name) not in registry.tools]
    return Report(
        registry=registry,
        window_start=window_start,
        window_end=window_end,
        window_days=window_days,
        window_kind=window_kind,
        sources=sources,
        coverage=coverage,
        rows=rows,
        unregistered_observed=unregistered,
        unregistered_addon=addon_explained,
        retired=retired,
    )


def source_label(key: str, sources: list[SourceResult]) -> str:
    for source in sources:
        if key in source.raw_names:
            return source.raw_names[key]
    return key


def observed_span(report: Report, source: SourceResult) -> tuple[str, float | None]:
    """Return the (cell text, fraction of the window covered) for one source."""
    if not source.available or source.first_ts is None or source.last_ts is None:
        return "-", None
    window = report.window_end - report.window_start
    fraction = (source.last_ts - source.first_ts) / window if window > 0 else None
    text = f"{iso(source.first_ts)} ~ {iso(source.last_ts)}"
    if fraction is not None:
        text += f" (창의 {min(fraction, 1.0) * 100:.2f}%)"
    return text, fraction


def render_markdown(report: Report) -> str:
    registry = report.registry
    unused = report.by_status("unused")
    unverified = report.by_status("unverified")
    used = report.by_status("used")
    available_sources = [source for source in report.sources if source.available]
    lines: list[str] = []
    lines.append("# 미사용 도구 리포트")
    lines.append("")
    lines.append("## 요약")
    lines.append("")
    lines.append(f"- 등록 도구(분모): {registry.count}개 (`{registry.directory}`, {registry.files}개 TOML)")
    lines.append(
        f"- 기간: {iso(report.window_start)} ~ {iso(report.window_end)} "
        f"({report.window_days}일, {report.window_kind})"
    )
    lines.append(f"- 사용: {len(used)}개 / 0회: {len(unused)}개 / 판정 불가: {len(unverified)}개")
    lines.append("")
    lines.append("## 원천")
    lines.append("")
    lines.append("| 원천 | 위치 | 상태 | 내용 | 관측 구간 |")
    lines.append("|---|---|---|---|---|")
    short_sources: list[tuple[SourceResult, float]] = []
    for source in report.sources:
        if not source.available:
            state = "없음"
        elif can_judge_zero(source, report.window_start):
            state = "사용"
        else:
            state = "창 밖만 있음"
        detail = source.detail or ""
        span, fraction = observed_span(report, source)
        if fraction is not None and fraction < 1.0:
            short_sources.append((source, fraction))
        lines.append(f"| `{source.name}` | `{source.location}` | {state} | {detail} | {span} |")
    for source, fraction in short_sources:
        lines.append("")
        lines.append(
            f"> 경고: `{source.name}` 가 창의 {fraction * 100:.2f}% 만 덮음 — "
            f"0회는 그 구간의 0회이며 {report.window_days}일 동안의 0회가 아닙니다."
        )
    lines.append("")
    lines.append("## 원천 커버리지 (계열별)")
    lines.append("")
    header = "| 계열 | " + " | ".join(f"`{source.name}`" for source in report.sources) + " |"
    lines.append(header)
    lines.append("|---|" + "---|" * len(report.sources))
    for family in ALL_FAMILIES:
        cells = [
            report.coverage.get(source.name, {}).get(family, "unknown")
            for source in report.sources
        ]
        lines.append(f"| {family} | " + " | ".join(cells) + " |")
    lines.append("")
    lines.append(
        "`recorded`는 그 계열의 모든 호출을 기록한다는 선언, `not_recorded`는 그 계열을 "
        "볼 수 없다는 선언, `unknown`은 어느 쪽도 확인되지 않았다는 뜻입니다. "
        "`not_recorded`/`unknown` 계열의 0은 0회 호출의 증거가 아닙니다."
    )
    lines.append("")
    lines.append(f"## {report.window_days}일 0회 ({len(unused)}개)")
    lines.append("")
    if not unused:
        # "no unused tools" has three different meanings and the report must
        # not collapse them: nothing was countable, something was countable but
        # part of the inventory is unverified, or the whole inventory was
        # counted. A reader who sees only the first sentence would take
        # "0회 없음" as "다 씀".
        if not available_sources:
            lines.append(
                "없음 — **그러나 0회를 셀 수 없습니다.** 사용 가능한 원천이 하나도 없어 "
                f"등록 도구 {len(unverified)}개가 전부 `판정 불가` 입니다. "
                "이 줄은 \"0회 도구가 없다\"는 뜻이 아닙니다."
            )
        elif unverified:
            lines.append(
                f"없음 — 사용 가능한 원천이 기록하는 계열에서는 호출이 있었습니다. "
                f"다만 {len(unverified)}개는 원천 커버리지가 확인되지 않아 `판정 불가` 이며, "
                "그 도구들에 대해서는 이 목록이 아무것도 주장하지 않습니다."
            )
        else:
            lines.append("없음 — 사용 가능한 원천이 기록하는 모든 계열에서 호출이 있었습니다.")
    else:
        lines.append(
            "| 도구 | 계열 |"
            + "".join(f" {source.name} |" for source in available_sources)
        )
        lines.append("|---|---|" + "---|" * len(available_sources))
        for row in unused:
            cells = "".join(
                f" {row.calls.get(source.name, 0)} |" for source in available_sources
            )
            lines.append(f"| `{row.name}` | {row.family} |{cells}")
    lines.append("")
    lines.append(f"## 판정 불가 ({len(unverified)}개)")
    lines.append("")
    if not unverified:
        lines.append("없음.")
    else:
        lines.append("| 도구 | 계열 | 이유 |")
        lines.append("|---|---|---|")
        for row in unverified:
            reason = "; ".join(row.reasons)
            lines.append(f"| `{row.name}` | {row.family} | {reason} |")
    if report.retired:
        lines.append("")
        lines.append(f"## 이미 정리됨 ({len(report.retired)}개)")
        lines.append("")
        lines.append("이전 목록에는 있었으나 현재 등록부에 없는 도구입니다(삭제 착지).")
        lines.append("")
        for name in report.retired:
            lines.append(f"- `{name}`")
    if registry.addons or report.unregistered_addon:
        lines.append("")
        lines.append(
            f"## addon export 로 설명되는 이름 ({registry.addon_count}개 선언, "
            f"관측 {len(report.unregistered_addon)}개)"
        )
        lines.append("")
        lines.append(
            f"`{registry.addon_directory or 'addons'}/*/lane.toml` 의 `[world.tools].export` 가 "
            f"선언한 도구입니다({registry.addon_files}개 파일). `config/tools` 등록부가 아니라 "
            "addon 계약이 정본이므로 \"등록부 밖\"이 아닙니다."
        )
        lines.append("")
        lines.append(
            "> 경고: addon 도구는 프로필·설치에 따라 존재 여부가 달라집니다. "
            "이 목록의 `0회` 를 삭제 근거로 쓰지 마세요. 여기서는 **분류**만 바로잡습니다."
        )
        lines.append("")
        if report.unregistered_addon:
            lines.append(
                "| 이름 | 정본 등록부 | "
                + " | ".join(f"`{source.name}`" for source in report.sources)
                + " |"
            )
            lines.append("|---|---|" + "---|" * len(report.sources))
            for name, addon_id, per_source in report.unregistered_addon:
                cells = " | ".join(
                    str(per_source.get(source.name, "")) for source in report.sources
                )
                lines.append(f"| `{name}` | `addons/{addon_id}` | {cells} |")
    if report.unregistered_observed:
        lines.append("")
        lines.append(f"## 등록부 밖에서 관측된 이름 ({len(report.unregistered_observed)}개)")
        lines.append("")
        lines.append(
            "원천에는 있으나 `config/tools/*.toml` 에도, addon `lane.toml` 의 "
            "`[world.tools].export` 에도 없는 이름입니다"
            "(삭제된 도구, 외부 MCP, 클라이언트 도구)."
        )
        lines.append("")
        lines.append(
            "| 이름 | 정본 등록부 | "
            + " | ".join(f"`{source.name}`" for source in report.sources)
            + " |"
        )
        lines.append("|---|---|" + "---|" * len(report.sources))
        for name, per_source in report.unregistered_observed:
            cells = " | ".join(str(per_source.get(source.name, "")) for source in report.sources)
            lines.append(f"| `{name}` | 없음 | {cells} |")
    if registry.errors or registry.duplicates:
        lines.append("")
        lines.append("## 등록부 경고")
        lines.append("")
        for error in registry.errors:
            lines.append(f"- {error}")
        for duplicate in registry.duplicates:
            lines.append(f"- 이름 중복: {duplicate}")
    lines.append("")
    return "\n".join(lines)


def render_json(report: Report) -> str:
    payload = {
        "registry": {
            "directory": report.registry.directory,
            "files": report.registry.files,
            "count": report.registry.count,
            "errors": report.registry.errors,
            "duplicates": report.registry.duplicates,
            "addon_directory": report.registry.addon_directory,
            "addon_files": report.registry.addon_files,
            "addon_count": report.registry.addon_count,
            "addon_errors": report.registry.addon_errors,
        },
        "window": {
            "start": iso(report.window_start),
            "end": iso(report.window_end),
            "days": report.window_days,
            "kind": report.window_kind,
        },
        "sources": [
            {
                "name": source.name,
                "location": source.location,
                "available": source.available,
                "detail": source.detail,
                "rows": source.rows,
                "files": source.files,
                "first_ts": iso(source.first_ts) if source.first_ts else None,
                "last_ts": iso(source.last_ts) if source.last_ts else None,
                "newest_ts": iso(source.newest_ts) if source.newest_ts else None,
                "can_judge_zero": can_judge_zero(source, report.window_start),
            }
            for source in report.sources
        ],
        "coverage": report.coverage,
        "counts": {
            "used": len(report.by_status("used")),
            "unused": len(report.by_status("unused")),
            "unverified": len(report.by_status("unverified")),
        },
        "unused": [
            {"tool": row.name, "family": row.family, "calls": row.calls}
            for row in report.by_status("unused")
        ],
        "unverified": [
            {"tool": row.name, "family": row.family, "reasons": row.reasons}
            for row in report.by_status("unverified")
        ],
        "retired": report.retired,
        "unregistered_observed": [
            {"tool": name, "calls": per_source}
            for name, per_source in report.unregistered_observed
        ],
        "unregistered_addon": [
            {"tool": name, "addon": addon_id, "calls": per_source}
            for name, addon_id, per_source in report.unregistered_addon
        ],
    }
    return json.dumps(payload, ensure_ascii=False, indent=2)


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------


def load_coverage(path: Path | None) -> dict[str, dict[str, str]]:
    if path is None:
        return DEFAULT_COVERAGE
    payload = json.loads(path.read_text(encoding="utf-8"))
    coverage: dict[str, dict[str, str]] = {}
    for source, families in payload.items():
        if not isinstance(families, dict):
            raise SystemExit(f"coverage json: `{source}` must map family -> declaration")
        coverage[source] = {}
        for family, declaration in families.items():
            if declaration not in {"recorded", "not_recorded", "unknown"}:
                raise SystemExit(
                    f"coverage json: {source}.{family} = {declaration!r}; "
                    "expected recorded|not_recorded|unknown"
                )
            coverage[source][family] = declaration
    return coverage


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Report registered tools with no recorded call in a trailing window."
    )
    parser.add_argument("--registry-dir", default="config/tools", help="tool registry TOML directory")
    parser.add_argument(
        "--addon-dir",
        default="addons",
        help="read `[world.tools].export` from <dir>/*/lane.toml as a second registry",
    )
    parser.add_argument(
        "--no-addons",
        action="store_true",
        help="ignore addon lane.toml exports (a name they declare is then reported as outside the registry)",
    )
    parser.add_argument("--data-dir", default=".masc", help="base directory holding runtime state")
    parser.add_argument("--ledger-dir", default=None, help="override: tool_calls ledger directory")
    parser.add_argument("--metrics-db", default=None, help="override: tool-metrics.sqlite3 path")
    parser.add_argument("--snapshot-json", default=None, help="cumulative dashboard projection (no window)")
    parser.add_argument("--no-ledger", action="store_true", help="skip the tool_calls ledger")
    parser.add_argument("--no-metrics", action="store_true", help="skip tool_metric_events")
    parser.add_argument("--days", type=int, default=30, help="trailing window in days (default 30)")
    parser.add_argument("--now", default=None, help="window end, ISO-8601 or epoch (default: now)")
    parser.add_argument("--format", choices=("md", "json"), default="md")
    parser.add_argument("--coverage-json", default=None, help="override the source coverage declaration")
    parser.add_argument(
        "--known-retired",
        action="append",
        default=[],
        help="repeatable: a tool name from an earlier unused list; reported when it left the registry",
    )
    parser.add_argument("--strict", action="store_true", help="exit 1 when any tool is unused")
    args = parser.parse_args(argv)

    data_dir = Path(args.data_dir)
    end_dt = parse_now(args.now)
    start_dt = end_dt - timedelta(days=args.days)
    start, end = start_dt.timestamp(), end_dt.timestamp()

    registry = load_registry(Path(args.registry_dir))
    if not args.no_addons:
        addon_dir = Path(args.addon_dir)
        exports, addon_files, addon_errors = load_addon_exports(addon_dir)
        registry.addon_directory = str(addon_dir)
        registry.addon_files = addon_files
        registry.addons = exports
        registry.addon_errors = addon_errors
    coverage = load_coverage(Path(args.coverage_json) if args.coverage_json else None)

    sources: list[SourceResult] = []
    window_kind = "trailing window"
    if not args.no_ledger:
        ledger_dir = Path(args.ledger_dir) if args.ledger_dir else data_dir / "tool_calls"
        sources.append(load_ledger(ledger_dir, start, end))
    if not args.no_metrics:
        metrics_db = Path(args.metrics_db) if args.metrics_db else data_dir / "tool-metrics.sqlite3"
        sources.append(load_metric_events(metrics_db, start, end))
    if args.snapshot_json:
        sources.append(load_snapshot(Path(args.snapshot_json)))
        window_kind = "cumulative projection — the window above does not apply"

    report = build_report(
        registry=registry,
        sources=sources,
        coverage=coverage,
        window_start=start,
        window_end=end,
        window_days=args.days,
        window_kind=window_kind,
        retired_names=args.known_retired,
    )
    if args.format == "json":
        sys.stdout.write(render_json(report) + "\n")
    else:
        sys.stdout.write(render_markdown(report) + "\n")

    unused = len(report.by_status("unused"))
    if args.strict and unused:
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
