"""End-to-end regression guard for the task-1575 supervise wiring: the real
shim binary, driven over its actual wire protocol (mode="observe"), must
observe a payload that makes *two* socket(2) attempts separated by a pause
-- not just the first one, and not zero.

This is the level the task-1571 C-stub tests
(test_exec_shim_fdpass.ml, test_exec_shim_observe_drain.ml) do not reach:
those fork a child that calls the seccomp/fd-passing primitives directly,
bypassing Exec_shim.spawn/supervise (private, not in exec_shim.mli) and the
plan_for_mode() box decision entirely. Three real bugs lived exactly in
that gap and none of the C-stub-level tests could have caught any of them:

  1. readfds built with the observe/not-observe branches swapped, so the
     supervise select loop never watched the listener fd while observing
     -- the wiring was inert regardless of what the C stubs did correctly
     in isolation.
  2. drain_one/drain_loop treating EAGAIN (queue empty, the ordinary state
     between bursts on a non-blocking listener) the same as ENOTCONN (the
     child gone), closing the listener after the first burst -- a second,
     later attempt was silently never observed.
  3. the static deny_sockets() ERRNO filter that "lib/exec_shim/exec_shim.ml"
     installs unconditionally for Observe mode racing the new
     SECCOMP_RET_USER_NOTIF filter on the same syscall (socket): seccomp
     takes the highest-priority action among all loaded filters and
     SECCOMP_RET_ERRNO outranks SECCOMP_RET_USER_NOTIF, so with both
     filters installed the static one always won and the listener never
     saw a notification at all -- the whole observe-drain feature was
     inert in the real request path even though the C-stub tests, which
     install only the notify filter, passed.

A test that seeds only one attempt cannot tell (1)+(3) (nothing observed)
apart from a working single-shot path; it takes two, spaced far enough
apart that the second one only arrives if the listener is still being
read, to pin all three shut at once.
"""

import base64
import json
import os
import selectors
import struct
import subprocess
import sys
import tempfile
import time
from pathlib import Path


def call(binary: Path, root: Path, config: Path, major: int, argv: list[str], timeout_sec: int):
    encode = lambda value: base64.b64encode(value.encode()).decode()
    request = {"v": major, "argv": [encode(arg) for arg in argv], "env": [],
               "cwd": encode(str(root)), "remote_root": encode(str(root)),
               "timeout_sec": timeout_sec, "stdin_len": 0, "mode": "observe"}
    payload = json.dumps(request).encode()
    environment = dict(os.environ, MASC_EXEC_SHIM_CONFIG=str(config))
    with subprocess.Popen([str(binary)], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                          stderr=subprocess.PIPE, env=environment) as process:
        assert process.stdin and process.stdout and process.stderr
        process.stdin.write(struct.pack(">Q", len(payload)) + payload)
        process.stdin.flush()
        # Left open until every byte of stdout/stderr is read: the shim reads
        # its own stdin readable-then-EOF as the caller cancelling (see
        # read_child_boundary's neighbour in the supervise loop) and SIGTERMs
        # the payload. Closing it before the selector loop drained output
        # raced the payload's own prints against that cancel signal -- empty
        # stdout with no error was exactly what that race produced here.
        output = {"stdout": bytearray(), "stderr": bytearray()}
        with selectors.DefaultSelector() as selector:
            selector.register(process.stdout, selectors.EVENT_READ, "stdout")
            selector.register(process.stderr, selectors.EVENT_READ, "stderr")
            deadline = time.monotonic() + timeout_sec + 10
            while selector.get_map():
                if time.monotonic() >= deadline:
                    process.kill()
                    raise AssertionError(f"shim did not finish: {output!r}")
                for key, _ in selector.select(timeout=0.1):
                    chunk = os.read(key.fd, 65536)
                    if chunk:
                        output[key.data].extend(chunk)
                    else:
                        selector.unregister(key.fileobj)
        process.stdin.close()
        status = process.wait(timeout=5)
    return status, bytes(output["stdout"]), bytes(output["stderr"])


# Two attempts, paused long enough (0.2s) that the second one only reaches
# the parent if the supervise select loop is still watching the listener
# after draining the first -- the exact window bug (2) closed early.
CHILD_SCRIPT = (
    "import socket, time\n"
    "def attempt(label):\n"
    "    try:\n"
    "        socket.socket(socket.AF_INET, socket.SOCK_STREAM)\n"
    "        print(label + ':ALLOWED')\n"
    "    except PermissionError:\n"
    "        print(label + ':EPERM')\n"
    "attempt('first')\n"
    "time.sleep(0.2)\n"
    "attempt('second')\n"
)


def main():
    binary = Path(sys.argv[1]).resolve()
    probe = json.loads(subprocess.check_output([str(binary), "--probe"]))
    if "observe" not in probe["capabilities"]:
        raise AssertionError("this fixture requires actual Observe/user_notif support")
    major = int(probe["version"].split(".")[0])
    with tempfile.TemporaryDirectory(prefix="masc-shim-observe-drain-") as temporary:
        root = Path(temporary)
        config = root / "shim.conf"
        config.write_text(f"remote_root={root}\nscratch_root={root}\n")
        # The shim refuses a config its group or every user may write; set the
        # mode rather than leave it to the umask.
        config.chmod(0o644)
        status, stdout, stderr = call(
            binary, root, config, major, ["python3", "-c", CHILD_SCRIPT], timeout_sec=10)
        text_out = stdout.decode(errors="replace")
        text_err = stderr.decode(errors="replace")
        if status != 0:
            raise AssertionError(f"shim transport exit {status}, stdout={text_out!r} stderr={text_err!r}")
        # External behaviour unchanged: both attempts still see EPERM, the
        # payload never actually gets a socket.
        if "first:EPERM" not in text_out or "second:EPERM" not in text_out:
            raise AssertionError(
                f"observe must still deny both socket attempts: stdout={text_out!r}")
        # The evidence lives in the wire trailer itself now (Exec_ssh_protocol
        # .trailer.observed_syscalls), not a side-channel stderr text line --
        # a completion verdict (vrf-75b5116cabdef13de98a595b19a8295d) rejected
        # the raw-printf shape as indistinguishable from an arbitrary log
        # line, not a type the caller can rely on. The trailer rides between
        # the last two \x1e (RS, 0x1e) bytes in stderr, same delimiter
        # Exec_ssh_protocol.render_trailer/parse_trailer use.
        rs = "\x1e"
        last = text_err.rfind(rs)
        if last <= 0:
            raise AssertionError(f"no trailer delimiter in stderr: {text_err!r}")
        first = text_err.rfind(rs, 0, last)
        if first < 0:
            raise AssertionError(f"only one trailer delimiter in stderr: {text_err!r}")
        trailer = json.loads(text_err[first + 1:last])["masc_exec_result"]
        if "observed_syscalls" not in trailer:
            raise AssertionError(
                f"no observed_syscalls field in the trailer at all -- readfds "
                f"wiring or the seccomp filter race is back. trailer={trailer!r}")
        count = len(trailer["observed_syscalls"])
        if count != 2:
            raise AssertionError(
                f"expected exactly 2 observed socket attempts, got {count} "
                f"(stderr={text_err!r}) -- the second-attempt window closed early")
    print(json.dumps({"kind": "observe-supervise-drain-e2e", "observed_attempts": count}))


if __name__ == "__main__":
    main()
