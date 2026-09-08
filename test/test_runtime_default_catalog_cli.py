"""The actual CLI validates deployment models with the server's sparse overlay."""
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
BINARY = str(Path(sys.argv.pop(1)).resolve()) if len(sys.argv) > 1 else None
RUNTIME_ID = 'operator_fixture.operator-model'
RUNTIME = '''
[providers.operator_fixture]
protocol = "openai-compatible-http"
endpoint = "http://127.0.0.1:9/v1"

[models.operator-model]
api-name = "operator-synthetic-model"
max-context = 8192
tools-support = false
streaming = false

[operator_fixture.operator-model]
max-concurrent = 1
max-request-body-bytes = 65536
'''
OVERLAY = '''
[[models]]
id_prefix = "operator-synthetic-model"
provider_name = "operator_fixture"
base = "openai_chat"
max_context_tokens = 8192
max_output_tokens = 1024
supports_tools = false
supports_tool_choice = false
supports_response_format_json = false
supports_structured_output = false
supports_native_streaming = false
'''


class RuntimeDefaultCatalog(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='masc-runtime-default-')
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name)
        config = self.base / '.masc/config'
        config.mkdir(parents=True)
        fixture = ROOT / 'scripts/fixtures/release-evidence'
        self.runtime = config / 'runtime.toml'
        self.overlay = config / 'agent-core-models-overlay.toml'
        self.runtime.write_text((fixture / 'runtime.toml').read_text() + RUNTIME)
        self.base_overlay = (fixture / self.overlay.name).read_text()
        self.overlay.write_text(self.base_overlay + OVERLAY)
        self.env = {k: v for k, v in os.environ.items()
                    if not k.startswith(('MASC_', 'AGENT_CORE_'))}
        self.env['HOME'] = str(self.base)

    def select(self):
        return subprocess.run([BINARY, 'runtime-default-set', '--base-path', str(self.base), RUNTIME_ID],
                              env=self.env, cwd=self.base, text=True, capture_output=True, timeout=20)

    def test_provider_scoped_sparse_overlay_is_accepted(self):
        overlay_before = self.overlay.read_bytes()
        result = self.select()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn('default = "' + RUNTIME_ID + '"', self.runtime.read_text())
        self.assertEqual(self.overlay.read_bytes(), overlay_before)

    def test_missing_model_does_not_change_runtime_file(self):
        self.overlay.write_text(self.base_overlay)
        before = self.runtime.read_bytes()
        result = self.select()
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn('catalog', result.stderr)
        self.assertEqual(self.runtime.read_bytes(), before)

    def test_malformed_overlay_does_not_change_runtime_file(self):
        self.overlay.write_text('[[models]\n')
        before = self.runtime.read_bytes()
        result = self.select()
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn('catalog overlay', result.stderr)
        self.assertEqual(self.runtime.read_bytes(), before)


if __name__ == '__main__':
    if BINARY is None:
        raise SystemExit('usage: test_runtime_default_catalog_cli.py /path/to/masc')
    unittest.main()
