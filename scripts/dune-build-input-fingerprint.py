#!/usr/bin/env python3
"""Hash the exact byte inputs of one Dune target rule."""

from __future__ import annotations

import argparse
import hashlib
import io
import json
from pathlib import Path
import subprocess
import sys
from typing import Any


SCHEMA = "masc.dune-build-input.v1"


class FingerprintError(RuntimeError):
    pass


def canonical_json(value: Any) -> bytes:
    return json.dumps(
        value, ensure_ascii=False, sort_keys=True, separators=(",", ":")
    ).encode("utf-8")


def resolve_dependency(repo_root: Path, dependency: Any) -> tuple[str, str, Path]:
    if not isinstance(dependency, dict) or set(dependency) != {"File"}:
        raise FingerprintError(f"unsupported Dune dependency: {dependency!r}")
    identity = dependency["File"]
    if (
        not isinstance(identity, list)
        or len(identity) != 2
        or not all(isinstance(item, str) for item in identity)
    ):
        raise FingerprintError(f"malformed Dune file dependency: {identity!r}")
    kind, value = identity
    if kind == "External":
        path = Path(value)
        if not path.is_absolute():
            raise FingerprintError(f"external dependency is not absolute: {value}")
    elif kind in {"In_build_dir", "In_source_tree"}:
        path = repo_root / value
    else:
        raise FingerprintError(f"unsupported Dune file kind: {kind}")
    if not path.is_file():
        raise FingerprintError(f"Dune dependency is not a readable file: {path}")
    return kind, value, path


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    try:
        with path.open("rb") as handle:
            for block in iter(lambda: handle.read(io.DEFAULT_BUFFER_SIZE), b""):
                digest.update(block)
    except OSError as error:
        raise FingerprintError(
            f"cannot hash Dune dependency {path}: {error}"
        ) from error
    return digest.hexdigest()


def fingerprint_rule(repo_root: Path, target: str, payload: Any) -> str:
    if not isinstance(payload, list) or len(payload) != 1:
        raise FingerprintError(
            f"expected exactly one Dune rule for {target}, found "
            f"{len(payload) if isinstance(payload, list) else 'non-list'}"
        )
    rule = payload[0]
    if not isinstance(rule, dict):
        raise FingerprintError("Dune rule is not an object")
    dependencies = rule.get("deps")
    targets = rule.get("targets")
    action = rule.get("action")
    if not isinstance(dependencies, list):
        raise FingerprintError("Dune rule deps are not a list")
    if not isinstance(targets, dict) or not isinstance(action, list):
        raise FingerprintError("Dune rule is missing typed targets or action")

    resolved = [resolve_dependency(repo_root, item) for item in dependencies]
    resolved.sort(key=lambda item: (item[0], item[1]))
    manifest = {
        "schema": SCHEMA,
        "target": target,
        "targets": targets,
        "action": action,
        "dependencies": [
            {"kind": kind, "path": value, "sha256": sha256_file(path)}
            for kind, value, path in resolved
        ],
    }
    return hashlib.sha256(canonical_json(manifest)).hexdigest()


def describe_rule(repo_root: Path, target: str) -> Any:
    command = [
        "dune",
        "describe",
        "rules",
        "--root",
        str(repo_root),
        "--format=json",
        target,
    ]
    try:
        completed = subprocess.run(
            command,
            check=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
    except (OSError, subprocess.CalledProcessError) as error:
        detail = getattr(error, "stderr", None) or str(error)
        raise FingerprintError(
            f"cannot query Dune rule for {target}: {detail}"
        ) from error
    try:
        return json.loads(completed.stdout)
    except json.JSONDecodeError as error:
        raise FingerprintError(f"Dune returned malformed JSON: {error}") from error


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--repo-root", required=True, type=Path)
    parser.add_argument("--target", required=True)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    try:
        repo_root = args.repo_root.resolve(strict=True)
        print(
            fingerprint_rule(
                repo_root, args.target, describe_rule(repo_root, args.target)
            )
        )
    except (OSError, FingerprintError) as error:
        print(str(error), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
