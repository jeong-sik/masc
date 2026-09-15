"""A child masc moves into its own process group does not inherit the terminal.

2026-09-15: `masc setup` run in a terminal lost every Claude Code verification.
The verification child was placed in its own process group, a background job
of the operator's terminal, with that terminal as stdin; its first read of it
stopped it with SIGTTIN and the group owner then SIGKILLed the stopped leader
before it wrote its report. Run without a terminal, the same setup passed.

Each case starts the fixture as the foreground job of a fresh pseudo-terminal,
so the fixture's stdin is that terminal, and has it run a shell that reads
stdin. The shell must reach end of input and exit, under both of the process
runner's spawn paths.
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


def run_under_terminal(mode):
    pid, master = pty.fork()
    if pid == 0:
        try:
            os.execv(args.binary, [args.binary, mode] + READER)
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
        if pid:
            if os.waitpid(pid, os.WNOHANG) == (0, 0):
                os.killpg(pid, signal.SIGKILL)
                os.waitpid(pid, 0)
                output += b'\n<fixture still running at the deadline>'
        os.close(master)
    return output.decode('utf-8', 'replace').replace('\r', '')


class TerminalStdin(unittest.TestCase):
    def check_mode(self, mode):
        output = run_under_terminal(mode)
        self.assertIn('exited 0 end-of-input', output,
                      '{} runner: the child did not reach end of input:\n{}'.format(mode, output))

    def test_the_eio_runner_gives_its_child_no_terminal(self):
        self.check_mode('eio')

    def test_the_unix_fallback_gives_its_child_no_terminal(self):
        self.check_mode('unix')


if __name__ == '__main__':
    unittest.main(argv=[sys.argv[0]] + remaining)
