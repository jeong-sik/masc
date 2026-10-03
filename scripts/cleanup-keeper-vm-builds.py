#!/usr/bin/env python3
"""Clean idle Dune output in this workspace's running Apple Keeper VMs.

Dry-run unless --apply is explicit. --interval-seconds repeats the sweep until
interrupted; scripts/keeper-vm-cleaner.py manages the background process.
"""

import argparse
import concurrent.futures
import importlib.util
import hashlib
import json
import math
import os
from pathlib import Path
import subprocess
import sys
import time
from typing import Any


GUEST_SOURCE = (
    Path(__file__).resolve().parents[1] / "config/scripts/keeper-build-cleanup.py"
)
SPEC = importlib.util.spec_from_file_location("keeper_build_cleanup", GUEST_SOURCE)
assert SPEC is not None and SPEC.loader is not None
GUEST = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(GUEST)
run = GUEST.run
guest_sweep = GUEST.guest_sweep


def sweep(base_path: Path, idle_hours: float, apply: bool) -> list[dict[str, Any]]:
    # This matches keeper_sandbox_runtime_setup.ml's normalized absolute-path hash.
    workspace_hash = hashlib.md5(str(base_path).encode()).hexdigest()
    inventory = json.loads(run(["container", "list", "--format", "json"]).stdout)
    selected: list[tuple[str, str]] = []
    for item in inventory:
        labels = item["configuration"]["labels"]
        if (
            labels.get("masc.mcp.kind") == "keeper-vm"
            and labels.get("masc.mcp.component") == "keeper-sandbox"
            and labels.get("masc.mcp.microvm_backend") == "apple_container"
            and labels.get("masc.mcp.base_path_hash") == workspace_hash
            and item["status"]["state"] == "running"
        ):
            keeper = labels["masc.mcp.keeper"]
            if not keeper or Path(keeper).name != keeper or keeper in (".", ".."):
                raise ValueError(f"invalid Keeper label: {keeper!r}")
            selected.append((item["configuration"]["id"], keeper))
    source = GUEST_SOURCE.read_text()

    def clean(target: tuple[str, str]) -> dict[str, Any]:
        container_id, keeper = target
        argv = [
            "container",
            "exec",
            "-i",
            container_id,
            "python3",
            "-",
            "--guest-root",
            f"/masc-work/{keeper}",
            "--idle-hours",
            str(idle_hours),
        ]
        if apply:
            argv.append("--apply")
        try:
            return {
                "container": container_id,
                **json.loads(run(argv, input=source).stdout),
            }
        except subprocess.CalledProcessError as error:
            return {"container": container_id, "error": error.stderr[-2000:]}

    # Two scans at a time keep filesystem traversal from swamping live Keeper I/O.
    with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
        return list(pool.map(clean, selected))


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--base-path", type=Path)
    parser.add_argument("--guest-root", type=Path, help=argparse.SUPPRESS)
    parser.add_argument("--idle-hours", type=float, default=24)
    parser.add_argument("--apply", action="store_true")
    parser.add_argument("--interval-seconds", type=float, default=0)
    args = parser.parse_args()
    if (
        not math.isfinite(args.idle_hours)
        or not math.isfinite(args.interval_seconds)
        or args.idle_hours < 0
        or args.interval_seconds < 0
    ):
        parser.error("idle hours and interval must be nonnegative")
    if args.guest_root:
        print(json.dumps(guest_sweep(args.guest_root, args.idle_hours, args.apply)))
        return 0
    if args.base_path is None:
        parser.error("--base-path is required")
    # Preserve path identity used by runtime labels; do not resolve symlink aliases.
    base = Path(os.path.abspath(args.base_path))
    while True:
        results: list[dict[str, Any]] = []
        try:
            results = sweep(base, args.idle_hours, args.apply)
            print(json.dumps({"time": time.time(), "vms": results}), flush=True)
        except (OSError, ValueError, KeyError, subprocess.CalledProcessError) as error:
            print(json.dumps({"time": time.time(), "error": str(error)}), flush=True)
            if not args.interval_seconds:
                return 1
        if not args.interval_seconds:
            return int(
                any(
                    "error" in result
                    or any("error" in entry for entry in result.get("entries", []))
                    for result in results
                )
            )
        time.sleep(args.interval_seconds)


if __name__ == "__main__":
    sys.exit(main())
