#!/usr/bin/env python3
import json
import os
from pathlib import Path
import shlex
import subprocess
import sys
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1]/'scripts/antigravity-context-pty.py'


class ContextTransport(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='masc-agy-context-test-')
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name).resolve()
        self.home = self.root/'home'
        self.home.mkdir(mode=0o700)
        self.records = self.root/'records.jsonl'
        self.records.write_text('')
        self.records.chmod(0o600)
        self.cli = self.root/'fake-agy'
        self.pid_file = self.root/'child-pid'
        callback = shlex.join([sys.executable, '-I', '-B', str(SCRIPT), '--capture', str(self.records)])
        self.cli.write_text('#!'+sys.executable+'\n'+f'''
import json, os, pathlib, subprocess, sys, time
if sys.argv[1:] == ['--version']:
    print('1.2.0')
    sys.exit(0)
assert sys.argv[1:] == ['--model', 'selected-model']
assert sys.stdin.isatty() and sys.stdout.isatty()
assert pathlib.Path.cwd() == pathlib.Path(os.environ['HOME'])
pathlib.Path({str(self.pid_file)!r}).write_text(str(os.getpid()))
payload = {{'model':{{'id':'Selected Model','display_name':'Selected Model','email':'PRIVATE_EMAIL'}},
           'version':'1.2.0','context_window':{{'context_window_size':1048576,'total_input_tokens':0,
           'total_output_tokens':0,'current_usage':None,'credential':'PRIVATE_KEY'}},
           'email':'PRIVATE_EMAIL','transcript_path':'PRIVATE_PATH'}}
print('PRIVATE_TERMINAL_OUTPUT', flush=True)
subprocess.run({callback!r}, shell=True, input=json.dumps(payload), text=True, check=True)
time.sleep(60)
''')
        self.cli.chmod(0o700)
        self.env = dict(os.environ, HOME=str(self.home), TERM='xterm-256color')

    def run_transport(self, timeout=5):
        return subprocess.run([sys.executable, '-I', '-B', str(SCRIPT), '--home', str(self.home),
                               '--cli', str(self.cli), '--model', 'selected-model', '--records', str(self.records),
                               '--timeout', str(timeout)], env=self.env, capture_output=True, text=True, timeout=15)

    def assert_child_reaped(self):
        pid = int(self.pid_file.read_text())
        with self.assertRaises(ProcessLookupError):
            os.kill(pid, 0)

    def test_status_callback_pty_projection_and_owned_cleanup(self):
        result = self.run_transport()
        self.assertEqual(result.returncode, 0, result.stderr)
        receipt = json.loads(result.stdout)
        self.assertEqual(receipt['status'], 'captured')
        self.assertEqual(receipt['records'][0]['context_window']['context_window_size'], 1048576)
        for secret in ('PRIVATE_EMAIL','PRIVATE_KEY','PRIVATE_PATH','PRIVATE_TERMINAL_OUTPUT'):
            self.assertNotIn(secret, result.stdout+result.stderr+self.records.read_text())
        self.assert_child_reaped()

    def test_timeout_still_reaps_owned_group(self):
        self.cli.write_text('#!'+sys.executable+'\nimport os,pathlib,time\npathlib.Path('+repr(str(self.pid_file))+').write_text(str(os.getpid()))\ntime.sleep(60)\n')
        result = self.run_transport(timeout=2)
        self.assertEqual(json.loads(result.stdout)['status'], 'timed_out')
        self.assert_child_reaped()

    def test_version_exec_uses_private_working_directory(self):
        self.cli.write_text('#!'+sys.executable+'\nimport os,pathlib,sys\nassert pathlib.Path.cwd()==pathlib.Path(os.environ["HOME"])\nassert sys.argv[1:]==["--version"]\nprint("1.2.0")\n')
        result = subprocess.run([sys.executable, '-I', '-B', str(SCRIPT), '--version-probe',
                                 '--home', str(self.home), '--cli', str(self.cli)],
                                env=self.env, capture_output=True, text=True, timeout=5)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), '1.2.0')

    def test_duplicate_payload_never_becomes_status_evidence(self):
        result = subprocess.run([sys.executable, '-I', '-B', str(SCRIPT), '--capture', str(self.records)],
                                input='{"model":null,"model":{"id":"spoof"}}', capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.records.read_bytes(), b'')


if __name__ == '__main__':
    unittest.main()
