"""Own runtime-events readers for an isolated Keeper scale experiment.

Readers acknowledge backlog draining before workload admission. Their normal
exit, loss counters and time windows are evidence requirements, not runtime
control policies. No shared server is discovered or modified.
"""
from __future__ import annotations

from dataclasses import dataclass
import hashlib
import json
import math
import os
from pathlib import Path
import re
import shutil
import signal
import subprocess
import time


@dataclass(frozen=True)
class Reader:
    name: str
    process: subprocess.Popen
    directory: Path
    binary: Path
    sha256: str


@dataclass(frozen=True)
class Capture:
    directory: Path
    readers: tuple[Reader, ...]


def digest(path):
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def write_json(path, value):
    path.write_text(json.dumps(value, indent=2) + "\n")


def start(*, output, base, tools, server, seconds, ready_timeout):
    directory = output / "runtime-events"
    directory.mkdir()
    readers = []
    try:
        ring = base / ".masc/runtime/events"
        deadline = time.monotonic() + ready_timeout
        while not (ring / f"{server.pid}.events").is_file():
            if server.poll() is not None:
                raise RuntimeError("owned server exited before its runtime-events ring appeared")
            if time.monotonic() >= deadline:
                raise RuntimeError("owned runtime-events ring readiness deadline")
            time.sleep(.02)
        if time.monotonic() >= deadline:
            raise RuntimeError("runtime-events readiness deadline before reader launch")
        for name in ("rtev_watch", "rtev_fibers"):
            child_dir = directory / name
            child_dir.mkdir()
            source = (tools / (name + ".exe")).resolve(strict=True)
            binary = child_dir / source.name
            shutil.copy2(source, binary)
            binary.chmod(0o700)
            sha256 = digest(source)
            if digest(binary) != sha256:
                raise RuntimeError("runtime-events reader changed during private copy")
            argv = [str(binary), str(ring), str(server.pid), str(seconds)]
            env = {"PATH": os.environ["PATH"], "LANG": "C.UTF-8",
                   "MASC_RTEV_CONTROL_DIR": str(child_dir)}
            with (child_dir / "report.txt").open("wb") as log:
                child = subprocess.Popen(argv, cwd=base, env=env, stdout=log,
                                         stderr=subprocess.STDOUT, start_new_session=True)
            readers.append(Reader(name, child, child_dir, binary, sha256))
            write_json(child_dir / "identity.json", {"argv": argv, "sha256": sha256,
                "pid": child.pid, "owned_server_pid": server.pid,
                "ready_timeout_s": ready_timeout, "maximum_observation_s": seconds})
        for reader in readers:
            while not ((reader.directory / "ready").is_file()
                       and (reader.directory / "report.txt").read_text().startswith(
                           f"ready pid={server.pid} ")):
                if reader.process.poll() is not None:
                    raise RuntimeError(f"{reader.name} exited before backlog-drained acknowledgement")
                if server.poll() is not None:
                    raise RuntimeError("owned server exited while tracing readers started")
                if time.monotonic() >= deadline:
                    raise RuntimeError("runtime-events reader readiness deadline")
                time.sleep(.02)
            stamp = float((reader.directory / "ready").read_text())
            if not math.isfinite(stamp) or reader.process.poll() is not None:
                raise RuntimeError("invalid or terminal runtime-events reader acknowledgement")
        if (time.monotonic() >= deadline or server.poll() is not None
                or any(reader.process.poll() is not None for reader in readers)):
            raise RuntimeError("runtime-events readiness expired before workload admission")
        return Capture(directory, tuple(readers))
    except BaseException as error:
        try:
            finish(Capture(directory, tuple(readers)), started_at_unix=None, ended_at_unix=None)
        except BaseException as cleanup_error:
            error.add_note(f"reader-start cleanup failed: {type(cleanup_error).__name__}: {cleanup_error}")
        raise


def _finish(capture, *, started_at_unix, ended_at_unix):
    # Signal every reader first; their observation windows end before the
    # server is stopped and removes its runtime-events ring.
    for reader in capture.readers:
        try:
            (reader.directory / "stop").touch()
        except OSError:
            pass  # Cleanup below still owns and reaps the process.
    rows = []
    for reader in capture.readers:
        forced = False
        error = None
        try:
            reader.process.wait(timeout=15)
        except subprocess.TimeoutExpired:
            forced = True
            try:
                os.killpg(reader.process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            reader.process.wait(timeout=5)
        try:
            report = (reader.directory / "report.txt").read_text()
            pairs = re.findall(r"\bevents=(\d+)\s+lost=(\d+)", report)
            if len(pairs) != 1:
                raise ValueError("missing or ambiguous runtime-events summary")
            events, lost = map(int, pairs[0])
            ready = float((reader.directory / "ready").read_text())
            ended = float((reader.directory / "ended").read_text())
            covers = (started_at_unix is not None and ended_at_unix is not None
                      and all(math.isfinite(t) for t in
                              (ready, started_at_unix, ended_at_unix, ended))
                      and ready <= started_at_unix <= ended_at_unix <= ended)
            unchanged = digest(reader.binary) == reader.sha256
            stop_ack = (reader.directory / "stop-ack").is_file()
            report_complete = (reader.directory / "report-complete").is_file()
        except (OSError, ValueError) as exc:
            error = f"{type(exc).__name__}: {exc}"
            events = lost = ready = ended = None
            covers = unchanged = False
            stop_ack = report_complete = False
        rows.append({"name": reader.name, "returncode": reader.process.returncode,
                     "forced_kill": forced, "events": events, "lost": lost,
                     "ready_at_unix": ready, "ended_at_unix": ended,
                     "covers_workload": covers, "binary_unchanged": unchanged,
                     "post_workload_stop_acknowledged": stop_ack,
                     "report_flush_acknowledged": report_complete,
                     "error": error, "complete": reader.process.returncode == 0
                     and not forced and error is None and events > 0
                     and lost == 0 and covers and unchanged and stop_ack and report_complete})
    result = {"scope": "Collection conditions only, with tracing overhead. Ready/stop acknowledgements bracket workload causally; wall stamps are diagnostic. Backlog state is discarded, detailed runs are thresholded/top-N, and neither zero post-drain loss nor completion proves complete causal traces or exclusive CPU attribution.",
              "started_at_unix": started_at_unix, "ended_at_unix": ended_at_unix,
              "complete": len(rows) == 2 and all(row["complete"] for row in rows),
              "readers": rows}
    write_json(capture.directory / "receipt.json", result)
    return result


def finish(capture, *, started_at_unix, ended_at_unix):
    try:
        return _finish(capture, started_at_unix=started_at_unix,
                       ended_at_unix=ended_at_unix)
    except BaseException as error:
        # Preserve the original failure, but never strand readers when a
        # receipt write, process wait or interruption fails midway through.
        for reader in capture.readers:
            try:
                if reader.process.poll() is None:
                    os.killpg(reader.process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            except BaseException as cleanup_error:
                error.add_note(f"{reader.name} kill failed: {cleanup_error}")
            try:
                reader.process.wait(timeout=5)
            except BaseException as cleanup_error:
                error.add_note(f"{reader.name} reap failed: {cleanup_error}")
        raise
