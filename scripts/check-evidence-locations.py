#!/usr/bin/env python3
"""Check explicit evidence-location sidecars without rewriting captured records.

Paths are relative to --repo-root (default: this script's repository). This is a
manual, scoped check, not a repository scan or a CI admission gate. Editable
source/document entries are checked for location only; their recorded digests
describe the capture revision, not their current bytes.
"""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess
import sys
from urllib.parse import quote
import xml.etree.ElementTree as ET


CONTENT_KINDS = {
    "retained_capture",
    "editable_reproduction_source",
    "editable_source",
    "editable_document",
}


def unique_object(pairs: list[tuple[str, object]]) -> dict[str, object]:
    result: dict[str, object] = {}
    for key, value in pairs:
        if key in result:
            raise ValueError(f"duplicate JSON field: {key}")
        result[key] = value
    return result


def read_json(path: Path) -> object:
    return json.loads(path.read_text(), object_pairs_hook=unique_object)


def fields(value: object, expected: set[str], label: str) -> dict[str, object]:
    if not isinstance(value, dict) or set(value) != expected:
        raise ValueError(f"{label}: expected exactly {sorted(expected)}")
    return value


def string(value: object, label: str) -> str:
    if not isinstance(value, str) or not value.strip():
        raise ValueError(f"{label}: expected a nonempty string")
    return value


def digest(value: object, label: str) -> str:
    text = string(value, label)
    if re.fullmatch(r"[0-9a-f]{64}", text) is None:
        raise ValueError(f"{label}: expected a lowercase SHA-256")
    return text


def rooted_path(root: Path, value: object, label: str) -> Path:
    text = string(value, label)
    path = Path(text)
    if path.is_absolute() or ".." in path.parts or path.as_posix() != text:
        raise ValueError(f"{label}: expected a repository-relative path")
    resolved = (root / path).resolve()
    if not resolved.is_relative_to(root):
        raise ValueError(f"{label}: path escapes the repository")
    return resolved


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def check(index_path: Path, root: Path) -> dict[str, int]:
    project_repo = string(
        ET.parse(root / "docs/constitution.xml").findtext("project/env/repo"),
        "constitution project/env/repo",
    ).strip().rstrip("/")
    data = fields(read_json(index_path), {
        "schema", "purpose", "paths_relative_to", "recorded_manifest",
        "files", "historical_records",
    }, "index")
    if data["schema"] != "masc.evidence.current-locations.v1":
        raise ValueError("index: unknown schema")
    if data["paths_relative_to"] != "repository_root":
        raise ValueError("index: unknown path authority")
    string(data["purpose"], "purpose")
    reference = fields(data["recorded_manifest"], {"path", "sha256"}, "recorded_manifest")
    reference_path = Path(string(reference["path"], "recorded_manifest.path"))
    if reference_path.is_absolute():
        raise ValueError("recorded_manifest.path: expected a relative path")
    recorded_path = (index_path.parent / reference_path).resolve()
    if not recorded_path.is_relative_to(root):
        raise ValueError("recorded_manifest.path: path escapes the repository")
    if sha256(recorded_path) != digest(reference["sha256"], "recorded_manifest.sha256"):
        raise ValueError("recorded_manifest: original bytes do not match the recorded digest")
    recorded = read_json(recorded_path)
    if not isinstance(recorded, dict) or not recorded:
        raise ValueError("recorded_manifest: expected a nonempty path/digest object")
    for path, value in recorded.items():
        rooted_path(root, path, "recorded path")
        digest(value, "recorded digest")

    seen: set[str] = set()
    counts = {"retained_capture": 0, "editable_lookup": 0, "historical_blob": 0}

    def recorded_entry(value: dict[str, object]) -> tuple[str, str]:
        path = string(value["recorded_path"], "recorded_path")
        expected = digest(value["recorded_sha256"], "recorded_sha256")
        if path in seen:
            raise ValueError(f"recorded entry occurs more than once: {path}")
        if path not in recorded or recorded[path] != expected:
            raise ValueError(f"entry does not match the original manifest: {path}")
        seen.add(path)
        return path, expected

    files = data["files"]
    if not isinstance(files, dict):
        raise ValueError("files: expected a path-keyed object")
    for current_path, value in files.items():
        entry = fields(value, {"recorded_path", "recorded_sha256", "content_kind"}, "file entry")
        _, expected = recorded_entry(entry)
        kind = string(entry["content_kind"], "content_kind")
        if kind not in CONTENT_KINDS:
            raise ValueError(f"unknown content_kind: {kind}")
        target = rooted_path(root, current_path, "current path")
        if not target.is_file():
            raise ValueError(f"current checkout file unavailable: {current_path}")
        if kind == "retained_capture":
            if sha256(target) != expected:
                raise ValueError(f"retained capture digest mismatch: {current_path}")
            counts["retained_capture"] += 1
        else:
            counts["editable_lookup"] += 1

    historical = data["historical_records"]
    if not isinstance(historical, list):
        raise ValueError("historical_records: expected a list")
    for value in historical:
        entry = fields(value, {"recorded_path", "recorded_sha256", "location"}, "historical entry")
        _, expected = recorded_entry(entry)
        location = fields(entry["location"], {"kind", "commit", "path", "url"}, "historical location")
        if location["kind"] != "git_blob":
            raise ValueError("historical location: unknown kind")
        commit = string(location["commit"], "historical commit")
        if re.fullmatch(r"[0-9a-f]{40}", commit) is None:
            raise ValueError("historical commit: expected a full lowercase Git commit")
        path = string(location["path"], "historical path")
        rooted_path(root, path, "historical path")
        url = string(location["url"], "historical URL")
        if url != f"{project_repo}/blob/{commit}/{quote(path, safe='/')}":
            raise ValueError("historical URL does not identify the declared project repository/commit/path")
        result = subprocess.run(
            ["git", "-C", str(root), "cat-file", "blob", f"{commit}:{path}"],
            capture_output=True, check=False,
        )
        if result.returncode != 0:
            raise ValueError(f"historical Git blob unavailable: {commit}:{path}")
        if hashlib.sha256(result.stdout).hexdigest() != expected:
            raise ValueError(f"historical Git blob digest mismatch: {commit}:{path}")
        counts["historical_blob"] += 1
    if seen != set(recorded):
        raise ValueError(f"recorded entries missing from location index: {sorted(set(recorded) - seen)}")
    return counts


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("indexes", nargs="+", type=Path, help="explicit current-locations.json paths")
    parser.add_argument("--repo-root", type=Path, default=Path(__file__).resolve().parents[1])
    args = parser.parse_args()
    root = args.repo_root.resolve()
    failed = False
    for argument in args.indexes:
        path = argument if argument.is_absolute() else root / argument
        try:
            path = path.resolve()
            if not path.is_relative_to(root):
                raise ValueError("index path escapes the repository")
            counts = check(path, root)
            print(f"PASS {argument}: {sum(counts.values())} entries; {counts}")
        except (OSError, UnicodeError, ValueError, ET.ParseError) as error:
            print(f"FAIL {argument}: {error}", file=sys.stderr)
            failed = True
    return 1 if failed else 0


if __name__ == "__main__":
    raise SystemExit(main())
