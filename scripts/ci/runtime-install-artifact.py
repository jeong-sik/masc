#!/usr/bin/env python3
"""Package or verify the exact inputs of install-local-build.sh --skip-build.

Verification binds downloaded bytes to independently read source/workflow/run
identities. It does not execute the binaries, install, or establish relocatability.
"""
import argparse
import hashlib
import json
from pathlib import Path, PurePosixPath
import shutil
import stat
import subprocess


SOURCES = ("scripts/install-local-build.sh", "scripts/check-runtime-deployment-preflight.sh",
           "scripts/ci/runtime-install-artifact.py")
RECORDS = ("build-targets.txt", "dependencies.txt")
FLAGS = ("behavior_executed", "installed", "release_verified", "relocatable_runtime_verified")


def require(condition, detail):
    if not condition:
        raise ValueError(detail)


def unique(pairs):
    result = {}
    for key, value in pairs:
        require(key not in result, "duplicate receipt field: " + key)
        result[key] = value
    return result


def commit(value):
    require(len(value) == 40 and set(value) <= set("0123456789abcdef"),
            "full lowercase source/workflow commit required")
    return value


def targets(repo):
    raw = subprocess.check_output(["bash", str(repo / SOURCES[0]), "--print-build-targets"],
                                  text=True).splitlines()
    result = [name.removeprefix("./") for name in raw]
    require(result and len(result) == len(set(result)), "empty or duplicate installer target")
    for name in result:
        path = PurePosixPath(name)
        require(path.parts == ("bin", path.name) and path.name.endswith(".exe"),
                "installer target is not one bin executable: " + name)
    return result


def describe(path):
    mode = path.lstat().st_mode
    require(stat.S_ISREG(mode), "payload must be a regular file: " + str(path))
    data = path.read_bytes()
    require(data, "payload is empty: " + str(path))
    return dict(bytes=len(data), sha256=hashlib.sha256(data).hexdigest(),
                executable=bool(mode & 0o111))


def pack(args):
    repo, directory = args.repo.resolve(), args.directory
    source = subprocess.check_output(["git", "-C", str(repo), "rev-parse", "HEAD"], text=True).strip()
    require(source == commit(args.source), "candidate source identity changed")
    subprocess.run(["git", "-C", str(repo), "diff", "--exit-code", "HEAD", "--"], check=True)
    expected = targets(repo)
    recorded = [name.removeprefix("./") for name in
                (args.records / "build-targets.txt").read_text().splitlines()]
    require(recorded == expected, "built targets differ from the candidate installer contract")
    directory.mkdir(parents=True, exist_ok=False)
    files = {}
    for name, source_path in ([(name, repo / "_build/default" / name) for name in expected]
                              + [(name, repo / name) for name in SOURCES]
                              + [(name, args.records / name) for name in RECORDS]):
        info = describe(source_path)
        if name in expected or name in SOURCES[:2]:
            require(info["executable"], "installer input is not executable: " + name)
        destination = directory / name
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source_path, destination)
        files[name] = describe(destination)
    receipt = dict(schema_version=1, target="installable-runtime-macos-arm64", platform="macos-arm64",
                   source_commit=source, source_tree=subprocess.check_output(
                       ["git", "-C", str(repo), "rev-parse", "HEAD^{tree}"], text=True).strip(),
                   workflow_head=commit(args.workflow_head), run_id=args.run_id, run_attempt=args.attempt,
                   build_targets=expected, build_directory="bin", files=files,
                   **{key: False for key in FLAGS})
    (directory / "build-receipt.json").write_text(json.dumps(receipt, indent=2) + "\n")
    return verify(args)


def verify(args):
    directory = args.directory
    require(stat.S_ISDIR(directory.lstat().st_mode), "artifact root must be a directory")
    receipt_path = directory / "build-receipt.json"
    require(stat.S_ISREG(receipt_path.lstat().st_mode), "receipt must be regular")
    receipt = json.loads(receipt_path.read_text(), object_pairs_hook=unique)
    require(receipt["schema_version"] == 1 and receipt["target"] == "installable-runtime-macos-arm64"
            and receipt["platform"] == "macos-arm64" and receipt["build_directory"] == "bin",
            "wrong installable runtime artifact scope")
    for key, expected in (("source_commit", args.source), ("workflow_head", args.workflow_head)):
        require(receipt[key] == commit(expected), "artifact identity mismatch: " + key)
    commit(receipt["source_tree"])
    require(receipt["run_id"] == args.run_id and receipt["run_attempt"] == args.attempt,
            "artifact differs from the independently read run/attempt")
    require(all(receipt[key] is False for key in FLAGS), "build receipt claims additional execution")
    files, actual = receipt["files"], set()
    require(isinstance(files, dict), "invalid file manifest")
    for path in directory.rglob("*"):
        mode = path.lstat().st_mode
        require(stat.S_ISDIR(mode) or stat.S_ISREG(mode), "nonregular artifact entry")
        if stat.S_ISREG(mode) and path != receipt_path:
            actual.add(path.relative_to(directory).as_posix())
    require(actual == set(files), "artifact membership differs from the manifest")
    for name, expected in files.items():
        path = PurePosixPath(name)
        require(not path.is_absolute() and name == path.as_posix()
                and all(part not in (".", "..") for part in path.parts), "unsafe artifact path")
        require(describe(directory / name) == expected, "artifact bytes or mode changed: " + name)
    expected = targets(directory)
    require(receipt["build_targets"] == expected, "manifest differs from the installer contract")
    require(set(files) == set(expected) | set(SOURCES) | set(RECORDS), "installer input missing")
    for name in expected + list(SOURCES[:2]):
        require(files[name]["executable"], "installer input lacks executable permission: " + name)
    return dict(source_commit=args.source, workflow_head=args.workflow_head, run_id=args.run_id,
                run_attempt=args.attempt, verified_files=len(files), build_directory="bin",
                receipt_sha256=hashlib.sha256(receipt_path.read_bytes()).hexdigest(),
                github_completion_independently_required=True, candidate_executed=False,
                installed=False, relocatable_runtime_verified=False)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)
    for name in ("pack", "verify"):
        command = subparsers.add_parser(name)
        command.add_argument("--directory", type=Path, required=True)
        command.add_argument("--source", required=True)
        command.add_argument("--workflow-head", required=True)
        command.add_argument("--run-id", required=True)
        command.add_argument("--attempt", required=True)
        if name == "pack":
            command.add_argument("--repo", type=Path, required=True)
            command.add_argument("--records", type=Path, required=True)
    args = parser.parse_args()
    try:
        print(json.dumps((pack if args.command == "pack" else verify)(args), indent=2))
    except (OSError, ValueError, KeyError, TypeError, subprocess.SubprocessError) as error:
        parser.exit(1, str(error) + "\n")


if __name__ == "__main__":
    main()
