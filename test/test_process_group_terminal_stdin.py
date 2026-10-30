"""A spawned child does not read a terminal passed as stdin.

2026-09-15: `masc setup` run in a terminal lost every Claude Code verification.
The verification child was placed in its own process group, a background job
of the operator's terminal, with that terminal as stdin; its first read of it
stopped it with SIGTTIN and the group owner then SIGKILLed the stopped leader
before it wrote its report. Run without a terminal, the same setup passed.

Each case starts the fixture on a fresh pseudo-terminal, so the fixture has a
controlling terminal. The stdin cases run it as the terminal's foreground job
with the terminal as its stdin; the child's shell must reach end of input.
The manager case also verifies that foreground Ctrl+C can still stop the
fixture and its child. A background server's explicit /dev/tty access is a
separate RFC-0470 supervisor problem.
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
READER = ['/bin/sh', '-c', 'if IFS= read -r line; then echo "read:$line"; else echo end-of-input; fi']
PARENT_HAS_TERMINAL = 'parent opens its terminal'
FIXTURE_STILL_RUNNING = '<fixture still running at the deadline>'
CHILD_RUNNING = 'fixture child running'


def reaped_by(pid, deadline):
    # The terminal reports end of output a moment before the fixture's exit
    # can be waited for. Killing it in that moment signals a group that holds
    # only a zombie, which Darwin refuses with EPERM.
    while True:
        finished, status = os.waitpid(pid, os.WNOHANG)
        if finished == pid:
            return status
        if time.monotonic() >= deadline:
            return None
        time.sleep(0.05)


def run_under_terminal(mode, command, interrupt=False):
    pid, master = pty.fork()
    if pid == 0:
        try:
            os.execv(args.binary, [args.binary, mode] + command)
        finally:
            os._exit(127)
    output = b''
    deadline = time.monotonic() + DEADLINE_SECONDS
    status = None
    interrupted = False
    try:
        while time.monotonic() < deadline:
            ready, _, _ = select.select([master], [], [], 0.5)
            if not ready:
                finished, wait_status = os.waitpid(pid, os.WNOHANG)
                if finished == pid:
                    status = wait_status
                    break
                continue
            try:
                chunk = os.read(master, 65536)
            except OSError:
                break
            if not chunk:
                break
            output += chunk
            if interrupt and not interrupted and CHILD_RUNNING.encode() in output:
                os.write(master, b'\x03')
                interrupted = True
    finally:
        if status is None:
            status = reaped_by(pid, deadline)
        if status is None:
            os.killpg(pid, signal.SIGKILL)
            _, status = os.waitpid(pid, 0)
            output += ('\n' + FIXTURE_STILL_RUNNING).encode()
        os.close(master)
    return output.decode('utf-8', 'replace').replace('\r', ''), status, interrupted


class TerminalStdin(unittest.TestCase):
    def check_mode(self, mode):
        output, _, _ = run_under_terminal(mode, READER)
        self.assertIn(PARENT_HAS_TERMINAL, output, output)
        self.assertNotIn(FIXTURE_STILL_RUNNING, output, output)
        self.assertIn('exited 0 end-of-input', output,
                      '{} runner: the child did not reach end of input:\n{}'.format(mode, output))

    def test_the_eio_runner_gives_its_child_no_terminal(self):
        self.check_mode('eio')

    def test_the_unix_fallback_gives_its_child_no_terminal(self):
        self.check_mode('unix')

    def test_the_server_manager_gives_its_child_no_terminal(self):
        self.check_mode('mgr')


    def test_foreground_ctrl_c_still_ends_the_manager_group(self):
        output, status, interrupted = run_under_terminal(
            'mgr', ['/bin/sh', '-c', 'sleep 30'], interrupt=True)
        self.assertTrue(interrupted, output)
        self.assertNotIn(FIXTURE_STILL_RUNNING, output, output)
        self.assertIsNotNone(status, output)
        self.assertTrue('signaled' in output or os.WIFSIGNALED(status), output)


if __name__ == '__main__':
    unittest.main(argv=[sys.argv[0]] + remaining)
