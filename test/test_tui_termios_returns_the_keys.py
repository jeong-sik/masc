"""The session gives back the keys it took from the tty layer."""
import fcntl
import os
import struct
import subprocess
import sys
import termios
import time

import test_tui_keyboard_input as h

# The sources this scenario stands over. scripts/ci/run-edited-tests.sh runs a
# suite when a pull request changes a path the suite names.
SOURCE_MODULES = (
    "bin/masc_tui_termios.ml",
)

# The keys masc_tui_termios takes off the tty layer so its own reader sees
# them: Ctrl-V (paste), Ctrl-O (Browser screenshot), Ctrl-Y (speak). A
# platform that has no such key is skipped -- VDSUSP is BSD only.
RECLAIMED = ("VLNEXT", "VDISCARD", "VDSUSP")
CC = 6  # tcgetattr's cc list


def taken_keys(attrs) -> dict[str, int]:
    out = {}
    for name in RECLAIMED:
        index = getattr(termios, name, None)
        if index is None:
            continue
        value = attrs[CC][index]
        out[name] = value if isinstance(value, int) else ord(value)
    return out


def run(executable: str) -> None:
    fixtures = h.with_workspace_identity(h.keeper_runtime_http_fixtures(), "")
    master_fd, slave_fd = os.openpty()
    try:
        fcntl.ioctl(slave_fd, termios.TIOCSWINSZ, struct.pack("HHHH", 30, 100, 0, 0))
        os.set_blocking(master_fd, False)
        before = taken_keys(termios.tcgetattr(slave_fd))
        if not before:
            raise AssertionError("this platform has none of the reclaimed keys")
        import tempfile
        with tempfile.TemporaryDirectory(prefix="masc-tui-termios-") as base_path:
            with h.test_http_endpoint(
                h.with_workspace_identity(h.keeper_runtime_http_fixtures(), base_path),
                None,
            ) as (port, start_http_endpoint, set_base):
                h.seed_workspace(base_path)
                set_base(base_path)
                start_http_endpoint()
                environment = os.environ.copy()
                for name in ("LINES", "COLUMNS", "NO_COLOR", "MASC_TUI_FORCE_COLOR"):
                    environment.pop(name, None)
                environment["PATH"] = h.path_without_masc(environment.get("PATH", ""))
                environment.update({
                    "MASC_BASE_PATH": base_path,
                    "MASC_HOST": "127.0.0.1",
                    "MASC_TUI_SYNC": "off",
                    "TERM": "xterm-256color",
                    "MASC_TOKEN": "masc-tui-termios-token",
                })
                process = subprocess.Popen(
                    [executable, "--base-path", base_path,
                     "--workspace", h.WORKSPACE_PAYLOAD,
                     "--port", str(port), "--refresh", "60"],
                    stdin=slave_fd, stdout=slave_fd, stderr=slave_fd,
                    env=environment, close_fds=True)
                output = bytearray()
                try:
                    h.wait_for_output(process, master_fd, output, b"MASC ",
                                      start=0, timeout=20)
                    # While it runs the keys are off, which is the whole point
                    # of taking them; that is what makes giving them back a
                    # thing the session has to do rather than a thing the
                    # terminal does.
                    during = taken_keys(termios.tcgetattr(slave_fd))
                    # Exit is an armed action: the first press arms it and
                    # the second confirms. Press and wait rather than press
                    # twice -- a second byte that arrives before the first is
                    # read is one keystroke to the reader, and waiting on the
                    # armed row is no better, because the phrase it draws has
                    # already been on screen for other reasons.
                    deadline = time.time() + 20
                    while process.poll() is None and time.time() < deadline:
                        os.write(master_fd, b"q")
                        for _ in range(20):
                            if process.poll() is not None:
                                break
                            # Drain, or the pty fills and the session blocks
                            # writing its next frame instead of reading the
                            # keystroke -- which reads exactly like a session
                            # that ignores q.
                            try:
                                chunk = os.read(master_fd, 65536)
                            except BlockingIOError:
                                chunk = b""
                            except OSError:
                                chunk = b""
                            if chunk:
                                output.extend(chunk)
                            time.sleep(0.05)
                    if process.poll() is None:
                        raise AssertionError("the session did not exit on q")
                finally:
                    if process.poll() is None:
                        process.kill()
                        process.wait(timeout=10)
                after = taken_keys(termios.tcgetattr(slave_fd))
    finally:
        os.close(master_fd)
        os.close(slave_fd)

    if during == before:
        raise AssertionError(
            f"the session never took the keys, so giving them back proves "
            f"nothing: {before}")
    if after != before:
        raise AssertionError(
            f"the session kept a key the operator had: before={before} "
            f"after={after}")


if __name__ == "__main__":
    run(os.path.abspath(sys.argv[1]))
    print("the session returns the keys it took: PASS")
