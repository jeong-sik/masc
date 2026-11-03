"""Count the pipe descriptors each Keeper VM runtime holds, and probe pipe growth.

lsof prints no peer in the NAME column for a pipe whose other end is closed
(8 columns for a connected pipe, 7 for an orphan; checked with a `sleep | true`
pair). A runtime that keeps orphan ends alive pins each pipe's kernel buffer.

usage:
  pipeleak.py once              table of runtimes, orphan and connected pipes
  pipeleak.py loop OUT SECS N   append N JSON lines, SECS apart, to OUT
"""

import fcntl
import json
import os
import re
import subprocess
import sys
import time

RUNTIME_MARK = "container-runtime-linux start"
NAME_PATTERN = re.compile(r"/containers/([A-Za-z0-9_.-]+)")
PROBE_BYTES = 70000
PROBE_SAMPLES = 3
PIPE_FD_TYPE = "PIPE"
LSOF_COLUMNS_ORPHAN = 7


def runtimes() -> dict[int, str]:
    listing = subprocess.run(
        ["ps", "-axo", "pid=,command="], capture_output=True, text=True, check=True
    ).stdout
    found: dict[int, str] = {}
    for line in listing.splitlines():
        if RUNTIME_MARK not in line:
            continue
        pid_text, _, command = line.strip().partition(" ")
        match = NAME_PATTERN.search(command)
        found[int(pid_text)] = match.group(1) if match else "unnamed"
    return found


def pipe_counts(pids: list[int]) -> dict[int, tuple[int, int]]:
    """pid -> (orphan, connected) pipe descriptor counts."""
    counts = {pid: [0, 0] for pid in pids}
    if not pids:
        return {}
    listing = subprocess.run(
        ["lsof", "-n", "-w", "-p", ",".join(str(p) for p in pids)],
        capture_output=True,
        text=True,
    ).stdout
    for line in listing.splitlines()[1:]:
        fields = line.split()
        if len(fields) < LSOF_COLUMNS_ORPHAN or fields[4] != PIPE_FD_TYPE:
            continue
        pid = int(fields[1])
        if pid not in counts:
            continue
        counts[pid][0 if len(fields) == LSOF_COLUMNS_ORPHAN else 1] += 1
    return {pid: (pair[0], pair[1]) for pid, pair in counts.items()}


def nonblocking_pipe() -> tuple[int, int]:
    read_fd, write_fd = os.pipe()
    flags = fcntl.fcntl(write_fd, fcntl.F_GETFL)
    fcntl.fcntl(write_fd, fcntl.F_SETFL, flags | os.O_NONBLOCK)
    return read_fd, write_fd


def bytewise_capacity() -> int:
    read_fd, write_fd = nonblocking_pipe()
    try:
        accepted = 0
        while True:
            try:
                os.write(write_fd, b"x")
            except BlockingIOError:
                return accepted
            accepted += 1
    finally:
        os.close(read_fd)
        os.close(write_fd)


def bigwrite_capacity() -> int:
    read_fd, write_fd = nonblocking_pipe()
    try:
        try:
            return os.write(write_fd, b"x" * PROBE_BYTES)
        except BlockingIOError:
            return 0
    finally:
        os.close(read_fd)
        os.close(write_fd)


def sample() -> dict:
    found = runtimes()
    counts = pipe_counts(sorted(found))
    per_runtime = {
        found[pid]: {"pid": pid, "orphan": orphan, "connected": connected}
        for pid, (orphan, connected) in counts.items()
    }
    return {
        "ts": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
        "epoch": int(time.time()),
        "bytewise": [bytewise_capacity() for _ in range(PROBE_SAMPLES)],
        "bigwrite": [bigwrite_capacity() for _ in range(PROBE_SAMPLES)],
        "orphan_total": sum(entry["orphan"] for entry in per_runtime.values()),
        "connected_total": sum(entry["connected"] for entry in per_runtime.values()),
        "runtimes": per_runtime,
    }


def print_table(snapshot: dict) -> None:
    print(snapshot["ts"], "bytewise", snapshot["bytewise"], "bigwrite", snapshot["bigwrite"])
    rows = sorted(snapshot["runtimes"].items(), key=lambda item: -item[1]["orphan"])
    for name, entry in rows:
        print(f'{entry["orphan"]:6d} orphan {entry["connected"]:3d} connected pid {entry["pid"]:6d} {name}')
    print(f'{snapshot["orphan_total"]:6d} orphan total, {snapshot["connected_total"]} connected')


def main(argv: list[str]) -> int:
    mode = argv[1] if len(argv) > 1 else "once"
    if mode == "once":
        print_table(sample())
        return 0
    if mode == "loop" and len(argv) == 5:
        out_path, seconds, count = argv[2], float(argv[3]), int(argv[4])
        for index in range(count):
            line = json.dumps(sample())
            with open(out_path, "a", encoding="utf-8") as handle:
                handle.write(line + "\n")
            if index + 1 < count:
                time.sleep(seconds)
        return 0
    print(__doc__)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
