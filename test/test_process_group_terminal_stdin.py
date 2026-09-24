"""A child masc starts does not reach the terminal masc was started from.

2026-09-15: `masc setup` run in a terminal lost every Claude Code verification.
The verification child was placed in its own process group, a background job
of the operator's terminal, with that terminal as stdin; its first read of it
stopped it with SIGTTIN and the group owner then SIGKILLed the stopped leader
before it wrote its report. Run without a terminal, the same setup passed.

2026-09-24: `masc start`, run as a background job of a terminal, stopped with
all nine of its official-client children for fourteen minutes. One of them,
agy, could not refresh its login token, opened /dev/tty for an interactive
login, and the kernel stopped the process group it shared with the server.

Each case starts the fixture as the foreground job of a fresh pseudo-terminal,
so the fixture has a controlling terminal and its stdin is that terminal. The
fixture starts a shell through one of masc's spawn paths. A shell that reads
stdin must reach end of input and exit; a shell that opens /dev/tty must be
refused, because the child is in a session of its own.
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
# Opening the terminal needs no read, so this shell ends either way; it only
# reports whether the open succeeded.
TERMINAL_OPENER = ['/bin/sh', '-c',
                   'if (exec 3</dev/tty) 2>/dev/null; then echo opened-the-terminal; else echo no-terminal; fi']
PARENT_HAS_TERMINAL = 'parent opens its terminal'
SPAWN_PATHS = ('mgr', 'eio', 'unix')


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


def run_under_terminal(mode, command):
    pid, master = pty.fork()
    if pid == 0:
        try:
            os.execv(args.binary, [args.binary, mode] + command)
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
            output += b'\n<fixture still running at the deadline>'
        os.close(master)
    return output.decode('utf-8', 'replace').replace('\r', '')


class TerminalStdin(unittest.TestCase):
    def check_mode(self, mode):
        output = run_under_terminal(mode, READER)
        self.assertIn('exited 0 end-of-input', output,
                      '{} runner: the child did not reach end of input:\n{}'.format(mode, output))

    def test_the_eio_runner_gives_its_child_no_terminal(self):
        self.check_mode('eio')

    def test_the_unix_fallback_gives_its_child_no_terminal(self):
        self.check_mode('unix')

    def test_the_server_manager_gives_its_child_no_terminal(self):
        self.check_mode('mgr')


class ControllingTerminal(unittest.TestCase):
    def test_no_spawn_path_lets_its_child_open_the_terminal(self):
        for mode in SPAWN_PATHS:
            with self.subTest(spawn_path=mode):
                output = run_under_terminal(mode, TERMINAL_OPENER)
                self.assertIn(PARENT_HAS_TERMINAL, output,
                              '{}: the fixture had no terminal, so this case proves nothing:\n{}'
                              .format(mode, output))
                self.assertIn('exited 0 no-terminal', output,
                              '{}: the child opened the terminal masc was started from:\n{}'
                              .format(mode, output))


if __name__ == '__main__':
    unittest.main(argv=[sys.argv[0]] + remaining)
