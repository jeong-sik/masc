from __future__ import annotations

import os
import pty
import subprocess
import sys

import test_tui_keyboard_input as harness


def main() -> int:
    master, slave = pty.openpty()
    process = subprocess.Popen(
        [sys.executable, "-c", "import os,time; os.write(1,b'probe-byte'); time.sleep(30)"],
        stdin=slave,
        stdout=slave,
        stderr=slave,
        start_new_session=True,
    )
    os.close(slave)
    os.set_blocking(master, False)
    output = bytearray()
    try:
        harness.wait_for_output(
            process, master, output, b"INTENDED-RED-MISSING-NEEDLE",
            start=0, timeout=0.25,
        )
    except AssertionError as error:
        print(f"INTENDED RED: {error}")
        return 1
    finally:
        process.kill()
        process.wait()
        os.close(master)
    raise AssertionError("probe unexpectedly found its missing needle")


if __name__ == "__main__":
    raise SystemExit(main())
