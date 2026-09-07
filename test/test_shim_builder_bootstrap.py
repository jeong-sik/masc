#!/usr/bin/env python3
"""Exercise the release builder wrapper with fake Docker/opam; no build or daemon."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

SOURCE = Path(__file__).resolve().parents[1] / 'scripts/remote-ssh/build-shim.sh'

DOCKER = r'''#!/usr/bin/env python3
import json, os, pathlib, subprocess, sys
args = sys.argv[1:]
with open(os.environ['DOCKER_LOG'], 'a') as f: f.write(json.dumps(args) + '\n')
if args[:2] == ['image', 'inspect']:
    sys.exit(0 if os.environ.get('FAKE_CACHE') == 'hit' else 1)
if args[0] == 'run':
    if '--name' in args:
        sh = args.index('sh')
        # Execute the actual preparation body, substituting only its commands.
        sys.exit(subprocess.run(['/bin/sh', '-c', args[sh + 2], *args[sh + 3:]]).returncode)
    mounts = [args[i + 1] for i, arg in enumerate(args) if arg == '-v']
    output = next(m[:-5] for m in mounts if m.endswith(':/out'))
    arch = args[args.index('--platform') + 1].split('/')[-1]
    pathlib.Path(output, 'masc-exec-shim-linux-' + arch).write_bytes(b'fixture artifact')
'''
OPAM = r'''#!/usr/bin/env python3
import json, os, sys
args = sys.argv[1:]
with open(os.environ['OPAM_LOG'], 'a') as f: f.write(json.dumps(args) + '\n')
if args[:1] == ['exec']:
    assert args == ['exec', '--switch=masc-shim', '--', 'ocamlc', '-version'], args
    print(os.environ.get('FAKE_COMPILER', '5.5.1'))
if args[:1] == ['install'] and os.environ.get('FAKE_INSTALL_FAIL'):
    sys.exit(42)
'''

class ShimBuilderTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='masc-shim-wrapper-')
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.bin = self.root / 'fake-bin'
        self.bin.mkdir()
        self.script = self.root / 'scripts/remote-ssh/build-shim.sh'
        self.script.parent.mkdir(parents=True)
        shutil.copyfile(SOURCE, self.script)
        (self.root / 'dune-project').write_text('(lang dune 3.0)\n  (ocaml (= 5.5.1))\n')
        self.docker_log = self.root / 'docker.jsonl'
        self.opam_log = self.root / 'opam.jsonl'
        self.env = os.environ | {
            'PATH': str(self.bin) + os.pathsep + os.environ['PATH'],
            'FIXTURE_ROOT': str(self.root),
            'DOCKER_LOG': str(self.docker_log), 'OPAM_LOG': str(self.opam_log),
        }
        self.command('docker', DOCKER)
        self.command('opam', OPAM)
        self.command('git', '#!/bin/sh\nprintf "%s\\n" "$FIXTURE_ROOT"\n')
        self.command('apk', '#!/bin/sh\necho musl-fixture\n')
        self.command('file', '#!/bin/sh\necho "ELF fixture: statically linked"\n')

    def command(self, name, text):
        p = self.bin / name
        p.write_text(text)
        p.chmod(0o755)

    def calls(self, path):
        return [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []

    def run_builder(self, **env):
        return subprocess.run(['bash', str(self.script), '--arch', 'amd64', '--out', 'dist'],
                              cwd=self.root, env=self.env | env, capture_output=True, text=True)

    def test_cold_build_uses_repository_compiler_and_prepared_image(self):
        result = self.run_builder()
        self.assertEqual(0, result.returncode, result.stderr)
        docker = self.calls(self.docker_log)
        opam = self.calls(self.opam_log)
        self.assertIn(['switch', 'create', 'masc-shim', 'ocaml-base-compiler.5.5.1', '-y'], opam)
        self.assertLess(opam.index(['repository', 'set-url', 'default', 'https://opam.ocaml.org']),
                        next(i for i, call in enumerate(opam) if call[0] == 'switch'))
        self.assertIn(['update', 'default'], opam)
        commit = next(call for call in docker if call[0] == 'commit')
        self.assertRegex(commit[-1], r'^masc-shim-build:amd64-[0-9a-f]{64}$')
        build = next(call for call in docker if call[0] == 'run' and '--rm' in call)
        self.assertIn(commit[-1], build)
        self.assertIn('_,ccopt=-static,ccopt=-no-pie', build[build.index('-e') + 1])
        self.assertIn('opam exec --switch=masc-shim -- dune build', build[-1])
        self.assertTrue((self.root / 'dist/masc-exec-shim-linux-amd64').exists())

    def test_matching_cache_skips_preparation(self):
        result = self.run_builder(FAKE_CACHE='hit')
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertEqual([], self.calls(self.opam_log))
        docker = self.calls(self.docker_log)
        self.assertFalse(any(c[0] == 'commit' for c in docker))
        tag = next(c[-1] for c in docker if c[:2] == ['image', 'inspect'])
        self.assertIn(tag, next(c for c in docker if c[0] == 'run'))

    def test_compiler_and_script_changes_change_cache_identity(self):
        tags = []
        for version, suffix in [('5.5.1', ''), ('5.5.2', ''), ('5.5.2', '\n# changed preparation\n')]:
            (self.root / 'dune-project').write_text(f'  (ocaml (= {version}))\n')
            self.script.write_text(SOURCE.read_text() + suffix)
            result = self.run_builder(FAKE_CACHE='hit')
            self.assertEqual(0, result.returncode, result.stderr)
            tags.append([c[-1] for c in self.calls(self.docker_log) if c[:2] == ['image', 'inspect']][-1])
        self.assertEqual(3, len(set(tags)))

    def test_failed_preparation_never_commits_or_builds(self):
        result = self.run_builder(FAKE_INSTALL_FAIL='1')
        self.assertEqual(42, result.returncode)
        docker = self.calls(self.docker_log)
        self.assertFalse(any(c[0] == 'commit' or (c[0] == 'run' and '--rm' in c) for c in docker))
        self.assertTrue(any(c[:2] == ['rm', '-f'] for c in docker))

    def test_wrong_compiler_is_rejected_before_dependency_install(self):
        result = self.run_builder(FAKE_COMPILER='5.5.0')
        self.assertNotEqual(0, result.returncode)
        self.assertFalse(any(c[0] == 'install' for c in self.calls(self.opam_log)))
        self.assertFalse(any(c[0] == 'commit' for c in self.calls(self.docker_log)))

    def test_missing_exact_compiler_never_starts_docker(self):
        (self.root / 'dune-project').write_text('  (ocaml (>= 5.5.1))\n')
        result = self.run_builder()
        self.assertNotEqual(0, result.returncode)
        self.assertEqual([], self.calls(self.docker_log))

if __name__ == '__main__':
    unittest.main()
