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
    def exercise(self, runtime, expected_command, failure=False, custom_docker=False, inspect_exit=1):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            receipt = root / 'receipt.json'
            capture = root / 'capture.py'
            capture.write_text('''import json, os, pathlib, sys
args = sys.argv[2:]
if args[:2] == ['image', 'inspect']:
    sys.exit(int(os.environ['TEST_INSPECT_EXIT']))
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
                       TEST_RECEIPT=str(receipt), TEST_EXIT='19' if failure else '0',
                       TEST_INSPECT_EXIT=str(inspect_exit))
            env.pop('MASC_TEST_FAKE_DOCKER_PATH', None)
            if custom_docker:
                env['MASC_TEST_FAKE_DOCKER_PATH'] = str(root / 'configured-docker')
            args = [BINARY, 'sandbox-image', '--tag', 'fixture:requested']
            if runtime:
                args.extend(['--runtime', runtime])
            result = subprocess.run(args, env=env, text=True, capture_output=True)
            if inspect_exit != 1:
                # The store answered "present" or did not answer: nothing is built.
                self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertFalse(receipt.exists(), 'a build ran after the store refused it')
                return result.stderr
            self.assertEqual(result.returncode == 0, not failure, result.stdout + result.stderr)
            data = json.loads(receipt.read_text())
            self.assertEqual(data['command'], expected_command)
            self.assertEqual(data['args'][:3], ['build', '-t', 'fixture:requested'])
            labels = [data['args'][i + 1] for i, arg in enumerate(data['args']) if arg == '--label']
            self.assertIn('org.opencontainers.image.version=fixture:requested', labels)
            self.assertIn('masc.sandbox.recipe=base', labels)
            if runtime == 'apple_container':
                self.assertIn('-f', data['args'])
            else:
                self.assertEqual(data['args'][-1], '-')
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

    def test_a_tag_already_in_the_store_is_not_rebuilt(self):
        stderr = self.exercise(None, 'docker', inspect_exit=0)
        self.assertIn('already in the image store', stderr)

    def test_a_store_that_does_not_answer_builds_nothing(self):
        stderr = self.exercise('apple_container', 'container', inspect_exit=3)
        self.assertIn('could not ask the image store', stderr)


if __name__ == '__main__':
    unittest.main()
