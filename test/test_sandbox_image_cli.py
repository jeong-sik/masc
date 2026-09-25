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
            self.assertTrue(any(label.startswith('org.opencontainers.image.version=')
                                and ':' not in label for label in labels), labels)
            self.assertRegex('\n'.join(labels),
                             r'org\.opencontainers\.image\.version=\d{8}T\d{4}Z-[0-9a-f]{8}')
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


class SandboxImageCatalogCliTest(unittest.TestCase):
    """promote records a tag the chosen store holds in <base>/.masc/config/sandbox-image-builds.toml."""

    def run_cli(self, root, base, *args, inspect_exit=0, config_dir=None):
        env = dict(os.environ, PATH=str(root) + os.pathsep + os.environ.get('PATH', ''),
                   TEST_INSPECT_EXIT=str(inspect_exit))
        env.pop('MASC_TEST_FAKE_DOCKER_PATH', None)
        env.pop('MASC_CONFIG_DIR', None)
        if config_dir is not None:
            env['MASC_CONFIG_DIR'] = str(config_dir)
        subcommand, *rest = args
        return subprocess.run([BINARY, 'sandbox-image', subcommand, '--base-path', str(base), *rest],
                              env=env, text=True, capture_output=True)

    def install_fake_stores(self, root, *commands):
        """Each command answers `image inspect` with TEST_INSPECT_EXIT: 0 holds the tag, 1 does not."""
        capture = root / 'capture.py'
        capture.write_text('''import os, sys
args = sys.argv[2:]
if args[:2] == ['image', 'inspect']:
    sys.exit(int(os.environ['TEST_INSPECT_EXIT']))
sys.exit(0)
''')
        for command in commands:
            fake = root / command
            fake.write_text('#!/bin/sh\nexec ' + shlex.quote(sys.executable) + ' '
                            + shlex.quote(str(capture)) + ' "$0" "$@"\n')
            fake.chmod(0o755)

    @staticmethod
    def builds(catalog):
        """The host file without its comment header: store tables and their tags."""
        return [line for line in catalog.read_text().splitlines()
                if line and not line.startswith('#')]

    def test_promote_replaces_the_tag_and_an_earlier_tag_goes_back(self):
        general = 'masc-sandbox:general'
        newer = 'masc-sandbox-base:20260925T0900Z-11112222'
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self.install_fake_stores(root, 'container')
            base = root / 'workspace'
            (base / '.masc' / 'config').mkdir(parents=True)
            catalog = base / '.masc' / 'config' / 'sandbox-image-builds.toml'

            first = self.run_cli(root, base, 'promote', 'base', general, '--runtime', 'apple_container')
            self.assertEqual(first.returncode, 0, first.stdout + first.stderr)
            self.assertEqual(self.builds(catalog),
                             ['[images.base.apple_container]', f'reference = "{general}"'],
                             'host file holds builds only, one tag per store')

            second = self.run_cli(root, base, 'promote', 'base', newer, '--runtime', 'apple_container')
            self.assertEqual(second.returncode, 0, second.stdout + second.stderr)
            self.assertEqual(self.builds(catalog),
                             ['[images.base.apple_container]', f'reference = "{newer}"'])

            before = catalog.read_text()
            absent = self.run_cli(root, base, 'promote', 'base', 'masc-sandbox-base:absent',
                                  '--runtime', 'apple_container', inspect_exit=1)
            self.assertNotEqual(absent.returncode, 0, 'a tag the store does not hold was promoted')
            self.assertIn('the apple_container image store did not report', absent.stderr)
            self.assertEqual(catalog.read_text(), before)

            silent = self.run_cli(root, base, 'promote', 'base', 'masc-sandbox-base:unasked',
                                  '--runtime', 'apple_container', inspect_exit=3)
            self.assertNotEqual(silent.returncode, 0, 'a store that did not answer was taken as yes')
            self.assertIn('could not ask the apple_container image store', silent.stderr)
            self.assertEqual(catalog.read_text(), before)

            back = self.run_cli(root, base, 'promote', 'base', general, '--runtime', 'apple_container')
            self.assertEqual(back.returncode, 0, back.stdout + back.stderr)
            self.assertEqual(self.builds(catalog),
                             ['[images.base.apple_container]', f'reference = "{general}"'])

            unknown = self.run_cli(root, base, 'promote', 'rust', 'masc-sandbox-rust:x',
                                   '--runtime', 'apple_container')
            self.assertNotEqual(unknown.returncode, 0)
            self.assertIn('no image "rust"', unknown.stderr)

            # `--` ends the options, so the flag-shaped value reaches the reference check.
            flag = self.run_cli(root, base, 'promote', '--runtime', 'apple_container', '--',
                                'base', '--privileged:x')
            self.assertNotEqual(flag.returncode, 0, 'a flag-shaped reference was promoted')
            self.assertIn('is not repository:tag', flag.stderr)

    def test_promote_asks_each_microvm_runtime_its_own_store(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self.install_fake_stores(root, 'nerdctl', 'msb')
            base = root / 'workspace'
            (base / '.masc' / 'config').mkdir(parents=True)
            catalog = base / '.masc' / 'config' / 'sandbox-image-builds.toml'

            kata = self.run_cli(root, base, 'promote', 'base', 'masc-sandbox:kata',
                                '--runtime', 'nerdctl_kata')
            self.assertEqual(kata.returncode, 0, kata.stdout + kata.stderr)
            # msb builds nothing, and a tag it loaded is promoted the same way.
            loaded = self.run_cli(root, base, 'promote', 'base', 'masc-sandbox:loaded',
                                  '--runtime', 'microsandbox')
            self.assertEqual(loaded.returncode, 0, loaded.stdout + loaded.stderr)
            self.assertEqual(self.builds(catalog),
                             ['[images.base.nerdctl_kata]', 'reference = "masc-sandbox:kata"',
                              '[images.base.microsandbox]', 'reference = "masc-sandbox:loaded"'])

            before = catalog.read_text()
            missing = self.run_cli(root, base, 'promote', 'base', 'masc-sandbox:not-loaded',
                                   '--runtime', 'microsandbox', inspect_exit=1)
            self.assertNotEqual(missing.returncode, 0, 'a tag msb does not hold was promoted')
            self.assertIn('the microsandbox image store did not report', missing.stderr)
            self.assertEqual(catalog.read_text(), before)

    def test_promote_writes_the_catalog_the_server_reads_under_masc_config_dir(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self.install_fake_stores(root, 'container')
            base = root / 'workspace'
            (base / '.masc' / 'config').mkdir(parents=True)
            config_dir = root / 'elsewhere'
            config_dir.mkdir()
            result = self.run_cli(root, base, 'promote', 'base', 'masc-sandbox:general',
                                  '--runtime', 'apple_container', config_dir=config_dir)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn('[images.base.apple_container]',
                          (config_dir / 'sandbox-image-builds.toml').read_text())
            self.assertFalse((base / '.masc' / 'config' / 'sandbox-image-builds.toml').exists())

if __name__ == '__main__':
    unittest.main()
