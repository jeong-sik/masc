#!/usr/bin/env python3
"""Plan or apply a keeper GitHub identity split.

The Docker PR lifecycle proof needs keepers to create PRs with one GitHub
identity and approve PRs authored by a different identity. This script keeps
the live config mutation explicit: dry-run is the default, and --apply writes
only keeper TOML files after creating backups.
"""

from __future__ import annotations

import argparse
import json
import re
import shutil
import sys
from dataclasses import asdict, dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

import tomllib


IDENTITY_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]*$")
SECTION_RE = re.compile(r"^\s*\[[^\]]+\]\s*(?:#.*)?$")


@dataclass(frozen=True)
class Assignment:
    keeper: str
    config_path: str
    github_identity: str
    credential_dir: str
    credential_dir_exists: bool


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--base-path",
        default=str(Path.home() / "me"),
        help="MASC base path containing .masc (default: ~/me).",
    )
    parser.add_argument(
        "--identity",
        action="append",
        required=True,
        help="GitHub identity name to distribute across keepers. Pass at least two.",
    )
    parser.add_argument(
        "--keeper-names",
        default="",
        help="Optional comma-separated keeper names. Default: all keeper TOMLs.",
    )
    parser.add_argument(
        "--apply",
        action="store_true",
        help="Write keeper TOMLs. Default is dry-run JSON only.",
    )
    parser.add_argument(
        "--allow-missing-bundles",
        action="store_true",
        help="Allow --apply even when identity GH config dirs are missing.",
    )
    parser.add_argument(
        "--backup-dir",
        default="",
        help="Backup directory for --apply. Default: .masc/backups/keeper-identity-split-<UTC>.",
    )
    return parser.parse_args(argv)


def validate_identity(identity: str) -> str:
    if not IDENTITY_RE.match(identity):
        raise ValueError(
            f"invalid identity {identity!r}: use letters, numbers, dot, underscore, dash; no slash"
        )
    return identity


def load_toml(path: Path) -> dict[str, Any]:
    with path.open("rb") as handle:
        data = tomllib.load(handle)
    if not isinstance(data, dict):
        raise ValueError(f"{path}: expected TOML object")
    return data


def keeper_config_paths(base_path: Path, explicit_names: str) -> list[Path]:
    config_dir = base_path / ".masc" / "config" / "keepers"
    if not config_dir.is_dir():
        raise FileNotFoundError(f"keeper config dir not found: {config_dir}")
    if explicit_names.strip():
        names = [
            item.strip()
            for item in explicit_names.split(",")
            if item.strip()
        ]
        return [config_dir / f"{name}.toml" for name in names]
    return sorted(path for path in config_dir.glob("*.toml") if path.name != "base.toml")


def build_plan(base_path: Path, identities: list[str], config_paths: list[Path]) -> list[Assignment]:
    plan: list[Assignment] = []
    for index, config_path in enumerate(config_paths):
        if not config_path.is_file():
            raise FileNotFoundError(f"keeper config missing: {config_path}")
        identity = identities[index % len(identities)]
        credential_dir = base_path / ".masc" / "github-identities" / identity / "gh"
        plan.append(
            Assignment(
                keeper=config_path.stem,
                config_path=str(config_path),
                github_identity=identity,
                credential_dir=str(credential_dir),
                credential_dir_exists=credential_dir.is_dir(),
            )
        )
    return plan


def keeper_section_bounds(lines: list[str], path: Path) -> tuple[int, int]:
    start = None
    for idx, line in enumerate(lines):
        if line.strip().split("#", 1)[0].strip() == "[keeper]":
            start = idx
            break
    if start is None:
        raise ValueError(f"{path}: missing [keeper] section")
    end = len(lines)
    for idx in range(start + 1, len(lines)):
        if SECTION_RE.match(lines[idx]):
            end = idx
            break
    return start, end


def set_toml_string_field(
    lines: list[str], *, path: Path, section_start: int, section_end: int, key: str, value: str
) -> tuple[list[str], int]:
    pattern = re.compile(rf'^(\s*{re.escape(key)}\s*=\s*)".*?"(\s*(?:#.*)?)$')
    for idx in range(section_start + 1, section_end):
        match = pattern.match(lines[idx].rstrip("\n"))
        if match:
            newline = "\n" if lines[idx].endswith("\n") else ""
            lines[idx] = f'{match.group(1)}"{value}"{match.group(2)}{newline}'
            return lines, section_end
    insert = section_end
    lines.insert(insert, f'{key} = "{value}"\n')
    return lines, section_end + 1


def update_keeper_config(path: Path, identity: str) -> None:
    original = path.read_text(encoding="utf-8")
    lines = original.splitlines(keepends=True)
    start, end = keeper_section_bounds(lines, path)
    lines, end = set_toml_string_field(
        lines,
        path=path,
        section_start=start,
        section_end=end,
        key="github_identity",
        value=identity,
    )
    lines, _ = set_toml_string_field(
        lines,
        path=path,
        section_start=start,
        section_end=end,
        key="git_identity_mode",
        value="github_identity",
    )
    updated = "".join(lines)
    parsed = tomllib.loads(updated)
    keeper = parsed.get("keeper")
    if not isinstance(keeper, dict):
        raise ValueError(f"{path}: updated TOML has no [keeper] object")
    if keeper.get("github_identity") != identity:
        raise ValueError(f"{path}: github_identity update did not round-trip")
    if keeper.get("git_identity_mode") != "github_identity":
        raise ValueError(f"{path}: git_identity_mode update did not round-trip")
    path.write_text(updated, encoding="utf-8")


def default_backup_dir(base_path: Path) -> Path:
    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    return base_path / ".masc" / "backups" / f"keeper-identity-split-{stamp}"


def apply_plan(base_path: Path, plan: list[Assignment], *, backup_dir: str, allow_missing: bool) -> Path:
    missing = [item for item in plan if not item.credential_dir_exists]
    if missing and not allow_missing:
        names = ", ".join(sorted({item.github_identity for item in missing}))
        raise RuntimeError(
            "refusing --apply because identity GH config dirs are missing: "
            f"{names}. Provision bundles first or pass --allow-missing-bundles."
        )
    backup_root = Path(backup_dir).expanduser() if backup_dir else default_backup_dir(base_path)
    backup_root.mkdir(parents=True, exist_ok=False)
    for item in plan:
        path = Path(item.config_path)
        shutil.copy2(path, backup_root / path.name)
        update_keeper_config(path, item.github_identity)
    return backup_root


def main(argv: list[str]) -> int:
    args = parse_args(argv)
    base_path = Path(args.base_path).expanduser().resolve()
    identities = [validate_identity(identity) for identity in args.identity]
    if len(set(identities)) < 2:
        raise SystemExit("at least two unique --identity values are required")
    config_paths = keeper_config_paths(base_path, args.keeper_names)
    plan = build_plan(base_path, identities, config_paths)
    backup_dir = None
    if args.apply:
        backup_dir = str(
            apply_plan(
                base_path,
                plan,
                backup_dir=args.backup_dir,
                allow_missing=args.allow_missing_bundles,
            )
        )
    payload = {
        "ok": True,
        "applied": bool(args.apply),
        "base_path": str(base_path),
        "identity_count": len(set(identities)),
        "keeper_count": len(plan),
        "backup_dir": backup_dir,
        "assignments": [asdict(item) for item in plan],
    }
    print(json.dumps(payload, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main(sys.argv[1:]))
    except Exception as exc:
        print(f"error: {exc}", file=sys.stderr)
        raise SystemExit(1)
