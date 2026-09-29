#!/usr/bin/env python3
"""Run two historical vision-artifact implementations with one checked-in harness."""
from __future__ import annotations

import argparse
import base64
import hashlib
import json
import os
from pathlib import Path
import shutil
import struct
import subprocess
import sys
import time
import zlib

BEFORE = "13cd318566ff2cfea423ca1a08dc92bc1522b2aa"
AFTER = "6ad482b39bb2cab3e0305086b5ecd65c7dff854a"
STANZA = """\n(executable
 (name vision_artifact_measure)
 (modules vision_artifact_measure)
 (libraries masc_test_deps))
"""
PNG = base64.b64decode(
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGP4z8AAAAMBAQDJ/pLvAAAAAElFTkSuQmCC"
)


def command(args: list[str], *, cwd: Path, env: dict[str, str] | None = None) -> str:
    done = subprocess.run(args, cwd=cwd, env=env, text=True, capture_output=True)
    if done.returncode:
        raise RuntimeError(
            f"{args!r} failed ({done.returncode})\n{done.stdout}\n{done.stderr}"
        )
    return done.stdout.strip()


def chunk(kind: bytes, payload: bytes) -> bytes:
    return struct.pack(">I", len(payload)) + kind + payload + struct.pack(
        ">I", zlib.crc32(kind + payload) & 0xFFFFFFFF
    )


def prepare_fixtures(dest: Path) -> str:
    dest.mkdir(parents=True)
    iend = PNG[-12:]
    if iend[4:8] != b"IEND":
        raise RuntimeError("seed PNG has no IEND chunk")
    inventory = hashlib.sha256()
    for index in range(541):
        # A complete PNG with a unique, deterministic ancillary text chunk.
        payload = b"seed\x00" + f"{index:04d}".encode() + b"x" * 42000
        data = PNG[:-12] + chunk(b"tEXt", payload) + iend
        name = f"{index:04d}.png"
        (dest / name).write_bytes(data)
        inventory.update(name.encode() + b"\0" + hashlib.sha256(data).digest())
    return inventory.hexdigest()


def prepare_source(repo: Path, root: Path, label: str, sha: str) -> tuple[Path, Path]:
    path = root / label
    command(["git", "worktree", "add", "--detach", str(path), sha], cwd=repo)
    got = command(["git", "rev-parse", "HEAD"], cwd=path)
    if got != sha:
        raise RuntimeError(f"source identity mismatch: {got} != {sha}")
    harness = repo / "test/vision_artifact_measure.ml"
    shutil.copy2(harness, path / "test/vision_artifact_measure.ml")
    dune = path / "test/dune"
    body = dune.read_text()
    if "vision_artifact_measure" in body:
        raise RuntimeError("historical source already contains the harness target")
    dune.write_text(body + STANZA)
    env = os.environ.copy()
    env["DUNE_JOBS"] = "2"
    command(["dune", "build", "test/vision_artifact_measure.exe"], cwd=path, env=env)
    binary = path / "_build/default/test/vision_artifact_measure.exe"
    if not binary.is_file():
        raise RuntimeError("measurement binary was not built")
    return path, binary


def wait_for(path: Path, process: subprocess.Popen[bytes], timeout: float) -> None:
    until = time.monotonic() + timeout
    while time.monotonic() < until:
        if path.exists():
            return
        if process.poll() is not None:
            raise RuntimeError(f"measurement exited before {path.name}: {process.returncode}")
        time.sleep(0.1)
    raise RuntimeError(f"measurement did not create {path.name}")


def run_window(
    *,
    label: str,
    sha: str,
    binary: Path,
    fixtures: Path,
    output: Path,
    tracer_dir: Path,
    count: int,
    seconds: int,
    index: int,
) -> dict[str, object]:
    output.mkdir(parents=True)
    state = output / "state"
    state.mkdir()
    events = output / "events"
    events.mkdir()
    env = os.environ.copy()
    env.update(
        MASC_BASE_PATH=str(state),
        MASC_CONFIG_DIR=str(state / ".masc"),
        MEASURE_SOURCE=sha,
        OCAML_RUNTIME_EVENTS_START="1",
        OCAML_RUNTIME_EVENTS_DIR=str(events),
    )
    started = time.time()
    proc = subprocess.Popen(
        [str(binary), str(state), str(fixtures), str(count), str(seconds)],
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, cwd=output, env=env,
    )
    watchers: list[tuple[str, subprocess.Popen[bytes]]] = []
    try:
        wait_for(state / "window-start", proc, 120)
        for name in ("rtev_fibers", "rtev_watch"):
            tool = tracer_dir / f"{name}.exe"
            if not tool.is_file():
                raise RuntimeError(f"missing runtime-events consumer: {tool}")
            watcher = subprocess.Popen(
                [str(tool), str(events), str(proc.pid), str(max(1, seconds - 2))],
                stdout=subprocess.PIPE, stderr=subprocess.PIPE, cwd=output,
            )
            watchers.append((name, watcher))
        stdout, stderr = proc.communicate(timeout=seconds + 30)
    except Exception:
        proc.kill()
        proc.communicate()
        raise
    (output / "stdout.jsonl").write_bytes(stdout)
    (output / "stderr.txt").write_bytes(stderr)
    for name, watcher in watchers:
        trace, error = watcher.communicate(timeout=seconds + 30)
        (output / f"{name}.txt").write_bytes(trace)
        (output / f"{name}.stderr.txt").write_bytes(error)
        if watcher.returncode:
            raise RuntimeError(f"{name} exited {watcher.returncode}: {error.decode(errors='replace')}")
    if proc.returncode:
        raise RuntimeError(f"measurement exited {proc.returncode}: {stderr.decode(errors='replace')}")
    rows = [json.loads(line) for line in stdout.decode().splitlines() if line.startswith("{")]
    if len(rows) != 1 or rows[0].get("source") != sha:
        raise RuntimeError("measurement receipt is missing or has wrong source")
    receipt = {
        "label": label, "source": sha, "window": index,
        "start_utc_epoch": started, "end_utc_epoch": time.time(),
        "binary_sha256": hashlib.sha256(binary.read_bytes()).hexdigest(),
        "result": rows[0],
    }
    (output / "receipt.json").write_text(json.dumps(receipt, indent=2) + "\n")
    return receipt


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--count", type=int, default=40)
    parser.add_argument("--seconds", type=int, default=90)
    parser.add_argument("--pairs", type=int, default=3)
    args = parser.parse_args()
    if args.count < 1 or args.count > 40 or args.seconds < 1 or args.pairs < 1:
        parser.error("count must be 1..40, seconds and pairs must be positive")
    repo = Path.cwd()
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    fixtures = output / "fixtures"
    inventory = prepare_fixtures(fixtures)
    (output / "fixture-sha256.txt").write_text(inventory + "\n")
    source_root = output.parent / "vision-sources"
    source_root.mkdir()
    before, before_binary = prepare_source(repo, source_root, "before", BEFORE)
    after, after_binary = prepare_source(repo, source_root, "after", AFTER)
    command(["dune", "build", "tools/rtev_trace/rtev_fibers.exe",
             "tools/rtev_trace/rtev_watch.exe"], cwd=after)
    tracer_dir = after / "_build/default/tools/rtev_trace"
    receipts = []
    order = [("before", BEFORE, before_binary), ("after", AFTER, after_binary)]
    for pair in range(args.pairs):
        for label, sha, binary in (order if pair % 2 == 0 else reversed(order)):
            receipts.append(run_window(
                label=label, sha=sha, binary=binary, fixtures=fixtures,
                output=output / f"window-{len(receipts) + 1:02d}-{label}",
                tracer_dir=tracer_dir, count=args.count,
                seconds=args.seconds, index=pair + 1))
    summary = {
        "before": BEFORE, "after": AFTER, "fixture_inventory_sha256": inventory,
        "count_per_window": args.count, "seconds_per_window": args.seconds,
        "pool_domains": 1, "receipts": receipts,
    }
    (output / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")
    print(json.dumps({"windows": len(receipts), "fixtures": inventory,
                      "output": str(output)}))
    return 0


if __name__ == "__main__":
    sys.exit(main())
