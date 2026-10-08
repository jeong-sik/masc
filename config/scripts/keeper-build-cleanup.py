#!/usr/bin/env python3
"""Shared guest-only Dune cleanup payload, embedded in the MASC binary."""

import argparse
import fcntl
import json
import os
from pathlib import Path
import shutil
import subprocess
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
                try:
                    target = os.readlink(descriptor)
                except FileNotFoundError:
                    # This descriptor closed; later ones may still own a checkout.
                    continue
                if target.startswith("/"):
                    paths.append(Path(target))
        except FileNotFoundError:
            # The process exited while its ownership was being inspected.
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


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--guest-root", type=Path, required=True)
    parser.add_argument("--idle-hours", type=float, required=True)
    parser.add_argument("--apply", action="store_true")
    args = parser.parse_args()
    print(json.dumps(guest_sweep(args.guest_root, args.idle_hours, args.apply)))
