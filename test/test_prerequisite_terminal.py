"""Exercise native installer I/O with an inert terminal child, without sudo."""
import argparse
import json
import os
import pty
import select
import subprocess
import sys
import unittest

parser = argparse.ArgumentParser()
parser.add_argument('--binary', required=True)
args, remaining = parser.parse_known_args()


class Terminal(unittest.TestCase):
    def test_password_prompt_stays_visible_and_stdout_is_a_clean_receipt(self):
        master, slave = pty.openpty()
        child = ('import sys,json,os; print("Enter fixture code:",file=sys.stderr,flush=True); '
                 'value=sys.stdin.readline().strip(); '
                 'print(json.dumps(dict(value=value,stdin_tty=os.isatty(0),stderr_tty=os.isatty(2))))')
        process = subprocess.Popen([args.binary, sys.executable, '-c', child], stdin=slave,
                                   stderr=slave, stdout=subprocess.PIPE)
        try:
            terminal = b''
            while b'Enter fixture code:' not in terminal:
                self.assertTrue(select.select([master], [], [], 5)[0], 'terminal prompt missing')
                terminal += os.read(master, 65536)
            os.write(master, b'fixture-answer\n')
            output, _ = process.communicate(timeout=5)
            self.assertEqual(process.returncode, 0)
            self.assertEqual(json.loads(output), dict(value='fixture-answer', stdin_tty=True, stderr_tty=True))
            self.assertNotIn(b'"stdin_tty"', terminal)
        finally:
            if process.poll() is None:
                process.kill()
                process.wait()
            process.stdout.close()
            os.close(master)
            os.close(slave)

    def test_failed_child_is_reaped_and_never_becomes_a_success_receipt(self):
        result = subprocess.run([args.binary, sys.executable, '-c', 'raise SystemExit(7)'],
                                capture_output=True, text=True, timeout=5)
        self.assertEqual(result.returncode, 1)
        self.assertEqual(result.stdout, '')


if __name__ == '__main__':
    unittest.main(argv=[__file__] + remaining)
