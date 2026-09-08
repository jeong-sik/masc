"""Selected-only rendering and transactional publication through the real helper."""
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

BINARY = None
if len(sys.argv) > 2 and sys.argv[1] == '--binary':
    BINARY = str(Path(sys.argv.pop(2)).resolve())
    sys.argv.pop(1)

ROOT = Path(__file__).resolve().parents[1]
MODULE = importlib.util.spec_from_file_location('runtime_setup', ROOT / 'scripts/install-runtime-setup.py')
SETUP = importlib.util.module_from_spec(MODULE)
MODULE.loader.exec_module(SETUP)


def spec(choice='vllm'):
    result = dict(choice=choice, model='operator/model-exact', max_context=8192, tools=True, streaming=False)
    if choice in ('vllm', 'llama_cpp'):
        result['endpoint'] = 'http://127.0.0.1:9/v1'
    elif choice == 'antigravity':
        result.update(credential_file='/operator/token-file', timeout_s=180)
    return result


class RuntimeSetup(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='runtime-setup-test-')
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name)
        self.config = self.base / '.masc/config'
        self.config.mkdir(parents=True)
        self.runtime = self.config / 'runtime.toml'
        self.overlay = self.config / 'agent-core-models-overlay.toml'
        self.runtime.write_bytes(b'# operator comment\n[runtime]\ndefault = "original.model"\n')
        self.overlay.write_bytes(b'# operator overlay\n')
        self.originals = (self.runtime.read_bytes(), self.overlay.read_bytes())
        self.binary = self.base / 'fixture-masc'

    def validator(self, code):
        self.binary.write_text('#!' + sys.executable + '\nimport sys\nfrom pathlib import Path\n' + code)
        self.binary.chmod(0o755)

    def test_selected_transport_uses_only_operator_model_and_capabilities(self):
        for choice in SETUP.CHOICES:
            with self.subTest(choice=choice):
                identity, runtime, overlay = SETUP.render(spec(choice))
                self.assertIn('setup_' + choice, identity)
                self.assertIn(b'operator/model-exact', runtime)
                self.assertIn(b'"max-context" = 8192', runtime)
                if choice in ('vllm', 'llama_cpp'):
                    self.assertIn(b'"provider_name" = "setup_' + choice.encode() + b'"', overlay)
                    self.assertIn(b'"supports_tools" = true', overlay)
                    self.assertIn(b'"supports_reasoning" = false', overlay)
                    self.assertIn(b'"supports_native_streaming" = false', overlay)
                    self.assertNotIn(b'max_output_tokens', overlay)
                else:
                    self.assertEqual(overlay, b'')

    def test_empty_api_key_env_means_no_credentials(self):
        _, runtime, _ = SETUP.render(dict(spec(), api_key_env=''))
        self.assertNotIn(b'credentials', runtime)

    def test_invalid_or_secret_bearing_spec_is_rejected(self):
        for changed in (dict(spec(), model=''), dict(spec(), max_context=True),
                        dict(spec(), tools='true'), dict(spec(), api_key_env='bad-key'), dict(spec(), api_key='secret-value'),
                        dict(spec('antigravity'), timeout_s=float('inf')),
                        dict(spec(), endpoint='https://user:secret@example.org/v1'),
                        dict(spec('antigravity'), credential_file='relative-token')):
            with self.subTest(spec=changed), self.assertRaises(SETUP.SetupError) as caught:
                SETUP.render(changed)
            self.assertNotIn('secret-value', str(caught.exception))

    def test_failed_validator_preserves_both_files_without_exposing_stderr(self):
        self.validator("print('credential-secret-value', file=sys.stderr)\nsys.exit(1)\n")
        with self.assertRaises(SETUP.SetupError) as caught:
            SETUP.configure(self.binary, self.base, spec())
        self.assertNotIn('credential-secret-value', str(caught.exception))
        self.assertEqual((self.runtime.read_bytes(), self.overlay.read_bytes()), self.originals)

    def test_success_validates_stage_and_preserves_existing_bytes(self):
        self.validator('''assert sys.argv[1] == 'runtime-default-set'
base = Path(sys.argv[3])
assert base != Path(''' + repr(str(self.base)) + ''')
runtime = base / '.masc/config/runtime.toml'
assert 'setup_vllm' in runtime.read_text()
runtime.write_text(runtime.read_text().replace('original.model', sys.argv[4]))
''')
        result = SETUP.configure(self.binary, self.base, spec())
        self.assertEqual(result['readiness'], 'not_probed')
        self.assertTrue(self.runtime.read_bytes().startswith(b'# operator comment\n'))
        self.assertIn(result['runtime_id'].encode(), self.runtime.read_bytes())
        self.assertTrue(self.overlay.read_bytes().startswith(self.originals[1]))

    def test_changed_snapshot_is_not_overwritten(self):
        self.validator('Path(' + repr(str(self.runtime)) + ").write_text('operator concurrent update')\n")
        with self.assertRaisesRegex(SETUP.SetupError, 'changed during validation'):
            SETUP.configure(self.binary, self.base, spec())
        self.assertEqual(self.runtime.read_text(), 'operator concurrent update')
        self.assertEqual(self.overlay.read_bytes(), self.originals[1])

    def test_second_file_publish_failure_rolls_back_overlay(self):
        self.validator('sys.exit(0)\n')
        original_write = SETUP.atomic_write
        def failing_write(path, content, mode):
            if path == self.runtime.resolve():
                raise OSError('simulated disk error')
            return original_write(path, content, mode)
        with patch.object(SETUP, 'atomic_write', side_effect=failing_write):
            with self.assertRaisesRegex(OSError, 'simulated disk error'):
                SETUP.configure(self.binary, self.base, spec())
        self.assertEqual((self.runtime.read_bytes(), self.overlay.read_bytes()), self.originals)


@unittest.skipUnless(BINARY, 'actual binary is supplied by targeted CI')
class CompiledRuntimeSetup(unittest.TestCase):
    def test_real_validator_accepts_each_transport_and_refuses_duplicate_without_changes(self):
        fixture = ROOT / 'scripts/fixtures/release-evidence'
        for choice in SETUP.CHOICES:
            with self.subTest(choice=choice), tempfile.TemporaryDirectory(prefix='runtime-setup-cli-') as tmp:
                base = Path(tmp)
                config = base / '.masc/config'
                config.mkdir(parents=True)
                for name in ('runtime.toml', 'agent-core-models-overlay.toml'):
                    (config / name).write_bytes((fixture / name).read_bytes())
                selected = spec(choice)
                if choice == 'antigravity':
                    token = base / 'credential-file'
                    token.write_text('fixture-only-token')
                    selected['credential_file'] = str(token)
                env = {k: v for k, v in os.environ.items() if not k.startswith(('MASC_', 'AGENT_CORE_'))}
                with patch.dict(os.environ, env, clear=True):
                    result = SETUP.configure(BINARY, base, selected)
                    self.assertEqual(result['validation'], 'passed')
                    self.assertEqual(result['readiness'], 'not_probed')
                    before = [(config / name).read_bytes() for name in ('runtime.toml', 'agent-core-models-overlay.toml')]
                    with self.assertRaises(SETUP.SetupError):
                        SETUP.configure(BINARY, base, selected)
                    self.assertEqual(before, [(config / name).read_bytes() for name in ('runtime.toml', 'agent-core-models-overlay.toml')])


if __name__ == '__main__':
    unittest.main()
