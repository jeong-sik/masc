"""Real owned processes; no Dune build or host argv inspection."""

import ctypes
import errno
import fcntl
import json
import os
from pathlib import Path
import shlex
import signal
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch

CI = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(CI))
import owned_process as owned  # noqa: E402 - exercise scripts without packaging them
import command_observer  # noqa: E402

RUNNER = CI.parent / "ci-run-tests.sh"
FIXTURE = """
import json,os,signal,sys,time
path,mode=sys.argv[1:]
pids={"root":os.getsid(0)}
def save():
    with open(path,"w") as output: json.dump(pids,output)
def worker(key,ignore=True):
    read,write=os.pipe()
    pid=os.fork()
    if pid==0:
        os.close(read)
        if mode!="escape": os.setpgid(0,0)
        signal.signal(signal.SIGTERM,signal.SIG_IGN if ignore else signal.SIG_DFL)
        if mode=="cleanup":
            signal.signal(signal.SIGTERM,lambda *_: open(path+".term","w").close())
        if mode=="escape":
            def escape(*_):
                os.setsid()
                open(path+".escape","w").close()
            signal.signal(signal.SIGUSR1,escape)
        os.write(write,b"r");os.close(write)
        signal.alarm(30)
        while True: signal.pause()
    os.close(write);os.read(read,1);os.close(read)
    pids[key]=pid;save()
worker("worker",mode!="cooperative")
if mode in ("normal","cleanup"): sys.exit(0)
cancelled=False
def cancel(*_):
    global cancelled
    cancelled=True
signal.signal(signal.SIGTERM,cancel)
save()
while not cancelled: time.sleep(.01)
if mode=="birth": worker("late")
sys.exit(0)
"""


def await_pids(path, process=None):
    deadline = time.monotonic() + 10
    while time.monotonic() < deadline:
        try:
            value = json.loads(path.read_text())
            if "worker" in value:
                return value
        except (FileNotFoundError, json.JSONDecodeError):
            pass
        if process is not None and process.poll() is not None:
            raise AssertionError("observer exited before fixture readiness")
        time.sleep(0.01)
    raise AssertionError("owned fixture did not become ready")


def await_file(path):
    deadline = time.monotonic() + 10
    while time.monotonic() < deadline:
        if path.exists():
            return
        time.sleep(0.01)
    raise AssertionError(f"owned fixture did not create {path.name}")


class ProcessOwnership(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.fixture = self.root / "fixture.py"
        self.fixture.write_text(FIXTURE)
        self.marker = self.root / "pids.json"
        self.env = dict(
            os.environ,
            CI_TEST_LOG_FILE=str(self.root / "observer.log"),
            CI_TEST_START_EPOCH=str(int(time.time())),
            CI_TEST_TIMEOUT_SEC="0",
            CI_TEST_TIMEOUT_GRACE_SEC="1",
            CI_TEST_HEARTBEAT_SEC="30",
            CI_TEST_DISK_MIN_AVAILABLE_MB="0",
            CI_TEST_DISK_CHECK_SEC="10",
            CI_CONTRACT_HARNESS_ENABLED="0",
            DUNE_SOURCEROOT=str(self.root),
        )
        self.capture = owned.native_capture()

    def tearDown(self):
        self.temp.cleanup()

    def command(self, mode):
        return shlex.join([sys.executable, str(self.fixture), str(self.marker), mode])

    def start(self, command, env=None):
        return subprocess.Popen(
            ["bash", str(RUNNER), command],
            cwd=self.root,
            env=env or self.env,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
        )

    def assert_dead(self, pid):
        state = owned.process_states().get(pid)
        self.assertTrue(state is None or state.startswith("Z"), (pid, state))

    def test_term_cleans_separate_groups_and_worker_born_during_cancel(self):
        peer = subprocess.Popen(["/bin/sleep", "30"], start_new_session=True)
        observer = self.start(self.command("birth"))
        handles = []
        try:
            pids = await_pids(self.marker, observer)
            self.assertEqual(os.getsid(pids["worker"]), pids["root"])
            self.assertNotEqual(os.getpgid(pids["worker"]), pids["root"])
            handles.append(self.capture(pids["worker"]))
            observer.send_signal(signal.SIGTERM)
            output, _ = observer.communicate(timeout=15)
            self.assertEqual(observer.returncode, 143, output[-2000:])
            final = json.loads(self.marker.read_text())
            self.assertIn("late", final)
            for key in ("worker", "late"):
                self.assert_dead(final[key])
            self.assertIsNone(peer.poll())
            self.assertNotIn("cleanup_unconfirmed", output[-2000:])
        finally:
            if observer.poll() is None:
                observer.terminate()
                observer.wait(timeout=10)
            for handle in handles:
                try:
                    handle.send(signal.SIGKILL)
                except ProcessLookupError:
                    pass
                handle.close()
            peer.terminate()
            peer.wait(timeout=5)

    def test_normal_root_exit_cleans_remaining_other_group(self):
        observer = self.start(self.command("normal"))
        output, _ = observer.communicate(timeout=15)
        self.assertEqual(observer.returncode, 0, output[-2000:])
        self.assert_dead(await_pids(self.marker)["worker"])

    def test_timeout_and_interrupt_preserve_authoritative_status(self):
        for cause, expected in [("timeout", 124), ("interrupt", 130)]:
            with self.subTest(cause=cause):
                if self.marker.exists():
                    self.marker.unlink()
                env = dict(
                    self.env, CI_TEST_TIMEOUT_SEC="1" if cause == "timeout" else "0"
                )
                observer = self.start(self.command("cooperative"), env)
                await_pids(self.marker, observer)
                if cause == "interrupt":
                    observer.send_signal(signal.SIGINT)
                output, _ = observer.communicate(timeout=15)
                self.assertEqual(observer.returncode, expected, output[-2000:])
                self.assert_dead(await_pids(self.marker)["worker"])

    def test_repeated_cancellation_during_cleanup_preserves_first_signal(self):
        env = dict(self.env, CI_TEST_TIMEOUT_GRACE_SEC="2")
        observer = self.start(self.command("cleanup"), env)
        try:
            pids = await_pids(self.marker, observer)
            await_file(Path(str(self.marker) + ".term"))
            observer.send_signal(signal.SIGINT)
            time.sleep(0.05)
            observer.send_signal(signal.SIGTERM)
            output, _ = observer.communicate(timeout=15)
            self.assertEqual(observer.returncode, 130, output[-2000:])
            self.assert_dead(pids["worker"])
        finally:
            if observer.poll() is None:
                observer.terminate()
                observer.wait(timeout=10)

    def test_harness_has_independent_session_and_preserves_foreground_bytes(self):
        harness_marker = self.root / "harness-session"
        payload = "owned-log-payload:" + "x" * 150000
        harness = self.root / "harness.py"
        harness.write_text(
            "import json,os,sys\n"
            f"sys.path.insert(0,{str(CI)!r})\nimport owned_process\n"
            f"pids=json.load(open({str(self.marker)!r}))\n"
            'assert os.getsid(0)!=pids["root"]\n'
            'state=owned_process.process_states().get(pids["worker"])\n'
            'assert state is None or state.startswith("Z")\n'
            f'open({str(harness_marker)!r},"w").write(str(os.getsid(0)))\n'
            f"sys.stdout.write({payload!r})\n"
            'print("owned-stderr-marker",file=sys.stderr)\n'
            "sys.exit(23)\n"
        )
        env = dict(
            self.env,
            CI_CONTRACT_HARNESS_ENABLED="1",
            CI_CONTRACT_HARNESS_CMD=shlex.join([sys.executable, str(harness)]),
        )
        observer = self.start(self.command("normal"), env)
        output, _ = observer.communicate(timeout=15)
        self.assertEqual(observer.returncode, 23, output[-2000:])
        self.assertTrue(harness_marker.exists())
        # Nonzero diagnostics also print the existing log tail. The complete
        # command payload must reach the foreground and occur once in storage.
        self.assertIn(payload, output)
        log = Path(env["CI_TEST_LOG_FILE"]).read_text()
        self.assertEqual(log.count(payload), 1)
        self.assertIn("owned-stderr-marker", output)
        self.assertEqual(log.count("cleanup_observation=no_live_session_members"), 2)

    def test_monitor_failure_finalizer_reaches_other_group_before_reaping(self):
        with open(self.root / "fixture.log", "wb") as output:
            owner = owned.OwnedSession(self.command("cooperative"), output)
            pids = await_pids(self.marker)
            owner.observe()

            def failed_tick():
                raise RuntimeError("fixture cleanup monitor failed")

            with self.assertRaisesRegex(RuntimeError, "fixture cleanup monitor failed"):
                owner.finish(1, failed_tick)
            self.assertTrue(owner.reaped)
            self.assertIsNotNone(owner.root.returncode)
            deadline = time.monotonic() + 5
            while time.monotonic() < deadline:
                state = owned.process_states().get(pids["worker"])
                if state is None or state.startswith("Z"):
                    break
                time.sleep(0.01)
            self.assert_dead(pids["worker"])

    def test_diagnostic_failure_preserves_known_command_and_timeout_status(self):
        previous = {
            number: signal.getsignal(number)
            for number in (signal.SIGINT, signal.SIGTERM)
        }
        try:
            for command, timeout, expected in (
                ("exit 23", "0", 23),
                (self.command("cooperative"), "1", 124),
            ):
                with self.subTest(expected=expected):
                    env = dict(self.env, CI_TEST_TIMEOUT_SEC=timeout)
                    with (
                        patch.dict(os.environ, env),
                        patch.object(sys, "argv", ["command_observer.py", command, ""]),
                        patch.object(
                            command_observer.subprocess,
                            "run",
                            side_effect=OSError("fixture diagnostics unavailable"),
                        ),
                    ):
                        self.assertEqual(command_observer.main(), expected)
        finally:
            for number, handler in previous.items():
                signal.signal(number, handler)

    def test_group_denial_returns_unconfirmed_before_live_root_natural_exit(self):
        root_marker = self.root / "live-root"
        script = self.root / "live-root.py"
        script.write_text(
            f'import time\nopen({str(root_marker)!r},"w").close()\ntime.sleep(8)\n'
        )
        command = "exec " + shlex.join([sys.executable, str(script)])
        owners, handles = [], []
        real_owner = owned.OwnedSession

        def factory(command, output):
            owner = real_owner(command, output)
            owners.append(owner)
            await_file(root_marker)
            handles.append(self.capture(owner.pid))
            return owner

        env = dict(self.env, CI_TEST_TIMEOUT_SEC="1", CI_TEST_TIMEOUT_GRACE_SEC="0")
        try:
            with (
                patch.dict(os.environ, env),
                patch.object(command_observer, "OwnedSession", factory),
                patch.object(
                    owned.os,
                    "killpg",
                    side_effect=PermissionError(
                        errno.EPERM, "fixture group signal denied"
                    ),
                ),
            ):
                observer = command_observer.Observer()
                try:
                    with patch.object(observer, "diagnostics"):
                        self.assertEqual(observer.run(command), 124)
                finally:
                    observer.close()
            owner = owners[0]
            self.assertIsNone(owner.terminal_status())
            self.assertFalse(owner.reaped)
            self.assertTrue(owner.signaling_ended)
            self.assertIn("root_unsettled", owner.uncertainty)
            with self.assertRaises(RuntimeError):
                owner.group_signal(signal.SIGTERM)
        finally:
            for handle in handles:
                try:
                    handle.send(signal.SIGKILL)
                except ProcessLookupError:
                    pass
                handle.close()
            for owner in owners:
                owner.root.wait(timeout=10)

    def test_observed_session_escape_is_explicit_and_still_uses_retained_handle(self):
        with open(self.root / "fixture.log", "wb") as output:
            owner = owned.OwnedSession(self.command("escape"), output)
            try:
                pids = await_pids(self.marker)
                owner.observe()
                owner.handles[pids["worker"]].send(signal.SIGUSR1)
                await_file(Path(str(self.marker) + ".escape"))
                owner.observe()
                self.assertIn("observed_session_escape", owner.uncertainty)
            finally:
                owner.finish(1)
            self.assert_dead(pids["worker"])

    def test_stale_handle_and_wrong_identity_never_signal_peer(self):
        child = subprocess.Popen(["/bin/sleep", "30"])
        peer = subprocess.Popen(["/bin/sleep", "30"])
        handle = self.capture(child.pid)
        peer_handle = self.capture(peer.pid)
        try:
            handle.send(signal.SIGTERM)
            child.wait(timeout=5)
            with self.assertRaises(ProcessLookupError):
                handle.send(signal.SIGTERM)
            if isinstance(peer_handle, owned.AuditTokenHandle):
                wrong = (ctypes.c_uint32 * 8)(*peer_handle.token)
                wrong[7] = (wrong[7] + 1) & 0xFFFFFFFF
                invalid = owned.AuditTokenHandle(peer_handle.native, peer.pid, wrong)
                with self.assertRaises(ProcessLookupError):
                    invalid.send(signal.SIGTERM)
            self.assertIsNone(peer.poll())
        finally:
            if child.poll() is None:
                child.terminate()
                child.wait(timeout=5)
            peer_handle.send(signal.SIGTERM)
            peer.wait(timeout=5)
            handle.close()
            peer_handle.close()

    def test_liveness_poll_supports_fd_above_select_boundary(self):
        # This exercises the real high-fd event primitive, not Linux pidfd
        # syscalls: those still require a Linux execution receipt.
        read, write = os.pipe()
        try:
            high = fcntl.fcntl(read, fcntl.F_DUPFD_CLOEXEC, 1024)
        except OSError as error:
            os.close(read)
            os.close(write)
            if error.errno in (errno.EMFILE, errno.EINVAL):
                self.skipTest("process fd limit prevents exercising select boundary")
            raise
        os.close(read)
        handle = object.__new__(owned.PidfdHandle)
        handle.fd = high
        try:
            self.assertTrue(handle.same_process())
            os.write(write, b"ready")
            self.assertFalse(handle.same_process())
        finally:
            handle.close()
            os.close(write)

    def test_acquisition_denial_reports_unconfirmed_instead_of_numeric_fallback(self):
        captured = {}

        def denied(pid):
            if pid not in captured:
                captured[pid] = self.capture(pid)
            raise PermissionError(errno.EACCES, "fixture denied process identity")

        real_owner = owned.OwnedSession

        def factory(command, output):
            return real_owner(command, output, capture=denied)

        try:
            with (
                patch.dict(os.environ, self.env),
                patch.object(command_observer, "OwnedSession", factory),
            ):
                observer = command_observer.Observer()
                try:
                    status = observer.run(self.command("normal"))
                finally:
                    observer.close()
            self.assertEqual(status, 125)
            self.assertTrue(captured)
            self.assertIn(
                "cleanup_unconfirmed", Path(self.env["CI_TEST_LOG_FILE"]).read_text()
            )
            # The denied separate group remains alive: there was no raw PID
            # fallback. This test owns a separately captured handle to clean it.
            self.assertTrue(any(handle.same_process() for handle in captured.values()))
        finally:
            for handle in captured.values():
                try:
                    handle.send(signal.SIGKILL)
                except ProcessLookupError:
                    pass
                handle.close()


if __name__ == "__main__":
    unittest.main()
