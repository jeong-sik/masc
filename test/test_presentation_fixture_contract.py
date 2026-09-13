"""Reproduce Dune's child TMPDIR replacement without building native code."""
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch


HELPER = Path(__file__).resolve().parents[1] / 'scripts/ci/presentation_fixture.py'
SPEC = importlib.util.spec_from_file_location('presentation_fixture', HELPER)
FIXTURE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(FIXTURE)


class PresentationFixtureContract(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.root = Path(temp.name).resolve()
        self.home = self.root / 'home'
        self.runner = self.home / 'runner-temp'
        self.runner.mkdir(parents=True)
        self.base = self.root / 'prepared-workspace'
        (self.base / 'inputs').mkdir(parents=True)
        (self.base / 'inputs/presentation.pptx').write_bytes(b'prepared original fixture')
        env = patch.dict(os.environ, HOME=str(self.home), RUNNER_TEMP=str(self.runner))
        env.start()
        self.addCleanup(env.stop)

    def test_dune_child_tmpdir_does_not_move_prepared_inputs(self):
        FIXTURE.publish(self.base)
        child_tmp = self.root / 'build-12345.dune'
        child_tmp.mkdir()
        code = '''import importlib.util,sys,tempfile
spec=importlib.util.spec_from_file_location("fixture",sys.argv[1])
fixture=importlib.util.module_from_spec(spec);spec.loader.exec_module(fixture)
base=fixture.read_base()
assert str(base)!=tempfile.gettempdir()
print((base/"inputs/presentation.pptx").read_bytes().decode())
'''
        result = subprocess.run([sys.executable, '-I', '-c', code, str(HELPER)],
                                env=dict(os.environ, TMPDIR=str(child_tmp)),
                                capture_output=True, text=True, check=True)
        self.assertEqual(result.stdout.strip(), 'prepared original fixture')
        self.assertEqual(FIXTURE.read_base(), self.base)

    def test_no_runner_temp_is_an_explicit_error(self):
        with patch.dict(os.environ, RUNNER_TEMP=''):
            with self.assertRaisesRegex(ValueError, 'require an absolute RUNNER_TEMP'):
                FIXTURE.read_base()

    def test_descriptor_rejects_unknown_fields_schema_and_noncanonical_paths(self):
        valid = {'schema': FIXTURE.SCHEMA, 'base_path': str(self.base)}
        invalid = [dict(valid, extra=True), dict(valid, schema='other'),
                   dict(valid, base_path='relative'), dict(valid, base_path=42),
                   dict(valid, base_path=str(self.base) + '/.'),
                   dict(valid, base_path=str(self.home))]
        for value in invalid:
            with self.subTest(value=value), self.assertRaises(ValueError):
                FIXTURE.validate(value)

    def test_duplicate_json_field_is_rejected(self):
        FIXTURE.descriptor_path().write_text(
            '{"schema":"masc.presentation_fixture.v1","base_path":' + json.dumps(str(self.base))
            + ',"base_path":' + json.dumps(str(self.home)) + '}')
        with self.assertRaisesRegex(ValueError, 'duplicate'):
            FIXTURE.read_base()

    def test_failed_publish_preserves_previous_descriptor(self):
        FIXTURE.publish(self.base)
        before = FIXTURE.descriptor_path().read_bytes()
        with self.assertRaises(ValueError):
            FIXTURE.publish(self.home)
        self.assertEqual(FIXTURE.descriptor_path().read_bytes(), before)


if __name__ == '__main__':
    unittest.main()
