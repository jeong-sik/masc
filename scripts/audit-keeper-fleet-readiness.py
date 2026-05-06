#!/usr/bin/env python3
"""Audit live keeper fleet readiness from on-disk MASC runtime state.

This is intentionally read-only. It separates configuration readiness
(Docker, GitHub identity, PR-capable preset) from behavioral evidence
(recent turns, board actions, PR/review tool usage) so operators do not
mistake a configured capability for proof that every keeper already used it.
"""

from __future__ import annotations

import argparse
import json
import re
import shlex
import sys
import time
from collections import Counter
from collections.abc import Iterator
from dataclasses import asdict, dataclass
from datetime import datetime
from pathlib import Path
from typing import Any

import tomllib


PR_CAPABLE_PRESETS = {"coding", "research", "delivery", "full"}
BOARD_TOOLS = {
    "keeper_board_post",
    "keeper_board_comment",
    "keeper_board_vote",
    "keeper_board_get",
    "keeper_board_list",
    "keeper_board_search",
}
PR_SURFACE_TOOLS = {
    "keeper_bash",
    "keeper_shell",
    "keeper_preflight_check",
    "keeper_pr_review_read",
    "keeper_pr_review_comment",
    "keeper_pr_review_reply",
    "masc_code_edit",
    "masc_code_git",
    "masc_code_shell",
    "masc_code_write",
}
PR_REVIEW_MUTATION_TOOLS = {
    "keeper_pr_review_comment",
    "keeper_pr_review_reply",
}
PR_CREATE_TOOLS = {
    "keeper_pr_create",
}
SHELL_TOOLS = {
    "keeper_bash",
    "keeper_shell",
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
GH_PR_CREATE_RE = re.compile(r"\bgh\s+pr\s+create\b", re.IGNORECASE)
GH_HOSTS_USER_RE = re.compile(r"^\s*user:\s*['\"]?([^'\"\s#]+)")


@dataclass
class KeeperAudit:
    name: str
    config_path: str
    runtime_path: str | None
    sandbox_profile: str | None
    network_mode: str | None
    tool_preset: str | None
    github_identity: str | None
    github_account_login: str | None
    git_identity_mode: str | None
    credential_dir: str | None
    credential_dir_exists: bool
    last_turn_ts: float | None
    last_turn_age_hours: float | None
    recent_action: bool
    board_action: bool
    product_action: bool
    design_action: bool
    pr_surface_action: bool
    pr_review_mutation: bool
    pr_create_action: bool
    git_push_action: bool
    pr_approve_mutation: bool
    pr_lifecycle_action: bool
    docker_pr_create_action: bool
    docker_git_push_action: bool
    docker_pr_approve_mutation: bool
    docker_pr_lifecycle_action: bool
    pr_created_evidence: bool
    pr_url_evidence: bool
    evidence_tools: list[str]
    board_post_evidence: list[str]
    product_evidence: list[str]
    design_evidence: list[str]
    pr_lifecycle_evidence: list[str]
    docker_pr_lifecycle_evidence: list[str]
    pr_evidence_refs: list[str]
    pr_evidence_sources: list[str]
    failures: list[str]
    warnings: list[str]


@dataclass
class PrCreationEvidence:
    refs: set[str]
    sources: set[str]

    @property
    def created(self) -> bool:
        return bool(self.refs)

    @property
    def url_present(self) -> bool:
        return any(ref.startswith("https://github.com/") for ref in self.refs)


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


def read_github_account_login(gh_config_dir: Path | None) -> str | None:
    if gh_config_dir is None:
        return None
    hosts_path = gh_config_dir / "hosts.yml"
    if not hosts_path.is_file():
        return None
    for line in hosts_path.read_text(encoding="utf-8", errors="replace").splitlines():
        match = GH_HOSTS_USER_RE.match(line)
        if match:
            return match.group(1).strip()
    return None


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


def tool_preset_from_config(config: dict[str, Any]) -> str | None:
    tool_access = config.get("tool_access")
    if isinstance(tool_access, dict):
        preset = tool_access.get("preset")
        if isinstance(preset, str) and preset:
            return preset
    preset = config.get("tool_preset")
    return preset if isinstance(preset, str) and preset else None


def tool_preset_from_runtime(runtime: dict[str, Any]) -> str | None:
    tool_access = runtime.get("tool_access")
    if isinstance(tool_access, dict):
        preset = tool_access.get("preset")
        if isinstance(preset, str) and preset:
            return preset
    return string_field(runtime, "tool_preset")


def tools_from_decision(row: dict[str, Any]) -> list[str]:
    tools: list[str] = []
    tool = row.get("tool")
    if isinstance(tool, str):
        tools.append(tool)
    for key in ("tools_used",):
        values = row.get(key)
        if isinstance(values, list):
            tools.extend(v for v in values if isinstance(v, str))
    contract = row.get("tool_contract")
    if isinstance(contract, dict):
        values = contract.get("tools_used")
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
    for key in ("ok", "success", "pr_work_action_success", "pr_review_action_success"):
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
        for key in ("output", "pr_url", "pull_request_url", "url", "html_url"):
            texts.append(text_field(output, key))
        result = output.get("result")
        if isinstance(result, dict):
            for key in ("pr_url", "pull_request_url", "url", "html_url"):
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
    for key in ("pr_url", "pull_request_url", "url", "html_url"):
        texts.append(text_field(row, key))
    for key in ("pr_number", "number"):
        value = row.get(key)
        if isinstance(value, int) and value > 0:
            texts.append(f"PR#{value}")
        elif isinstance(value, str) and value.strip().isdigit():
            texts.append(f"PR#{value.strip()}")
    return [text for text in texts if text]


def command_texts_from_structured_input(row: dict[str, Any]) -> list[str]:
    texts: list[str] = []
    for container in (dict_field(row, "args"), dict_field(row, "input")):
        if container is None:
            continue
        for key in ("cmd", "command"):
            texts.append(text_field(container, key))
        argv = container.get("argv")
        if isinstance(argv, list) and all(isinstance(item, str) for item in argv):
            texts.append(" ".join(argv))
    return [text for text in texts if text]


def row_mentions_evidence_run_id(
    row: dict[str, Any], evidence_run_id: str | None
) -> bool:
    if not evidence_run_id:
        return True
    try:
        haystack = json.dumps(row, ensure_ascii=False, sort_keys=True)
    except (TypeError, ValueError):
        haystack = str(row)
    return evidence_run_id.lower() in haystack.lower()


def add_pr_refs_from_structured_output(
    *,
    refs: set[str],
    sources: set[str],
    source: str,
    row: dict[str, Any],
) -> None:
    for text in pr_ref_texts_from_structured_output(row):
        for url in PR_URL_RE.findall(text):
            refs.add(url)
            sources.add(source)
        for match in PR_CREATED_NUMBER_RE.findall(text):
            refs.add(f"PR#{match}")
            sources.add(source)
        if text.startswith("PR#") and text[3:].isdigit():
            refs.add(text)
            sources.add(source)


def pr_evidence_from_row(row: dict[str, Any]) -> tuple[set[str], set[str]]:
    refs: set[str] = set()
    sources: set[str] = set()
    source = text_field(row, "_source_path")
    tools = set(tools_from_decision(row))
    tool_name = text_field(row, "tool_name")
    if tool_name:
        tools.add(tool_name)

    success = row_succeeded(row)
    if tools & PR_CREATE_TOOLS and success:
        refs.add("keeper_pr_create")
        sources.add(source)
        add_pr_refs_from_structured_output(
            refs=refs, sources=sources, source=source, row=row
        )

    if success and tools & SHELL_TOOLS:
        args_text = "\n".join(command_texts_from_structured_input(row))
        if GH_PR_CREATE_RE.search(args_text):
            refs.add("gh pr create")
            sources.add(source)
            add_pr_refs_from_structured_output(
                refs=refs, sources=sources, source=source, row=row
            )

    return refs, sources


def bool_field(row: dict[str, Any], key: str) -> bool:
    value = row.get(key)
    return value if isinstance(value, bool) else False


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


MARKER_LIST_FIELDS = (
    "audit_markers",
    "evidence_markers",
    "lifecycle_markers",
    "result_markers",
    "route_markers",
)
MARKER_OBJECT_FIELDS = (
    "audit",
    "evidence",
    "metadata",
    "route",
    "route_evidence",
    "tool_metadata",
)


def normalized_marker(value: Any) -> str | None:
    if isinstance(value, str) and value.strip():
        return value.strip().lower()
    return None


def structured_markers(row: dict[str, Any]) -> set[str]:
    markers: set[str] = set()

    def add_marker(value: Any) -> None:
        marker = normalized_marker(value)
        if marker is not None:
            markers.add(marker)

    def add_key_value(key: str, value: Any) -> None:
        marker = normalized_marker(value)
        if marker is not None:
            markers.add(f"{key}={marker}")

    for key in MARKER_LIST_FIELDS:
        value = row.get(key)
        if isinstance(value, list):
            for item in value:
                add_marker(item)
        else:
            add_marker(value)

    for key in MARKER_OBJECT_FIELDS:
        value = row.get(key)
        if isinstance(value, dict):
            for marker_key in MARKER_LIST_FIELDS:
                nested = value.get(marker_key)
                if isinstance(nested, list):
                    for item in nested:
                        add_marker(item)
                else:
                    add_marker(nested)
            for scalar_key in (
                "action",
                "event",
                "execution_via",
                "op",
                "route_via",
                "sandbox_profile",
                "via",
            ):
                add_key_value(f"{key}.{scalar_key}", value.get(scalar_key))

    for key in (
        "action",
        "execution_via",
        "op",
        "review_event",
        "route_via",
        "sandbox_profile",
        "tool_action",
        "via",
    ):
        add_key_value(key, row.get(key))

    return markers


def marker_matches(markers: set[str], *needles: str) -> bool:
    for marker in markers:
        if any(
            marker == needle or marker.startswith(f"{needle}:") for needle in needles
        ):
            return True
    return False


def has_gh_pr_create_marker(row: dict[str, Any]) -> bool:
    markers = structured_markers(row)
    return marker_matches(markers, "pr_create", "gh_pr_create", "gh pr create")


def has_pr_approve_marker(row: dict[str, Any]) -> bool:
    markers = structured_markers(row)
    return marker_matches(
        markers,
        "pr_approve",
        "approve",
        "action=approve",
        "event=approve",
        "review_event=approve",
    )


def has_docker_execution_marker(row: dict[str, Any]) -> bool:
    markers = structured_markers(row)
    return marker_matches(
        markers,
        "execution_via=docker",
        "execution_via=brokered",
        "metadata.execution_via=docker",
        "metadata.execution_via=brokered",
        "metadata.route_via=docker",
        "metadata.route_via=brokered",
        "metadata.via=docker",
        "metadata.via=brokered",
        "route.execution_via=docker",
        "route.execution_via=brokered",
        "route.route_via=docker",
        "route.route_via=brokered",
        "route.via=docker",
        "route.via=brokered",
        "route_evidence.execution_via=docker",
        "route_evidence.execution_via=brokered",
        "route_evidence.route_via=docker",
        "route_evidence.route_via=brokered",
        "route_evidence.via=docker",
        "route_evidence.via=brokered",
        "route_via=docker",
        "route_via=brokered",
        "tool_metadata.execution_via=docker",
        "tool_metadata.execution_via=brokered",
        "tool_metadata.route_via=docker",
        "tool_metadata.route_via=brokered",
        "tool_metadata.via=docker",
        "tool_metadata.via=brokered",
        "via=docker",
        "via=brokered",
    )


def has_tool_call_docker_execution_marker(row: dict[str, Any]) -> bool:
    return has_docker_execution_marker(row) or has_docker_execution_marker(
        output_json(row)
    )


def shell_words(command: str) -> list[str]:
    try:
        return shlex.split(command)
    except ValueError:
        return []


def tool_call_command_candidates(row: dict[str, Any]) -> list[str]:
    candidates: list[str] = []

    def add(raw: Any) -> None:
        if isinstance(raw, str):
            command = raw.strip()
            if command and command not in candidates:
                candidates.append(command)

    input_json = row.get("input")
    if isinstance(input_json, dict):
        tool = row.get("tool")
        if tool == "keeper_shell" and input_json.get("op") == "gh":
            cmd = input_json.get("cmd")
            if isinstance(cmd, str):
                add("gh " + cmd.strip())
        elif tool == "keeper_bash":
            add(input_json.get("cmd"))
        elif tool == "masc_code_shell":
            add(input_json.get("command"))
        elif tool == "masc_code_git":
            add(input_json.get("action"))

    add(output_json(row).get("command"))
    return candidates


def gh_argv(command: str) -> list[str]:
    words = shell_words(command)
    if words and words[0].lower() == "gh":
        return words[1:]
    return []


def command_is_git_push(command: str) -> bool:
    words = shell_words(command)
    return len(words) >= 2 and words[0].lower() == "git" and words[1].lower() == "push"


def command_is_gh_pr_create(command: str) -> bool:
    argv = gh_argv(command)
    return len(argv) >= 2 and argv[0].lower() == "pr" and argv[1].lower() == "create"


def command_is_gh_pr_approve(command: str) -> bool:
    argv = gh_argv(command)
    lowered_args = [arg.lower() for arg in argv[3:]]
    return (
        len(argv) >= 3
        and argv[0].lower() == "pr"
        and argv[1].lower() == "review"
        and "--approve" in lowered_args
    )


def pr_lifecycle_evidence_from_decision(
    row: dict[str, Any],
) -> tuple[set[str], set[str]]:
    evidence: set[str] = set()
    docker_evidence: set[str] = set()
    docker_routed_cache: bool | None = None

    def docker_routed() -> bool:
        nonlocal docker_routed_cache
        if docker_routed_cache is None:
            docker_routed_cache = has_docker_execution_marker(row)
        return docker_routed_cache

    def add(item: str) -> None:
        evidence.add(item)
        if docker_routed():
            docker_evidence.add(item)

    if any(tool_succeeded_in_row(row, tool) for tool in PR_CREATE_TOOLS):
        add("pr_create:keeper_pr_create")
    tool = row.get("tool")
    if (
        row.get("event") == "tool_exec"
        and isinstance(tool, str)
        and tool in SHELL_TOOLS
        and row_success(row)
        and has_gh_pr_create_marker(row)
    ):
        add(f"pr_create:{tool}:gh_pr_create")
    if tool_succeeded_in_row(row, "keeper_pr_review_comment") and has_pr_approve_marker(
        row
    ):
        add("pr_approve:keeper_pr_review_comment")
    return evidence, docker_evidence


def pr_lifecycle_evidence_from_tool_call(
    row: dict[str, Any],
) -> tuple[set[str], set[str]]:
    evidence: set[str] = set()
    docker_evidence: set[str] = set()
    tool = row.get("tool")
    if not isinstance(tool, str) or not bool_field(row, "success"):
        return evidence, docker_evidence

    def add(item: str) -> None:
        evidence.add(item)
        if has_tool_call_docker_execution_marker(row):
            docker_evidence.add(item)

    if tool == "keeper_pr_create":
        add("pr_create:keeper_pr_create")
    elif tool == "masc_code_git":
        for command in tool_call_command_candidates(row):
            if command.strip().lower() == "push":
                add("git_push:masc_code_git")
                break
    elif tool in SHELL_TOOLS or tool == "masc_code_shell":
        for command in tool_call_command_candidates(row):
            if command_is_git_push(command):
                add(f"git_push:{tool}")
            if command_is_gh_pr_create(command):
                add(f"pr_create:{tool}")
            if command_is_gh_pr_approve(command):
                add(f"pr_approve:{tool}")
    return evidence, docker_evidence


def metric_source(row: dict[str, Any]) -> str:
    for key in ("pr_work_action_source", "tool_name", "tool"):
        value = row.get(key)
        if isinstance(value, str) and value.strip():
            return value.strip()
    return "pr_action_metrics"


def tools_from_action_metric(row: dict[str, Any]) -> list[str]:
    tools: list[str] = []
    for key in ("pr_work_action_source", "tool_name", "tool"):
        value = row.get(key)
        if isinstance(value, str):
            tools.append(value)
    return tools


def pr_lifecycle_evidence_from_action_metric(
    row: dict[str, Any],
) -> tuple[set[str], set[str]]:
    evidence: set[str] = set()
    docker_evidence: set[str] = set()
    source = metric_source(row)

    def add(item: str) -> None:
        evidence.add(item)
        if has_docker_execution_marker(row):
            docker_evidence.add(item)

    metric_event = row.get("metric_event")
    if metric_event == "keeper_pr_work_action":
        if not bool_field(row, "pr_work_action_success"):
            return evidence, docker_evidence
        action = row.get("pr_work_action")
        if not isinstance(action, str):
            return evidence, docker_evidence
        match action.upper():
            case "PR_CREATE":
                add(f"pr_create:{source}")
            case "GIT_PUSH":
                add(f"git_push:{source}")
    elif metric_event == "keeper_pr_review_action":
        if not bool_field(row, "pr_review_action_success"):
            return evidence, docker_evidence
        action = row.get("pr_review_action")
        if isinstance(action, str) and action.upper() == "APPROVE":
            add(f"pr_approve:{source}")
    return evidence, docker_evidence


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


def day_key_from_unix(ts_unix: float) -> int:
    return int(datetime.fromtimestamp(ts_unix).strftime("%Y%m%d"))


def pr_action_metric_day_key(path: Path) -> int | None:
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


def pr_action_metric_paths(
    base_path: Path, name: str, *, min_day_key: int | None = None
) -> list[Path]:
    metrics_dir = base_path / ".masc" / "keepers" / name / "pr-action-metrics"
    if not metrics_dir.exists():
        return []
    candidates: list[tuple[int, str, Path]] = []
    for path in metrics_dir.rglob("*.jsonl"):
        if not path.is_file():
            continue
        day_key = pr_action_metric_day_key(path)
        if min_day_key is not None and day_key is not None and day_key < min_day_key:
            continue
        candidates.append((day_key or -1, str(path), path))
    return [path for _, _, path in sorted(candidates, reverse=True)]


def pr_creation_scan_paths(base_path: Path, name: str) -> list[Path]:
    root = base_path / ".masc"
    paths: list[Path] = decision_log_paths(base_path, name)
    history = root / "keepers" / name / ".playground_pr_history.jsonl"
    if history.exists():
        paths.append(history)
    for subdir in ("metrics", "pr-action-metrics", "execution-receipts"):
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


def complete_lifecycle_evidence(evidence: set[str]) -> bool:
    return (
        any(item.startswith("pr_create:") for item in evidence)
        and any(item.startswith("git_push:") for item in evidence)
        and any(item.startswith("pr_approve:") for item in evidence)
    )


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
        day_key = pr_action_metric_day_key(path)
        candidates.append((day_key or -1, str(path), path))
    return [path for _, _, path in sorted(candidates, reverse=True)]


def scan_keeper_evidence(
    base_path: Path,
    name: str,
    *,
    max_silence_hours: float | None = None,
    evidence_run_id: str | None = None,
    now: float | None = None,
) -> tuple[float | None, set[str], set[str], set[str]]:
    latest_ts: float | None = None
    tools: set[str] = set()
    pr_lifecycle_evidence: set[str] = set()
    docker_pr_lifecycle_evidence: set[str] = set()
    min_metric_ts: float | None = None
    min_metric_day_key: int | None = None
    if max_silence_hours is not None:
        min_metric_ts = (time.time() if now is None else now) - (
            max_silence_hours * 3600.0
        )
        min_metric_day_key = day_key_from_unix(min_metric_ts)
    for decisions in decision_log_paths(base_path, name):
        for row in iter_jsonl(decisions):
            ts = numeric_field(row, "ts_unix")
            if ts is not None:
                latest_ts = ts if latest_ts is None else max(latest_ts, ts)
            tools.update(tools_from_decision(row))
            if row_mentions_evidence_run_id(row, evidence_run_id):
                row_evidence, row_docker_evidence = (
                    pr_lifecycle_evidence_from_decision(row)
                )
                pr_lifecycle_evidence.update(row_evidence)
                docker_pr_lifecycle_evidence.update(row_docker_evidence)
    for metrics in pr_action_metric_paths(
        base_path, name, min_day_key=min_metric_day_key
    ):
        for row in iter_jsonl(metrics):
            ts = numeric_field(row, "ts_unix")
            if min_metric_ts is not None and ts is not None and ts < min_metric_ts:
                continue
            if ts is not None:
                latest_ts = ts if latest_ts is None else max(latest_ts, ts)
            tools.update(tools_from_action_metric(row))
            if row_mentions_evidence_run_id(row, evidence_run_id):
                row_evidence, row_docker_evidence = (
                    pr_lifecycle_evidence_from_action_metric(row)
                )
                pr_lifecycle_evidence.update(row_evidence)
                docker_pr_lifecycle_evidence.update(row_docker_evidence)
        if complete_lifecycle_evidence(
            pr_lifecycle_evidence
        ) and complete_lifecycle_evidence(docker_pr_lifecycle_evidence):
            break
    if not (
        complete_lifecycle_evidence(pr_lifecycle_evidence)
        and complete_lifecycle_evidence(docker_pr_lifecycle_evidence)
    ):
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
                if row_mentions_evidence_run_id(row, evidence_run_id):
                    row_evidence, row_docker_evidence = (
                        pr_lifecycle_evidence_from_tool_call(row)
                    )
                    pr_lifecycle_evidence.update(row_evidence)
                    docker_pr_lifecycle_evidence.update(row_docker_evidence)
            if complete_lifecycle_evidence(
                pr_lifecycle_evidence
            ) and complete_lifecycle_evidence(docker_pr_lifecycle_evidence):
                break
    return latest_ts, tools, pr_lifecycle_evidence, docker_pr_lifecycle_evidence


def audit_keeper(
    *,
    base_path: Path,
    config_path: Path,
    max_silence_hours: float,
    require_board_evidence: bool,
    require_product_evidence: bool,
    require_design_evidence: bool,
    require_pr_surface_evidence: bool,
    require_pr_review_evidence: bool,
    require_pr_create_evidence: bool,
    require_git_push_evidence: bool,
    require_pr_approve_evidence: bool,
    require_pr_created_evidence: bool,
    require_pr_url_evidence: bool,
    require_docker_pr_create_evidence: bool,
    require_docker_git_push_evidence: bool,
    require_docker_pr_approve_evidence: bool,
    evidence_run_id: str | None,
    forbidden_github_identities: set[str] | None = None,
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
    tool_preset = tool_preset_from_runtime(runtime) or tool_preset_from_config(config)
    github_identity = string_field(runtime, "github_identity") or string_field(
        config, "github_identity"
    )
    git_identity_mode = string_field(runtime, "git_identity_mode") or string_field(
        config, "git_identity_mode"
    )

    if sandbox_profile != "docker":
        failures.append("sandbox_not_docker")
    if network_mode != "inherit":
        failures.append("network_not_inherit")
    if tool_preset not in PR_CAPABLE_PRESETS:
        failures.append("preset_not_pr_capable")
    if not github_identity:
        failures.append("github_identity_missing")
    elif forbidden_github_identities and github_identity in forbidden_github_identities:
        failures.append(f"github_identity_forbidden_{github_identity}")
    if git_identity_mode != "github_identity":
        failures.append("git_identity_mode_not_github_identity")

    credential_dir: Path | None = None
    credential_dir_exists = False
    github_account_login: str | None = None
    if github_identity:
        credential_dir = (
            base_path / ".masc" / "github-identities" / github_identity / "gh"
        )
        credential_dir_exists = credential_dir.is_dir()
        if not credential_dir_exists:
            failures.append("github_credential_dir_missing")
        else:
            github_account_login = read_github_account_login(credential_dir)
            if (
                forbidden_github_identities
                and github_account_login in forbidden_github_identities
                and github_account_login != github_identity
            ):
                failures.append(f"github_account_forbidden_{github_account_login}")

    (
        evidence_ts,
        tools,
        pr_lifecycle_evidence,
        docker_pr_lifecycle_evidence,
    ) = scan_keeper_evidence(
        base_path,
        name,
        max_silence_hours=max_silence_hours,
        evidence_run_id=evidence_run_id,
    )
    pr_creation_evidence = scan_pr_creation_evidence(base_path, name)
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
            for ts in (evidence_ts, board_post_ts, runtime_turn_ts, updated_ts)
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
    product_action = bool(product_evidence)
    design_action = bool(design_evidence)
    pr_surface_action = bool(tools & PR_SURFACE_TOOLS)
    pr_review_mutation = bool(tools & PR_REVIEW_MUTATION_TOOLS)
    pr_create_action = any(
        item.startswith("pr_create:") for item in pr_lifecycle_evidence
    )
    git_push_action = any(
        item.startswith("git_push:") for item in pr_lifecycle_evidence
    )
    pr_approve_mutation = any(
        item.startswith("pr_approve:") for item in pr_lifecycle_evidence
    )
    pr_lifecycle_action = pr_create_action and git_push_action and pr_approve_mutation
    docker_pr_create_action = any(
        item.startswith("pr_create:") for item in docker_pr_lifecycle_evidence
    )
    docker_git_push_action = any(
        item.startswith("git_push:") for item in docker_pr_lifecycle_evidence
    )
    docker_pr_approve_mutation = any(
        item.startswith("pr_approve:") for item in docker_pr_lifecycle_evidence
    )
    docker_pr_lifecycle_action = (
        docker_pr_create_action
        and docker_git_push_action
        and docker_pr_approve_mutation
    )
    pr_created_evidence = pr_creation_evidence.created
    pr_url_evidence = pr_creation_evidence.url_present
    if require_board_evidence and not board_action:
        failures.append("board_action_evidence_missing")
    if require_product_evidence and not product_action:
        failures.append("product_action_evidence_missing")
    if require_design_evidence and not design_action:
        failures.append("design_action_evidence_missing")
    if require_pr_surface_evidence and not pr_surface_action:
        failures.append("pr_surface_evidence_missing")
    elif not pr_surface_action:
        warnings.append("pr_surface_evidence_missing")
    if require_pr_review_evidence and not pr_review_mutation:
        failures.append("pr_review_mutation_evidence_missing")
    elif not pr_review_mutation:
        warnings.append("pr_review_mutation_evidence_missing")
    if require_pr_create_evidence and not pr_create_action:
        failures.append("pr_create_evidence_missing")
    if require_pr_created_evidence and not pr_created_evidence:
        failures.append("pr_created_evidence_missing")
    elif not pr_created_evidence:
        warnings.append("pr_created_evidence_missing")
    if require_pr_url_evidence and not pr_url_evidence:
        failures.append("pr_url_evidence_missing")
    elif pr_created_evidence and not pr_url_evidence:
        warnings.append("pr_url_evidence_missing")
    if require_git_push_evidence and not git_push_action:
        failures.append("git_push_evidence_missing")
    if require_pr_approve_evidence and not pr_approve_mutation:
        failures.append("pr_approve_evidence_missing")
    if require_docker_pr_create_evidence and not docker_pr_create_action:
        failures.append("docker_pr_create_evidence_missing")
    if require_docker_git_push_evidence and not docker_git_push_action:
        failures.append("docker_git_push_evidence_missing")
    if require_docker_pr_approve_evidence and not docker_pr_approve_mutation:
        failures.append("docker_pr_approve_evidence_missing")

    return KeeperAudit(
        name=name,
        config_path=str(config_path),
        runtime_path=str(runtime_path) if runtime_path.exists() else None,
        sandbox_profile=sandbox_profile,
        network_mode=network_mode,
        tool_preset=tool_preset,
        github_identity=github_identity,
        github_account_login=github_account_login,
        git_identity_mode=git_identity_mode,
        credential_dir=str(credential_dir) if credential_dir else None,
        credential_dir_exists=credential_dir_exists,
        last_turn_ts=last_turn_ts,
        last_turn_age_hours=last_turn_age_hours,
        recent_action=recent_action,
        board_action=board_action,
        product_action=product_action,
        design_action=design_action,
        pr_surface_action=pr_surface_action,
        pr_review_mutation=pr_review_mutation,
        pr_create_action=pr_create_action,
        git_push_action=git_push_action,
        pr_approve_mutation=pr_approve_mutation,
        pr_lifecycle_action=pr_lifecycle_action,
        docker_pr_create_action=docker_pr_create_action,
        docker_git_push_action=docker_git_push_action,
        docker_pr_approve_mutation=docker_pr_approve_mutation,
        docker_pr_lifecycle_action=docker_pr_lifecycle_action,
        pr_created_evidence=pr_created_evidence,
        pr_url_evidence=pr_url_evidence,
        evidence_tools=sorted(tools),
        board_post_evidence=sorted(board_post_evidence),
        product_evidence=sorted(product_evidence),
        design_evidence=sorted(design_evidence),
        pr_lifecycle_evidence=sorted(pr_lifecycle_evidence),
        docker_pr_lifecycle_evidence=sorted(docker_pr_lifecycle_evidence),
        pr_evidence_refs=sorted(pr_creation_evidence.refs),
        pr_evidence_sources=sorted(pr_creation_evidence.sources),
        failures=failures,
        warnings=warnings,
    )


def build_report(args: argparse.Namespace) -> dict[str, Any]:
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
            require_product_evidence=args.require_product_evidence,
            require_design_evidence=args.require_design_evidence,
            require_pr_surface_evidence=args.require_pr_surface_evidence,
            require_pr_review_evidence=args.require_pr_review_evidence,
            require_pr_create_evidence=(
                args.require_pr_create_evidence or args.require_pr_lifecycle_evidence
            ),
            require_git_push_evidence=(
                args.require_git_push_evidence or args.require_pr_lifecycle_evidence
            ),
            require_pr_approve_evidence=(
                args.require_pr_approve_evidence or args.require_pr_lifecycle_evidence
            ),
            require_pr_created_evidence=args.require_pr_created_evidence,
            require_pr_url_evidence=args.require_pr_url_evidence,
            require_docker_pr_create_evidence=(
                args.require_docker_pr_create_evidence
                or args.require_docker_pr_lifecycle_evidence
            ),
            require_docker_git_push_evidence=(
                args.require_docker_git_push_evidence
                or args.require_docker_pr_lifecycle_evidence
            ),
            require_docker_pr_approve_evidence=(
                args.require_docker_pr_approve_evidence
                or args.require_docker_pr_lifecycle_evidence
            ),
            evidence_run_id=args.evidence_run_id,
            forbidden_github_identities=set(args.forbid_github_identity or []),
        )
        for path in config_paths
    ]

    fleet_failures: list[str] = []
    if len(config_paths) < args.expected_keepers:
        fleet_failures.append(
            f"minimum_{args.expected_keepers}_configured_keepers_got_{len(config_paths)}"
        )
    github_identity_counts = Counter(
        keeper.github_identity for keeper in keepers if keeper.github_identity
    )
    github_account_counts = Counter(
        keeper.github_account_login
        for keeper in keepers
        if keeper.github_account_login
    )
    requires_docker_approve = (
        args.require_docker_pr_approve_evidence
        or args.require_docker_pr_lifecycle_evidence
    )
    if requires_docker_approve and len(github_identity_counts) < 2:
        fleet_failures.append(
            "docker_pr_approve_identity_pool_insufficient"
            f"_unique_github_identities_{len(github_identity_counts)}"
        )
    if requires_docker_approve:
        unresolved_account_identities = sorted(
            {
                keeper.github_identity
                for keeper in keepers
                if keeper.github_identity and not keeper.github_account_login
            }
        )
        if unresolved_account_identities:
            fleet_failures.append(
                "docker_pr_approve_identity_pool_unresolved_github_accounts_"
                f"{len(unresolved_account_identities)}"
            )
        elif len(github_account_counts) < 2:
            fleet_failures.append(
                "docker_pr_approve_account_pool_insufficient"
                f"_unique_accounts_{len(github_account_counts)}"
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
        "github_identity_counts": dict(sorted(github_identity_counts.items())),
        "github_account_counts": dict(sorted(github_account_counts.items())),
        "requirements": {
            "require_board_evidence": args.require_board_evidence,
            "require_product_evidence": args.require_product_evidence,
            "require_design_evidence": args.require_design_evidence,
            "forbid_github_identity": args.forbid_github_identity or [],
            "require_pr_surface_evidence": args.require_pr_surface_evidence,
            "require_pr_review_evidence": args.require_pr_review_evidence,
            "require_pr_create_evidence": args.require_pr_create_evidence,
            "require_pr_created_evidence": args.require_pr_created_evidence,
            "require_pr_url_evidence": args.require_pr_url_evidence,
            "require_git_push_evidence": args.require_git_push_evidence,
            "require_pr_approve_evidence": args.require_pr_approve_evidence,
            "require_pr_lifecycle_evidence": args.require_pr_lifecycle_evidence,
            "require_docker_pr_create_evidence": (
                args.require_docker_pr_create_evidence
            ),
            "require_docker_git_push_evidence": args.require_docker_git_push_evidence,
            "require_docker_pr_approve_evidence": (
                args.require_docker_pr_approve_evidence
            ),
            "require_docker_pr_lifecycle_evidence": (
                args.require_docker_pr_lifecycle_evidence
            ),
            "evidence_run_id": args.evidence_run_id,
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
        print(
            "- {name}: {marker} preset={preset} sandbox={sandbox}/{network} "
            "gh={github} recent={recent} age={age} board={board} "
            "gh_account={github_account} "
            "product={product} design={design} "
            "pr_surface={pr_surface} pr_review={pr_review} "
            "pr_create={pr_create} git_push={git_push} "
            "pr_approve={pr_approve} pr_created={pr_created} pr_url={pr_url} "
            "docker_pr_create={docker_pr_create} "
            "docker_git_push={docker_git_push} "
            "docker_pr_approve={docker_pr_approve}".format(
                name=keeper["name"],
                marker=marker,
                preset=keeper["tool_preset"],
                sandbox=keeper["sandbox_profile"],
                network=keeper["network_mode"],
                github=keeper["github_identity"],
                github_account=keeper["github_account_login"],
                recent=str(keeper["recent_action"]).lower(),
                age=age_label,
                board=str(keeper["board_action"]).lower(),
                product=str(keeper["product_action"]).lower(),
                design=str(keeper["design_action"]).lower(),
                pr_surface=str(keeper["pr_surface_action"]).lower(),
                pr_review=str(keeper["pr_review_mutation"]).lower(),
                pr_create=str(keeper["pr_create_action"]).lower(),
                git_push=str(keeper["git_push_action"]).lower(),
                pr_approve=str(keeper["pr_approve_mutation"]).lower(),
                pr_created=str(keeper["pr_created_evidence"]).lower(),
                pr_url=str(keeper["pr_url_evidence"]).lower(),
                docker_pr_create=str(keeper["docker_pr_create_action"]).lower(),
                docker_git_push=str(keeper["docker_git_push_action"]).lower(),
                docker_pr_approve=str(keeper["docker_pr_approve_mutation"]).lower(),
            )
        )
        for ref in keeper["pr_evidence_refs"][:5]:
            print(f"    pr_evidence: {ref}")
        for failure in failures:
            print(f"    fail: {failure}")
        for warning in warnings:
            print(f"    warn: {warning}")


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--base-path",
        default=str(Path.home() / "me"),
        help="MASC base path containing .masc (default: ~/me)",
    )
    parser.add_argument(
        "--expected-keepers",
        type=int,
        default=14,
        help="Minimum configured keeper count required for fleet readiness.",
    )
    parser.add_argument("--max-silence-hours", type=float, default=2400.0)
    parser.add_argument(
        "--forbid-github-identity",
        action="append",
        default=[],
        metavar="IDENTITY",
        help=(
            "Fail keepers using this GitHub identity. Repeat for multiple "
            "operator or unsafe identity names."
        ),
    )
    parser.add_argument(
        "--no-require-board-evidence",
        action="store_false",
        dest="require_board_evidence",
        help="Do not fail when a keeper lacks board action evidence.",
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
        "--require-pr-surface-evidence",
        action="store_true",
        help="Fail unless each keeper has used a PR/git/code surface tool.",
    )
    parser.add_argument(
        "--require-pr-review-evidence",
        action="store_true",
        help="Fail unless each keeper has used PR review/comment/reply mutation tools.",
    )
    parser.add_argument(
        "--require-pr-create-evidence",
        action="store_true",
        help="Fail unless each keeper has direct PR creation evidence.",
    )
    parser.add_argument(
        "--require-pr-created-evidence",
        action="store_true",
        help="Fail unless each keeper has structured successful PR creation evidence.",
    )
    parser.add_argument(
        "--require-pr-url-evidence",
        action="store_true",
        help="Fail unless each keeper has a structured GitHub pull request URL.",
    )
    parser.add_argument(
        "--require-git-push-evidence",
        action="store_true",
        help="Fail unless each keeper has direct git push evidence.",
    )
    parser.add_argument(
        "--require-pr-approve-evidence",
        action="store_true",
        help="Fail unless each keeper has direct APPROVE review evidence.",
    )
    parser.add_argument(
        "--require-pr-lifecycle-evidence",
        action="store_true",
        help=(
            "Fail unless each keeper has direct PR create, git push, and "
            "PR APPROVE evidence."
        ),
    )
    parser.add_argument(
        "--require-docker-pr-create-evidence",
        action="store_true",
        help=(
            "Fail unless each keeper has direct PR creation evidence with an "
            "explicit Docker execution marker."
        ),
    )
    parser.add_argument(
        "--require-docker-git-push-evidence",
        action="store_true",
        help=(
            "Fail unless each keeper has direct git push evidence with an "
            "explicit Docker execution marker."
        ),
    )
    parser.add_argument(
        "--require-docker-pr-approve-evidence",
        action="store_true",
        help=(
            "Fail unless each keeper has direct APPROVE review evidence with an "
            "explicit Docker execution marker."
        ),
    )
    parser.add_argument(
        "--require-docker-pr-lifecycle-evidence",
        action="store_true",
        help=(
            "Fail unless each keeper has direct PR create, git push, and "
            "PR APPROVE evidence with explicit Docker execution markers."
        ),
    )
    parser.add_argument(
        "--evidence-run-id",
        default=None,
        help=(
            "When set, count PR lifecycle evidence only from rows that mention "
            "this run id. This prevents older proof runs from satisfying a "
            "fresh lifecycle reprobe."
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
