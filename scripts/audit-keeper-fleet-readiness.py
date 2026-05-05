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
import sys
import time
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


@dataclass
class KeeperAudit:
    name: str
    config_path: str
    runtime_path: str | None
    sandbox_profile: str | None
    network_mode: str | None
    tool_preset: str | None
    github_identity: str | None
    git_identity_mode: str | None
    credential_dir: str | None
    credential_dir_exists: bool
    last_turn_ts: float | None
    last_turn_age_hours: float | None
    recent_action: bool
    board_action: bool
    pr_surface_action: bool
    pr_review_mutation: bool
    evidence_tools: list[str]
    failures: list[str]
    warnings: list[str]


def load_json(path: Path) -> dict[str, Any]:
    with path.open("r", encoding="utf-8") as handle:
        data = json.load(handle)
    if not isinstance(data, dict):
        raise ValueError(f"{path}: expected JSON object")
    return data


def iter_jsonl(path: Path) -> list[dict[str, Any]]:
    rows: list[dict[str, Any]] = []
    if not path.exists():
        return rows
    with path.open("r", encoding="utf-8") as handle:
        for line_no, line in enumerate(handle, start=1):
            line = line.strip()
            if not line:
                continue
            try:
                row = json.loads(line)
            except json.JSONDecodeError as exc:
                raise ValueError(f"{path}:{line_no}: {exc}") from exc
            if isinstance(row, dict):
                rows.append(row)
    return rows


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


def scan_keeper_evidence(base_path: Path, name: str) -> tuple[float | None, set[str]]:
    decisions = base_path / ".masc" / "keepers" / f"{name}.decisions.jsonl"
    latest_ts: float | None = None
    tools: set[str] = set()
    for row in iter_jsonl(decisions):
        ts = numeric_field(row, "ts_unix")
        if ts is not None:
            latest_ts = ts if latest_ts is None else max(latest_ts, ts)
        tools.update(tools_from_decision(row))
    return latest_ts, tools


def audit_keeper(
    *,
    base_path: Path,
    config_path: Path,
    max_silence_hours: float,
    require_board_evidence: bool,
    require_pr_surface_evidence: bool,
    require_pr_review_evidence: bool,
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
    if git_identity_mode != "github_identity":
        failures.append("git_identity_mode_not_github_identity")

    credential_dir: Path | None = None
    credential_dir_exists = False
    if github_identity:
        credential_dir = (
            base_path / ".masc" / "github-identities" / github_identity / "gh"
        )
        credential_dir_exists = credential_dir.is_dir()
        if not credential_dir_exists:
            failures.append("github_credential_dir_missing")

    evidence_ts, tools = scan_keeper_evidence(base_path, name)
    runtime_turn_ts = numeric_field(runtime, "last_turn_ts")
    updated_ts = iso_to_unix(string_field(runtime, "updated_at"))
    last_turn_ts = max(
        (ts for ts in (evidence_ts, runtime_turn_ts, updated_ts) if ts is not None),
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

    board_action = bool(tools & BOARD_TOOLS)
    pr_surface_action = bool(tools & PR_SURFACE_TOOLS)
    pr_review_mutation = bool(tools & PR_REVIEW_MUTATION_TOOLS)
    if require_board_evidence and not board_action:
        failures.append("board_action_evidence_missing")
    if require_pr_surface_evidence and not pr_surface_action:
        failures.append("pr_surface_evidence_missing")
    elif not pr_surface_action:
        warnings.append("pr_surface_evidence_missing")
    if require_pr_review_evidence and not pr_review_mutation:
        failures.append("pr_review_mutation_evidence_missing")
    elif not pr_review_mutation:
        warnings.append("pr_review_mutation_evidence_missing")

    return KeeperAudit(
        name=name,
        config_path=str(config_path),
        runtime_path=str(runtime_path) if runtime_path.exists() else None,
        sandbox_profile=sandbox_profile,
        network_mode=network_mode,
        tool_preset=tool_preset,
        github_identity=github_identity,
        git_identity_mode=git_identity_mode,
        credential_dir=str(credential_dir) if credential_dir else None,
        credential_dir_exists=credential_dir_exists,
        last_turn_ts=last_turn_ts,
        last_turn_age_hours=last_turn_age_hours,
        recent_action=recent_action,
        board_action=board_action,
        pr_surface_action=pr_surface_action,
        pr_review_mutation=pr_review_mutation,
        evidence_tools=sorted(tools),
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
            require_pr_surface_evidence=args.require_pr_surface_evidence,
            require_pr_review_evidence=args.require_pr_review_evidence,
        )
        for path in config_paths
    ]

    fleet_failures: list[str] = []
    if len(config_paths) != args.expected_keepers:
        fleet_failures.append(
            f"expected_{args.expected_keepers}_configured_keepers_got_{len(config_paths)}"
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
            "require_pr_surface_evidence": args.require_pr_surface_evidence,
            "require_pr_review_evidence": args.require_pr_review_evidence,
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
        "expected={expected_keepers} max_silence_hours={max_silence_hours}".format(
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
            "pr_surface={pr_surface} pr_review={pr_review}".format(
                name=keeper["name"],
                marker=marker,
                preset=keeper["tool_preset"],
                sandbox=keeper["sandbox_profile"],
                network=keeper["network_mode"],
                github=keeper["github_identity"],
                recent=str(keeper["recent_action"]).lower(),
                age=age_label,
                board=str(keeper["board_action"]).lower(),
                pr_surface=str(keeper["pr_surface_action"]).lower(),
                pr_review=str(keeper["pr_review_mutation"]).lower(),
            )
        )
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
    parser.add_argument("--expected-keepers", type=int, default=14)
    parser.add_argument("--max-silence-hours", type=float, default=2400.0)
    parser.add_argument(
        "--no-require-board-evidence",
        action="store_false",
        dest="require_board_evidence",
        help="Do not fail when a keeper lacks board action evidence.",
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
