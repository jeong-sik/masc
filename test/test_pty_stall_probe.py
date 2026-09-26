from __future__ import annotations

import io
import os
import pty
import re
import subprocess
import sys
import time
from types import SimpleNamespace
from unittest.mock import patch

import test_tui_keyboard_input as harness


def main() -> int:
    master, slave = pty.openpty()
    process = subprocess.Popen(
        [
            sys.executable,
            "-c",
            "import os,time; os.write(1,b'probe-byte'); end=time.monotonic()+1; exec('while time.monotonic()<end: pass')",
        ],
        stdin=slave,
        stdout=slave,
        stderr=slave,
        start_new_session=True,
    )
    os.close(slave)
    os.set_blocking(master, False)
    output = bytearray()
    try:
        try:
            harness.wait_for_output(
                process, master, output, b"INTENDED-RED-MISSING-NEEDLE",
                start=0, timeout=0.25,
            )
        except AssertionError as error:
            message = str(error)
            assert "timed out waiting" in message, message
            assert "silence " in message, message
            assert re.search(r"loadavg\(at timeout\) [^;]+", message), message
            assert "child utime/stime at last byte " in message, message
            assert "at timeout " in message and "delta +" in message, message
            print(f"INTENDED RED: {message}")
        else:
            raise AssertionError("probe unexpectedly found its missing needle")
    finally:
        process.kill()
        process.wait()
        os.close(master)

    with patch("builtins.open", side_effect=OSError("no /proc")):
        with patch.object(harness, "_child_cpu_ticks", return_value=None):
            unavailable = harness._stall_line(
                SimpleNamespace(pid=123), bytearray(b"x"),
                started_at=0.0, started_len=0, last_byte_at=0.0,
                last_byte_ticks=None,
            )
    assert "loadavg(at timeout) unavailable" in unavailable, unavailable
    assert "child utime/stime unavailable" in unavailable, unavailable

    with patch("builtins.open", return_value=io.StringIO("0.11 0.22 0.33 4/5 123\n")):
        with patch.object(harness, "_child_cpu_ticks", return_value=(20, 30)):
            with patch.object(harness.os, "sysconf", return_value=100):
                raw_load = harness._stall_line(
                    SimpleNamespace(pid=123), bytearray(b"x"),
                    started_at=0.0, started_len=0, last_byte_at=0.0,
                    last_byte_ticks=(10, 20),
                )
    assert "loadavg(at timeout) 0.11 0.22 0.33 4/5 123" in raw_load, raw_load
    print("CONTRACT CHECK: /proc unavailable markers and raw loadavg content verified")
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
