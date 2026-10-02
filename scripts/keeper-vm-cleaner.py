#!/usr/bin/env python3
"""Manage a periodic VM build cleaner without a system service installation."""

import argparse
import fcntl
import json
import math
import os
from pathlib import Path
import subprocess
import sys
import time


def running(state: Path) -> bool:
    with (state / "service.lock").open("a") as lease:
        try:
            fcntl.flock(lease, fcntl.LOCK_EX | fcntl.LOCK_NB)
            return False
        except BlockingIOError:
            return True


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("start", "status", "stop", "run"))
    parser.add_argument("--base-path", type=Path, required=True)
    parser.add_argument("--idle-hours", type=float, default=24)
    parser.add_argument("--interval-seconds", type=float, default=3600)
    args = parser.parse_args()
    if (
        not math.isfinite(args.idle_hours)
        or not math.isfinite(args.interval_seconds)
        or args.idle_hours < 0
        or args.interval_seconds <= 0
    ):
        parser.error("idle hours must be nonnegative; interval must be positive")
    base = Path(os.path.abspath(args.base_path))
    state = base / ".masc" / "maintenance" / "keeper-vm-cleaner"
    state.mkdir(parents=True, exist_ok=True)
    stop = state / "stop-requested"
    if args.command == "status":
        print(json.dumps({"running": running(state), "state_dir": str(state)}))
        return 0
    if args.command == "stop":
        with (state / "control.lock").open("a") as control:
            fcntl.flock(control, fcntl.LOCK_EX)
            if running(state):
                stop.touch()
                print("stop requested; the current sweep will finish safely")
            else:
                print("already stopped")
        return 0
    if args.command == "start":
        if running(state):
            print("already running")
            return 0
        with (state / "service.log").open("a") as log:
            child = subprocess.Popen(
                [
                    sys.executable,
                    str(Path(__file__).resolve()),
                    "run",
                    "--base-path",
                    str(base),
                    "--idle-hours",
                    str(args.idle_hours),
                    "--interval-seconds",
                    str(args.interval_seconds),
                ],
                stdin=subprocess.DEVNULL,
                stdout=log,
                stderr=log,
                start_new_session=True,
            )
        for _ in range(50):
            if running(state):
                print(f"started; state: {state}")
                return 0
            if child.poll() is not None:
                print(f"start failed; see {state / 'service.log'}", file=sys.stderr)
                return 1
            time.sleep(0.1)
        print("start not confirmed; check status", file=sys.stderr)
        return 1

    # Keep the inode and descriptor for the entire service lifetime. Status and
    # stop never signal a PID, so a stale PID file cannot kill another process.
    with (
        (state / "service.lock").open("a") as lease,
        (state / "control.lock").open("a") as control,
    ):
        # Serialize making the service visible and clearing a stale stop marker
        # with stop itself, so startup cannot erase an acknowledged request.
        fcntl.flock(control, fcntl.LOCK_EX)
        try:
            fcntl.flock(lease, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            return 0
        stop.unlink(missing_ok=True)
        (state / "service.log").write_text("")
        (state / "config.json").write_text(
            json.dumps(
                {
                    "pid": os.getpid(),
                    "idle_hours": args.idle_hours,
                    "interval_seconds": args.interval_seconds,
                    "script": str(Path(__file__).resolve()),
                }
            )
        )
        fcntl.flock(control, fcntl.LOCK_UN)
        cleaner = Path(__file__).with_name("cleanup-keeper-vm-builds.py")
        while not stop.exists():
            result = subprocess.run(
                [
                    sys.executable,
                    str(cleaner),
                    "--base-path",
                    str(base),
                    "--idle-hours",
                    str(args.idle_hours),
                    "--apply",
                ],
                text=True,
                capture_output=True,
                check=False,
            )
            # A fixed pair of reports bounds maintenance's own storage growth.
            temporary = state / "last-sweep.tmp"
            temporary.write_text(result.stdout)
            temporary.replace(state / "last-sweep.json")
            (state / "last-error.txt").write_text(result.stderr[-8000:])
            deadline = time.monotonic() + args.interval_seconds
            while not stop.exists() and time.monotonic() < deadline:
                time.sleep(min(1, max(0, deadline - time.monotonic())))
    return 0


if __name__ == "__main__":
    sys.exit(main())
