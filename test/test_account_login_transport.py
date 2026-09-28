"""Exercise the real login helper with isolated synthetic native clients."""
import json
import os
from pathlib import Path
import select
import subprocess
import sys
import time
import unittest


HELPER = Path(__file__).resolve().parents[1] / 'scripts/account-login-transport.py'


class Transport:
    def __init__(self, source, mode='pipe'):
        self.process = subprocess.Popen(
            [sys.executable, str(HELPER), mode, sys.executable, '-u', '-c', source],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        self.pending = b''
        self.events = []

    def send(self, **command):
        self.process.stdin.write(json.dumps(command).encode() + b'\n')
        self.process.stdin.flush()

    def until(self, predicate, timeout=5):
        deadline = time.monotonic() + timeout
        while not predicate(self.events):
            while b'\n' not in self.pending:
                remaining = deadline - time.monotonic()
                if remaining <= 0 or not select.select([self.process.stdout], [], [], remaining)[0]:
                    raise AssertionError(f'No expected event; received {self.events!r}')
                data = os.read(self.process.stdout.fileno(), 65536)
                if not data:
                    raise AssertionError(f'Helper ended before expected event: {self.events!r}')
                self.pending += data
            line, self.pending = self.pending.split(b'\n', 1)
            self.events.append(json.loads(line))
        return self.events

    def output(self):
        return ''.join(event['text'] for event in self.events if event['event'] == 'output')

    def complete(self, event='exited', timeout=5):
        self.until(lambda events: any(item['event'] == event for item in events), timeout)
        self.process.wait(timeout=timeout)
        if self.process.returncode != 0:
            raise AssertionError(f'Helper returned {self.process.returncode}')
        if self.process.stderr.read():
            raise AssertionError('Helper leaked diagnostics to stderr')
        return next(item for item in self.events if item['event'] == event)

    def close(self):
        if self.process.poll() is None:
            self.process.terminate()
            try:
                self.process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.wait(timeout=5)
        for stream in (self.process.stdin, self.process.stdout, self.process.stderr):
            stream.close()


class LoginTransportTests(unittest.TestCase):
    def transport(self, source, mode='pipe'):
        transport = Transport(source, mode)
        self.addCleanup(transport.close)
        return transport

    def assert_dead(self, pid):
        # Orphaned grandchildren can briefly remain zombies until init reaps
        # them. Zombies hold neither execution nor inherited transport fds.
        result = subprocess.run(['ps', '-o', 'stat=', '-p', str(pid)],
                                capture_output=True, text=True, check=False)
        self.assertTrue(not result.stdout.strip() or result.stdout.strip().startswith('Z'),
                        f'Native process {pid} still alive: {result.stdout}')

    def test_pipe_code_prompt_and_exit_without_input_reflection(self):
        transport = self.transport(
            "import sys\nprint('Enter code:', flush=True)\n"
            "code = sys.stdin.readline().strip()\n"
            "print('accepted' if code == 'private-code' else 'rejected', flush=True)\n")
        transport.until(lambda _: 'Enter code:' in transport.output())
        transport.send(kind='text', text='private-code')
        self.assertEqual(transport.complete()['code'], 0)
        self.assertIn('accepted', transport.output())
        self.assertNotIn('private-code', transport.output())

    def test_utf8_split_across_native_writes(self):
        transport = self.transport(
            "import os,time\ndata='인증✓'.encode()\n"
            "for value in data:\n os.write(1, bytes([value])); time.sleep(.02)\n")
        self.assertEqual(transport.complete()['code'], 0)
        self.assertEqual(transport.output(), '인증✓')

    def test_pipe_eof_follows_queued_input(self):
        transport = self.transport(
            "import sys\ndata=sys.stdin.read()\n"
            "print('complete' if data == 'value\\n' else 'wrong', flush=True)\n")
        transport.send(kind='text', text='value')
        transport.send(kind='key', key='eof')
        self.assertEqual(transport.complete()['code'], 0)
        self.assertIn('complete', transport.output())
        self.assertEqual(sum(event['event'] == 'input_ready' for event in transport.events), 2)

    def test_pty_echo_is_disabled_before_prompt_and_code(self):
        transport = self.transport(
            "import sys,termios\nflags=termios.tcgetattr(0)[3]\n"
            "print('echo-off' if not flags & (termios.ECHO | termios.ECHONL) else 'echo-on', flush=True)\n"
            "code=sys.stdin.readline().strip()\n"
            "print('accepted' if code == 'private-code' else 'rejected', flush=True)\n", 'pty')
        transport.until(lambda _: 'echo-' in transport.output())
        transport.send(kind='text', text='private-code')
        self.assertEqual(transport.complete()['code'], 0)
        self.assertIn('echo-off', transport.output())
        self.assertIn('accepted', transport.output())
        self.assertNotIn('private-code', transport.output())

    def test_pty_arrow_and_eof_bytes(self):
        transport = self.transport(
            "import os,tty\ntty.setraw(0)\nos.write(1,b'ready')\n"
            "data=b''\nwhile len(data)<4:\n data+=os.read(0,4-len(data))\n"
            "os.write(1,b'accepted' if data==b'\\x1b[A\\x04' else b'rejected')\n", 'pty')
        transport.until(lambda _: 'ready' in transport.output())
        transport.send(kind='key', key='up')
        transport.send(kind='key', key='eof')
        self.assertEqual(transport.complete()['code'], 0)
        self.assertIn('accepted', transport.output())

    def test_large_blocked_native_stdin_cannot_block_cancel(self):
        transport = self.transport("import os,time\nprint(os.getpid(),flush=True)\ntime.sleep(30)\n")
        transport.until(lambda _: '\n' in transport.output())
        pid = int(transport.output().strip())
        transport.send(kind='text', text='x' * 262144)
        time.sleep(.05)
        started = time.monotonic()
        transport.send(kind='cancel')
        transport.complete('cancelled', timeout=3)
        self.assertLess(time.monotonic() - started, 3)
        self.assertFalse(any(event['event'] == 'input_ready' for event in transport.events),
                         'Blocked native input must not be acknowledged as drained')
        self.assert_dead(pid)
        self.assertNotIn('xxx', transport.output())

    def test_disconnect_kills_child_and_grandchild(self):
        transport = self.transport(
            "import os,time\nchild=os.fork()\n"
            "if child==0:\n time.sleep(30); os._exit(0)\n"
            "print(str(os.getpid())+' '+str(child),flush=True)\ntime.sleep(30)\n")
        transport.until(lambda _: '\n' in transport.output())
        pids = [int(value) for value in transport.output().split()]
        transport.process.stdin.close()
        transport.complete('cancelled', timeout=3)
        for pid in pids:
            self.assert_dead(pid)

    def test_exited_leader_cannot_leave_grandchild_holding_pipes(self):
        transport = self.transport(
            "import os,time\nchild=os.fork()\n"
            "if child==0:\n time.sleep(30); os._exit(0)\n"
            "print(str(os.getpid())+' '+str(child),flush=True)\nos._exit(0)\n")
        self.assertEqual(transport.complete(timeout=3)['code'], 0)
        for pid in (int(value) for value in transport.output().split()):
            self.assert_dead(pid)


if __name__ == '__main__':
    unittest.main()
