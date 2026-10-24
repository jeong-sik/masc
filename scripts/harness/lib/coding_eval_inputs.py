#!/usr/bin/env python3
"""Bind coding-eval resume receipts to the inputs that produced them."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import stat
import subprocess
import sys
import tempfile


def digest_bytes(data):
    return hashlib.sha256(data).hexdigest()


def file_identity(path, label):
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    try:
        before = os.fstat(fd)
        if not stat.S_ISREG(before.st_mode):
            raise ValueError("experiment input is not a regular file: " + str(path))
        digest = hashlib.sha256()
        with os.fdopen(fd, "rb", closefd=False) as stream:
            for block in iter(lambda: stream.read(1024 * 1024), b""):
                digest.update(block)
        after = os.fstat(fd)
        if (before.st_size, before.st_mtime_ns, before.st_ctime_ns) != (
            after.st_size, after.st_mtime_ns, after.st_ctime_ns
        ):
            raise ValueError("experiment input changed while read: " + str(path))
        return {"path": label, "bytes": after.st_size, "sha256": digest.hexdigest()}
    finally:
        os.close(fd)


def tree_identity(root):
    result = []
    for directory, directories, files in os.walk(root, followlinks=False):
        for name in sorted(directories):
            if (Path(directory) / name).is_symlink():
                raise ValueError("experiment input directory is a symlink")
        for name in sorted(files):
            path = Path(directory) / name
            result.append(file_identity(path, str(path.relative_to(root))))
    return sorted(result, key=lambda row: row["path"])


def encode(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":")).encode()


def read_json(path):
    # Canonical re-encoding must not erase ambiguous source identities before
    # the report's strict decoder can inspect them. The hook sees every object,
    # including objects nested inside the experiment inputs or a receipt.
    def unique_object(pairs):
        value = {}
        for key, item in pairs:
            if key in value:
                raise ValueError("duplicate JSON object key " + repr(key) + " in " + str(path))
            value[key] = item
        return value

    return json.loads(path.read_text(), object_pairs_hook=unique_object)


def model_identity(args):
    return {"provider": args.provider, "model": args.model}


def run_identity(args):
    return {**model_identity(args), "case_id": args.case_id, "run_index": args.run_index,
            "experiment_digest": args.experiment_digest, "memory_mode": args.memory_mode}


def check_receipt(args):
    row = read_json(args.receipt)
    expected = {**run_identity(args), "run_id": args.run_id}
    if not isinstance(row, dict) or any(
        type(row.get(key)) is not type(value) or row[key] != value
        for key, value in expected.items()
    ):
        raise ValueError("run receipt identity differs from the requested run: " + str(args.receipt))


def experiment(args):
    scripts = [
        "scripts/harness_coding_eval.sh", "scripts/run-local.sh",
        "scripts/harness/lib/coding_eval_evidence.sh",
        "scripts/harness/lib/coding_eval_inputs.py",
        "scripts/harness/lib/coding_eval_sandbox.py",
        "scripts/harness/lib/server_bootstrap.sh",
        "scripts/harness/lib/mcp_call.sh", "scripts/harness/lib/test_framework.sh",
        "scripts/harness/prompts/coding_keeper.txt",
    ]
    inputs = {
        "source_head": subprocess.check_output(
            ["git", "-C", str(args.root), "rev-parse", "HEAD"], text=True
        ).strip(),
        "models": sorted(args.models.split(",")),
        "memory_mode": args.memory_mode,
        "execution_mode": args.execution_mode,
        "sandbox_profile": "docker",
        "grader_image_id": args.image,
        "corpus": tree_identity(args.cases),
        "source_config": tree_identity(args.root / "config"),
        "runtime_config": file_identity(args.runtime_config, "runtime.toml"),
        "scripts": [file_identity(args.root / path, path) for path in scripts],
        "binaries": [
            file_identity(args.binary, "masc"),
            file_identity(args.report_binary, "coding_eval_report_cli"),
        ],
        "acceptance_manifest": None,
    }
    if args.acceptance_manifest:
        inputs["acceptance_manifest"] = file_identity(args.acceptance_manifest, "acceptance.json")
    return {
        "schema": "masc.coding_eval.experiment.v1",
        "experiment_digest": digest_bytes(encode(inputs)),
        "inputs": inputs,
    }


def write_new(path, data):
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd, "wb") as stream:
        stream.write(data + b"\n")


def capture(args):
    current = experiment(args)
    if args.out.exists() or args.out.is_symlink():
        if args.out.is_symlink():
            raise ValueError("experiment manifest must not be a symlink")
        existing = read_json(args.out)
        if existing != current:
            raise ValueError("experiment inputs differ from --out; use a new output directory")
    elif args.check:
        raise ValueError("experiment manifest is missing")
    else:
        old_receipts = list((args.out.parent / "runs").glob("*/evidence.json"))
        old_index = args.out.parent / "runs.jsonl"
        if old_receipts or (old_index.exists() and old_index.stat().st_size):
            raise ValueError("existing run evidence has no bound experiment manifest")
        write_new(args.out, encode(current))
    print(current["experiment_digest"])


def collect(args):
    manifest = read_json(args.experiment)
    expected = manifest["experiment_digest"]
    if expected != digest_bytes(encode(manifest["inputs"])):
        raise ValueError("experiment manifest digest mismatch")
    rows = []
    seen = set()
    for path in sorted(args.runs.glob("*/evidence.json")):
        row = read_json(path)
        if row.get("experiment_digest") != expected:
            raise ValueError("run evidence belongs to another experiment: " + str(path))
        if row.get("memory_mode") != manifest["inputs"]["memory_mode"]:
            raise ValueError("run memory mode differs from its experiment: " + str(path))
        if row.get("run_id") in seen:
            raise ValueError("duplicate run identity: " + str(path))
        seen.add(row.get("run_id"))
        rows.append(encode(row))
    fd, name = tempfile.mkstemp(prefix=".coding-eval-rows-", dir=args.out.parent)
    temporary = Path(name)
    try:
        with os.fdopen(fd, "wb") as stream:
            stream.write(b"\n".join(rows) + b"\n")
        os.replace(temporary, args.out)
    finally:
        temporary.unlink(missing_ok=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    capture_parser = commands.add_parser("capture")
    capture_parser.add_argument("--root", required=True, type=Path)
    capture_parser.add_argument("--cases", required=True, type=Path)
    capture_parser.add_argument("--runtime-config", required=True, type=Path)
    capture_parser.add_argument("--binary", required=True, type=Path)
    capture_parser.add_argument("--report-binary", required=True, type=Path)
    capture_parser.add_argument("--models", required=True)
    capture_parser.add_argument("--memory-mode", required=True)
    capture_parser.add_argument("--execution-mode", required=True)
    capture_parser.add_argument("--image", required=True)
    capture_parser.add_argument("--acceptance-manifest", type=Path)
    capture_parser.add_argument("--out", required=True, type=Path)
    capture_parser.add_argument("--check", action="store_true")
    collect_parser = commands.add_parser("collect")
    collect_parser.add_argument("--experiment", required=True, type=Path)
    collect_parser.add_argument("--runs", required=True, type=Path)
    collect_parser.add_argument("--out", required=True, type=Path)
    for command in ("model-alias", "run-id", "check-receipt"):
        identity_parser = commands.add_parser(command)
        identity_parser.add_argument("--provider", required=True)
        identity_parser.add_argument("--model", required=True)
        if command != "model-alias":
            identity_parser.add_argument("--case-id", required=True)
            identity_parser.add_argument("--run-index", required=True, type=int)
            identity_parser.add_argument("--experiment-digest", required=True)
            identity_parser.add_argument("--memory-mode", required=True)
        if command == "check-receipt":
            identity_parser.add_argument("--receipt", required=True, type=Path)
            identity_parser.add_argument("--run-id", required=True)
    args = parser.parse_args()
    try:
        if args.command == "capture":
            capture(args)
        elif args.command == "collect":
            collect(args)
        elif args.command == "model-alias":
            print("model-" + digest_bytes(encode(model_identity(args))))
        elif args.command == "run-id":
            print("run-" + digest_bytes(encode(run_identity(args))))
        else:
            check_receipt(args)
    except (OSError, ValueError, KeyError, subprocess.CalledProcessError) as error:
        print("coding-eval experiment refused: " + str(error), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
