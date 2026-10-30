"""Foreground CI observation; all command lifetime effects belong to OwnedSession."""

import datetime
import os
from pathlib import Path
import signal
import subprocess
import sys
import time

from owned_process import OwnedSession


class Observer:
    def __init__(self):
        self.log_path = os.environ["CI_TEST_LOG_FILE"]
        self.writer = open(self.log_path, "ab", buffering=0)
        self.reader = open(self.log_path, "rb")
        self.reader.seek(0, os.SEEK_END)
        self.started = float(os.environ["CI_TEST_START_EPOCH"])
        self.timeout = int(os.environ["CI_TEST_TIMEOUT_SEC"])
        self.grace = int(os.environ["CI_TEST_TIMEOUT_GRACE_SEC"])
        if self.grace < 0:
            raise ValueError("CI_TEST_TIMEOUT_GRACE_SEC must be non-negative")
        self.heartbeat = int(os.environ["CI_TEST_HEARTBEAT_SEC"])
        self.disk_interval = int(os.environ["CI_TEST_DISK_CHECK_SEC"])
        self.disk_minimum = int(os.environ["CI_TEST_DISK_MIN_AVAILABLE_MB"])
        self.next_heartbeat = time.monotonic()
        self.next_disk_check = time.monotonic() + self.disk_interval
        self.disk_reported = False
        self.cancel_signal = None
        self.owner = None
        self.command = ""

    def cancel(self, signum, _frame):
        # Repeated cancellation never interrupts retained-ownership cleanup.
        if self.cancel_signal is None:
            self.cancel_signal = signum

    def pump(self):
        # One I/O quantum per monitor tick keeps noisy commands from starving
        # deadline/cancellation checks. The final drain loses no log bytes.
        data = self.reader.read(65536)
        if data:
            sys.stdout.buffer.write(data)
            sys.stdout.buffer.flush()
        return bool(data)

    def log(self, message):
        self.writer.write((message + "\n").encode())
        self.pump()

    def diagnostics(self, reason):
        env = dict(
            os.environ,
            CI_DIAG_TEST_CMD=self.command,
            CI_DIAG_ACTIVE_PID=str(self.owner.pid) if self.owner else "",
        )
        runner = Path(__file__).resolve().parents[1] / "ci-run-tests.sh"
        try:
            subprocess.run(
                ["bash", str(runner), "--ci-run-diagnostics", reason],
                env=env,
                check=True,
            )
        except (OSError, subprocess.SubprocessError) as error:
            # Observability cannot replace a known command/timeout status.
            self.log(f"[ci-diag] unavailable reason={reason} error={error}")

    def monitor(self):
        self.pump()
        now = time.monotonic()
        if now >= self.next_heartbeat:
            self.next_heartbeat = now + self.heartbeat
            stamp = datetime.datetime.now(datetime.timezone.utc).strftime(
                "%Y-%m-%dT%H:%M:%SZ"
            )
            self.log(
                f"[ci-heartbeat] {stamp} elapsed_sec={int(time.time() - self.started)} command still running"
            )
        if now >= self.next_disk_check:
            self.next_disk_check = now + self.disk_interval
            if not self.disk_reported and self.disk_minimum > 0:
                try:
                    root = os.environ["DUNE_SOURCEROOT"]
                    rows = subprocess.check_output(
                        ["df", "-Pm", root], text=True
                    ).splitlines()
                    available = int(rows[1].split()[3])
                except (OSError, ValueError, IndexError, subprocess.SubprocessError):
                    return
                if available <= self.disk_minimum:
                    self.disk_reported = True
                    self.log(
                        f"[ci-observe] disk_pressure path={root} available_mb={available} min_available_mb={self.disk_minimum}"
                    )
                    self.diagnostics("disk_pressure_observed")

    def run(self, command):
        if self.cancel_signal is not None:
            return 128 + self.cancel_signal
        self.command = command
        status = None
        started = time.monotonic()
        self.next_disk_check = started + self.disk_interval
        self.owner = OwnedSession(command, self.writer)
        try:
            while True:
                if self.cancel_signal is not None:
                    status = 128 + self.cancel_signal
                    break
                status = self.owner.terminal_status()
                if status is not None:
                    break
                self.owner.observe()
                self.monitor()
                if self.timeout > 0 and time.monotonic() - started >= self.timeout:
                    status = 124
                    self.log(f"[ci-observe] timeout timeout_sec={self.timeout}")
                    self.diagnostics(f"timeout_{self.timeout}s")
                    break
                time.sleep(0.1)
        finally:
            try:
                self.owner.finish(self.grace, self.monitor)
            except Exception as error:
                self.owner.uncertainty.add(
                    f"cleanup_failed: {type(error).__name__}: {error}"
                )
                if status is None or status == 0:
                    status = 125
            finally:
                if self.owner.uncertainty:
                    self.log(
                        "[ci-observe] cleanup_unconfirmed scope=owned_session escaped_sessions=not_covered "
                        + "; ".join(sorted(self.owner.uncertainty))
                    )
                    if status == 0:
                        status = 125
                else:
                    self.log(
                        "[ci-observe] cleanup_observation=no_live_session_members "
                        "scope=owned_session escaped_sessions=not_covered"
                    )
                while self.pump():
                    pass
        if self.cancel_signal is not None and status == 0:
            status = 128 + self.cancel_signal
        self.owner = None
        return status

    def close(self):
        self.reader.close()
        self.writer.close()


def main():
    observer = Observer()
    signal.signal(signal.SIGINT, observer.cancel)
    signal.signal(signal.SIGTERM, observer.cancel)
    try:
        command, contract = sys.argv[1:]
        observer.log(f"[ci-run] command: {command}")
        observer.log(f"[ci-run] heartbeat_sec={observer.heartbeat}")
        observer.log(f"[ci-run] timeout_sec={observer.timeout}")
        observer.log(
            f"[ci-run] disk_min_available_mb={observer.disk_minimum} disk_check_sec={observer.disk_interval}"
        )
        observer.log(
            "[ci-run] started_at="
            + datetime.datetime.now(datetime.timezone.utc).strftime(
                "%Y-%m-%dT%H:%M:%SZ"
            )
        )
        observer.log(f"[ci-run] log_file={observer.log_path}")
        observer.log(f"[ci-run] source_root={os.environ['DUNE_SOURCEROOT']}")
        effective = command
        if (
            "dune " in command or "dune-local.sh" in command
        ) and "unset DUNE_RPC" not in command:
            effective = "unset DUNE_RPC; " + command
        status = observer.run(effective)
        if status:
            if status == 124:
                observer.log(
                    f"[ci-run] ERROR: test command timed out after {observer.timeout}s"
                )
            else:
                observer.diagnostics(f"nonzero_exit_{status}")
                observer.log(f"[ci-run] ERROR: test command failed with exit={status}")
            return status
        if os.environ["CI_CONTRACT_HARNESS_ENABLED"] == "1":
            observer.log(f"[ci-run] contract_harness_command: {contract}")
            status = observer.run(contract)
            if status:
                observer.diagnostics(f"contract_harness_exit_{status}")
                observer.log(
                    f"[ci-run] ERROR: contract harness failed with exit={status}"
                )
                return status
            observer.log("[ci-run] contract harness completed successfully")
        else:
            observer.log(
                f"[ci-run] contract harness skipped (CI_CONTRACT_HARNESS_ENABLED={os.environ['CI_CONTRACT_HARNESS_ENABLED']})"
            )
        observer.log(
            f"[ci-run] tests completed successfully (elapsed_sec={int(time.time() - observer.started)})"
        )
        return 0
    finally:
        observer.close()


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        print(f"[ci-run] ERROR: observer failed: {error}", file=sys.stderr)
        sys.exit(125)
