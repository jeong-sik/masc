"""Selected-only rendering and transactional publication through the real helper."""
import contextlib
import io
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
    if choice in ('vllm', 'llama_cpp', 'openai_compatible'):
        result['endpoint'] = 'http://127.0.0.1:9/v1'
    elif choice == 'antigravity':
        result.update(credential_file='/operator/token-file', timeout_s=180)
    return result


class ModelSelection(unittest.TestCase):
    def test_codex_cache_filters_hidden_models_and_preserves_exact_id(self):
        with tempfile.TemporaryDirectory() as directory:
            Path(directory, 'models_cache.json').write_text(json.dumps({'models':[
                {'slug':'observed-id','display_name':'Visible model','visibility':'list','context_window':4567},
                {'slug':'hidden','visibility':'hide','context_window':99},
                {'slug':'bad\nname','visibility':'list'},
                {'slug':'observed-id','visibility':'list'}]}))
            with patch.dict(os.environ, {'CODEX_HOME':directory}):
                models, origin = SETUP.discover_models('codex')
                self.assertEqual(models,[dict(id='observed-id',label='Visible model',context=4567)])
                self.assertIn('cached',origin)
                failed_lookup=subprocess.CompletedProcess([],1,'','')
                with patch('subprocess.run',return_value=failed_lookup), patch('sys.stdin',io.StringIO('1\n')), contextlib.redirect_stderr(io.StringIO()) as terminal:
                    selected=SETUP.select_model('/fixture/masc','codex')
                self.assertEqual(selected,dict(model='observed-id',max_context=4567))
                self.assertIn('No number to enter',terminal.getvalue())

    def test_astra_uses_codex_effective_context_instead_of_api_maximum(self):
        with tempfile.TemporaryDirectory() as directory:
            Path(directory,'models_cache.json').write_text(json.dumps({'models':[{
                'slug':'gpt-6-astra','display_name':'GPT-6-Astra','visibility':'list',
                'context_window':272000,'max_context_window':872000}]}))
            with patch.dict(os.environ,{'CODEX_HOME':directory}), patch('sys.stdin',io.StringIO('1\n')), patch('subprocess.run') as cli, contextlib.redirect_stderr(io.StringIO()):
                selected=SETUP.select_model('/fixture/masc','codex')
            self.assertEqual(selected,dict(model='gpt-6-astra',max_context=272000))
            cli.assert_not_called()

    def test_empty_codex_cache_uses_installed_list(self):
        with tempfile.TemporaryDirectory() as directory, patch.dict(os.environ, {'CODEX_HOME':directory}):
            def cli(argv, **kwargs):
                data=({'models':[dict(id='catalog-id',label='Catalog model',max_context=9876)]}
                      if argv[1]=='runtime-model-list' else dict(model='catalog-id',max_context=9876))
                return subprocess.CompletedProcess(argv,0,json.dumps(data),'')
            with patch('subprocess.run',side_effect=cli), patch('sys.stdin',io.StringIO('99\n1\n')), contextlib.redirect_stderr(io.StringIO()) as terminal:
                selected=SETUP.select_model('/fixture/masc','codex')
            self.assertEqual(selected,dict(model='catalog-id',max_context=9876))
            self.assertIn('account availability',terminal.getvalue())

    def test_http_models_offer_actual_server_id_and_configured_limit(self):
        from http.server import BaseHTTPRequestHandler, HTTPServer
        import threading
        class Handler(BaseHTTPRequestHandler):
            def do_GET(self):
                assert self.path == '/v1/models'
                payload=json.dumps({'data':[{'id':'served-model','max_model_len':8192}]}).encode()
                self.send_response(200);self.send_header('Content-Length',str(len(payload)));self.end_headers();self.wfile.write(payload)
            def log_message(self,*args): pass
        with HTTPServer(('127.0.0.1',0),Handler) as server:
            thread=threading.Thread(target=server.serve_forever);thread.start()
            try:
                with patch('sys.stdin',io.StringIO('1\n')), contextlib.redirect_stderr(io.StringIO()):
                    selected=SETUP.select_model('/unused','vllm','http://127.0.0.1:'+str(server.server_port)+'/v1')
                self.assertEqual(selected,dict(model='served-model',max_context=8192))
            finally:
                server.shutdown();thread.join()

    def test_context_lookup_rejects_wrong_identity_and_bool(self):
        replies=[dict(model='another',max_context=123),dict(model='manual',max_context=True)]
        for reply in replies:
            def cli(argv,**kwargs):
                return subprocess.CompletedProcess(argv,0,json.dumps({'models':[]} if argv[1]=='runtime-model-list' else reply),'')
            with self.subTest(reply=reply), patch('subprocess.run',side_effect=cli), patch('sys.stdin',io.StringIO('manual\nq\n')), contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SETUP.SetupError):
                SETUP.select_model('/fixture/masc','claude_code')


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
                if choice in ('vllm', 'llama_cpp', 'openai_compatible'):
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

    def test_failed_validator_preserves_both_files_and_reports_the_reason(self):
        self.validator("print('model alias is absent from the capability catalog', file=sys.stderr)\nsys.exit(1)\n")
        with self.assertRaises(SETUP.SetupError) as caught:
            SETUP.configure(self.binary, self.base, spec())
        self.assertIn('model alias is absent from the capability catalog', str(caught.exception))
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

    def test_http_exact_target_uses_same_endpoint_model_and_credential(self):
        import tomllib
        runtime_id, _, overlay = SETUP.render(dict(spec(), api_key_env='MY_MODEL_KEY'))
        catalog = tomllib.loads(overlay.decode())
        provider = catalog['providers'][0]
        target = catalog['targets'][0]
        self.assertEqual(provider['base_url'], spec()['endpoint'])
        self.assertEqual(provider['api_key_env'], 'MY_MODEL_KEY')
        self.assertEqual(target, dict(id=runtime_id, provider_ref=provider['id'], model_id=spec()['model']))

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
class InstalledModelCatalog(unittest.TestCase):
    def test_astra_exact_provider_scoped_catalog_is_not_generic_gpt_fallback(self):
        result=subprocess.run([BINARY,'runtime-model-list','codex'],check=True,capture_output=True,text=True)
        models=json.loads(result.stdout)['models']
        astra=next(row for row in models if row['id']=='gpt-6-astra')
        self.assertEqual(astra['max_context'],1050000)
        result=subprocess.run([BINARY,'runtime-model-info','gpt-6-astra','--client','codex'],check=True,capture_output=True,text=True)
        self.assertEqual(json.loads(result.stdout)['max_context'],1050000)
        unknown=subprocess.run([BINARY,'runtime-model-info','gpt-unknown-fixture','--client','codex'],capture_output=True,text=True)
        self.assertNotEqual(unknown.returncode,0)
        self.assertEqual(unknown.stdout,'')

    def test_claude_list_includes_sonnet5_and_selects_without_context_question(self):
        result=subprocess.run([BINARY,'runtime-model-list','claude-code'],check=True,capture_output=True,text=True)
        catalog=json.loads(result.stdout)
        self.assertIs(catalog['account_availability_verified'],False)
        models=catalog['models']
        sonnet=next(row for row in models if row['id']=='claude-sonnet-5')
        self.assertEqual(sonnet['max_context'],1000000)
        self.assertTrue(all(row['id'].startswith('claude-') and row['max_context']>0 for row in models))
        self.assertNotIn('claude_code',{row['id'] for row in models})
        index=models.index(sonnet)+1
        with patch('sys.stdin',io.StringIO(str(index)+'\n')), contextlib.redirect_stderr(io.StringIO()) as terminal:
            selected=SETUP.select_model(BINARY,'claude_code')
        self.assertEqual(selected,dict(model='claude-sonnet-5',max_context=1000000))
        self.assertIn('No number to enter',terminal.getvalue())
        self.assertNotIn('Documented/configured context limit',terminal.getvalue())


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
