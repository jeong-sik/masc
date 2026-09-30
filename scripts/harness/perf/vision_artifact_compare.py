#!/usr/bin/env python3
"""Run two historical vision-artifact implementations with one checked-in harness."""
from __future__ import annotations

import argparse
import base64
import hashlib
import json
import os
import re
import signal
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
    if label == "after":
        for name in ("rtev_fibers.ml", "rtev_watch.ml"):
            shutil.copy2(repo / "tools/rtev_trace" / name,
                         path / "tools/rtev_trace" / name)
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


def trace_header(name: str, body: bytes) -> dict[str, int]:
    summary = re.compile(
        r"pid=[0-9]+ (?:dir=.+ )?window_s=[0-9]+\.[0-9]+ "
        r"(?:backlog_drained=[0-9]+ )?events=([0-9]+) lost=([0-9]+)"
    )
    matches = [match for line in body.decode().splitlines()
               if (match := summary.fullmatch(line)) is not None]
    if len(matches) != 1:
        raise RuntimeError(f"{name} has {len(matches)} runtime-events summaries")
    events, lost = map(int, matches[0].groups())
    if events == 0 or lost != 0:
        raise RuntimeError(f"{name} has events={events} lost={lost}")
    return {"events": events, "lost": lost}


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
    proc: subprocess.Popen[bytes] | None = None
    watchers: list[tuple[str, subprocess.Popen[bytes], Path]] = []
    completed = False
    try:
        proc = subprocess.Popen(
            [str(binary), str(state), str(fixtures), str(count), str(seconds)],
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, cwd=output, env=env,
        )
        wait_for(state / "window-ready", proc, 120)
        for name in ("rtev_fibers", "rtev_watch"):
            tool = tracer_dir / f"{name}.exe"
            if not tool.is_file():
                raise RuntimeError(f"missing runtime-events consumer: {tool}")
            control = output / f"{name}-control"
            control.mkdir()
            watcher_env = os.environ.copy()
            watcher_env["MASC_RTEV_CONTROL_DIR"] = str(control)
            watcher = subprocess.Popen(
                [str(tool), str(events), str(proc.pid), str(seconds + 60)],
                stdout=subprocess.PIPE, stderr=subprocess.PIPE, cwd=output,
                env=watcher_env,
            )
            watchers.append((name, watcher, control))
            wait_for(control / "ready", watcher, 30)
        (state / "window-go").write_text(str(time.time()) + chr(10))
        wait_for(state / "window-complete", proc, seconds + 120)
        traces: dict[str, dict[str, float | int]] = {}
        for name, watcher, control in watchers:
            (control / "stop").write_text(str(time.time()) + chr(10))
            trace, error = watcher.communicate(timeout=30)
            (output / f"{name}.txt").write_bytes(trace)
            (output / f"{name}.stderr.txt").write_bytes(error)
            if watcher.returncode:
                raise RuntimeError(f"{name} exited {watcher.returncode}: {error.decode(errors='replace')}")
            summary = trace_header(name, trace)
            ready = float((control / "ready").read_text())
            ended = float((control / "ended").read_text())
            traces[name] = {"ready_utc_epoch": ready, "end_utc_epoch": ended,
                            **summary}
        (state / "window-release").write_text(str(time.time()) + chr(10))
        stdout, stderr = proc.communicate(timeout=30)
        (output / "stdout.jsonl").write_bytes(stdout)
        (output / "stderr.txt").write_bytes(stderr)
        if proc.returncode:
            raise RuntimeError(f"measurement exited {proc.returncode}: {stderr.decode(errors='replace')}")
        rows = [json.loads(line) for line in stdout.decode().splitlines()
                if line.startswith("{")]
        if len(rows) != 1 or rows[0].get("source") != sha:
            raise RuntimeError("measurement receipt is missing or has wrong source")
        samples = rows[0].get("samples")
        if not isinstance(samples, list) or len(samples) != 3 + 5 * count:
            raise RuntimeError("per-operation samples are missing or incomplete")
        for sample in samples:
            if (sample.get("operation") not in {"store_frame", "store_kept_new",
                                                 "store_kept_repeat", "load_kept",
                                                 "load_frame"}
                or not isinstance(sample.get("fixture"), str)
                or not re.fullmatch(r"[0-9]{4}\.png", sample["fixture"])
                or sample.get("outcome") != "verified"
                or not isinstance(sample.get("start_utc_epoch"), (int, float))
                or not isinstance(sample.get("end_utc_epoch"), (int, float))
                or not isinstance(sample.get("elapsed_ms"), (int, float))
                or sample["start_utc_epoch"] > sample["end_utc_epoch"]
                or sample["elapsed_ms"] < 0):
                raise RuntimeError("invalid per-operation sample")
        first_start = min(row["start_utc_epoch"] for row in samples)
        last_end = max(row["end_utc_epoch"] for row in samples)
        if any(not (trace["ready_utc_epoch"] <= first_start
                    and last_end <= trace["end_utc_epoch"])
               for trace in traces.values()):
            raise RuntimeError("one or more operations fell outside a trace window")
        receipt = {
            "label": label, "source": sha, "window": index,
            "start_utc_epoch": started, "end_utc_epoch": time.time(),
            "binary_sha256": hashlib.sha256(binary.read_bytes()).hexdigest(),
            "trace": traces,
            "result": rows[0],
        }
        (output / "receipt.json").write_text(json.dumps(receipt, indent=2) + chr(10))
        completed = True
        return receipt
    except BaseException as error:
        (output / "failure.json").write_text(
            json.dumps({"type": type(error).__name__, "message": str(error)}) + chr(10))
        raise
    finally:
        owned = [("measurement", proc)] + [(name, watcher) for name, watcher, _ in watchers]
        cleanup = {}
        for name, child in owned:
            if child is None:
                continue
            if child.poll() is None:
                child.kill()
            try:
                stdout, stderr = child.communicate(timeout=10)
            except subprocess.TimeoutExpired:
                child.kill()
                stdout, stderr = child.communicate(timeout=10)
            log_names = (("stdout.jsonl", "stderr.txt") if name == "measurement"
                         else (f"{name}.txt", f"{name}.stderr.txt"))
            for filename, data in zip(log_names, (stdout, stderr)):
                log = output / filename
                if not log.exists():
                    log.write_bytes(data)
            cleanup[name] = {"returncode": child.returncode, "reaped": child.poll() is not None}
        (output / "cleanup.json").write_text(json.dumps(
            {"completed": completed, "children": cleanup}, indent=2) + chr(10))


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--count", type=int, default=40)
    parser.add_argument("--seconds", type=int, default=90)
    parser.add_argument("--pairs", type=int, default=3)
    args = parser.parse_args()
    def interrupted(signum: int, _frame: object) -> None:
        raise KeyboardInterrupt(f"signal {signum}")
    signal.signal(signal.SIGTERM, interrupted)
    signal.signal(signal.SIGINT, interrupted)
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
