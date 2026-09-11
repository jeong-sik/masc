"""Selected-only rendering and transactional publication through the real helper."""
import contextlib
import io
import importlib.util
import json
import os
import pty
import select
import termios
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
    if choice in ('vllm', 'llama_cpp', 'openai_compatible', 'ollama', 'messages'):
        result['endpoint'] = 'http://127.0.0.1:9/v1'
        if choice == 'messages':
            result['provider_kind'] = 'anthropic'
    elif choice == 'antigravity':
        result.update(credential_file='/operator/token-file', timeout_s=180)
    return result


class ModelSelection(unittest.TestCase):
    def test_independent_catalog_sources_are_visible_without_runtime_bindings(self):
        inventory = dict(runtimes=[], integrations=[dict(
            id='openrouter', display_name='OpenRouter', protocol='openai-compatible-http',
            endpoint='https://openrouter.ai/api/v1', api_key_env='OPENROUTER_API_KEY',
            origin='agent_core_catalog', setup_support='new_connection', provider_kind='openai_compat')])
        rows = SETUP.connection_sources(inventory)
        source = next(row for row in rows if row['provider_id'] == 'openrouter')
        self.assertEqual(source['choice'], 'openai_compatible')
        self.assertEqual(source['endpoint'], 'https://openrouter.ai/api/v1')
        self.assertEqual(source['rows'], [])

    def test_integration_only_private_auth_is_preserved_or_explicitly_protected(self):
        for kind in ('file', 'inline'):
            integration = dict(id='private-provider', display_name='Private', protocol='openai-compatible-http',
                               endpoint='https://example.com/v1', origin='runtime_config',
                               setup_support='new_connection', credential_kind=kind)
            if kind == 'file':
                integration['credential_file'] = '/private/owned-api-key'
            source = SETUP.connection_sources(dict(runtimes=[], integrations=[integration]))[0]
            self.assertEqual(source['credential_kind'], kind)
            if kind == 'file':
                with patch.object(SETUP, 'native_discover_models', return_value=([], 'server')) as discover:
                    SETUP.source_models('/fixture', source, 10)
                self.assertEqual(discover.call_args.args[1]['credential_file'], '/private/owned-api-key')
                _, selected = SETUP.resolve_model_spec(source, dict(id='new-model',context=8192), 10)
                self.assertEqual(selected['credential_file'], '/private/owned-api-key')
                self.assertNotIn('api_key_env', selected)
            else:
                with patch.object(SETUP, 'native_discover_models', side_effect=AssertionError('anonymous request')):
                    self.assertEqual(SETUP.source_models('/fixture', source, 10)[0], [])
                with self.assertRaisesRegex(SETUP.SetupError, 'protected credential'):
                    SETUP.resolve_model_spec(source, dict(id='new-model',context=8192), 10)

    def test_private_key_is_piped_and_removed_when_setup_does_not_commit(self):
        with tempfile.TemporaryDirectory() as directory:
            key = Path(directory, 'pending-key')
            def save(argv, **kwargs):
                self.assertEqual(argv, ['/fixture/masc', 'runtime-store-credential'])
                self.assertEqual(kwargs['input'], 'hidden-secret')
                self.assertNotIn('hidden-secret', str(argv))
                key.write_text(kwargs['input'])
                key.chmod(0o600)
                return subprocess.CompletedProcess(argv, 0, json.dumps(dict(
                    schema='masc.private_credential_reference.v1', credential_file=str(key))), '')
            with patch.object(SETUP.sys.stdin, 'isatty', return_value=True), \
                    patch.object(SETUP.getpass, 'getpass', return_value='hidden-secret'), \
                    patch.object(SETUP.subprocess, 'run', side_effect=save), \
                    SETUP.PendingCredentials('/fixture/masc') as credentials:
                self.assertEqual(credentials.save(), str(key))
                self.assertTrue(key.exists())
            self.assertFalse(key.exists())

    def test_successfully_committed_key_remains_private(self):
        with tempfile.TemporaryDirectory() as directory:
            key = Path(directory, 'committed-key')
            key.write_text('hidden-secret')
            key.chmod(0o600)
            result = subprocess.CompletedProcess([], 0, json.dumps(dict(
                schema='masc.private_credential_reference.v1', credential_file=str(key))), '')
            with patch.object(SETUP.sys.stdin, 'isatty', return_value=True), \
                    patch.object(SETUP.getpass, 'getpass', return_value='hidden-secret'), \
                    patch.object(SETUP.subprocess, 'run', return_value=result), \
                    SETUP.PendingCredentials('/fixture/masc') as credentials:
                path = credentials.save()
                credentials.retain([dict(credential_file=path)])
            self.assertTrue(key.exists())
            self.assertEqual(key.stat().st_mode & 0o777, 0o600)

    def test_replaced_key_creates_new_binding_instead_of_reusing_old_env_auth(self):
        source = dict(choice='openai_compatible', endpoint='https://provider.invalid/v1',
                      api_key_env='', credential_file='/private/saved-key', credential_kind='file',
                      credential_replaced=True, rows=[dict(id='old.binding', model='same-model',
                      max_context=8192, tools=True)])
        with patch.object(SETUP, 'native_discover_models', return_value=(
                [dict(id='same-model', label='Model', context=None)], 'server')):
            models, _ = SETUP.source_models('/fixture/masc', source, 10)
        self.assertEqual(len(models), 1)
        self.assertIsNone(models[0]['existing'])
        runtime, selected = SETUP.resolve_model_spec(source, models[0], 10)
        self.assertNotEqual(runtime, 'old.binding')
        self.assertEqual(selected['credential_file'], '/private/saved-key')
        self.assertNotIn('api_key_env', selected)

    def test_messages_kind_and_path_are_preserved_in_native_catalog_overlay(self):
        import tomllib
        configured = dict(spec('messages'), credential_file='/private/saved-key', request_path='/v1/messages')
        _, runtime, overlay = SETUP.render(configured)
        self.assertNotIn(b'hidden-secret', runtime + overlay)
        catalog = tomllib.loads(overlay.decode())
        self.assertEqual(catalog['providers'][0]['kind'], 'anthropic')
        self.assertEqual(catalog['providers'][0]['request_path'], '/v1/messages')
        providers = tomllib.loads(runtime.decode())['providers']
        self.assertEqual(next(iter(providers.values()))['credentials'], dict(type='file', path='/private/saved-key'))

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

    def test_fresh_codex_uses_client_catalog_before_rendering_connection(self):
        with tempfile.TemporaryDirectory() as directory, patch.dict(os.environ, {'CODEX_HOME':directory}):
            def cli(argv, **kwargs):
                if argv[0] == '/owned/codex':
                    self.assertEqual(argv[1:], ['debug','models','--bundled'])
                    self.assertNotEqual(kwargs['env']['CODEX_HOME'],directory)
                    self.assertNotIn('UNRELATED_API_KEY',kwargs['env'])
                    self.assertNotIn('OPENAI_API_KEY',kwargs['env'])
                    self.assertEqual(kwargs['cwd'],kwargs['env']['HOME'])
                    data={'models':[dict(slug='catalog-id',display_name='Client model',visibility='list',
                                         context_window=272000,max_context_window=872000)]}
                else:
                    self.assertEqual(argv[1],'runtime-model-list')
                    data={'models':[dict(id='catalog-id',label='API model',max_context=1050000)]}
                return subprocess.CompletedProcess(argv,0,json.dumps(data),'')
            source=dict(choice='codex',endpoint='',api_key_env='',command='/owned/codex',rows=[])
            with patch.dict(os.environ,{'UNRELATED_API_KEY':'canary','OPENAI_API_KEY':'canary'}), patch('subprocess.run',side_effect=cli):
                models,origin=SETUP.source_models('/fixture/masc',source,10)
                _,selected=SETUP.resolve_model_spec(source,models[0],10)
            self.assertEqual(selected['model'],'catalog-id')
            self.assertEqual(selected['max_context'],272000)
            self.assertEqual(selected['command'],'/owned/codex')
            self.assertIn('CLI bundled',origin)
            self.assertEqual(list(Path(directory).iterdir()),[])

    def test_unavailable_codex_catalog_does_not_inherit_api_capacity(self):
        with tempfile.TemporaryDirectory() as directory, patch.dict(os.environ, {'CODEX_HOME':directory}):
            def cli(argv, **kwargs):
                if argv[1] == 'debug':
                    return subprocess.CompletedProcess(argv,1,'','unsupported client command')
                self.assertEqual(argv[1],'runtime-model-list')
                return subprocess.CompletedProcess(argv,0,json.dumps({'models':[
                    dict(id='catalog-id',label='API model',max_context=1050000)]}),'')
            with patch('subprocess.run',side_effect=cli), patch('sys.stdin',io.StringIO('1\nq\n')), contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SETUP.SetupError):
                SETUP.select_model('/fixture/masc','codex')

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
        self.binary.write_text('#!' + sys.executable + '\nimport sys,json\nfrom pathlib import Path\n' + \
            "if sys.argv[1] == 'runtime-wizard-catalog':\n print(json.dumps({'runtimes':[{'id':'original.model'}]})); sys.exit(0)\n" + code)
        self.binary.chmod(0o755)

    def test_selected_transport_uses_only_operator_model_and_capabilities(self):
        for choice in SETUP.CHOICES:
            with self.subTest(choice=choice):
                identity, runtime, overlay = SETUP.render(spec(choice))
                self.assertIn('setup_' + choice, identity)
                self.assertIn(b'operator/model-exact', runtime)
                self.assertIn(b'"max-context" = 8192', runtime)
                if choice in ('vllm', 'llama_cpp', 'openai_compatible', 'ollama', 'messages'):
                    self.assertIn(('"provider_name" = ' + SETUP.toml(identity.split('.')[0])).encode(), overlay)
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

    def test_multiple_connections_keep_identity_default_and_fallback_order(self):
        first, second = spec(), dict(spec(), model='another-owned-model')
        first_id, second_id = SETUP.render(first)[0], SETUP.render(second)[0]
        self.validator('''assert sys.argv[1] == 'runtime-default-set'
assert sys.argv[4:] == ''' + repr([second_id, '--setup-lanes', '--setup-imp', '--fallback-runtime', 'original.model', '--fallback-runtime', first_id]) + '''
runtime = Path(sys.argv[3]) / '.masc/config/runtime.toml'
runtime.write_text(runtime.read_text().replace('default = "original.model"', 'default = ' + json.dumps(sys.argv[4])))
''')
        result = SETUP.configure_many(self.binary, self.base, [first, second],
                                      ['original.model', first_id, second_id], default_id=second_id)
        self.assertEqual(result['runtime_ids'], [second_id, 'original.model', first_id])
        self.assertTrue(self.overlay.read_bytes().startswith(self.originals[1]))
        self.assertIn(b'another-owned-model', self.runtime.read_bytes())
        self.assertIn(b'operator/model-exact', self.runtime.read_bytes())
        self.assertNotEqual(first_id, second_id)
        self.assertNotEqual(first_id, SETUP.render(dict(first, endpoint='http://another.invalid/v1'))[0])

    def test_any_failed_selected_model_preserves_all_connections(self):
        self.validator('''if sys.argv[1] == 'runtime-verify':
 print(json.dumps({'schema':'masc.runtime_verification.v1','runtime_id':sys.argv[4],
                   'status':'failed','checks':{'response':True,'tool_roundtrip':False}}))
 sys.exit(1)
''')
        with self.assertRaises(SETUP.VerificationError):
            SETUP.configure_many(self.binary, self.base, [spec()], verify=True)
        self.assertEqual((self.runtime.read_bytes(), self.overlay.read_bytes()), self.originals)

    def test_unavailable_receipt_carries_the_configuration_detail(self):
        # A workspace config the server cannot parse reports the class alone
        # unless the detail travels with it, and the class reads as a model
        # connection problem. The recurring cause is an overlay entry holding
        # a capability field a later release removed (masc#34872).
        detail = ('catalog overlay /w/.masc/config/agent-core-models-overlay.toml: '
                  'model entry "GLM-5-Turbo" contains unknown field(s): '
                  'supports_extended_thinking')
        self.validator("""if sys.argv[1] == 'runtime-verify':
 print(json.dumps({'schema':'masc.runtime_verification.v1','runtime_id':sys.argv[4],
                   'status':'unavailable',
                   'checks':{'response':False,'tool_called':False,'tool_roundtrip':False},
                   'failure':{'code':'invalid_configuration',
                              'message':'The workspace runtime configuration could not be loaded.',
                              'detail':""" + repr(detail) + """}}))
 sys.exit(2)
""")
        with self.assertRaises(SETUP.VerificationError) as raised:
            SETUP.configure_many(self.binary, self.base, [spec()], verify=True)
        self.assertEqual(raised.exception.failure['code'], 'invalid_configuration')
        self.assertEqual(raised.exception.failure['detail'], detail)
        self.assertEqual((self.runtime.read_bytes(), self.overlay.read_bytes()), self.originals)

    def test_real_verification_receipt_must_join_selected_identity(self):
        self.validator('''if sys.argv[1] == 'runtime-verify':
 print(json.dumps({'schema':'masc.runtime_verification.v1','runtime_id':'another.runtime',
                   'status':'verified','checks':{'response':True,'tool_roundtrip':True}}))
''')
        with self.assertRaises(SETUP.VerificationError):
            SETUP.configure_many(self.binary, self.base, [spec()], verify=True)
        self.assertEqual((self.runtime.read_bytes(), self.overlay.read_bytes()), self.originals)

    def test_successful_model_verification_is_required_before_publish(self):
        self.validator('''if sys.argv[1] == 'runtime-verify':
 assert Path(sys.argv[3]) != Path(''' + repr(str(self.base)) + ''')
 print(json.dumps({'schema':'masc.runtime_verification.v1','runtime_id':sys.argv[4],
                   'status':'verified','checks':{'response':True,'tool_roundtrip':True}}))
''')
        result = SETUP.configure_many(self.binary, self.base, [spec()], verify=True)
        self.assertEqual(result['readiness'], 'verified')
        self.assertEqual(len(result['verifications']), 1)


class MultipleSelection(unittest.TestCase):
    def test_terminal_arrows_space_and_enter_preserve_multiple_choices_and_restore_tty(self):
        master, slave = pty.openpty()
        original = termios.tcgetattr(slave)
        program = ('import importlib.util,json; s=importlib.util.spec_from_file_location("setup",' +
                   repr(str(ROOT / 'scripts/install-runtime-setup.py')) +
                   '); m=importlib.util.module_from_spec(s); s.loader.exec_module(m); '
                   'print(json.dumps(m.pick("Choose connections",["Codex","Claude","Ollama"],multiple=True)))')
        process = subprocess.Popen([sys.executable, '-c', program], stdin=slave, stderr=slave,
                                   stdout=subprocess.PIPE, env=dict(os.environ, TERM='xterm'))
        try:
            terminal = b''
            while b'0 selected' not in terminal:
                self.assertTrue(select.select([master], [], [], 5)[0], 'picker did not render')
                terminal += os.read(master, 65536)
            os.write(master, b' \x1b[B \r')
            # macOS waits for terminal output to drain while restoring termios.
            # Keep consuming the UI, just as a real terminal emulator does.
            while True:
                ready = select.select([master, process.stdout], [], [], 5)[0]
                self.assertTrue(ready, 'picker did not finish')
                if master in ready:
                    terminal += os.read(master, 65536)
                if process.stdout in ready:
                    break
            output, _ = process.communicate(timeout=5)
            self.assertEqual(process.returncode, 0, terminal)
            self.assertEqual(json.loads(output), [0, 1])
            restored = termios.tcgetattr(slave)
            # PENDIN is kernel-maintained pending-input state on macOS, not a
            # terminal mode chosen by the picker.
            restored[3] &= ~getattr(termios, 'PENDIN', 0)
            original[3] &= ~getattr(termios, 'PENDIN', 0)
            self.assertEqual(restored, original)
        finally:
            if process.poll() is None:
                process.kill()
                process.wait()
            process.stdout.close()
            os.close(master)
            os.close(slave)

    def test_accessible_number_input_selects_several_without_model_typing(self):
        with patch('sys.stdin', io.StringIO('1,3\n')), contextlib.redirect_stderr(io.StringIO()):
            self.assertEqual(SETUP.pick('Connections', ['Codex', 'Claude', 'Ollama'], multiple=True), [0, 2])

    def test_ollama_loads_only_selected_model_and_uses_effective_context(self):
        responses = [{'capabilities':['completion','tools'], 'parameters':'',
                      'model_info':{'qwen.context_length':999999}}, {},
                     {'models':[{'name':'owned-qwen','context_length':16384}]}]
        source = dict(choice='ollama', endpoint='http://localhost:11434', api_key_env='', command='')
        with patch.object(SETUP, 'http_json', side_effect=responses) as requests:
            identity, configured = SETUP.resolve_model_spec(source, {'id':'owned-qwen','context':999999}, 10)
        self.assertEqual(configured['max_context'], 16384)
        self.assertIs(configured['tools'], True)
        self.assertEqual(requests.call_args_list[1].args[-1], {'model':'owned-qwen','stream':False})
        self.assertIn(b'"num-ctx" = 16384', SETUP.render(configured)[1])
        self.assertEqual(identity, SETUP.render(configured)[0])

    def test_ollama_architecture_maximum_never_becomes_effective_context(self):
        responses = [{'parameters':'', 'model_info':{'qwen.context_length':999999}}, {'models':[]}]
        with patch.object(SETUP, 'http_json', side_effect=responses):
            self.assertIsNone(SETUP.ollama_model_details('http://localhost:11434', 'owned-qwen')['context'])

    def test_workspace_context_is_matched_to_same_connection_and_exact_model(self):
        source = dict(choice='openai_compatible', endpoint='https://provider.invalid/v1', api_key_env='OWNED_KEY',
                      rows=[dict(id='glm.model', model='glm-5.3', max_context=200000, tools=True)])
        with patch.object(SETUP, 'native_discover_models', return_value=([
                dict(id='glm-5.3',label='GLM',context=None), dict(id='different-model',label='Other',context=None)], 'server')):
            rows, _ = SETUP.source_models('/fixture/masc', source, 10)
        self.assertEqual(rows[0]['context'], 200000)
        self.assertIsNone(rows[1]['context'])
        self.assertEqual(SETUP.resolve_model_spec(source, rows[0], 10), ('glm.model', None))

    def test_model_labels_cannot_inject_terminal_escape_sequences(self):
        self.assertNotIn('\x1b', SETUP.terminal_text('model\x1b[2J'))

    def test_distinct_existing_bindings_for_same_model_remain_selectable(self):
        source = dict(choice='openai_compatible', endpoint='http://localhost:8080/v1', api_key_env='', rows=[
            dict(id='provider.small', model='same-model', max_context=8192, tools=True),
            dict(id='provider.large', model='same-model', max_context=16384, tools=True)])
        with patch.object(SETUP, 'native_discover_models', return_value=([dict(id='same-model',label='Model',context=None)], 'server')):
            models, _ = SETUP.source_models('/fixture', source, 10)
        self.assertEqual([row['existing']['id'] for row in models], ['provider.small','provider.large'])
        self.assertEqual([row['context'] for row in models], [8192,16384])

    def test_protected_credentials_are_not_silently_cloned_without_auth(self):
        for kind in ('inline','file','unknown'):
            source = dict(choice='openai_compatible', credential_kind=kind)
            with self.subTest(kind=kind), self.assertRaisesRegex(SETUP.SetupError, 'protected credential'):
                SETUP.resolve_model_spec(source, dict(id='new-model',context=8192), 10)
            existing = dict(id='existing.id',tools=True)
            self.assertEqual(SETUP.resolve_model_spec(source, dict(existing=existing), 10), ('existing.id',None))

    def test_unreachable_selected_server_returns_to_recovery_menu(self):
        with patch.object(SETUP, 'configured_inventory', return_value={}), \
             patch.object(SETUP, 'select_connections', side_effect=OSError('private endpoint diagnostics')), \
             patch.object(SETUP, 'pick', return_value=[1]), contextlib.redirect_stderr(io.StringIO()) as terminal:
            result = SETUP.wizard('/fixture', '/workspace', 10)
        self.assertEqual(result['readiness'], 'deferred')
        self.assertNotIn('private endpoint diagnostics', terminal.getvalue())

    def test_invalid_existing_workspace_can_choose_unused_sibling_without_writes(self):
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory) / 'workspace'
            base.mkdir()
            old = base / 'old-state'
            old.write_bytes(b'preserve this state')
            replies = [subprocess.CompletedProcess([],1,json.dumps(dict(status='needs_attention',issues=[
                dict(path=str(old),detail='unsupported schema')]))),
                subprocess.CompletedProcess([],0,json.dumps(dict(status='ready',read_only=True,scope='keeper_goal_state_schema')))]
            with patch('subprocess.run',side_effect=replies), patch.object(SETUP,'pick',return_value=[0]), \
                 patch('sys.stdin.isatty',return_value=True), contextlib.redirect_stderr(io.StringIO()):
                result = SETUP.workspace_check('/fixture',base)
            self.assertEqual(result['base_path'], str(base.resolve()) + '-new')
            self.assertEqual(old.read_bytes(), b'preserve this state')
            self.assertFalse(Path(result['base_path']).exists())


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
    def test_multiple_models_bind_imp_and_reselection_preserves_both_connections(self):
        import tomllib
        fixture = ROOT / 'scripts/fixtures/release-evidence'
        with tempfile.TemporaryDirectory(prefix='runtime-multiple-cli-') as tmp:
            base = Path(tmp)
            config = base / '.masc/config'
            config.mkdir(parents=True)
            for name in ('runtime.toml', 'agent-core-models-overlay.toml'):
                (config / name).write_bytes((fixture / name).read_bytes())
            models = [spec(), dict(spec(), model='second-owned-model')]
            ids = [SETUP.render(model)[0] for model in models]
            env = {k:v for k,v in os.environ.items() if not k.startswith(('MASC_', 'AGENT_CORE_'))}
            with patch.dict(os.environ,env,clear=True):
                SETUP.configure_many(BINARY,base,models,ids,default_id=ids[1])
                configured = tomllib.loads((config / 'runtime.toml').read_text())
                self.assertEqual(configured['runtime']['default'],ids[1])
                self.assertEqual(configured['runtime']['assignments']['imp'],ids[1])
                self.assertEqual(configured['runtime']['lanes'][ids[1]]['candidates'],[ids[1],ids[0]])
                SETUP.configure_many(BINARY,base,[],[ids[0]])
                inventory = SETUP.configured_inventory(BINARY,base)
                self.assertTrue(set(ids) <= {row['id'] for row in inventory['runtimes']})
                configured = tomllib.loads((config / 'runtime.toml').read_text())
                self.assertEqual(configured['runtime']['assignments']['imp'],ids[0])

    def test_real_validator_accepts_each_transport_and_reuses_identical_connection(self):
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
                    second = SETUP.configure(BINARY, base, selected)
                    self.assertEqual(second['runtime_id'], result['runtime_id'])
                    self.assertEqual(before, [(config / name).read_bytes() for name in ('runtime.toml', 'agent-core-models-overlay.toml')])


if __name__ == '__main__':
    unittest.main()
