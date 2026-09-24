"""A child masc starts is not stopped by, and does not read, the terminal.

2026-09-15: `masc setup` run in a terminal lost every Claude Code verification.
The verification child was placed in its own process group, a background job
of the operator's terminal, with that terminal as stdin; its first read of it
stopped it with SIGTTIN and the group owner then SIGKILLed the stopped leader
before it wrote its report. Run without a terminal, the same setup passed.

2026-09-24: `masc start`, run as a background job of a terminal, stopped with
all nine of its official-client children for fourteen minutes. One of them,
agy, could not refresh its login token and opened /dev/tty for an interactive
login. The kernel then stopped the process group it shared with the server.

Each case starts the fixture on a fresh pseudo-terminal, so the fixture has a
controlling terminal. The stdin cases run it as the terminal's foreground job
with the terminal as its stdin; the child's shell must reach end of input.
The background case runs it the way `masc start &` runs, and its child sets
the terminal and reads it through /dev/tty; the group must not stop.
"""
import argparse
import os
import pty
import select
import signal
import sys
import time
import unittest

parser = argparse.ArgumentParser()
parser.add_argument('--binary', required=True)
args, remaining = parser.parse_known_args()

# Long enough for a loaded CI runner to spawn two processes; a stopped child
# never finishes, so the bound is what turns a hang into a failure.
DEADLINE_SECONDS = 30
# The background job's own bound, inside the terminal's, so the launcher can
# still say what happened before the terminal is closed on it.
JOB_DEADLINE_SECONDS = 20
READER = ['/bin/sh', '-c', 'if IFS= read -r line; then echo "read:$line"; else echo end-of-input; fi']
# Rewrites the terminal's settings unchanged, then reads it, the way a CLI's
# login prompt does. As a background job with the default dispositions, the
# first stops the whole group with SIGTTOU and the second with SIGTTIN. It
# calls tcsetattr itself because /bin/stty sets SIGTTOU back to its default,
# so stty is stopped by the terminal whatever its parent ignores.
TERMINAL_TOUCHER = [sys.executable, '-c', '''
import os, termios
fd = os.open("/dev/tty", os.O_RDWR)
termios.tcsetattr(fd, termios.TCSANOW, termios.tcgetattr(fd))
print("set-the-terminal", flush=True)
try:
    os.read(fd, 1)
    print("read-a-line")
except OSError as error:
    print("read-refused", error.errno)
''']
PARENT_HAS_TERMINAL = 'parent opens its terminal'
BACKGROUND_PREMISE = 'the fixture is a background job of the terminal'
FIXTURE_STILL_RUNNING = '<fixture still running at the deadline>'
JOB_STILL_RUNNING = '<background job still running at its deadline>'


def reaped_by(pid, deadline):
    # The terminal reports end of output a moment before the fixture's exit
    # can be waited for. Killing it in that moment signals a group that holds
    # only a zombie, which Darwin refuses with EPERM.
    while True:
        if os.waitpid(pid, os.WNOHANG) != (0, 0):
            return True
        if time.monotonic() >= deadline:
            return False
        time.sleep(0.05)


def launch_background_job(argv):
    # Runs in the terminal's session leader, which stays the foreground job.
    job = os.fork()
    if job == 0:
        os.setpgid(0, 0)
        os.execv(argv[0], argv)
    try:
        os.setpgid(job, job)
    except PermissionError:
        pass  # EACCES: the job already moved itself and called exec
    if os.getpgid(job) != os.tcgetpgrp(1):
        print(BACKGROUND_PREMISE, flush=True)
    if not reaped_by(job, time.monotonic() + JOB_DEADLINE_SECONDS):
        os.killpg(job, signal.SIGKILL)
        os.waitpid(job, 0)
        print(JOB_STILL_RUNNING, flush=True)


def run_under_terminal(mode, command, background=False):
    pid, master = pty.fork()
    if pid == 0:
        try:
            argv = [args.binary, mode] + command
            if background:
                launch_background_job(argv)
                os._exit(0)
            os.execv(args.binary, argv)
        finally:
            os._exit(127)
    output = b''
    deadline = time.monotonic() + DEADLINE_SECONDS
    try:
        while time.monotonic() < deadline:
            ready, _, _ = select.select([master], [], [], 0.5)
            if not ready:
                if os.waitpid(pid, os.WNOHANG) != (0, 0):
                    pid = 0
                    break
                continue
            try:
                chunk = os.read(master, 65536)
            except OSError:
                break
            if not chunk:
                break
            output += chunk
    finally:
        if pid and not reaped_by(pid, deadline):
            os.killpg(pid, signal.SIGKILL)
            os.waitpid(pid, 0)
            output += ('\n' + FIXTURE_STILL_RUNNING).encode()
        os.close(master)
    return output.decode('utf-8', 'replace').replace('\r', '')


class TerminalStdin(unittest.TestCase):
    def check_mode(self, mode):
        output = run_under_terminal(mode, READER)
        self.assertNotIn(FIXTURE_STILL_RUNNING, output, output)
        self.assertIn('exited 0 end-of-input', output,
                      '{} runner: the child did not reach end of input:\n{}'.format(mode, output))

    def test_the_eio_runner_gives_its_child_no_terminal(self):
        self.check_mode('eio')

    def test_the_unix_fallback_gives_its_child_no_terminal(self):
        self.check_mode('unix')

    def test_the_server_manager_gives_its_child_no_terminal(self):
        self.check_mode('mgr')


class BackgroundServer(unittest.TestCase):
    def test_a_child_touching_the_terminal_does_not_stop_the_server_group(self):
        output = run_under_terminal('server', TERMINAL_TOUCHER, background=True)
        self.assertIn(BACKGROUND_PREMISE, output,
                      'the fixture did not run as a background job, so this case proves nothing:\n'
                      + output)
        self.assertIn(PARENT_HAS_TERMINAL, output, output)
        self.assertNotIn(JOB_STILL_RUNNING, output,
                         'the terminal stopped the server group:\n' + output)
        self.assertNotIn(FIXTURE_STILL_RUNNING, output, output)
        self.assertIn('set-the-terminal', output, output)
        self.assertIn('read-refused', output, output)


if __name__ == '__main__':
    unittest.main(argv=[sys.argv[0]] + remaining)
