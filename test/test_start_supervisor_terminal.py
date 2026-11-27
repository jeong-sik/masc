"""A server started from a terminal holds no terminal (RFC-0470 §4.2, #38700).

2026-09-24: a `masc start` run as a background job of a terminal stopped for
14 minutes. A Keeper's client opened /dev/tty to ask for a login; the kernel
stopped the whole process group with SIGTTIN, server included.

Each case starts start_supervisor_terminal_fixture.exe on a fresh
pseudo-terminal. In the `supervise` role it does what `masc start` does: with
a terminal it supervises a server started by Masc_server_lifecycle.start (the
same executable in its stand-in server role), and without one it says it
would serve. The stand-in server reports whether it has a terminal, lets a
child read /dev/tty, writes lines until SIGTERM and exits with 7.

A background case runs the fixture as a job of a stand-in shell: the pty's
session leader forks it into a process group of its own and waits, so the
job is not the terminal's foreground group. The control runs the stand-in
server without the supervisor, as #38700 found it, and expects it to stop.
"""
import enum
import os
import pty
import select
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import unittest


def split_binary(argv: list[str]) -> tuple[str, list[str]]:
    """The fixture path after --binary, and the arguments left for unittest."""
    if '--binary' not in argv[:-1]:
        raise SystemExit('usage: test_start_supervisor_terminal.py --binary FIXTURE [unittest args]')
    at = argv.index('--binary')
    return os.path.abspath(argv[at + 1]), argv[:at] + argv[at + 2:]


BINARY, REMAINING = split_binary(sys.argv[1:])

# Long enough for a loaded CI runner to spawn a few processes; a stopped
# group never finishes, so the bound is what turns a hang into a failure.
DEADLINE_SECONDS = 30
SERVER_EXIT_CODE = 7
# Any port: the stand-in server binds nothing. It names the output file.
PORT = 18931
# What the supervisor must not hold back while it is stopped (RFC-0470 §5.6):
# more than a pipe buffer.
STOPPED_GROWTH_BYTES = 64 * 1024

SUPERVISING = 'supervising'
SERVER_READY = 'server ready'
SERVER_NO_TERMINAL = 'server terminal: none'
SERVER_HAS_TERMINAL = 'server terminal: present'
CHILD_NO_TERMINAL = 'server child: no terminal'
SERVER_TERMINATED = 'server got SIGTERM'

# What an interactive shell gives the job it starts. The runner may hand this
# test some of them ignored (GNU timeout ignores SIGTTIN and SIGTTOU), and an
# ignored SIGTTIN turns the control's stop into a read error.
JOB_CONTROL_DEFAULTS = (signal.SIGTTIN, signal.SIGTTOU, signal.SIGTSTP, signal.SIGHUP,
                        signal.SIGINT, signal.SIGQUIT, signal.SIGTERM, signal.SIGPIPE)


class Role(enum.Enum):
    SUPERVISE = enum.auto()
    SERVE_HERE = enum.auto()


class Placement(enum.Enum):
    FOREGROUND = enum.auto()
    BACKGROUND = enum.auto()


def role_argv(role: Role, base: str) -> list[str]:
    match role:
        case Role.SUPERVISE:
            return ['supervise', base, str(PORT)]
        case Role.SERVE_HERE:
            return ['serve-here']


def exit_code(status: int) -> int:
    code = os.waitstatus_to_exitcode(status)
    return code if code >= 0 else 128 - code


def process_state(pid: int) -> str:
    result = subprocess.run(['ps', '-o', 'stat=', '-p', str(pid)],
                            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, check=False)
    return result.stdout.decode().strip()


def alive(pid: int) -> bool:
    """A process that exited but waits for its adopter to reap it is gone."""
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return not process_state(pid).startswith('Z')


def wait_gone(pid: int, deadline: float) -> bool:
    while alive(pid):
        if time.monotonic() >= deadline:
            return False
        time.sleep(0.05)
    return True


def run_job(argv: list[str], placement: Placement) -> None:
    """The pty's session leader: the fixture itself, or a shell that waits for it."""
    for number in JOB_CONTROL_DEFAULTS:
        signal.signal(number, signal.SIG_DFL)
    match placement:
        case Placement.FOREGROUND:
            os.execv(BINARY, argv)
        case Placement.BACKGROUND:
            job = os.fork()
            if job == 0:
                os.setpgid(0, 0)
                os.execv(BINARY, argv)
            try:
                os.setpgid(job, job)
            except OSError:
                pass  # the job already did it, or already exec'd
            os.write(1, 'job {}\n'.format(job).encode())
            _, status = os.waitpid(job, 0)
            os._exit(exit_code(status))


class Terminal:
    """The fixture on a fresh pty, as the foreground job or a background one."""

    def __init__(self, role: Role, placement: Placement) -> None:
        self.base = tempfile.mkdtemp(prefix='masc-start-supervisor-')
        self.output = b''
        self.status: int | None = None
        self.closed = False
        self.server: int | None = None
        argv = [BINARY] + role_argv(role, self.base)
        pid, master = pty.fork()
        if pid == 0:
            try:
                run_job(argv, placement)
            finally:
                os._exit(127)
        self.pid = pid
        self.master = master
        self.job: int | None = None
        match placement:
            case Placement.BACKGROUND:
                self.job = int(self.read_until_line('job '))
            case Placement.FOREGROUND:
                pass

    def background_job(self) -> int:
        if self.job is None:
            raise AssertionError('the fixture runs as the foreground job, not a background one')
        return self.job

    def server_pid(self) -> int:
        if self.server is None:
            raise AssertionError('the stand-in server has not said its pid:\n' + self.text()[-4000:])
        return self.server

    def text(self) -> str:
        return self.output.decode('utf-8', 'replace').replace('\r', '')

    def pump(self, timeout: float) -> bool:
        """Reads what the terminal has; False once it has nothing more to say."""
        if self.closed:
            return False
        if not select.select([self.master], [], [], timeout)[0]:
            return True
        try:
            chunk = os.read(self.master, 65536)
        except OSError:
            return False
        if not chunk:
            return False
        self.output += chunk
        return True

    def read_until(self, marker: str) -> str:
        deadline = time.monotonic() + DEADLINE_SECONDS
        while marker not in self.text():
            if time.monotonic() >= deadline or not self.pump(0.2):
                raise AssertionError('no {!r} on the terminal:\n{}'.format(marker, self.text()[-4000:]))
        return self.text()

    def read_until_line(self, prefix: str) -> str:
        text = self.read_until(prefix)
        rest = text[text.index(prefix) + len(prefix):]
        deadline = time.monotonic() + DEADLINE_SECONDS
        while '\n' not in rest and time.monotonic() < deadline:
            self.pump(0.2)
            text = self.text()
            rest = text[text.index(prefix) + len(prefix):]
        return rest.split('\n', 1)[0].strip()

    def read_server_pid(self) -> int:
        server = int(self.read_until_line('server pid '))
        self.server = server
        return server

    def wait(self) -> int:
        """Reads until the session leader exits; its exit code."""
        deadline = time.monotonic() + DEADLINE_SECONDS
        while self.status is None and time.monotonic() < deadline:
            finished, status = os.waitpid(self.pid, os.WNOHANG)
            if finished == self.pid:
                self.status = status
                break
            if not self.pump(0.1):
                time.sleep(0.05)
        while self.pump(0):
            pass
        if self.status is None:
            raise AssertionError('the fixture still runs at the deadline:\n' + self.text()[-4000:])
        return exit_code(self.status)

    def output_file(self) -> str:
        return os.path.join(self.base, '.masc', 'logs', 'masc-server-{}.log'.format(PORT))

    def close(self) -> None:
        if self.status is None:
            for group in (self.job, self.pid):
                if group is not None:
                    try:
                        os.killpg(group, signal.SIGKILL)
                    except OSError:
                        pass
            try:
                os.waitpid(self.pid, 0)
            except ChildProcessError:
                pass
        if self.server is not None and alive(self.server):
            try:
                os.killpg(self.server, signal.SIGKILL)
            except OSError:
                pass
        if not self.closed:
            os.close(self.master)
            self.closed = True
        shutil.rmtree(self.base, ignore_errors=True)


class SupervisedStart(unittest.TestCase):
    def start(self, placement: Placement) -> Terminal:
        terminal = Terminal(Role.SUPERVISE, placement)
        self.addCleanup(terminal.close)
        text = terminal.read_until(SERVER_READY)
        self.assertIn(SUPERVISING, text, text)
        terminal.read_server_pid()
        return terminal

    def test_a_background_start_leaves_the_server_no_terminal_to_stop_on(self) -> None:
        terminal = self.start(Placement.BACKGROUND)
        text = terminal.text()
        self.assertIn(SERVER_NO_TERMINAL, text, text)
        self.assertIn(CHILD_NO_TERMINAL, text, text)
        os.kill(terminal.background_job(), signal.SIGTERM)
        self.assertEqual(terminal.wait(), SERVER_EXIT_CODE, terminal.text())
        self.assertIn(SERVER_TERMINATED, terminal.text())

    def test_ctrl_c_stops_the_server_and_the_supervisor_ends_with_its_code(self) -> None:
        terminal = self.start(Placement.FOREGROUND)
        os.write(terminal.master, b'\x03')
        self.assertEqual(terminal.wait(), SERVER_EXIT_CODE, terminal.text())
        self.assertIn(SERVER_TERMINATED, terminal.text())
        self.assertFalse(alive(terminal.server_pid()))

    def test_closing_the_terminal_stops_the_server(self) -> None:
        terminal = self.start(Placement.FOREGROUND)
        os.close(terminal.master)
        terminal.closed = True
        self.assertEqual(terminal.wait(), SERVER_EXIT_CODE)
        self.assertFalse(alive(terminal.server_pid()))

    def test_a_stopped_supervisor_does_not_stop_the_server(self) -> None:
        terminal = self.start(Placement.BACKGROUND)
        job = terminal.background_job()
        os.kill(job, signal.SIGTSTP)
        deadline = time.monotonic() + DEADLINE_SECONDS
        while not process_state(job).startswith('T'):
            self.assertLess(time.monotonic(), deadline, 'the supervisor did not stop')
            time.sleep(0.05)
        stopped_at = os.path.getsize(terminal.output_file())
        while os.path.getsize(terminal.output_file()) < stopped_at + STOPPED_GROWTH_BYTES:
            self.assertLess(time.monotonic(), deadline,
                            'the server stopped writing while its supervisor was stopped')
            terminal.pump(0.05)
        self.assertTrue(process_state(job).startswith('T'))
        os.kill(job, signal.SIGCONT)
        os.kill(job, signal.SIGTERM)
        self.assertEqual(terminal.wait(), SERVER_EXIT_CODE, terminal.text()[-4000:])
        self.assertIn(SERVER_TERMINATED, terminal.text())

    def test_a_killed_supervisor_leaves_the_server_writing(self) -> None:
        terminal = self.start(Placement.BACKGROUND)
        server = terminal.server_pid()
        os.kill(terminal.background_job(), signal.SIGKILL)
        self.assertEqual(terminal.wait(), 128 + signal.SIGKILL)
        self.assertTrue(alive(server))
        size = os.path.getsize(terminal.output_file())
        deadline = time.monotonic() + DEADLINE_SECONDS
        while os.path.getsize(terminal.output_file()) <= size:
            self.assertLess(time.monotonic(), deadline, 'the server stopped writing')
            time.sleep(0.05)
        os.kill(server, signal.SIGTERM)
        self.assertTrue(wait_gone(server, time.monotonic() + DEADLINE_SECONDS))


class WithoutTerminal(unittest.TestCase):
    def test_a_start_with_no_terminal_serves_itself(self) -> None:
        base = tempfile.mkdtemp(prefix='masc-start-supervisor-')
        self.addCleanup(shutil.rmtree, base, True)
        result = subprocess.run([BINARY] + role_argv(Role.SUPERVISE, base), stdin=subprocess.DEVNULL,
                                stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                start_new_session=True, timeout=DEADLINE_SECONDS, check=False)
        output = result.stdout.decode('utf-8', 'replace')
        self.assertEqual(result.returncode, 0, output)
        self.assertIn('no terminal: serving here', output)


class Control(unittest.TestCase):
    """Without the supervisor the same child stops the whole group (#38700)."""

    def test_an_undetached_server_stops_when_its_child_reads_the_terminal(self) -> None:
        terminal = Terminal(Role.SERVE_HERE, Placement.BACKGROUND)
        self.addCleanup(terminal.close)
        text = terminal.read_until(SERVER_HAS_TERMINAL)
        self.assertNotIn(SERVER_READY, text)
        job = terminal.background_job()
        deadline = time.monotonic() + DEADLINE_SECONDS
        while not process_state(job).startswith('T'):
            terminal.pump(0.05)
            self.assertLess(time.monotonic(), deadline,
                            'the control did not stop; the harness cannot show the defect:\n'
                            + terminal.text())
        self.assertNotIn(SERVER_READY, terminal.text())


if __name__ == '__main__':
    unittest.main(argv=[sys.argv[0]] + REMAINING)
