#!/usr/bin/env python3
"""Verify downloaded probe bytes against independently read GitHub run identity.

Does not fetch GitHub, execute the candidate or install dependencies.
"""
import argparse
import hashlib
import json
from pathlib import Path, PurePosixPath
import stat


def require(condition, detail):
    if not condition:
        raise ValueError(detail)


def unique(pairs):
    result = {}
    for key, value in pairs:
        require(key not in result, "duplicate receipt field")
        result[key] = value
    return result


def verify(args):
    directory = args.directory
    require(stat.S_ISDIR(directory.lstat().st_mode), "artifact root must be a directory")
    receipt_path = directory / "build-receipt.json"
    require(stat.S_ISREG(receipt_path.lstat().st_mode), "receipt must be a regular file")
    receipt = json.loads(receipt_path.read_text(), object_pairs_hook=unique)
    require(receipt["schema_version"] == 1 and receipt["platform"] == "macos-arm64" and
            receipt["target"] == "test/keeper_preparation_trial_driver.exe", "wrong artifact scope")
    for key, expected in (("source_commit", args.source), ("workflow_head", args.workflow_head)):
        require(len(expected) == 40 and set(expected) <= set("0123456789abcdef"), "full commit identity required")
        require(receipt[key] == expected, "artifact identity mismatch: " + key)
    require(receipt["run_id"] == args.run_id and receipt["run_attempt"] == args.attempt,
            "artifact run/attempt differs from the independently read completed run")
    require(len(receipt["source_tree"]) == 40 and set(receipt["source_tree"]) <= set("0123456789abcdef"),
            "source tree identity is absent")
    for key in ("provider_execution_requested", "behavior_executed", "installed",
                "release_verified", "relocatable_runtime_verified"):
        require(receipt[key] is False, "build artifact unexpectedly claims additional execution")
    files = receipt["files"]
    require(isinstance(files, dict) and {
        "keeper_preparation_trial_driver.exe", "preparation_trial.py", "PREPARATION-HARNESS.md",
        "dependencies.txt", "prompts/keeper.md"} <= set(files), "required payload missing")
    actual = set()
    for path in directory.rglob("*"):
        mode = path.lstat().st_mode
        require(stat.S_ISREG(mode) or stat.S_ISDIR(mode), "nonregular artifact entry")
        if stat.S_ISREG(mode) and path != receipt_path:
            actual.add(path.relative_to(directory).as_posix())
    require(actual == set(files), "downloaded payload membership differs from build receipt")
    for name, expected in files.items():
        relative = PurePosixPath(name)
        require(not relative.is_absolute() and name == relative.as_posix() and
                all(part not in (".", "..") for part in relative.parts), "unsafe payload path")
        payload = directory.joinpath(*relative.parts)
        require(stat.S_ISREG(payload.lstat().st_mode), "payload is not regular")
        require(type(expected["bytes"]) is int and payload.stat().st_size == expected["bytes"],
                "payload size mismatch: " + name)
        with payload.open("rb") as source:
            digest = hashlib.file_digest(source, "sha256").hexdigest()
        require(digest == expected["sha256"], "payload digest mismatch: " + name)
    return dict(scope="downloaded exact-source preparation build payload", source_commit=args.source,
                workflow_head=args.workflow_head, run_id=args.run_id, run_attempt=args.attempt,
                verified_files=len(files), binary_sha256=files["keeper_preparation_trial_driver.exe"]["sha256"],
                receipt_sha256=hashlib.sha256(receipt_path.read_bytes()).hexdigest(),
                github_completion_independently_required=True, candidate_executed=False,
                model_trial_verified=False, installed=False)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--directory", type=Path, required=True)
    parser.add_argument("--source", required=True)
    parser.add_argument("--workflow-head", required=True)
    parser.add_argument("--run-id", required=True)
    parser.add_argument("--attempt", required=True)
    args = parser.parse_args()
    try:
        print(json.dumps(verify(args), indent=2))
    except (OSError, ValueError, KeyError, TypeError) as error:
        parser.exit(1, str(error) + "\n")


if __name__ == "__main__":
    main()
