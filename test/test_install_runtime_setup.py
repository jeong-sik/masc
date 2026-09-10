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
    def setUp(self):
        renderer = patch.object(SETUP, 'render', return_value=('fixture.native-model', b'', b''))
        self.renderer = renderer.start()
        self.addCleanup(renderer.stop)

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

    def test_antigravity_account_switch_drops_old_models_and_context(self):
        source = dict(choice='antigravity', endpoint='', api_key_env='',
                      credential_file='/private/new-account', credential_kind='file',
                      credential_replaced=True, rows=[
                          dict(id='old.shared', model='shared-model', max_context=8192),
                          dict(id='old.exclusive', model='old-account-only', max_context=16384)])
        with patch.object(SETUP, 'antigravity_models', return_value=[
                dict(id='shared-model', label='Shared model', context=None),
                dict(id='new-model', label='New model', context=65536)]):
            models, _ = SETUP.source_models('/fixture/masc', source, 10)
        self.assertEqual([model['id'] for model in models], ['shared-model', 'new-model'])
        self.assertIsNone(models[0]['context'])
        self.assertEqual(models[1]['context'], 65536)
        self.assertTrue(all(model['existing'] is None for model in models))

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


class RuntimeSetupAdapter(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='native-setup-adapter-')
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name)
        self.revision = 'a' * 64
        self.requests = []
        self.transports = []

    def native(self, argv, **kwargs):
        command = argv[1]
        self.assertEqual(argv[0], '/fixture/masc')
        self.transports.append(command)
        payload = None
        if command != 'runtime-setup-inventory':
            path = Path(argv[-1])
            self.assertEqual(path.stat().st_mode & 0o777, 0o600)
            self.assertNotIn('operator/model-exact', str(argv))
            payload = json.loads(path.read_text())
            self.requests.append((path, payload))
        if command == 'runtime-setup-render':
            value = dict(runtime_id='native.' + payload['model'], runtime_toml='native runtime', model_overlay_toml='native overlay')
        elif command == 'runtime-setup-inventory':
            value = dict(runtimes=[dict(id='original.model')], setup_revision=self.revision)
        elif command == 'runtime-setup-batch':
            value = dict(runtime_id=payload['default_runtime_id'], runtime_ids=payload['runtime_ids'],
                         configured=True, validation='passed', readiness='verified' if payload['verify'] else 'not_probed')
        else:
            self.fail('Unexpected native command: ' + command)
        return subprocess.CompletedProcess(argv, 0, json.dumps(value), '')

    def test_native_identity_and_private_transport_are_used_without_local_rendering(self):
        with patch.object(SETUP.subprocess, 'run', side_effect=self.native):
            identity, runtime, overlay = SETUP.render(spec(), '/fixture/masc')
        self.assertEqual((identity, runtime, overlay), ('native.operator/model-exact', b'native runtime', b'native overlay'))
        self.assertFalse(self.requests[0][0].exists())
        with self.assertRaises(SETUP.SetupError):
            SETUP.render(spec(), None)

    def test_multi_selection_uses_original_revision_and_native_default_order(self):
        first, second = spec(), dict(spec(), model='other-model')
        with patch.object(SETUP.subprocess, 'run', side_effect=self.native):
            result = SETUP.configure_many('/fixture/masc', self.base, [first, second],
                ['original.model', 'native.operator/model-exact', 'native.other-model'],
                default_id='native.other-model', verify=True, expected_revision=self.revision)
        self.assertNotIn('runtime-setup-inventory', self.transports)
        request = self.requests[-1][1]
        self.assertEqual(request['expected_revision'], self.revision)
        self.assertEqual(request['runtime_ids'], ['native.other-model', 'original.model', 'native.operator/model-exact'])
        self.assertEqual(result['readiness'], 'verified')
        self.assertEqual(request['connections'], [first, second])

    def test_noninteractive_configuration_observes_before_rendering(self):
        with patch.object(SETUP.subprocess, 'run', side_effect=self.native):
            SETUP.configure('/fixture/masc', self.base, spec())
        self.assertEqual(self.transports, ['runtime-setup-inventory', 'runtime-setup-render', 'runtime-setup-batch'])

    def test_native_verification_failure_identifies_connection_without_raw_diagnostics(self):
        response = dict(schema='masc.runtime_setup_error.v1', kind='verification_failed', runtime_id='failed.runtime', error='safe error')
        with patch.object(SETUP.subprocess, 'run', return_value=subprocess.CompletedProcess([], 1, json.dumps(response), 'private provider diagnostics')):
            with self.assertRaises(SETUP.VerificationError) as error:
                SETUP.native_setup_command('/fixture/masc', 'runtime-setup-batch', {})
        self.assertEqual(error.exception.runtime_id, 'failed.runtime')
        self.assertNotIn('private provider diagnostics', str(error.exception))

    def test_changed_configuration_is_not_reobserved_to_silently_accept_stale_choices(self):
        def cli(argv, **kwargs):
            if argv[1] == 'runtime-setup-batch':
                return subprocess.CompletedProcess(argv, 1, json.dumps(dict(schema='masc.runtime_setup_error.v1',
                    kind='changed_configuration', error='Configuration changed; refresh the selection before saving.')), '')
            return self.native(argv, **kwargs)
        with patch.object(SETUP.subprocess, 'run', side_effect=cli), self.assertRaisesRegex(SETUP.SetupError, 'Configuration changed'):
            SETUP.configure_many('/fixture/masc', self.base, [spec()], expected_revision=self.revision)
        self.assertNotIn('runtime-setup-inventory', self.transports)

    def test_unjoined_success_receipt_is_refused(self):
        with patch.object(SETUP, 'render', return_value=('native.model', b'', b'')), \
                patch.object(SETUP, 'native_setup_command', return_value=dict(runtime_id='wrong.model', runtime_ids=['wrong.model'],
                    configured=True, validation='passed', readiness='verified')), self.assertRaises(SETUP.SetupError):
            SETUP.configure_many('/fixture/masc', self.base, [spec()], verify=True, expected_revision=self.revision)

    def test_lost_commit_receipt_does_not_delete_selected_credentials(self):
        key = self.base / 'pending-key'
        key.write_text('fixture-only-private-key')
        key.chmod(0o600)
        selected = dict(spec(), credential_file=str(key))
        with SETUP.PendingCredentials('/fixture/masc') as credentials, \
                patch.object(SETUP, 'render', return_value=('native.model', b'', b'')), \
                patch.object(SETUP, 'configured_inventory', return_value=dict(runtimes=[], setup_revision=self.revision)), \
                patch.object(SETUP, 'select_connections', return_value=(['native.model'], [selected], {'native.model':'Selected model'})), \
                patch.object(SETUP, 'pick', side_effect=[[0], [1]]), \
                patch.object(SETUP, 'configure_many', side_effect=SETUP.SetupError('receipt lost')), \
                contextlib.redirect_stderr(io.StringIO()):
            credentials.register_account_reference(str(key))
            SETUP.wizard_with_credentials('/fixture/masc', self.base, 10, credentials)
        self.assertTrue(key.exists())


class MultipleSelection(unittest.TestCase):
    def setUp(self):
        renderer = patch.object(SETUP, 'render', return_value=('fixture.native-model', b'', b''))
        self.renderer = renderer.start()
        self.addCleanup(renderer.stop)

    def terminal_choice(self, keys, expected):
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
            os.write(master, keys)
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
            self.assertEqual(json.loads(output), expected)
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

    def test_terminal_arrows_space_and_enter_preserve_multiple_choices_and_restore_tty(self):
        self.terminal_choice(b' \x1b[B \r', [0, 1])

    def test_enter_selects_focused_option_without_space_or_typing(self):
        self.terminal_choice(b'\x1b[B\r', [1])

    def test_accessible_enter_selects_first_option(self):
        with patch('sys.stdin', io.StringIO('\n')), contextlib.redirect_stderr(io.StringIO()):
            self.assertEqual(SETUP.pick('Connections', ['Codex', 'Claude'], multiple=True), [0])

    def test_fast_setup_still_exposes_every_provider_through_browse(self):
        sources = [dict(choice='claude_code', command='claude', credential_file=None, api_key_env='',
                        endpoint='', label='Claude Code'),
                   dict(choice='openai_compatible', command='', credential_file=None, api_key_env='FIXTURE_NO_API_KEY',
                        endpoint='https://example.org', label='Another provider')]
        with patch.object(SETUP.shutil, 'which', return_value='/owned/claude'), \
                patch.dict(os.environ, {'FIXTURE_NO_API_KEY': ''}), \
                patch.object(SETUP, 'pick', side_effect=[[3], [1]]) as picker:
            shown, selected = SETUP.pick_connection_sources(sources)
        self.assertEqual(len(picker.call_args_list[0].args[1]), 4)
        self.assertIn('Fast setup', picker.call_args_list[0].args[0])
        self.assertEqual(shown[selected[0]], sources[1])

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
        self.renderer.assert_called_once_with(configured, None)
        self.assertEqual(identity, 'fixture.native-model')

    def test_wizard_ollama_context_uses_native_private_reference(self):
        source = dict(choice='ollama', endpoint='http://localhost:11434', api_key_env='',
                      credential_kind='file', credential_file='/private/key', command='')
        with patch.object(SETUP, 'native_serving_context', return_value=dict(context=16384, tools=True)) as native, \
                patch.object(SETUP, 'http_json') as legacy:
            _, configured = SETUP.resolve_model_spec(source, dict(id='owned-model', context=999999), 10,
                                                      binary='/fixture/masc')
        native.assert_called_once_with('/fixture/masc', source, 'owned-model', 10, load=True)
        legacy.assert_not_called()
        self.assertEqual(configured['max_context'], 16384)
        self.assertEqual(configured['credential_file'], '/private/key')

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
                 patch.object(SETUP,'workspace_upgrade_catalog',return_value=dict(keepers=[],backups=[])), \
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
    def test_native_fractional_identity_survives_json_transport(self):
        selected = dict(spec('antigravity'), timeout_s=824.844977148233)
        first = SETUP.render(selected, BINARY)
        second = SETUP.render(dict(selected, timeout_s=824.8449771482331), BINARY)
        self.assertEqual(first, second)
        self.assertIn(b'operator/model-exact', first[1])

    def test_selection_revision_detects_later_workspace_edit_before_any_publish(self):
        fixture = ROOT / 'scripts/fixtures/release-evidence'
        with tempfile.TemporaryDirectory(prefix='runtime-native-cas-') as directory:
            base = Path(directory)
            config = base / '.masc/config'
            config.mkdir(parents=True)
            for name in ('runtime.toml', 'agent-core-models-overlay.toml'):
                (config / name).write_bytes((fixture / name).read_bytes())
            env = {k:v for k,v in os.environ.items() if not k.startswith(('MASC_', 'AGENT_CORE_'))}
            with patch.dict(os.environ, env, clear=True):
                original_selection = SETUP.configured_inventory(BINARY, base)
                runtime = config / 'runtime.toml'
                runtime.write_bytes(runtime.read_bytes() + b'\n# later operator edit\n')
                before = [p.read_bytes() for p in (runtime, config / 'agent-core-models-overlay.toml')]
                with self.assertRaisesRegex(SETUP.SetupError, 'Configuration changed'):
                    SETUP.configure_many(BINARY, base, [spec()], expected_revision=original_selection['setup_revision'])
                self.assertEqual(before, [p.read_bytes() for p in (runtime, config / 'agent-core-models-overlay.toml')])

    def test_messages_kind_and_path_are_preserved_in_native_catalog_overlay(self):
        import tomllib
        configured = dict(spec('messages'), credential_file='/private/saved-key', request_path='/v1/messages')
        _, runtime, overlay = SETUP.render(configured, BINARY)
        self.assertNotIn(b'hidden-secret', runtime + overlay)
        catalog = tomllib.loads(overlay.decode())
        self.assertEqual(catalog['providers'][0]['kind'], 'anthropic')
        self.assertEqual(catalog['providers'][0]['request_path'], '/v1/messages')
        providers = tomllib.loads(runtime.decode())['providers']
        self.assertEqual(next(iter(providers.values()))['credentials'], dict(type='file', path='/private/saved-key'))

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
            ids = [SETUP.render(model, BINARY)[0] for model in models]
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
