"""Verify an already-built masc sends image builds to the requested runtime.

Usage: python3 test/test_sandbox_image_cli.py /path/to/masc
No Docker daemon, VM, network, or image build is used.
"""
import json
import os
from pathlib import Path
import shlex
import subprocess
import sys
import tempfile
import unittest

BINARY = str(Path(sys.argv.pop(1)).resolve())


class SandboxImageCliTest(unittest.TestCase):
    def exercise(self, runtime, expected_command, failure=False, custom_docker=False):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            receipt = root / 'receipt.json'
            capture = root / 'capture.py'
            capture.write_text('''import json, os, pathlib, sys
args = sys.argv[2:]
recipe = sys.stdin.read() if args[-1] == '-' else pathlib.Path(args[args.index('-f') + 1]).read_text()
pathlib.Path(os.environ['TEST_RECEIPT']).write_text(json.dumps({'command': pathlib.Path(sys.argv[1]).name, 'args': args, 'recipe': recipe}))
sys.exit(int(os.environ['TEST_EXIT']))
''')
            for command in ['docker', 'nerdctl', 'container', 'configured-docker']:
                fake = root / command
                fake.write_text('#!/bin/sh\nexec ' + shlex.quote(sys.executable) + ' '
                                + shlex.quote(str(capture)) + ' "$0" "$@"\n')
                fake.chmod(0o755)
            env = dict(os.environ, PATH=str(root) + os.pathsep + os.environ.get('PATH', ''),
                       TEST_RECEIPT=str(receipt), TEST_EXIT='19' if failure else '0')
            env.pop('MASC_TEST_FAKE_DOCKER_PATH', None)
            if custom_docker:
                env['MASC_TEST_FAKE_DOCKER_PATH'] = str(root / 'configured-docker')
            args = [BINARY, 'sandbox-image', '--tag', 'fixture:requested']
            if runtime:
                args.extend(['--runtime', runtime])
            result = subprocess.run(args, env=env, text=True, capture_output=True)
            self.assertEqual(result.returncode == 0, not failure, result.stdout + result.stderr)
            data = json.loads(receipt.read_text())
            self.assertEqual(data['command'], expected_command)
            self.assertEqual(data['args'][:3], ['build', '-t', 'fixture:requested'])
            if runtime == 'apple_container':
                self.assertEqual(data['args'][3], '-f')
            else:
                self.assertEqual(data['args'][3:], ['-'])
            recipe = subprocess.run([BINARY, 'sandbox-image', '--print'], env=env,
                                    text=True, capture_output=True, check=True).stdout
            self.assertEqual(data['recipe'], recipe)
            if failure:
                self.assertIn('19', result.stderr)
                self.assertIn(expected_command, result.stderr)

    def test_default_uses_docker(self):
        self.exercise(None, 'docker')

    def test_configured_docker_argv_is_preserved(self):
        self.exercise(None, 'configured-docker', custom_docker=True)

    def test_kata_uses_nerdctl_even_with_docker_override(self):
        self.exercise('nerdctl_kata', 'nerdctl', custom_docker=True)

    def test_apple_uses_container_context_directory(self):
        self.exercise('apple_container', 'container')

    def test_runtime_build_failure_is_not_success(self):
        self.exercise('nerdctl_kata', 'nerdctl', failure=True)


if __name__ == '__main__':
    unittest.main()
