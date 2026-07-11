#!/usr/bin/env python3
"""Audit live keeper fleet readiness from on-disk MASC runtime state.

This is intentionally read-only. It separates static sandbox/runtime
configuration from durable evidence (recent turns, board actions, persisted PR
references) so operators do not mistake a configured capability for proof that
every keeper already used it.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
import time
from collections.abc import Iterator
from dataclasses import asdict, dataclass
from datetime import datetime
from pathlib import Path
from typing import Any

import tomllib


BOARD_TOOLS = {
    "keeper_board_post",
    "keeper_board_comment",
    "keeper_board_vote",
    "keeper_board_get",
    "keeper_board_list",
    "keeper_board_search",
}
WEB_SEARCH_TOOLS = {
    "masc_web_search",
    "WebSearch",
    "SearchWeb",
}
PRODUCT_DOMAIN_MARKERS = {
    "customer",
    "goal",
    "goals",
    "pm",
    "product",
    "roadmap",
    "strategy",
}
DESIGN_DOMAIN_MARKERS = {
    "design",
    "interface",
    "product-design",
    "ui",
    "ux",
}
PR_URL_RE = re.compile(
    r"https://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/pull/[0-9]+"
)
PR_CREATED_NUMBER_RE = re.compile(
    r"\b(?:created|opened|published)\s+(?:a\s+)?(?:github\s+)?"
    r"(?:draft\s+)?PR\s*#([0-9]+)\b",
    re.IGNORECASE,
)
ERROR_STATUSES = {"error", "failed", "failure", "timeout", "cancelled", "canceled"}


def default_base_path() -> str | None:
    # RFC-0121: MASC_BASE_PATH is the sole canonical source.
    value = os.environ.get("MASC_BASE_PATH", "").strip()
    return value or None


@dataclass
class KeeperAudit:
    name: str
    config_path: str
    runtime_path: str | None
    sandbox_profile: str | None
    network_mode: str | None
    tool_access: list[str] | None
    last_turn_ts: float | None
    last_turn_age_hours: float | None
    recent_action: bool
    board_action: bool
    web_search_action: bool
    product_action: bool
    design_action: bool
    pr_created_evidence: bool
    provider_turn_evidence: bool
    checkpoint_evidence: bool
    history_evidence: bool
    tool_call_log_evidence: bool
    evidence_tools: list[str]
    board_post_evidence: list[str]
    web_search_evidence: list[str]
    product_evidence: list[str]
    design_evidence: list[str]
    pr_evidence_refs: list[str]
    pr_evidence_sources: list[str]
    provider_turn_evidence_refs: list[str]
    checkpoint_evidence_refs: list[str]
    history_evidence_refs: list[str]
    tool_call_log_evidence_refs: list[str]
    failures: list[str]
    warnings: list[str]


@dataclass
class PrCreationEvidence:
    refs: set[str]
    sources: set[str]

    @property
    def created(self) -> bool:
        return bool(self.refs)


@dataclass
class PersistentWorkEvidence:
    latest_ts: float | None
    provider_turn_refs: set[str]
    checkpoint_refs: set[str]
    history_refs: set[str]
    tool_call_log_refs: set[str]

    @property
    def provider_turn(self) -> bool:
        return bool(self.provider_turn_refs)

    @property
    def checkpoint(self) -> bool:
        return bool(self.checkpoint_refs)

    @property
    def history(self) -> bool:
        return bool(self.history_refs)

    @property
    def tool_call_log(self) -> bool:
        return bool(self.tool_call_log_refs)


def load_json(path: Path) -> dict[str, Any]:
    with path.open("r", encoding="utf-8", errors="replace") as handle:
        data = json.load(handle)
    if not isinstance(data, dict):
        raise ValueError(f"{path}: expected JSON object")
    return data


def iter_jsonl(path: Path) -> Iterator[dict[str, Any]]:
    if not path.exists():
        return
    with path.open("r", encoding="utf-8", errors="replace") as handle:
        for line_no, line in enumerate(handle, start=1):
            line = line.strip()
            if not line:
                continue
            try:
                row = json.loads(line)
            except json.JSONDecodeError as exc:
                raise ValueError(f"{path}:{line_no}: {exc}") from exc
            if isinstance(row, dict):
                yield row


def load_toml(path: Path) -> dict[str, Any]:
    with path.open("rb") as handle:
        data = tomllib.load(handle)
    if not isinstance(data, dict):
        raise ValueError(f"{path}: expected TOML object")
    return data


def merge_dicts(base: dict[str, Any], overlay: dict[str, Any]) -> dict[str, Any]:
    merged = dict(base)
    for key, value in overlay.items():
        if isinstance(value, dict) and isinstance(merged.get(key), dict):
            merged[key] = merge_dicts(merged[key], value)
        else:
            merged[key] = value
    return merged


def load_keeper_config(path: Path, seen: set[Path] | None = None) -> dict[str, Any]:
    seen = set() if seen is None else seen
    resolved = path.resolve()
    if resolved in seen:
        raise ValueError(f"{path}: cyclic keeper.base include")
    seen.add(resolved)

    raw = load_toml(path)
    keeper = raw.get("keeper")
    if not isinstance(keeper, dict):
        return {}

    base_name = keeper.get("base")
    if isinstance(base_name, str) and base_name.strip():
        base_path = path.parent / base_name
        base_keeper = load_keeper_config(base_path, seen)
        return merge_dicts(base_keeper, keeper)
    return keeper


def string_field(data: dict[str, Any], key: str) -> str | None:
    value = data.get(key)
    return value if isinstance(value, str) and value != "" else None


def numeric_field(data: dict[str, Any], key: str) -> float | None:
    value = data.get(key)
    if isinstance(value, bool):
        return None
    if isinstance(value, int | float):
        return float(value)
    return None


def iso_to_unix(raw: str | None) -> float | None:
    if not raw:
        return None
    try:
        normalized = raw.replace("Z", "+00:00")
        return datetime.fromisoformat(normalized).timestamp()
    except ValueError:
        return None


def observed_ts(row: dict[str, Any]) -> float | None:
    ts = numeric_field(row, "ts_unix")
    if ts is None:
        ts = numeric_field(row, "ts")
    if ts is not None:
        return ts
    return iso_to_unix(text_field(row, "ts"))


def status_is_error(value: Any) -> bool:
    return isinstance(value, str) and value.lower() in ERROR_STATUSES


def path_from_link(base_path: Path, raw: Any) -> Path | None:
    if not isinstance(raw, str) or not raw.strip():
        return None
    path = Path(raw.strip()).expanduser()
    if not path.is_absolute():
        path = base_path / path
    return path


def path_label(base_path: Path, path: Path) -> str:
    try:
        return path.relative_to(base_path).as_posix()
    except ValueError:
        return str(path)


def jsonl_has_object(path: Path) -> bool:
    try:
        for _row in iter_jsonl(path):
            return True
    except ValueError:
        return False
    return False


def string_list_value(value: Any) -> list[str] | None:
    if not isinstance(value, list):
        return None
    tools: list[str] = []
    for item in value:
        if not isinstance(item, str):
            return None
        item = item.strip()
        if item:
            tools.append(item)
    return tools


def tool_access_from_config(
    config: dict[str, Any],
) -> tuple[list[str] | None, list[str]]:
    raw = config.get("tool_access")
    if raw is None:
        return None, []
    tools = string_list_value(raw)
    if tools is None:
        return None, ["tool_access_config_invalid"]
    return tools, []


def tool_access_from_runtime(
    runtime: dict[str, Any],
) -> tuple[list[str] | None, list[str]]:
    raw = runtime.get("tool_access")
    if raw is None:
        return None, []
    tools = string_list_value(raw)
    if tools is None:
        return None, ["tool_access_runtime_invalid"]
    return tools, []


def tools_from_decision(row: dict[str, Any]) -> list[str]:
    tools: list[str] = []
    tool = row.get("tool")
    if isinstance(tool, str):
        tools.append(tool)
    for key in ("tools_used",):
        values = row.get(key)
        if isinstance(values, list):
            tools.extend(v for v in values if isinstance(v, str))
    calls = row.get("tool_calls")
    if isinstance(calls, list):
        for call in calls:
            if isinstance(call, dict):
                name = call.get("tool_name")
                if isinstance(name, str):
                    tools.append(name)
    return tools


def row_success(row: dict[str, Any]) -> bool:
    ok = row.get("ok")
    if isinstance(ok, bool):
        return ok
    outcome = row.get("outcome")
    return outcome == "success"


def text_field(data: dict[str, Any], key: str) -> str:
    value = data.get(key)
    return value if isinstance(value, str) else ""


def row_succeeded(row: dict[str, Any]) -> bool:
    for key in ("ok", "success"):
        value = row.get(key)
        if value is False:
            return False
    error = row.get("error")
    if isinstance(error, str) and error.strip():
        return False
    if error not in (None, False, ""):
        return False
    outcome = row.get("outcome")
    if isinstance(outcome, str) and outcome.lower() in {"error", "failed", "failure"}:
        return False
    output = row.get("output")
    if isinstance(output, dict) and output.get("ok") is False:
        return False
    return True


def dict_field(data: dict[str, Any], key: str) -> dict[str, Any] | None:
    value = data.get(key)
    return value if isinstance(value, dict) else None


def pr_ref_texts_from_structured_output(row: dict[str, Any]) -> list[str]:
    texts: list[str] = []
    output = row.get("output")
    if isinstance(output, str):
        texts.append(output)
    elif isinstance(output, dict):
        for key in ("output", "url", "html_url"):
            texts.append(text_field(output, key))
        result = output.get("result")
        if isinstance(result, dict):
            for key in ("url", "html_url"):
                texts.append(text_field(result, key))
            for key in ("pr_number", "number"):
                value = result.get(key)
                if isinstance(value, int) and value > 0:
                    texts.append(f"PR#{value}")
                elif isinstance(value, str) and value.strip().isdigit():
                    texts.append(f"PR#{value.strip()}")
        for key in ("pr_number", "number"):
            value = output.get(key)
            if isinstance(value, int) and value > 0:
                texts.append(f"PR#{value}")
            elif isinstance(value, str) and value.strip().isdigit():
                texts.append(f"PR#{value.strip()}")
    for key in ("url", "html_url"):
        texts.append(text_field(row, key))
    for key in ("pr_number", "number"):
        value = row.get(key)
        if isinstance(value, int) and value > 0:
            texts.append(f"PR#{value}")
        elif isinstance(value, str) and value.strip().isdigit():
            texts.append(f"PR#{value.strip()}")
    route_evidence = dict_field(row, "route_evidence")
    if route_evidence is not None:
        for key in ("url", "html_url"):
            texts.append(text_field(route_evidence, key))
        for key in ("pr_number", "number"):
            value = route_evidence.get(key)
            if isinstance(value, int) and value > 0:
                texts.append(f"PR#{value}")
            elif isinstance(value, str) and value.strip().isdigit():
                texts.append(f"PR#{value.strip()}")
    return [text for text in texts if text]


def add_pr_refs_from_structured_output(
    *,
    refs: set[str],
    sources: set[str],
    source: str,
    row: dict[str, Any],
) -> bool:
    added = False
    for text in pr_ref_texts_from_structured_output(row):
        for url in PR_URL_RE.findall(text):
            refs.add(url)
            sources.add(source)
            added = True
        for match in PR_CREATED_NUMBER_RE.findall(text):
            refs.add(f"PR#{match}")
            sources.add(source)
            added = True
        if text.startswith("PR#") and text[3:].isdigit():
            refs.add(text)
            sources.add(source)
            added = True
    return added


def pr_evidence_from_row(row: dict[str, Any]) -> tuple[set[str], set[str]]:
    refs: set[str] = set()
    sources: set[str] = set()
    source = text_field(row, "_source_path")
    if row_succeeded(row):
        add_pr_refs_from_structured_output(
            refs=refs, sources=sources, source=source, row=row
        )

    return refs, sources


def output_json(row: dict[str, Any]) -> dict[str, Any]:
    output = row.get("output")
    if isinstance(output, dict):
        return output
    if isinstance(output, str):
        try:
            parsed = json.loads(output)
        except json.JSONDecodeError:
            return {}
        return parsed if isinstance(parsed, dict) else {}
    return {}


def tool_succeeded_in_row(row: dict[str, Any], tool_name: str) -> bool:
    if row.get("tool") == tool_name:
        return row.get("ok") is True
    calls = row.get("tool_calls")
    if isinstance(calls, list):
        for call in calls:
            if not isinstance(call, dict):
                continue
            if call.get("tool_name") == tool_name and call.get("outcome") == "ok":
                return True
    return False


def explicit_success(row: dict[str, Any]) -> bool:
    for key in ("ok", "success"):
        value = row.get(key)
        if isinstance(value, bool):
            return value
    outcome = row.get("outcome")
    if isinstance(outcome, str):
        return outcome.lower() in {"ok", "success", "succeeded"}
    output = output_json(row)
    for key in ("ok", "success"):
        value = output.get(key)
        if isinstance(value, bool):
            return value
    status = output.get("status")
    return isinstance(status, str) and status.lower() in {"ok", "success", "succeeded"}


SECRETISH_QUERY_RE = re.compile(
    r"(?i)\b(api[_-]?key|authorization|bearer|password|secret|token)\b"
)


def web_search_query_preview(row: dict[str, Any]) -> str | None:
    candidates: list[Any] = [row.get("query")]
    for key in ("args", "input", "params", "request"):
        value = row.get(key)
        if isinstance(value, dict):
            candidates.append(value.get("query"))
            candidates.append(value.get("q"))
    for candidate in candidates:
        if not isinstance(candidate, str):
            continue
        query = " ".join(candidate.split())
        if not query:
            continue
        if SECRETISH_QUERY_RE.search(query):
            return "[redacted]"
        return query if len(query) <= 96 else f"{query[:93]}..."
    return None


def source_slug(source: str) -> str:
    return re.sub(r"[^a-z0-9_.=-]+", "_", source.lower()).strip("_") or "unknown"


def web_search_evidence_item(tool: str, row: dict[str, Any], source: str) -> str:
    parts = [f"web_search:{tool}"]
    query = web_search_query_preview(row)
    if query:
        parts.append(f"query={query}")
    ts = numeric_field(row, "ts_unix") or numeric_field(row, "ts")
    if ts is not None:
        parts.append(f"ts={int(ts)}")
    parts.append(f"source={source_slug(Path(source).name)}")
    return ":".join(parts)


def web_search_evidence_from_decision(row: dict[str, Any], source: str) -> set[str]:
    if not row_succeeded(row):
        return set()

    evidence: set[str] = set()
    tool = row.get("tool")
    if isinstance(tool, str) and tool in WEB_SEARCH_TOOLS and explicit_success(row):
        evidence.add(web_search_evidence_item(tool, row, source))

    tools = set(tools_from_decision(row))
    for tool_name in sorted(tools & WEB_SEARCH_TOOLS):
        if explicit_success(row):
            evidence.add(web_search_evidence_item(tool_name, row, source))

    calls = row.get("tool_calls")
    if isinstance(calls, list):
        for call in calls:
            if not isinstance(call, dict):
                continue
            name = call.get("tool_name") or call.get("tool")
            if not isinstance(name, str) or name not in WEB_SEARCH_TOOLS:
                continue
            if explicit_success(call) or row_success(row):
                evidence.add(web_search_evidence_item(name, call, source))
    return evidence


def web_search_evidence_from_tool_call(row: dict[str, Any], source: str) -> set[str]:
    tool = row.get("tool")
    if not isinstance(tool, str) or tool not in WEB_SEARCH_TOOLS:
        return set()
    if not explicit_success(row) or not row_succeeded(row):
        return set()
    return {web_search_evidence_item(tool, row, source)}


def decision_log_paths(base_path: Path, name: str) -> list[Path]:
    log_dir = base_path / ".masc" / "keepers"
    base_name = f"{name}.decisions.jsonl"
    if not log_dir.exists():
        return []
    paths: list[tuple[int, Path]] = []
    for path in log_dir.glob(f"{base_name}*"):
        suffix = path.name[len(base_name) :]
        if suffix == "":
            paths.append((0, path))
        elif suffix.startswith(".") and suffix[1:].isdigit():
            paths.append((int(suffix[1:]), path))
    return [path for _, path in sorted(paths, key=lambda item: item[0])]


def dated_jsonl_day_key(path: Path) -> int | None:
    month = path.parent.name
    day = path.stem
    if (
        len(month) == 7
        and month[4] == "-"
        and month[:4].isdigit()
        and month[5:].isdigit()
        and len(day) == 2
        and day.isdigit()
    ):
        return int(f"{month[:4]}{month[5:]}{day}")
    return None


def trace_session_ids_from_row(row: dict[str, Any]) -> set[str]:
    ids: set[str] = set()

    def add(value: Any) -> None:
        if isinstance(value, str) and value.strip():
            ids.add(value.strip())

    for container in (
        row,
        dict_field(row, "runtime_contract"),
        dict_field(row, "route_evidence"),
        dict_field(row, "action_radius"),
    ):
        if container is None:
            continue
        add(container.get("trace_id"))
        add(container.get("session_id"))
    return ids


def pr_creation_scan_paths(base_path: Path, name: str) -> list[Path]:
    root = base_path / ".masc"
    paths: list[Path] = decision_log_paths(base_path, name)
    history = root / "keepers" / name / ".playground_pr_history.jsonl"
    if history.exists():
        paths.append(history)
    for subdir in ("metrics", "execution-receipts"):
        base = root / "keepers" / name / subdir
        if base.is_dir():
            paths.extend(
                sorted(path for path in base.rglob("*.jsonl") if path.is_file())
            )
    trajectories = root / "trajectories" / name
    if trajectories.is_dir():
        paths.extend(
            sorted(path for path in trajectories.glob("*.jsonl") if path.is_file())
        )
    calls_dir = root / "tool_calls"
    if calls_dir.exists():
        paths.extend(
            sorted(path for path in calls_dir.rglob("*.jsonl") if path.is_file())
        )
    return paths


def scan_pr_creation_evidence(base_path: Path, name: str) -> PrCreationEvidence:
    refs: set[str] = set()
    sources: set[str] = set()
    for path in pr_creation_scan_paths(base_path, name):
        for row in iter_jsonl(path):
            row = dict(row)
            row_keeper = row.get("keeper") or row.get("keeper_name") or row.get("name")
            if isinstance(row_keeper, str) and row_keeper != name:
                continue
            row["_source_path"] = str(path)
            row_refs, row_sources = pr_evidence_from_row(row)
            refs.update(row_refs)
            sources.update(row_sources)
    return PrCreationEvidence(refs=refs, sources=sources)


def board_post_paths(base_path: Path) -> list[Path]:
    path = base_path / ".masc" / "board_posts.jsonl"
    return [path] if path.exists() else []


def domain_tokens(value: Any) -> set[str]:
    if not isinstance(value, str):
        return set()
    raw = value.strip().lower()
    if not raw:
        return set()
    tokens = set(re.split(r"[^a-z0-9]+", raw))
    tokens.discard("")
    tokens.add(raw)
    return tokens


def domain_marker_sources(
    value: Any,
    *,
    prefix: str,
    domain_markers: set[str],
) -> list[str]:
    sources: list[str] = []
    if isinstance(value, str):
        if domain_tokens(value) & domain_markers:
            sources.append(f"{prefix}={value.strip().lower()}")
    elif isinstance(value, list):
        for index, item in enumerate(value):
            sources.extend(
                domain_marker_sources(
                    item,
                    prefix=f"{prefix}[{index}]",
                    domain_markers=domain_markers,
                )
            )
    elif isinstance(value, dict):
        for key, item in value.items():
            if isinstance(key, str):
                sources.extend(
                    domain_marker_sources(
                        item,
                        prefix=f"{prefix}.{key}",
                        domain_markers=domain_markers,
                    )
                )
    return sources


def board_post_domain_sources(
    row: dict[str, Any],
    domain_markers: set[str],
) -> list[str]:
    sources = domain_marker_sources(
        row.get("hearth"),
        prefix="hearth",
        domain_markers=domain_markers,
    )
    meta = row.get("meta")
    if isinstance(meta, dict):
        sources.extend(
            domain_marker_sources(
                meta,
                prefix="meta",
                domain_markers=domain_markers,
            )
        )
    return sorted(set(sources))


def board_post_evidence_item(kind: str, row: dict[str, Any], source: str) -> str:
    post_id = string_field(row, "id") or "unknown"
    source_slug = re.sub(r"[^a-z0-9_.=-]+", "_", source.lower()).strip("_")
    return f"{kind}:board_post:{post_id}:{source_slug}"


def scan_keeper_board_posts(
    base_path: Path,
    name: str,
    *,
    max_silence_hours: float | None = None,
    now: float | None = None,
) -> tuple[float | None, set[str], set[str], set[str]]:
    latest_ts: float | None = None
    board_post_evidence: set[str] = set()
    product_evidence: set[str] = set()
    design_evidence: set[str] = set()
    min_ts: float | None = None
    if max_silence_hours is not None:
        min_ts = (time.time() if now is None else now) - (max_silence_hours * 3600.0)

    for path in board_post_paths(base_path):
        for row in iter_jsonl(path):
            if string_field(row, "author") != name:
                continue
            ts = numeric_field(row, "updated_at") or numeric_field(row, "created_at")
            if min_ts is not None and ts is not None and ts < min_ts:
                continue
            if ts is not None:
                latest_ts = ts if latest_ts is None else max(latest_ts, ts)
            post_id = string_field(row, "id") or "unknown"
            board_post_evidence.add(f"board_post:{post_id}")
            for source in board_post_domain_sources(row, PRODUCT_DOMAIN_MARKERS):
                product_evidence.add(board_post_evidence_item("product", row, source))
            for source in board_post_domain_sources(row, DESIGN_DOMAIN_MARKERS):
                design_evidence.add(board_post_evidence_item("design", row, source))

    return latest_ts, board_post_evidence, product_evidence, design_evidence


def global_tool_call_paths(base_path: Path) -> list[Path]:
    calls_dir = base_path / ".masc" / "tool_calls"
    if not calls_dir.exists():
        return []
    candidates: list[tuple[int, str, Path]] = []
    for path in calls_dir.rglob("*.jsonl"):
        if not path.is_file():
            continue
        day_key = dated_jsonl_day_key(path)
        candidates.append((day_key or -1, str(path), path))
    return [path for _, _, path in sorted(candidates, reverse=True)]


def scan_keeper_evidence(
    base_path: Path,
    name: str,
    *,
    max_silence_hours: float | None = None,
    now: float | None = None,
) -> tuple[float | None, set[str]]:
    latest_ts: float | None = None
    tools: set[str] = set()
    min_metric_ts: float | None = None
    if max_silence_hours is not None:
        min_metric_ts = (time.time() if now is None else now) - (
            max_silence_hours * 3600.0
        )
    for decisions in decision_log_paths(base_path, name):
        for row in iter_jsonl(decisions):
            ts = numeric_field(row, "ts_unix")
            if ts is not None:
                latest_ts = ts if latest_ts is None else max(latest_ts, ts)
            tools.update(tools_from_decision(row))
    for calls in global_tool_call_paths(base_path):
        for row in iter_jsonl(calls):
            if row.get("keeper") != name:
                continue
            ts = numeric_field(row, "ts") or numeric_field(row, "ts_unix")
            if min_metric_ts is not None and ts is not None and ts < min_metric_ts:
                continue
            if ts is not None:
                latest_ts = ts if latest_ts is None else max(latest_ts, ts)
            tool = row.get("tool")
            if isinstance(tool, str):
                tools.add(tool)
    return latest_ts, tools


def scan_keeper_web_search_evidence(
    base_path: Path,
    name: str,
    *,
    max_silence_hours: float | None = None,
    now: float | None = None,
) -> tuple[float | None, set[str]]:
    latest_ts: float | None = None
    evidence: set[str] = set()
    min_ts: float | None = None
    if max_silence_hours is not None:
        min_ts = (time.time() if now is None else now) - (max_silence_hours * 3600.0)

    def fresh_enough(row: dict[str, Any]) -> bool:
        ts = numeric_field(row, "ts_unix") or numeric_field(row, "ts")
        return ts is None or min_ts is None or ts >= min_ts

    def observe_ts(row: dict[str, Any]) -> None:
        nonlocal latest_ts
        ts = numeric_field(row, "ts_unix") or numeric_field(row, "ts")
        if ts is not None:
            latest_ts = ts if latest_ts is None else max(latest_ts, ts)

    for decisions in decision_log_paths(base_path, name):
        for row in iter_jsonl(decisions):
            if not fresh_enough(row):
                continue
            observe_ts(row)
            evidence.update(web_search_evidence_from_decision(row, str(decisions)))

    for calls in global_tool_call_paths(base_path):
        for row in iter_jsonl(calls):
            if row.get("keeper") != name:
                continue
            if not fresh_enough(row):
                continue
            observe_ts(row)
            evidence.update(web_search_evidence_from_tool_call(row, str(calls)))

    return latest_ts, evidence


def runtime_manifest_paths(base_path: Path, name: str) -> list[Path]:
    manifest_dir = base_path / ".masc" / "keepers" / name / "runtime-manifests"
    if not manifest_dir.is_dir():
        return []
    candidates: list[tuple[float, str, Path]] = []
    for path in manifest_dir.glob("*.jsonl"):
        if not path.is_file():
            continue
        try:
            mtime = path.stat().st_mtime
        except OSError:
            continue
        candidates.append((mtime, str(path), path))
    return [path for _mtime, _raw, path in sorted(candidates, reverse=True)]


def row_event(row: dict[str, Any]) -> str:
    return text_field(row, "event").lower()


def row_links(row: dict[str, Any]) -> dict[str, Any]:
    links = row.get("links")
    return links if isinstance(links, dict) else {}


def manifest_value_matches(expected: Any, actual: Any) -> bool:
    if expected is None or expected == "":
        return True
    if actual is None or actual == "":
        return False
    return str(expected) == str(actual)


def tool_log_identity_value(row: dict[str, Any], key: str) -> Any:
    value = row.get(key)
    if value is not None and value != "":
        return value
    contract = dict_field(row, "runtime_contract")
    if contract is None:
        return None
    return contract.get(key)


def turn_ref(trace: str, generation: str, turn: str) -> str:
    parts = [f"trace={trace}"]
    if generation:
        parts.append(f"generation={generation}")
    if turn:
        parts.append(f"turn={turn}")
    return ":".join(parts)


def manifest_turn_has_successful_provider(rows: list[dict[str, Any]]) -> bool:
    has_started = any(row_event(row) == "provider_attempt_started" for row in rows)
    has_finished = any(
        row_event(row) == "provider_attempt_finished"
        and not status_is_error(row.get("status"))
        for row in rows
    )
    terminal_rows = [row for row in rows if row_event(row) == "turn_finished"]
    terminal_ok = not terminal_rows or any(
        not status_is_error(row.get("status")) for row in terminal_rows
    )
    return has_started and has_finished and terminal_ok


def history_paths_for_trace(base_path: Path, trace: str) -> list[Path]:
    trace_dir = base_path / ".masc" / "traces" / trace
    return [trace_dir / "history.jsonl", trace_dir / "history.internal.jsonl"]


def tool_call_log_has_matching_row(
    path: Path,
    *,
    name: str,
    trace: str,
    generation: str,
    turn: str,
) -> bool:
    try:
        rows = iter_jsonl(path)
        for row in rows:
            row_keeper = row.get("keeper_name", row.get("keeper"))
            if isinstance(row_keeper, str) and row_keeper != name:
                continue
            row_ids = trace_session_ids_from_row(row)
            if not trace or trace not in row_ids:
                continue
            if not manifest_value_matches(
                generation, tool_log_identity_value(row, "generation")
            ):
                continue
            if not manifest_value_matches(
                turn, tool_log_identity_value(row, "keeper_turn_id")
            ):
                continue
            return True
    except ValueError:
        return False
    return False


def scan_persistent_work_evidence(
    base_path: Path,
    name: str,
    *,
    max_silence_hours: float | None = None,
    now: float | None = None,
) -> PersistentWorkEvidence:
    latest_ts: float | None = None
    provider_turn_refs: set[str] = set()
    checkpoint_refs: set[str] = set()
    history_refs: set[str] = set()
    tool_call_log_refs: set[str] = set()
    min_ts: float | None = None
    if max_silence_hours is not None:
        min_ts = (time.time() if now is None else now) - (max_silence_hours * 3600.0)

    turns: dict[tuple[str, str, str], list[dict[str, Any]]] = {}
    for manifest in runtime_manifest_paths(base_path, name):
        for row in iter_jsonl(manifest):
            row_keeper = string_field(row, "keeper_name")
            if row_keeper is not None and row_keeper != name:
                continue
            ts = observed_ts(row)
            if min_ts is not None and ts is not None and ts < min_ts:
                continue
            if ts is not None:
                latest_ts = ts if latest_ts is None else max(latest_ts, ts)
            trace = string_field(row, "trace_id") or manifest.stem
            generation_value = row.get("generation")
            turn_value = row.get("keeper_turn_id")
            generation = "" if generation_value is None else str(generation_value)
            turn = "" if turn_value is None else str(turn_value)
            row = dict(row)
            row["_source_path"] = str(manifest)
            turns.setdefault((trace, generation, turn), []).append(row)

    for (trace, generation, turn), rows in turns.items():
        ref = turn_ref(trace, generation, turn)
        if manifest_turn_has_successful_provider(rows):
            provider_turn_refs.add(f"provider_turn:{ref}")

        for history_path in history_paths_for_trace(base_path, trace):
            if history_path.is_file() and jsonl_has_object(history_path):
                history_refs.add(f"history:{path_label(base_path, history_path)}")

        for row in rows:
            links = row_links(row)
            if row_event(row) == "checkpoint_saved":
                checkpoint_path = path_from_link(
                    base_path, links.get("checkpoint_path")
                )
                if checkpoint_path is not None and checkpoint_path.is_file():
                    checkpoint_refs.add(
                        f"checkpoint:{ref}:{path_label(base_path, checkpoint_path)}"
                    )
            if row_event(row) == "turn_finished":
                tool_log_path = path_from_link(
                    base_path, links.get("tool_call_log_path")
                )
                if (
                    tool_log_path is not None
                    and tool_log_path.is_file()
                    and tool_call_log_has_matching_row(
                        tool_log_path,
                        name=name,
                        trace=trace,
                        generation=generation,
                        turn=turn,
                    )
                ):
                    tool_call_log_refs.add(
                        f"tool_call_log:{ref}:{path_label(base_path, tool_log_path)}"
                    )

    return PersistentWorkEvidence(
        latest_ts=latest_ts,
        provider_turn_refs=provider_turn_refs,
        checkpoint_refs=checkpoint_refs,
        history_refs=history_refs,
        tool_call_log_refs=tool_call_log_refs,
    )


def audit_keeper(
    *,
    base_path: Path,
    config_path: Path,
    max_silence_hours: float,
    require_board_evidence: bool,
    require_web_search_evidence: bool,
    require_product_evidence: bool,
    require_design_evidence: bool,
    require_pr_created_evidence: bool,
    require_provider_turn_evidence: bool,
    require_checkpoint_evidence: bool,
    require_history_evidence: bool,
    tool_call_log_evidence_required: bool,
) -> KeeperAudit:
    name = config_path.stem
    config = load_keeper_config(config_path)
    runtime_path = base_path / ".masc" / "keepers" / f"{name}.json"
    runtime: dict[str, Any] = {}
    failures: list[str] = []
    warnings: list[str] = []
    if runtime_path.exists():
        runtime = load_json(runtime_path)
    else:
        failures.append("runtime_missing")

    sandbox_profile = string_field(runtime, "sandbox_profile") or string_field(
        config, "sandbox_profile"
    )
    network_mode = string_field(runtime, "network_mode") or string_field(
        config, "network_mode"
    )
    config_tool_access, config_tool_access_failures = tool_access_from_config(config)
    runtime_tool_access, runtime_tool_access_failures = tool_access_from_runtime(
        runtime
    )
    tool_access = (
        runtime_tool_access if runtime_tool_access is not None else config_tool_access
    )

    if sandbox_profile != "docker":
        failures.append("sandbox_not_docker")
    if network_mode != "host":
        failures.append("network_not_inherit")
    failures.extend(config_tool_access_failures)
    failures.extend(runtime_tool_access_failures)

    evidence_ts, tools = scan_keeper_evidence(
        base_path,
        name,
        max_silence_hours=max_silence_hours,
    )
    pr_creation_evidence = scan_pr_creation_evidence(base_path, name)
    web_search_ts, web_search_evidence = scan_keeper_web_search_evidence(
        base_path,
        name,
        max_silence_hours=max_silence_hours,
    )
    persistent_work_evidence = scan_persistent_work_evidence(
        base_path,
        name,
        max_silence_hours=max_silence_hours,
    )
    (
        board_post_ts,
        board_post_evidence,
        product_evidence,
        design_evidence,
    ) = scan_keeper_board_posts(base_path, name, max_silence_hours=max_silence_hours)
    runtime_turn_ts = numeric_field(runtime, "last_turn_ts")
    updated_ts = iso_to_unix(string_field(runtime, "updated_at"))
    last_turn_ts = max(
        (
            ts
            for ts in (
                evidence_ts,
                board_post_ts,
                web_search_ts,
                persistent_work_evidence.latest_ts,
                runtime_turn_ts,
                updated_ts,
            )
            if ts is not None
        ),
        default=None,
    )
    last_turn_age_hours: float | None = None
    recent_action = False
    if last_turn_ts is None:
        failures.append("last_turn_missing")
    else:
        last_turn_age_hours = max(0.0, (time.time() - last_turn_ts) / 3600.0)
        recent_action = last_turn_age_hours <= max_silence_hours
        if not recent_action:
            failures.append("silence_window_exceeded")

    board_action = bool(tools & BOARD_TOOLS) or bool(board_post_evidence)
    web_search_action = bool(web_search_evidence)
    product_action = bool(product_evidence)
    design_action = bool(design_evidence)
    pr_created_evidence = pr_creation_evidence.created
    provider_turn_evidence = persistent_work_evidence.provider_turn
    checkpoint_evidence = persistent_work_evidence.checkpoint
    history_evidence = persistent_work_evidence.history
    tool_call_log_evidence = persistent_work_evidence.tool_call_log
    if require_board_evidence and not board_action:
        failures.append("board_action_evidence_missing")
    if require_web_search_evidence and not web_search_action:
        failures.append("web_search_evidence_missing")
    if require_product_evidence and not product_action:
        failures.append("product_action_evidence_missing")
    if require_design_evidence and not design_action:
        failures.append("design_action_evidence_missing")
    if require_pr_created_evidence and not pr_created_evidence:
        failures.append("pr_created_evidence_missing")
    elif not pr_created_evidence:
        warnings.append("pr_created_evidence_missing")
    if require_provider_turn_evidence and not provider_turn_evidence:
        failures.append("provider_turn_evidence_missing")
    if require_checkpoint_evidence and not checkpoint_evidence:
        failures.append("checkpoint_evidence_missing")
    if require_history_evidence and not history_evidence:
        failures.append("history_evidence_missing")
    if tool_call_log_evidence_required and not tool_call_log_evidence:
        failures.append("tool_call_log_evidence_missing")

    return KeeperAudit(
        name=name,
        config_path=str(config_path),
        runtime_path=str(runtime_path) if runtime_path.exists() else None,
        sandbox_profile=sandbox_profile,
        network_mode=network_mode,
        tool_access=tool_access,
        last_turn_ts=last_turn_ts,
        last_turn_age_hours=last_turn_age_hours,
        recent_action=recent_action,
        board_action=board_action,
        web_search_action=web_search_action,
        product_action=product_action,
        design_action=design_action,
        pr_created_evidence=pr_created_evidence,
        provider_turn_evidence=provider_turn_evidence,
        checkpoint_evidence=checkpoint_evidence,
        history_evidence=history_evidence,
        tool_call_log_evidence=tool_call_log_evidence,
        evidence_tools=sorted(tools),
        board_post_evidence=sorted(board_post_evidence),
        web_search_evidence=sorted(web_search_evidence),
        product_evidence=sorted(product_evidence),
        design_evidence=sorted(design_evidence),
        pr_evidence_refs=sorted(pr_creation_evidence.refs),
        pr_evidence_sources=sorted(pr_creation_evidence.sources),
        provider_turn_evidence_refs=sorted(persistent_work_evidence.provider_turn_refs),
        checkpoint_evidence_refs=sorted(persistent_work_evidence.checkpoint_refs),
        history_evidence_refs=sorted(persistent_work_evidence.history_refs),
        tool_call_log_evidence_refs=sorted(persistent_work_evidence.tool_call_log_refs),
        failures=failures,
        warnings=warnings,
    )


def build_report(args: argparse.Namespace) -> dict[str, Any]:
    if args.base_path is None:
        raise SystemExit(
            "Error: MASC_BASE_PATH is required (or pass --base-path PATH). "
            "RFC-0121 forbids ME_ROOT/cwd fallback."
        )
    base_path = Path(args.base_path).expanduser().resolve()
    config_dir = base_path / ".masc" / "config" / "keepers"
    if not config_dir.is_dir():
        raise SystemExit(f"keeper config dir not found: {config_dir}")

    config_paths = sorted(
        path for path in config_dir.glob("*.toml") if path.name != "base.toml"
    )
    keepers = [
        audit_keeper(
            base_path=base_path,
            config_path=path,
            max_silence_hours=args.max_silence_hours,
            require_board_evidence=args.require_board_evidence,
            require_web_search_evidence=args.require_web_search_evidence,
            require_product_evidence=args.require_product_evidence,
            require_design_evidence=args.require_design_evidence,
            require_pr_created_evidence=args.require_pr_created_evidence,
            require_provider_turn_evidence=(
                args.require_provider_turn_evidence
                or args.require_persistent_work_evidence
            ),
            require_checkpoint_evidence=(
                args.require_checkpoint_evidence
                or args.require_persistent_work_evidence
            ),
            require_history_evidence=(
                args.require_history_evidence or args.require_persistent_work_evidence
            ),
            tool_call_log_evidence_required=(
                args.tool_call_log_evidence_required
                or args.require_persistent_work_evidence
            ),
        )
        for path in config_paths
    ]

    fleet_failures: list[str] = []
    if len(config_paths) < args.expected_keepers:
        fleet_failures.append(
            f"minimum_{args.expected_keepers}_configured_keepers_got_{len(config_paths)}"
        )
    failed_keepers = [keeper for keeper in keepers if keeper.failures]
    ok = not fleet_failures and not failed_keepers
    return {
        "ok": ok,
        "base_path": str(base_path),
        "config_dir": str(config_dir),
        "expected_keepers": args.expected_keepers,
        "configured_keepers": len(config_paths),
        "max_silence_hours": args.max_silence_hours,
        "requirements": {
            "require_board_evidence": args.require_board_evidence,
            "require_web_search_evidence": args.require_web_search_evidence,
            "require_product_evidence": args.require_product_evidence,
            "require_design_evidence": args.require_design_evidence,
            "require_pr_created_evidence": args.require_pr_created_evidence,
            "require_provider_turn_evidence": args.require_provider_turn_evidence,
            "require_checkpoint_evidence": args.require_checkpoint_evidence,
            "require_history_evidence": args.require_history_evidence,
            "tool_call_log_evidence_required": args.tool_call_log_evidence_required,
            "require_persistent_work_evidence": args.require_persistent_work_evidence,
        },
        "fleet_failures": fleet_failures,
        "failed_keepers": [keeper.name for keeper in failed_keepers],
        "keepers": [asdict(keeper) for keeper in keepers],
    }


def print_text(report: dict[str, Any]) -> None:
    status = "PASS" if report["ok"] else "FAIL"
    print(f"keeper fleet readiness: {status}")
    print(
        "base_path={base_path} configured={configured_keepers} "
        "minimum={expected_keepers} max_silence_hours={max_silence_hours}".format(
            **report
        )
    )
    if report["fleet_failures"]:
        print("fleet failures:")
        for failure in report["fleet_failures"]:
            print(f"  - {failure}")
    for keeper in report["keepers"]:
        failures = keeper["failures"]
        warnings = keeper["warnings"]
        marker = "OK" if not failures else "FAIL"
        age = keeper["last_turn_age_hours"]
        age_label = "unknown" if age is None else f"{age:.2f}h"
        tool_access_label = (
            "default"
            if keeper["tool_access"] is None
            else str(len(keeper["tool_access"]))
        )
        print(
            "- {name}: {marker} tool_access={tool_access} "
            "sandbox={sandbox}/{network} "
            "recent={recent} age={age} board={board} "
            "web_search={web_search} "
            "product={product} design={design} "
            "pr_created={pr_created} "
            "provider_turn={provider_turn} checkpoint={checkpoint} "
            "history={history} tool_call_log={tool_call_log}".format(
                name=keeper["name"],
                marker=marker,
                tool_access=tool_access_label,
                sandbox=keeper["sandbox_profile"],
                network=keeper["network_mode"],
                recent=str(keeper["recent_action"]).lower(),
                age=age_label,
                board=str(keeper["board_action"]).lower(),
                web_search=str(keeper["web_search_action"]).lower(),
                product=str(keeper["product_action"]).lower(),
                design=str(keeper["design_action"]).lower(),
                pr_created=str(keeper["pr_created_evidence"]).lower(),
                provider_turn=str(keeper["provider_turn_evidence"]).lower(),
                checkpoint=str(keeper["checkpoint_evidence"]).lower(),
                history=str(keeper["history_evidence"]).lower(),
                tool_call_log=str(keeper["tool_call_log_evidence"]).lower(),
            )
        )
        for ref in keeper["pr_evidence_refs"][:5]:
            print(f"    pr_evidence: {ref}")
        for ref in keeper["web_search_evidence"][:5]:
            print(f"    web_search_evidence: {ref}")
        for ref in keeper["provider_turn_evidence_refs"][:3]:
            print(f"    provider_turn_evidence: {ref}")
        for ref in keeper["checkpoint_evidence_refs"][:3]:
            print(f"    checkpoint_evidence: {ref}")
        for ref in keeper["history_evidence_refs"][:3]:
            print(f"    history_evidence: {ref}")
        for ref in keeper["tool_call_log_evidence_refs"][:3]:
            print(f"    tool_call_log_evidence: {ref}")
        for failure in failures:
            print(f"    fail: {failure}")
        for warning in warnings:
            print(f"    warn: {warning}")


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--base-path",
        default=default_base_path(),
        help="MASC base path containing .masc (required; reads MASC_BASE_PATH)",
    )
    parser.add_argument(
        "--expected-keepers",
        type=int,
        default=18,
        help="Minimum configured keeper count required for fleet readiness.",
    )
    parser.add_argument("--max-silence-hours", type=float, default=2400.0)
    parser.add_argument(
        "--no-require-board-evidence",
        action="store_false",
        dest="require_board_evidence",
        help="Do not fail when a keeper lacks board action evidence.",
    )
    parser.add_argument(
        "--require-web-search-evidence",
        action="store_true",
        help=(
            "Fail unless each keeper has successful masc_web_search/WebSearch/SearchWeb "
            "evidence from decision or global tool-call logs."
        ),
    )
    parser.add_argument(
        "--require-product-evidence",
        action="store_true",
        help=(
            "Fail unless each keeper has recent product-domain board evidence "
            "from explicit hearth or metadata markers."
        ),
    )
    parser.add_argument(
        "--require-design-evidence",
        action="store_true",
        help=(
            "Fail unless each keeper has recent design-domain board evidence "
            "from explicit hearth or metadata markers."
        ),
    )
    parser.add_argument(
        "--require-pr-created-evidence",
        action="store_true",
        help="Fail unless each keeper has structured successful PR creation evidence.",
    )
    parser.add_argument(
        "--require-provider-turn-evidence",
        action="store_true",
        help=(
            "Fail unless each keeper has runtime-manifest evidence of a "
            "successful provider attempt."
        ),
    )
    parser.add_argument(
        "--require-llm-turn-evidence",
        action="store_true",
        dest="require_provider_turn_evidence",
        help="Alias for --require-provider-turn-evidence.",
    )
    parser.add_argument(
        "--require-checkpoint-evidence",
        action="store_true",
        help=(
            "Fail unless each keeper has a checkpoint_saved manifest row "
            "whose linked checkpoint file exists."
        ),
    )
    parser.add_argument(
        "--require-history-evidence",
        action="store_true",
        help=(
            "Fail unless each keeper has persisted history.jsonl or "
            "history.internal.jsonl evidence for a manifest trace."
        ),
    )
    parser.add_argument(
        "--tool-call-log-evidence-required",
        action="store_true",
        dest="tool_call_log_evidence_required",
        help=(
            "Fail unless each keeper has a turn_finished manifest row whose "
            "linked tool-call log contains a matching row."
        ),
    )
    parser.add_argument(
        "--require-persistent-work-evidence",
        action="store_true",
        help=(
            "Fail unless each keeper has provider-turn, checkpoint, history, "
            "and tool-call-log evidence."
        ),
    )
    parser.add_argument("--json", action="store_true", help="Emit JSON report.")
    return parser.parse_args(argv)


def main(argv: list[str]) -> int:
    args = parse_args(argv)
    report = build_report(args)
    if args.json:
        print(json.dumps(report, ensure_ascii=False, indent=2, sort_keys=True))
    else:
        print_text(report)
    return 0 if report["ok"] else 1


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
