#!/usr/bin/env python3
"""Clean idle Dune output in this workspace's running Apple Keeper VMs.

Dry-run unless --apply is explicit. --interval-seconds repeats the sweep until
interrupted; scripts/keeper-vm-cleaner.py manages the background process.
"""

import argparse
import concurrent.futures
import fcntl
import hashlib
import json
import math
import os
from pathlib import Path
import shutil
import subprocess
import sys
import time
from typing import Any


def run(argv: list[str], **kwargs: Any) -> subprocess.CompletedProcess[str]:
    return subprocess.run(argv, text=True, capture_output=True, check=True, **kwargs)


def tree_stats(root: Path) -> tuple[int, float]:
    """No symlink traversal. Count allocated blocks and newest modification."""
    size = 0
    newest = root.stat().st_mtime

    def fail(error: OSError) -> None:
        raise error

    for directory, dirs, files in os.walk(root, followlinks=False, onerror=fail):
        for name in dirs + files:
            entry = (Path(directory) / name).lstat()
            size += entry.st_blocks * 512
            newest = max(newest, entry.st_mtime)
    return size, newest


def process_paths() -> list[Path]:
    """Fail closed on unreadable live process ownership, excluding ourselves."""
    paths: list[Path] = []
    for process in Path("/proc").iterdir():
        if not process.name.isdecimal() or int(process.name) == os.getpid():
            continue
        try:
            # Zombies have no cwd/exe. Other live processes must be inspectable.
            state = (process / "stat").read_text().rsplit(")", 1)[1].split()[0]
            if state == "Z":
                continue
            for name in ("cwd", "exe"):
                paths.append(Path(os.readlink(process / name)))
            for descriptor in (process / "fd").iterdir():
                target = os.readlink(descriptor)
                if target.startswith("/"):
                    paths.append(Path(target))
        except FileNotFoundError:
            # A process or descriptor vanished while enumerating it.
            continue
    return paths


def guest_sweep(root: Path, idle_hours: float, apply: bool) -> dict[str, Any]:
    if not root.is_dir() or root.is_symlink():
        raise ValueError(f"not a real Keeper work directory: {root}")
    root = root.resolve(strict=True)
    dune = shutil.which("dune")
    report: dict[str, Any] = {"root": str(root), "apply": apply, "entries": []}
    before = shutil.disk_usage(root).free
    if dune is None:
        report["skip"] = "dune unavailable"
        return report
    cutoff = time.time() - idle_hours * 3600

    def fail(error: OSError) -> None:
        raise error

    candidates: list[Path] = []
    for directory, dirs, _ in os.walk(root, followlinks=False, onerror=fail):
        if "_build" in dirs:
            candidates.append(Path(directory) / "_build")
        dirs[:] = [
            name for name in dirs if name not in ("_build", ".git", "node_modules")
        ]
    for build in candidates:
        repo = build.parent
        entry: dict[str, Any] = {"build": str(build)}
        report["entries"].append(entry)
        if build.is_symlink() or not (repo / "dune-project").is_file():
            entry["skip"] = "not a default Dune build directory"
            continue
        if (repo / ".masc-keep-build").exists():
            entry["skip"] = "operator retention marker"
            continue
        # Same lock key and UID as scripts/dune-local.sh, without waiting.
        key = run(["cksum"], input=str(repo)).stdout.split()[0]
        lock = (
            Path(os.environ.get("TMPDIR", "/tmp"))
            / f"masc-dune-{os.getuid()}-{key}.lock"
        )
        lock = Path(os.environ.get("DUNE_LOCAL_LOCK", str(lock)))
        with lock.open("a") as lease:
            try:
                fcntl.flock(lease, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                entry["skip"] = "wrapper build lock held"
                continue
            if any(path.is_relative_to(repo) for path in process_paths()):
                entry["skip"] = "live process uses checkout"
                continue
            size, newest = tree_stats(build)
            entry["allocated_bytes"] = size
            if newest > cutoff:
                entry["skip"] = "recent build output"
                continue
            if not apply:
                entry["action"] = "would clean"
                continue
            # Clean individual targets: whole-project clean can unlink promoted
            # source files. Keep .lock so its inode continues excluding builds.
            targets = [
                f"_build/{path.name}"
                for path in build.iterdir()
                if path.name != ".lock"
            ]
            if not targets:
                entry["skip"] = "empty build output"
                continue
            # Dune 3.24's targeted clean takes its native, nonblocking flock.
            # Relative --build-dir overrides an inherited DUNE_BUILD_DIR.
            result = subprocess.run(
                [
                    dune,
                    "clean",
                    "--root",
                    str(repo),
                    "--build-dir",
                    "_build",
                    "--",
                    *targets,
                ],
                cwd=repo,
                text=True,
                capture_output=True,
                check=False,
            )
            entry["action"] = "cleaned" if result.returncode == 0 else "clean failed"
            if result.returncode:
                entry["error"] = result.stderr[-2000:]
    report["guest_free_bytes_delta"] = shutil.disk_usage(root).free - before
    return report


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
    source = Path(__file__).read_text()

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
