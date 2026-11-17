"""Exercise receipts from the real shim binary, with stdin held open as its transport."""

import base64
import array
from contextlib import contextmanager
import fcntl
import hashlib
import json
import os
from pathlib import Path
import selectors
import select
import signal
import struct
import subprocess
import sys
import tempfile
import termios
import time


def call(binary: Path, root: Path, config: Path, major: int, mode: str, argv: list[str],
         acceptance_frame: bool = False, framed_stdin: bytes = b"", *,
         launcher: tuple[str, ...] = (), interactive_stdin: bool = False):
    encode = lambda value: base64.b64encode(value.encode()).decode()
    request = {"v": major, "argv": [encode(arg) for arg in argv], "env": [],
               "cwd": encode(str(root)), "remote_root": encode(str(root)),
               "timeout_sec": 10, "stdin_len": len(framed_stdin), "mode": mode}
    if interactive_stdin:
        if framed_stdin:
            raise AssertionError("interactive request must have an empty initial payload")
        del request["stdin_len"]
        request["stdin_stream"] = True
    if acceptance_frame:
        request["acceptance_frame"] = True
    payload = json.dumps(request).encode() + framed_stdin
    environment = dict(os.environ, MASC_EXEC_SHIM_CONFIG=str(config))
    with subprocess.Popen([*launcher, str(binary)], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                          stderr=subprocess.PIPE, env=environment) as process:
        assert process.stdin and process.stdout and process.stderr
        process.stdin.write(struct.pack(">Q", len(payload)) + payload)
        process.stdin.flush()
        output = {"stdout": bytearray(), "stderr": bytearray()}
        with selectors.DefaultSelector() as selector:
            selector.register(process.stdout, selectors.EVENT_READ, "stdout")
            selector.register(process.stderr, selectors.EVENT_READ, "stderr")
            deadline = time.monotonic() + 20
            while selector.get_map():
                if time.monotonic() >= deadline:
                    process.kill()
                    raise AssertionError("shim did not finish its bounded fixture")
                for key, _ in selector.select(timeout=0.1):
                    chunk = os.read(key.fd, 65536)
                    if chunk:
                        output[key.data].extend(chunk)
                    else:
                        selector.unregister(key.fileobj)
        process.stdin.close()
        status = process.wait(timeout=5)
    trailer = result_trailer(bytes(output["stderr"]))
    return status, bytes(output["stdout"]), trailer, bytes(output["stderr"])


def result_trailer(stderr: bytes):
    parts = stderr.rsplit(b"\x1e", 2)
    if len(parts) != 3 or parts[-1] != b"":
        raise AssertionError(f"no complete result trailer: {stderr!r}")
    return json.loads(parts[1])["masc_exec_result"]


def observe_channel_refusals(binary, helper, root, config, major):
    records = []
    for fault_errno in ("EPERM", "EAFNOSUPPORT"):
        launcher = (str(helper), "--standard-descriptor-fixture",
                    "deny-socketpair", fault_errno)
        # The same outer filter must leave the actual feature probe working:
        # otherwise this would only test the unsupported-host branch.
        filtered_probe = json.loads(subprocess.check_output(
            [*launcher, str(binary), "--probe"], timeout=20))
        if (int(filtered_probe["version"].split(".")[0]) != major
                or not {"observe", "user_notif", "interactive_stdin"}.issubset(
                    filtered_probe["capabilities"])):
            raise AssertionError(f"fault filter disabled the real Observe probe: {filtered_probe!r}")
        for interactive_stdin in (False, True):
            before = set(root.iterdir())
            # stdout is writable under Observe. An outside-scratch file would
            # remain absent even if the vulnerable payload actually started.
            marker = b"OBSERVE-PAYLOAD-MUST-NOT-START"
            argv = ["/bin/sh", "-c", "printf OBSERVE-PAYLOAD-MUST-NOT-START"]
            status, stdout, trailer, stderr = call(
                binary, root, config, major, "observe", argv,
                acceptance_frame=True, launcher=launcher,
                interactive_stdin=interactive_stdin)
            expected_receipt = {"mode": "observe", "plan": "filesystem_and_network_box",
                                "boundary": "refused"}
            if status != 1 or trailer["execution_receipt"] != expected_receipt:
                raise AssertionError(f"channel failure was not refused before spawn: {status}, {trailer!r}")
            if (stdout or marker in stderr or b"masc_request_accepted" in stderr
                    or trailer["exit"] is not None or trailer["signal"] is not None
                    or trailer["timed_out"]):
                raise AssertionError(f"channel refusal emitted payload/acceptance/exit: {stdout!r}, {stderr!r}")
            if not isinstance(trailer["shim_error"], str) or not trailer["shim_error"].startswith(
                    "remote_ssh_shim_error: cannot prepare Observe notification channel: "):
                raise AssertionError(f"fixture missed the channel preparation boundary: {trailer!r}")
            after = set(root.iterdir())
            if after != before:
                raise AssertionError(f"channel refusal leaked scratch: before={before!r}, after={after!r}")
            records.append({"case": "Observe channel preparation refused before payload",
                            "socketpair_errno": fault_errno,
                            "stdin": "interactive" if interactive_stdin else "framed",
                            "filtered_probe": filtered_probe, "transport_exit": status,
                            "stdout_bytes": len(stdout), "scratch_cleaned": True,
                            "trailer": trailer})
    return records


class InteractiveRun:
    """Drive the real binary; the payload, pipes and receipts are not mocked."""

    def __init__(self, binary, root, config, argv, timeout_sec, mode="effect"):
        encode = lambda value: base64.b64encode(value.encode()).decode()
        request = {"v": 3, "argv": [encode(arg) for arg in argv], "env": [],
                   "cwd": encode(str(root)), "remote_root": encode(str(root)),
                   "timeout_sec": timeout_sec, "stdin_stream": True, "mode": mode}
        self.process = subprocess.Popen(
            [str(binary)], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
            stderr=subprocess.PIPE, bufsize=0,
            env=dict(os.environ, MASC_EXEC_SHIM_CONFIG=str(config)))
        assert self.process.stdin and self.process.stdout and self.process.stderr
        self.streams = {"stdout": self.process.stdout, "stderr": self.process.stderr}
        self.output = {"stdout": bytearray(), "stderr": bytearray()}
        self.pids = []
        payload = json.dumps(request).encode()
        try:
            self.send(struct.pack(">Q", len(payload)) + payload)
        except BaseException:
            self.cleanup()
            raise

    def pump(self, read_stdout=True):
        streams = [stream for name, stream in self.streams.items()
                   if read_stdout or name != "stdout"]
        readable, _, _ = select.select(streams, [], [], 0.05)
        for stream in readable:
            name = next(name for name, active in self.streams.items() if active is stream)
            chunk = os.read(stream.fileno(), 65536)
            if chunk:
                self.output[name].extend(chunk)
            else:
                del self.streams[name]

    def until(self, predicate, message, read_stdout=True):
        deadline = time.monotonic() + 15
        while not predicate():
            if time.monotonic() >= deadline:
                raise AssertionError(message)
            self.pump(read_stdout)

    def send(self, payload):
        fd = self.process.stdin.fileno()
        os.set_blocking(fd, False)
        deadline = time.monotonic() + 15
        while payload:
            try:
                count = os.write(fd, payload)
                payload = payload[count:]
            except BlockingIOError:
                if time.monotonic() >= deadline:
                    raise AssertionError("interactive host write did not progress")
                select.select([], [fd], [], 0.05)

    def take_stdout(self, count):
        self.until(lambda: len(self.output["stdout"]) >= count,
                   "the payload did not answer its input")
        result = bytes(self.output["stdout"][:count])
        del self.output["stdout"][:count]
        return result

    def ready_group(self):
        self.until(lambda: b"\n" in self.output["stdout"], "no child readiness handshake")
        line, _, remaining = self.output["stdout"].partition(b"\n")
        self.output["stdout"] = bytearray(remaining)
        tag, child, grandchild = line.split()
        if tag != b"READY":
            raise AssertionError(f"unexpected handshake: {line!r}")
        pids = [int(child), int(grandchild)]
        if [os.getpgid(pid) for pid in pids] != [pids[0], pids[0]]:
            raise AssertionError("the payload and grandchild do not share their owned process group")
        self.pids = pids

    def close_input(self):
        self.process.stdin.close()

    def finish(self):
        self.until(lambda: not self.streams, "shim output did not reach EOF")
        status = self.process.wait(timeout=5)
        return status, result_trailer(bytes(self.output["stderr"]))

    def cleanup(self):
        # Also cover failures before READY: only the shim's direct children
        # can be added here, and only their own process groups are killed.
        groups = set(self.pids[:1])
        children = Path(f"/proc/{self.process.pid}/task/{self.process.pid}/children")
        try:
            direct = [int(pid) for pid in children.read_text().split()]
        except FileNotFoundError:
            direct = []
        for pid in direct:
            try:
                if os.getpgid(pid) == pid:
                    groups.add(pid)
                os.kill(pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
        for pid in groups:
            try:
                # A group still owns grandchildren after its leader is reaped.
                os.killpg(pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
        if self.process.poll() is None:
            self.process.kill()
        self.process.wait(timeout=5)
        for stream in (self.process.stdin, self.process.stdout, self.process.stderr):
            stream.close()


@contextmanager
def interactive(binary, root, config, script, timeout_sec=30, mode="effect"):
    run = InteractiveRun(binary, root, config, [sys.executable, "-c", script], timeout_sec, mode)
    try:
        yield run
    finally:
        run.cleanup()


def process_state(pid):
    try:
        return Path(f"/proc/{pid}/stat").read_text().rsplit(")", 1)[1].split()[0]
    except FileNotFoundError:
        return None


def stopped_group(run, read_stdout=True):
    # A killed orphan can await PID1 reaping. Z proves it cannot execute;
    # it is recorded separately from disappearance, not called fully reaped.
    run.until(lambda: all(process_state(pid) in (None, "Z") for pid in run.pids),
              "cancel/timeout left a live child or grandchild", read_stdout)
    return [{"pid": pid, "state": process_state(pid)} for pid in run.pids]


def fill_input_pipe(run):
    fd = run.process.stdin.fileno()
    block = bytes(range(256)) * 256
    written = 0
    deadline = time.monotonic() + 10
    while time.monotonic() < deadline:
        try:
            written += os.write(fd, block)
        except BlockingIOError:
            if not select.select([], [fd], [], 0.1)[1]:
                return {"host_bytes_written": written, "host_stdin_writable": False}
    raise AssertionError("a child that never reads did not exert stdin backpressure")


def wait_full_stdout_pipe(run):
    fd = run.process.stdout.fileno()
    capacity = fcntl.fcntl(fd, fcntl.F_GETPIPE_SZ)
    pending = array.array("i", [0])

    def full():
        fcntl.ioctl(fd, termios.FIONREAD, pending, True)
        return pending[0] == capacity

    run.until(full, "payload output did not fill the unread host pipe", read_stdout=False)
    return {"host_stdout_capacity": capacity, "host_stdout_pending": pending[0]}


def applied_effect(trailer):
    expected = {"mode": "effect", "plan": "unrestricted", "boundary": "sandbox_applied"}
    if trailer["execution_receipt"] != expected:
        raise AssertionError(f"wrong execution boundary: {trailer!r}")


EXCHANGE = r'''
import hashlib, os, struct
def exact(count):
    data = b""
    while len(data) < count:
        chunk = os.read(0, count - len(data))
        if not chunk:
            raise RuntimeError("stdin ended before the dependent exchange")
        data += chunk
    return data
for _ in range(2):
    data = exact(struct.unpack(">I", exact(4))[0])
    answer = hashlib.sha256(data).digest() + data[::-1]
    packet = struct.pack(">I", len(answer)) + answer
    while packet:
        packet = packet[os.write(1, packet):]
os._exit(7)
'''

RESISTANT_GROUP = r'''
import os, signal
signal.signal(signal.SIGTERM, signal.SIG_IGN)
grandchild = os.fork()
if grandchild == 0:
    while True:
        signal.pause()
os.write(1, ("READY %d %d\n" % (os.getpid(), grandchild)).encode())
'''

OBSERVE_EXCHANGE = r'''
import errno, os, signal, socket
signal.signal(signal.SIGTERM, signal.SIG_DFL)
try:
    attempted = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
except OSError as error:
    if error.errno != errno.EPERM:
        raise
else:
    attempted.close()
    raise AssertionError("Observe allowed a real socket")
os.write(1, b"socket:EPERM\n")
data = b""
while len(data) < 4:
    chunk = os.read(0, 4 - len(data))
    if not chunk:
        raise RuntimeError("transport ended before the later input")
    data += chunk
os.write(1, b"read:" + data)
while True:
    signal.pause()
'''


def interactive_observe_case(binary, root, config):
    with interactive(binary, root, config, OBSERVE_EXCHANGE, mode="observe") as run:
        # No second socket notification is pending when this peer waits for
        # later input. A blocking second NOTIF_RECV would stall the supervisor
        # before either this response or the following input can be relayed.
        ready = b"socket:EPERM\n"
        if run.take_stdout(len(ready)) != ready:
            raise AssertionError("the actual Observe socket attempt did not return EPERM")
        later_input = b"a\x00\xffz"
        run.send(later_input)
        if run.take_stdout(5 + len(later_input)) != b"read:" + later_input:
            raise AssertionError("Observe stopped relaying after its first notification")
        run.close_input()
        status, trailer = run.finish()
        expected = {"mode": "observe", "plan": "filesystem_and_network_box",
                    "boundary": "sandbox_applied"}
        if (status != 0 or trailer["execution_receipt"] != expected
                or trailer["exit"] is not None or trailer["signal"] != signal.SIGTERM
                or trailer["timed_out"] or trailer["shim_error"] is not None):
            raise AssertionError(f"Observe EOF cancellation lost its real outcome: {status}, {trailer!r}")
        observed = trailer["observed_syscalls"]
        if len(observed) != 1 or type(observed[0]) is not int or observed[0] <= 0:
            raise AssertionError(f"the one actual socket attempt lost its notification: {trailer!r}")
        return {"case": "interactive Observe notification then dependent input and EOF",
                "transport_exit": status, "trailer": trailer}


def interactive_cases(binary, root, config):
    records = []
    with interactive(binary, root, config, EXCHANGE) as run:
        payload = bytes(range(256)) + b"\x00first\xff"
        for _ in range(2):
            run.send(struct.pack(">I", len(payload)) + payload)
            size = struct.unpack(">I", run.take_stdout(4))[0]
            if size != 32 + len(payload):
                raise AssertionError("the child changed the binary response length")
            answer = run.take_stdout(size)
            if answer != hashlib.sha256(payload).digest() + payload[::-1]:
                raise AssertionError("NUL/binary input or output changed in transit")
            # The second request cannot be sent until the first reply arrives.
            payload = answer + b"\x00dependent second\xff"
        status, trailer = run.finish()
        applied_effect(trailer)
        if (status != 0 or trailer["exit"] != 7 or trailer["signal"] is not None
                or trailer["timed_out"] or trailer["shim_error"] is not None):
            raise AssertionError(f"dependent exchange lost its real exit: {status}, {trailer!r}")
        records.append({"case": "interactive dependent binary exchanges", "trailer": trailer})
    for input_pressure, output_pressure, timed_out in [
            (False, False, False), (True, False, False),
            (True, True, False), (True, True, True)]:
        tail = ("while True:\n    os.write(1, b'\\x00\\xff' * 32768)\n" if output_pressure
                else "while True:\n    signal.pause()\n")
        with interactive(binary, root, config, RESISTANT_GROUP + tail,
                         timeout_sec=10 if timed_out else 30) as run:
            run.ready_group()
            pressure = wait_full_stdout_pipe(run) if output_pressure else {}
            if input_pressure:
                pressure.update(fill_input_pipe(run))
            if not timed_out:
                run.close_input()
            states = stopped_group(run, read_stdout=not output_pressure)
            if output_pressure:
                # Keep stdout full through the shim's own termination. A
                # bounded drain must disclose lost output, not report success.
                run.until(lambda: run.process.poll() is not None,
                          "shim blocked behind the unread host stdout", read_stdout=False)
            status, trailer = run.finish()
            applied_effect(trailer)
            if trailer["exit"] is not None or trailer["timed_out"] != timed_out:
                raise AssertionError(f"cancellation cause/exit was fabricated: {trailer!r}")
            if output_pressure:
                expected_error = "interactive_output_incomplete: output did not drain after child exit"
                if status != 1 or trailer["shim_error"] != expected_error or trailer["signal"] is not None:
                    raise AssertionError(f"incomplete output was reported as success: {status}, {trailer!r}")
            elif status != 0 or trailer["signal"] != signal.SIGKILL or trailer["shim_error"] is not None:
                raise AssertionError(f"drained EOF cancellation lost its real signal: {status}, {trailer!r}")
            records.append({"case": "interactive process-group cancellation",
                            "stdin_pressure": input_pressure, "stdout_pressure": output_pressure,
                            "timeout": timed_out, "pressure": pressure,
                            "stopped_processes": states, "transport_exit": status, "trailer": trailer})
    return records


def main():
    binary = Path(sys.argv[1]).resolve()
    fault_helper = Path(sys.argv[2]).resolve()
    probe = json.loads(subprocess.check_output([str(binary), "--probe"]))
    if "observe" not in probe["capabilities"]:
        raise AssertionError("Linux feature fixture requires actual Observe support")
    major = int(probe["version"].split(".")[0])
    records = []
    with tempfile.TemporaryDirectory(prefix="masc-shim-receipts-") as temporary:
        root = Path(temporary)
        config = root / "shim.conf"
        config.write_text(f"remote_root={root}\nscratch_root={root}\n")
        # The shim refuses a config its group or every user may write; set the
        # mode rather than leave it to the umask.
        config.chmod(0o644)
        cases = [
            ("effect", ["/bin/sh", "-c", "exit 127"], "sandbox_applied", "unrestricted", 127),
            ("observe", ["/bin/sh", "-c", "printf discard >/dev/null"],
             "sandbox_applied", "filesystem_and_network_box", 0),
            ("guest_local", ["/bin/sh", "-c", "printf guest >guest-output"],
             "sandbox_applied", "network_box", 0),
            ("observe", [str(root / "missing-executable")],
             "exec_failed", "filesystem_and_network_box", 127),
        ]
        for mode, argv, boundary, plan, expected_exit in cases:
            status, stdout, trailer, _ = call(binary, root, config, major, mode, argv)
            expected_receipt = {"mode": mode, "plan": plan, "boundary": boundary}
            if status != 0 or trailer["exit"] != expected_exit or trailer["execution_receipt"] != expected_receipt:
                raise AssertionError(f"receipt/status mismatch: {status}, {trailer!r}")
            if trailer["signal"] is not None or trailer["timed_out"] or trailer["shim_error"] is not None:
                raise AssertionError(f"unexpected transport outcome: {trailer!r}")
            records.append({"transport_exit": status, "stdout_bytes": len(stdout), "trailer": trailer})
        if (root / "guest-output").read_text() != "guest":
            raise AssertionError("Guest_local did not execute the fixture write")
        # The acceptance frame is the first thing on stderr, only when asked, and
        # it leaves the trailer where it was. The payload writes to stderr too, to
        # show the frame is ahead of payload bytes rather than merged into them.
        if "request_acceptance_frame" not in probe["capabilities"]:
            raise AssertionError("the shim does not advertise request_acceptance_frame")
        frame = b"\x1e" + json.dumps({"masc_request_accepted": {"v": major}},
                                       separators=(",", ":")).encode() + b"\x1e"
        argv = ["/bin/sh", "-c", "printf payload-err >&2; exit 3"]
        status, _, trailer, stderr = call(binary, root, config, major, "effect", argv,
                                          acceptance_frame=True)
        if status != 0 or trailer["exit"] != 3 or not stderr.startswith(frame + b"payload-err"):
            raise AssertionError(f"acceptance frame missing or misplaced: {status}, {stderr!r}")
        if stderr.count(frame) != 1:
            raise AssertionError(f"acceptance frame written more than once: {stderr!r}")
        status, _, trailer, stderr = call(binary, root, config, major, "effect", argv)
        if frame in stderr or not stderr.startswith(b"payload-err"):
            raise AssertionError(f"a request that did not ask got a frame: {stderr!r}")
        records.append({"acceptance_frame_first": True, "trailer": trailer})
        status, _, trailer, _ = call(binary, root, root / "missing-config", major, "observe", ["/bin/true"])
        if status != 1 or trailer["exit"] is not None or trailer["execution_receipt"] != {
                "mode": "observe", "plan": "filesystem_and_network_box", "boundary": "refused"}:
            raise AssertionError(f"pre-spawn refusal mislabeled as applied: {status}, {trailer!r}")
        records.append({"transport_exit": status, "boundary": trailer["execution_receipt"]})
        framed = bytes(range(256)) + b"\x00framed input\xff"
        status, stdout, trailer, _ = call(binary, root, config, major, "effect", ["/bin/cat"],
                                          framed_stdin=framed)
        applied_effect(trailer)
        if (status != 0 or stdout != framed or trailer["exit"] != 0
                or trailer["signal"] is not None or trailer["timed_out"]
                or trailer["shim_error"] is not None):
            raise AssertionError(f"framed input did not reach child EOF intact: {status}, {trailer!r}")
        records.append({"case": "framed binary input reaches EOF", "stdout_bytes": len(stdout),
                        "trailer": trailer})
        if major != 3 or "interactive_stdin" not in probe["capabilities"]:
            raise AssertionError("real shim must advertise V3 interactive_stdin before interactive requests")
        records.extend(interactive_cases(binary, root, config))
        records.append(interactive_observe_case(binary, root, config))
        records.extend(observe_channel_refusals(binary, fault_helper, root, config, major))
    print(json.dumps({"kind": "actual-shim-execution-receipts",
                      "binary_sha256": hashlib.sha256(binary.read_bytes()).hexdigest(),
                      "fault_helper_sha256": hashlib.sha256(fault_helper.read_bytes()).hexdigest(),
                      "records": records}, indent=2))


if __name__ == "__main__":
    main()
