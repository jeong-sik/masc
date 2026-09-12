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
import time
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


def named_spec(model_id, provider='openrouter', endpoint='https://openrouter.ai/api/v1', key='OPENROUTER_API_KEY'):
    result = dict(choice='openai_compatible', model=model_id, max_context=1000000, tools=True, streaming=True,
                  endpoint=endpoint, api_key_env=key, provider_id=provider,
                  provider_display_name=provider, model_key=SETUP.model_slug(model_id),
                  provider_declared=False, thinking_disable_encodable=True, reasoning_effort='high')
    return result


def presentation_readiness(base='/tmp/workspace', parser='started', renderer='missing'):
    return dict(schema='masc.presentation_tools_readiness.v1', scope='workspace_host_runtime',
                base_path=base, presentation_inspection='not_run',
                status='tools_available' if parser == renderer == 'started' else 'unavailable',
                checks=[dict(component='python_pptx', command=base + '/.masc/runtime-tools/presentation/bin/python3', status=parser),
                        dict(component='libreoffice', command='soffice', status=renderer)])


class PresentationPrerequisites(unittest.TestCase):
    def test_partial_install_stays_unavailable_and_uses_selected_workspace(self):
        readiness = presentation_readiness()
        catalog = dict(schema='masc.prerequisite_actions.v1', dependency_readiness=readiness,
                       actions=[dict(id='presentation_parser_install', label='Install parser', detail='Workspace parser',
                                     source_url='https://python-pptx.readthedocs.io/en/latest/user/install.html', requires_admin=False)])
        receipt = dict(schema='masc.prerequisite_action_result.v1', status='commands_completed_recheck_required',
                       readiness='unavailable', dependency_readiness=readiness)
        output = io.StringIO()
        with patch.object(SETUP.subprocess, 'run', side_effect=[
                subprocess.CompletedProcess([], 0, json.dumps(catalog), ''),
                subprocess.CompletedProcess([], 0, json.dumps(receipt), '')]) as run, \
                patch.object(SETUP, 'pick', return_value=(0, 'Install parser')), contextlib.redirect_stderr(output):
            self.assertTrue(SETUP.prerequisite_menu('masc', 'presentation-tools', base_path='/tmp/workspace'))
        self.assertTrue(all(call.args[0][-2:] == ['--base-path', '/tmp/workspace'] for call in run.call_args_list))
        self.assertIn('libreoffice: missing', output.getvalue())
        self.assertNotIn('Both presentation dependencies started successfully', output.getvalue())

    def test_claimed_ready_cannot_hide_a_failed_parser(self):
        readiness = presentation_readiness(parser='failed', renderer='started')
        readiness['status'] = 'tools_available'
        with self.assertRaises(SETUP.SetupError):
            SETUP.decode_presentation_tools_readiness(readiness)

    def test_ready_other_workspace_does_not_enable_the_selected_workspace(self):
        with self.assertRaisesRegex(SETUP.SetupError, 'another workspace'):
            SETUP.decode_presentation_tools_readiness(
                presentation_readiness(base='/tmp/other', renderer='started'), '/tmp/selected')

    @unittest.skipUnless(BINARY, 'requires CI-built native executable')
    def test_successful_install_commands_cannot_hide_failed_renderer_probe(self):
        with tempfile.TemporaryDirectory() as directory:
            commands = Path(directory) / 'commands'
            commands.mkdir()
            # Package managers are fixtures: this test must never install host packages.
            for name, code in [('brew', 0), ('sudo', 0), ('soffice', 7)]:
                command = commands / name
                command.write_text('#!/bin/sh\nexit ' + str(code) + '\n')
                command.chmod(0o755)
            env = dict(os.environ, PATH=str(commands) + os.pathsep + os.environ.get('PATH', ''))
            base = Path(directory) / 'workspace'
            base.mkdir()
            args = [BINARY, 'prerequisite-actions', 'presentation-tools', '--base-path', str(base)]
            catalog = subprocess.run(args, env=env, capture_output=True, text=True, check=True)
            actions = json.loads(catalog.stdout)['actions']
            if not any(row['id'] == 'presentation_renderer_install' for row in actions):
                self.skipTest('host has only manual renderer instructions')
            result = subprocess.run(args + ['--execute', 'presentation_renderer_install'],
                                    env=env, capture_output=True, text=True)
            receipt = json.loads(result.stdout)
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(receipt['status'], 'failed')
            self.assertEqual(receipt['readiness'], 'unavailable')
            self.assertEqual(list(base.iterdir()), [], 'renderer fixture cannot create a parser environment')

    @unittest.skipUnless(BINARY, 'requires CI-built native executable')
    def test_native_catalog_does_not_substitute_another_python(self):
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory) / 'workspace'
            base.mkdir()
            commands = Path(directory) / 'commands'
            commands.mkdir()
            renderer = commands / 'soffice'
            renderer.write_text('#!/bin/sh\nprintf "fixture LibreOffice version\\n"\n')
            renderer.chmod(0o755)
            env = dict(os.environ, PATH=str(commands) + os.pathsep + os.environ.get('PATH', ''))
            before = list(base.iterdir())
            result = subprocess.run([BINARY, 'prerequisite-actions', 'presentation-tools', '--base-path', str(base)],
                                    env=env, capture_output=True, text=True, check=True)
            self.assertEqual(list(base.iterdir()), before, 'detection must not install or create a workspace environment')
            observed = SETUP.decode_presentation_tools_readiness(json.loads(result.stdout)['dependency_readiness'])
            checks = {row['component']: row for row in observed['checks']}
            self.assertEqual(checks['python_pptx']['status'], 'missing')
            self.assertEqual(checks['libreoffice']['status'], 'started')
            self.assertEqual(observed['status'], 'unavailable')
            # An actual isolated interpreter without third-party packages must
            # fail the import, even though the interpreter itself starts.
            venv = base / '.masc/runtime-tools/presentation'
            subprocess.run([sys.executable, '-I', '-m', 'venv', '--without-pip', str(venv)], check=True)
            result = subprocess.run([BINARY, 'prerequisite-actions', 'presentation-tools', '--base-path', str(base)],
                                    env=env, capture_output=True, text=True, check=True)
            observed = SETUP.decode_presentation_tools_readiness(json.loads(result.stdout)['dependency_readiness'])
            parser = next(row for row in observed['checks'] if row['component'] == 'python_pptx')
            self.assertEqual(parser['status'], 'failed')
            self.assertIn('pptx', parser['detail'])
            self.assertEqual(observed['status'], 'unavailable')


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
        # Cache filtering (visibility, duplicate ids, malformed names) is the
        # binary's job now; the wizard only consumes runtime-model-list rows.
        def cli(argv, **kwargs):
            self.assertEqual(argv[1], 'runtime-model-list')
            return subprocess.CompletedProcess(argv, 0, json.dumps(
                {'models': [dict(id='observed-id', label='Visible model', max_context=4567)]}), '')
        with patch('subprocess.run', side_effect=cli), patch('sys.stdin', io.StringIO('1\n')), contextlib.redirect_stderr(io.StringIO()) as terminal:
            selected = SETUP.select_model('/fixture/masc', 'codex')
        self.assertEqual(selected, dict(model='observed-id', max_context=4567))
        self.assertIn('Installed MASC model catalog', terminal.getvalue())

    def test_astra_uses_codex_effective_context_instead_of_api_maximum(self):
        # Effective-vs-architectural window resolution is the binary catalog's
        # contract; the wizard keeps whatever window the row states.
        def cli(argv, **kwargs):
            return subprocess.CompletedProcess(argv, 0, json.dumps(
                {'models': [dict(id='gpt-6-astra', label='GPT-6-Astra', max_context=272000)]}), '')
        with patch('subprocess.run', side_effect=cli), patch('sys.stdin', io.StringIO('1\n')), contextlib.redirect_stderr(io.StringIO()):
            selected = SETUP.select_model('/fixture/masc', 'codex')
        self.assertEqual(selected, dict(model='gpt-6-astra', max_context=272000))

    def test_fresh_codex_uses_client_catalog_before_rendering_connection(self):
        # The vendor CLI is never driven from the wizard: one runtime-model-list
        # call answers. Environment isolation around the vendor CLI is verified
        # by the binary's own suite.
        def cli(argv, **kwargs):
            self.assertEqual(argv[1], 'runtime-model-list')
            return subprocess.CompletedProcess(argv, 0, json.dumps(
                {'models': [dict(id='catalog-id', label='Client model', max_context=272000)]}), '')
        source = dict(choice='codex', endpoint='', api_key_env='', command='/owned/codex', rows=[])
        with patch('subprocess.run', side_effect=cli):
            models, origin = SETUP.source_models('/fixture/masc', source, 10)
            _, selected = SETUP.resolve_model_spec(source, models[0], 10)
        self.assertEqual(selected['model'], 'catalog-id')
        self.assertEqual(selected['max_context'], 272000)
        self.assertEqual(selected['command'], '/owned/codex')
        self.assertIn('MASC model catalog', origin)

    def test_unavailable_codex_catalog_does_not_inherit_api_capacity(self):
        # With no catalog and no discovery the wizard has nothing to offer:
        # cancelling is the only honest path (no guessed capacity).
        def cli(argv, **kwargs):
            self.assertEqual(argv[1], 'runtime-model-list')
            return subprocess.CompletedProcess(argv, 0, json.dumps({'models': []}), '')
        with patch('subprocess.run', side_effect=cli), patch('sys.stdin', io.StringIO('q\n')), \
                contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SETUP.SetupError):
            SETUP.select_model('/fixture/masc', 'codex')

    def test_http_models_offer_actual_server_id_and_configured_limit(self):
        # Discovery is owned by the native runtime: the wizard calls the
        # binary and trusts its observation. Wire-format parsing of /models
        # (including max_model_len) is verified by the OCaml discovery suite.
        def native(argv, **kwargs):
            self.assertEqual(argv[1], 'runtime-discover-models')
            return subprocess.CompletedProcess(argv, 0, json.dumps({
                'source': 'account_or_server_model_list', 'account_availability_verified': False,
                'models': [dict(id='served-model', label='served-model', context=8192)]}), '')
        with patch('subprocess.run', side_effect=native), patch('sys.stdin', io.StringIO('1\n')), contextlib.redirect_stderr(io.StringIO()):
            selected = SETUP.select_model('/fixture/masc', 'vllm', 'http://server.example/v1')
        self.assertEqual(selected, dict(model='served-model', max_context=8192))

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


class CodexExplicitRefresh(unittest.TestCase):
    def test_refresh_bypasses_cached_discovery_and_keeps_exact_context(self):
        source = dict(choice='codex', command='/owned/codex', endpoint='', api_key_env='', rows=[])
        receipt = dict(schema='masc.codex_model_refresh.v1', source='isolated_cli_cache',
                       models=[dict(id='new-model', label='New model', context=272000, is_default=True)])
        with patch.object(SETUP.subprocess, 'run', return_value=subprocess.CompletedProcess([], 0, json.dumps(receipt), '')) as run, \
                patch.object(SETUP, 'catalog_models', return_value=[]):
            rows, origin = SETUP.source_models('/owned/masc', source, 10, refresh=True)
        self.assertEqual(rows[0]['context'], 272000)
        self.assertEqual(run.call_args.args[0], ['/owned/masc', 'runtime-codex-models', '--cli-path', '/owned/codex'])
        self.assertIn('refreshed', origin)

    def test_unavailable_refresh_is_labeled_offline_fallback(self):
        source = dict(choice='codex', command='codex', endpoint='', api_key_env='', rows=[])
        with patch.object(SETUP, 'refresh_codex_models', side_effect=SETUP.SetupError('Online unavailable; cached fallback.')), \
                patch.object(SETUP, 'catalog_models', return_value=[dict(id='cached', label='Cached', context=123)]):
            rows, origin = SETUP.source_models('/owned/masc', source, 10, refresh=True)
        self.assertEqual(rows[0]['id'], 'cached')
        self.assertIn('cached fallback', origin)

    @unittest.skipUnless(BINARY, 'requires CI-built native executable')
    def test_native_refresh_has_no_old_cache_or_turn_and_preserves_source(self):
        with tempfile.TemporaryDirectory() as directory:
            home = Path(directory)
            original = home / '.codex'
            original.mkdir()
            (original / 'auth.json').write_text('{"fixture":"private"}')
            (original / 'auth.json').chmod(0o600)
            (original / 'models_cache.json').write_text('{"models":[{"slug":"stale","context_window":1}]}')
            before = {p.name: p.read_bytes() for p in original.iterdir()}
            client = home / 'fake-codex'
            client.write_text('''#!/usr/bin/env python3
import json, os, pathlib, sys
home = pathlib.Path(os.environ['CODEX_HOME'])
assert home != pathlib.Path(os.environ['HOME']) / '.codex'
assert not (home / 'models_cache.json').exists()
for line in sys.stdin:
    request = json.loads(line)
    method = request['method']
    if method == 'initialized': continue
    if method == 'initialize': result = {'userAgent':'fixture/1'}
    elif method == 'account/read': result = {'account':{'type':'apiKey'}, 'requiresOpenaiAuth':True}
    elif method == 'model/list':
        (home / 'models_cache.json').write_text(json.dumps({'models':[{'slug':'fresh-model','context_window':272000}]}))
        result = {'data':[{'id':'ui-id','model':'fresh-model','displayName':'Fresh model','isDefault':True}], 'nextCursor':None}
    else: raise AssertionError('unexpected operation ' + method)
    print(json.dumps({'id':request['id'],'result':result}), flush=True)
''')
            client.chmod(0o700)
            result = subprocess.run([BINARY, 'runtime-codex-models', '--cli-path', str(client)],
                env=dict(os.environ, HOME=str(home), CODEX_HOME=str(original)), capture_output=True, text=True, timeout=30)
            self.assertEqual(result.returncode, 0, result.stderr)
            receipt = json.loads(result.stdout)
            self.assertEqual(receipt['source'], 'isolated_cli_cache')
            self.assertEqual(receipt['models'][0]['id'], 'fresh-model')
            self.assertEqual(receipt['models'][0]['context'], 272000)
            self.assertEqual(before, {p.name: p.read_bytes() for p in original.iterdir()})
            self.assertNotIn('private', result.stdout)


class ModelReleaseSelection(unittest.TestCase):
    def test_discovery_release_join_keeps_context_and_unknown_models(self):
        recent = dict(status='official_release', kind='general_availability',
                      released_on='2026-07-09', recency='within_three_calendar_months',
                      source_url='https://official.example/release')
        release_catalog = dict(schema='masc.model_release_catalog.v1', models=[
            dict(publisher='openai', model_id='exact-recent', release=recent),
            dict(publisher='anthropic', model_id='other-publisher', release=recent)])
        source = dict(choice='codex', command='codex', endpoint='', api_key_env='', rows=[],
                      model_release_catalog=release_catalog)
        observed = [dict(id='unknown', label='Unknown', context=272000, created=9999999999),
                    dict(id='exact-recent', label='Recent', context=272000),
                    dict(id='exact-recent-alias', label='Unproven alias', context=1000),
                    dict(id='other-publisher', label='Other publisher', context=2000)]
        with patch.object(SETUP, 'catalog_models', return_value=observed):
            rows, origin = SETUP.source_models('/owned/masc', source, 10)
        self.assertEqual(rows[0]['id'], 'exact-recent')
        self.assertEqual(rows[0]['context'], 272000)
        self.assertEqual(len(rows), 4)
        self.assertIn('recent release', SETUP.model_choice_label(rows[0]))
        for row in rows[1:]:
            self.assertIsNone(row['release'])
            self.assertIn('release date unknown', SETUP.model_choice_label(row))
        self.assertIn('model catalog', origin)
        # An explicit gateway is not an official publisher identity.
        self.assertIsNone(SETUP.release_metadata(dict(source, endpoint='https://gateway.example'), 'exact-recent'))

    def test_limited_release_is_visible_without_general_release_recommendation(self):
        row = dict(id='limited', label='Limited', release=dict(status='official_release',
            kind='limited_release', released_on='2026-09-03', recency='within_three_calendar_months'))
        self.assertFalse(SETUP.recently_released(row))
        self.assertIn('limited release 2026-09-03', SETUP.model_choice_label(row))


class NamedCatalogSources(unittest.TestCase):
    INVENTORY = {'runtimes': [], 'integrations': [
        {'id': 'openrouter', 'display_name': 'openrouter', 'protocol': 'openai-compatible-http',
         'origin': 'agent_core_catalog', 'setup_support': 'new_connection',
         'verification_support': 'response_tool', 'endpoint': 'https://openrouter.ai/api/v1',
         'api_key_env': 'OPENROUTER_API_KEY', 'provider_kind': 'openai_compat'},
        {'id': 'already', 'display_name': 'already', 'protocol': 'openai-compatible-http',
         'origin': 'runtime_config', 'setup_support': 'existing_binding',
         'verification_support': 'response_tool', 'endpoint': 'https://example.test/v1',
         'api_key_env': 'ALREADY_API_KEY'},
        {'id': 'wrongwire', 'display_name': 'wrongwire', 'protocol': 'messages-http',
         'origin': 'agent_core_catalog', 'setup_support': 'new_connection',
         'verification_support': 'response_tool', 'endpoint': 'https://example.test',
         'api_key_env': 'EXAMPLE_API_KEY'},
        {'id': 'nokey', 'display_name': 'nokey', 'protocol': 'openai-compatible-http',
         'origin': 'agent_core_catalog', 'setup_support': 'new_connection',
         'verification_support': 'response_tool', 'endpoint': 'https://example.test/v1',
         'api_key_env': ''},
    ]}

    def catalog_sources(self, inventory):
        return [source for source in SETUP.connection_sources(inventory) if source.get('catalog_provider')]

    def test_unconfigured_catalog_integrations_become_named_sources(self):
        sources = self.catalog_sources(self.INVENTORY)
        self.assertEqual([source['provider_id'] for source in sources], ['openrouter'])
        source = sources[0]
        self.assertEqual(source['choice'], 'openai_compatible')
        self.assertEqual(source['endpoint'], 'https://openrouter.ai/api/v1')
        self.assertEqual(source['api_key_env'], 'OPENROUTER_API_KEY')
        self.assertEqual(source['credential_kind'], 'env')
        self.assertEqual(source['rows'], [])

    def test_an_older_binary_without_integrations_yields_no_catalog_sources(self):
        self.assertEqual(self.catalog_sources({'runtimes': []}), [])

    def test_render_names_the_provider_and_writes_a_target_only_overlay(self):
        identity, runtime, overlay = SETUP.render(named_spec('anthropic/claude-opus-5'))
        self.assertEqual(identity, 'openrouter.openrouter-anthropic-claude-opus-5')
        self.assertIn(b'["providers"."openrouter"]', runtime)
        self.assertIn(b'"display-name" = "openrouter"', runtime)
        self.assertIn(b'"endpoint" = "https://openrouter.ai/api/v1"', runtime)
        self.assertIn(b'["models"."openrouter-anthropic-claude-opus-5"]', runtime)
        self.assertIn(b'"api-name" = "anthropic/claude-opus-5"', runtime)
        self.assertIn(b'"reasoning-effort" = "high"', runtime)
        # The catalog row owns the window; the runtime entry does not restate it.
        self.assertNotIn(b'max-context', runtime)
        self.assertIn(b'["openrouter"."openrouter-anthropic-claude-opus-5"]', runtime)
        self.assertNotIn(b'"models"', overlay)
        self.assertNotIn(b'"providers"', overlay)
        self.assertIn(b'"targets"', overlay)
        self.assertIn(b'"model_id" = "anthropic/claude-opus-5"', overlay)
        self.assertIn(b'"enable_thinking" = false', overlay)

    def test_render_skips_the_provider_section_the_workspace_config_declares(self):
        _, runtime, overlay = SETUP.render(dict(named_spec('z-ai/glm-5.3'), provider_declared=True,
                                                thinking_disable_encodable=False, reasoning_effort=None))
        self.assertNotIn(b'"providers"', runtime)
        self.assertNotIn(b'reasoning-effort', runtime)
        self.assertNotIn(b'wizard-default', runtime)
        self.assertNotIn(b'enable_thinking', overlay)

    def test_resolve_rejects_a_served_id_the_catalog_does_not_curate(self):
        source = self.catalog_sources(self.INVENTORY)[0]
        with self.assertRaises(SETUP.SetupError):
            SETUP.resolve_model_spec(source, dict(id='vendor/uncurated', label='x', context=None, existing=None), 1)

    def test_resolve_rejects_a_catalog_row_without_tool_support(self):
        source = self.catalog_sources(self.INVENTORY)[0]
        catalog = {'id': 'google/gemma3-4b', 'label': 'google/gemma3-4b', 'max_context': 1000000,
                   'accepted_reasoning_efforts': None, 'supports_tools': False, 'supports_streaming': True}
        with self.assertRaises(SETUP.SetupError) as raised:
            SETUP.resolve_model_spec(source, dict(id=catalog['id'], label='x', context=None,
                                                  existing=None, catalog=catalog), 1)
        self.assertIn('tool support', str(raised.exception))

    def test_a_failed_catalog_read_is_an_error_not_an_empty_list(self):
        failure = subprocess.CompletedProcess([], 1, '', 'provider listing exploded')
        with patch('subprocess.run', return_value=failure):
            with self.assertRaises(SETUP.SetupError) as raised:
                SETUP.provider_catalog_models('binary', 'openrouter')
        self.assertIn('provider listing exploded', str(raised.exception))

    def test_resolve_builds_a_named_spec_from_the_catalog_row(self):
        source = self.catalog_sources(self.INVENTORY)[0]
        catalog = {'id': 'anthropic/claude-opus-5', 'label': 'anthropic/claude-opus-5', 'max_context': 1000000,
                   'accepted_reasoning_efforts': ['none', 'high'], 'default_reasoning_effort': 'high',
                   'supports_tools': True, 'supports_streaming': True}
        runtime_id, spec = SETUP.resolve_model_spec(
            source, dict(id=catalog['id'], label='x', context=None, existing=None, catalog=catalog), 1)
        self.assertEqual(runtime_id, 'openrouter.openrouter-anthropic-claude-opus-5')
        self.assertEqual(spec['max_context'], 1000000)
        self.assertTrue(spec['tools'])
        self.assertTrue(spec['thinking_disable_encodable'])
        self.assertEqual(spec['reasoning_effort'], 'high')

    def test_source_models_leads_with_curated_rows_and_keeps_discovery_extras(self):
        source = self.catalog_sources(self.INVENTORY)[0]
        catalog_rows = [
            {'id': 'anthropic/claude-opus-5', 'label': 'anthropic/claude-opus-5', 'max_context': 1000000,
             'accepted_reasoning_efforts': ['none', 'high'], 'default_reasoning_effort': 'high',
             'supports_tools': True, 'supports_streaming': True},
        ]
        with patch.object(SETUP, 'provider_catalog_models', return_value=catalog_rows), \
             patch.object(SETUP, 'native_discover_models', return_value=(
                 [dict(id='anthropic/claude-opus-5', label='claude opus', context=99),
                  dict(id='vendor/uncurated', label='uncurated', context=7)],
                 'Current account/server model list')):
            rows, origin = SETUP.source_models('binary', source, 1)
        self.assertEqual(rows[0]['id'], 'anthropic/claude-opus-5')
        self.assertEqual(rows[0]['context'], 99)
        self.assertEqual(rows[0]['catalog'], catalog_rows[0])
        self.assertEqual(rows[1]['id'], 'vendor/uncurated')
        self.assertNotIn('catalog', rows[1])

    # test_discovery_reads_openrouters_context_length_field moved to the OCaml
    # discovery suite (test/test_runtime_model_discovery.py): wire parsing of
    # context_length/max_model_len belongs to the native runtime now.
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

    def _picker_program(self, labels, multiple=False, guarded=False):
        call = 'm.pick("Pick", ' + repr(labels) + (', multiple=True' if multiple else '') + ')'
        if guarded:
            body = ('try:\n'
                    '    print(json.dumps(%s))\n'
                    'except Exception as error:\n'
                    '    print(json.dumps({"error": error.__class__.__name__}))' % call)
        else:
            body = 'print(json.dumps(%s))' % call
        return ('import importlib.util,json; s=importlib.util.spec_from_file_location("setup",' +
                repr(str(ROOT / 'scripts/install-runtime-setup.py')) +
                '); m=importlib.util.module_from_spec(s); s.loader.exec_module(m);\n' + body)

    def _drive_picker(self, program, steps):
        """steps: (needle, keys, occurrences) triples; the picker redraws one
        frame per key, so a repeated footer proves the key was consumed."""
        master, slave = pty.openpty()
        original = termios.tcgetattr(slave)
        process = subprocess.Popen([sys.executable, '-c', program], stdin=slave, stderr=slave,
                                   stdout=subprocess.PIPE, env=dict(os.environ, TERM='xterm'))
        terminal = b''
        try:
            for needle, keys, occurrences in steps:
                deadline = time.monotonic() + 5
                while terminal.count(needle) < occurrences:
                    remaining = max(0.1, deadline - time.monotonic())
                    self.assertTrue(select.select([master], [], [], remaining)[0],
                                    'picker never showed ' + repr(needle) + '; tail: ' + repr(terminal[-300:]))
                    terminal += os.read(master, 65536)
                if keys:
                    os.write(master, keys)
            while True:
                ready = select.select([master, process.stdout], [], [], 5)[0]
                self.assertTrue(ready, 'picker did not finish')
                if master in ready:
                    terminal += os.read(master, 65536)
                if process.stdout in ready:
                    break
            output, _ = process.communicate(timeout=5)
            self.assertEqual(process.returncode, 0, terminal)
            restored = termios.tcgetattr(slave)
            restored[3] &= ~getattr(termios, 'PENDIN', 0)
            original[3] &= ~getattr(termios, 'PENDIN', 0)
            self.assertEqual(restored, original)
            return json.loads(output), terminal
        finally:
            if process.poll() is None:
                process.kill()
                process.wait()
            process.stdout.close()
            os.close(master)
            os.close(slave)

    def test_filter_typing_narrows_and_returns_the_real_index(self):
        result, terminal = self._drive_picker(self._picker_program(['Anthropic Claude', 'OpenAI GPT', 'Google Gemini']), [
            (b'3/3 shown', b'gpt', 1),
            (b'1/3 shown', b'\r', 1),
        ])
        self.assertEqual(result, [1])
        self.assertIn(b'Filter: gpt', terminal)

    def test_multiple_choices_made_under_a_filter_keep_real_indexes(self):
        result, _ = self._drive_picker(self._picker_program(['Alpha one', 'Alpha two', 'Beta one'], multiple=True), [
            (('0 selected · 3/3 shown').encode(), b'alph', 1),
            (b'2/3 shown', b' ', 1),
            (('1 selected · 2/3 shown').encode(), b'\x1b', 1),
            (('1 selected · 3/3 shown').encode(), b'\x1b[B\x1b[B', 1),
            ('› [ ] Beta one'.encode(), b' ', 1),
            ('› [x] Beta one'.encode(), b'\r', 1),
        ])
        self.assertEqual(result, [0, 2])

    def test_enter_with_no_filter_matches_waits_instead_of_selecting(self):
        result, _ = self._drive_picker(self._picker_program(['Alpha one', 'Beta one']), [
            (b'2/2 shown', b'zzz', 1),
            (b'no matches', b'\r', 1),
            # Enter must redraw instead of returning: a second frame with the
            # same footer is the proof the key was consumed as a no-op.
            (b'no matches', b'\x7f\x7f\x7f', 2),
            (b'2/2 shown', b'\r', 2),
        ])
        self.assertEqual(result, [0])

    def test_esc_without_a_filter_still_cancels(self):
        result, _ = self._drive_picker(self._picker_program(['Alpha one', 'Beta one'], guarded=True), [
            (b'2/2 shown', b'\x1b', 1),
        ])
        self.assertEqual(result, {'error': 'SetupError'})

    def test_q_and_k_type_into_the_filter_instead_of_commanding(self):
        # Model ids start with any letter (qwen, kimi): every printable byte
        # is filter text, movement is arrows only and q no longer cancels.
        result, terminal = self._drive_picker(self._picker_program(['qwen big', 'kimi-k3', 'beta one']), [
            (b'3/3 shown', b'qwen', 1),
            (b'Filter: qwen', b'\r', 1),
        ])
        self.assertEqual(result, [0])
        result, terminal = self._drive_picker(self._picker_program(['kimi-k3', 'beta one']), [
            (b'2/2 shown', b'kimi', 1),
            (b'Filter: kimi', b'\r', 1),
        ])
        self.assertEqual(result, [0])

    def test_a_byte_right_after_esc_clears_the_filter_and_is_kept(self):
        result, _ = self._drive_picker(self._picker_program(['alpha one', 'golf two']), [
            (b'2/2 shown', b'al', 1),
            (b'Filter: al', b'\x1bg', 1),
            (b'Filter: g', b'\r', 1),
        ])
        self.assertEqual(result, [1])

    def test_narrowing_then_clearing_keeps_the_cursor_on_its_row(self):
        labels = ['opt-{}'.format(index) for index in range(10)] + ['needle row']
        result, _ = self._drive_picker(self._picker_program(labels), [
            (b'11/11 shown', b'needle', 1),
            (b'1/11 shown', b'\x1b', 1),
            (b'11/11 shown', b'\r', 1),
        ])
        self.assertEqual(result, [10])

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
        # The native serving-context observation owns load and the effective
        # window; the wizard records what it reports, not the listed maximum.
        source = dict(choice='ollama', endpoint='http://localhost:11434', api_key_env='', command='')
        with patch.object(SETUP, 'native_serving_context',
                          return_value=dict(context=16384, tools=True)) as native:
            identity, configured = SETUP.resolve_model_spec(source, {'id': 'owned-qwen', 'context': 999999}, 10,
                                                            binary='/fixture/masc')
        native.assert_called_once_with('/fixture/masc', source, 'owned-qwen', 10, load=True)
        self.assertEqual(configured['max_context'], 16384)
        self.renderer.assert_called_once_with(configured, '/fixture/masc')
        self.assertEqual(identity, 'fixture.native-model')

    def test_wizard_ollama_context_uses_native_private_reference(self):
        source = dict(choice='ollama', endpoint='http://localhost:11434', api_key_env='',
                      credential_kind='file', credential_file='/private/key', command='')
        with patch.object(SETUP, 'native_serving_context',
                          return_value=dict(context=16384, tools=True)) as native:
            _, configured = SETUP.resolve_model_spec(source, dict(id='owned-model', context=999999), 10,
                                                      binary='/fixture/masc')
        native.assert_called_once_with('/fixture/masc', source, 'owned-model', 10, load=True)
        self.assertEqual(configured['max_context'], 16384)
        self.assertEqual(configured['credential_file'], '/private/key')

    def test_ollama_architecture_maximum_never_becomes_effective_context(self):
        # The native observation owns the effective window. When it reports
        # none, the wizard refuses to inherit the listed architecture maximum
        # and only an explicit operator value may proceed.
        with patch.object(SETUP, 'native_serving_context', return_value=dict(context=None, tools=True)):
            source = dict(choice='ollama', endpoint='http://localhost:11434', api_key_env='', command='')
            with patch('sys.stdin', io.StringIO('q\n')), contextlib.redirect_stderr(io.StringIO()), \
                    self.assertRaises(SETUP.SetupError):
                SETUP.resolve_model_spec(source, dict(id='owned-qwen', context=None), 10, binary='/fixture/masc')

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
        # Leaving through the recovery menu after a failure is not the operator
        # deferring the step: nothing was saved, so the journey must not report
        # a saved workspace or exit 0.
        self.assertEqual(result['readiness'], 'failed')
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

    def test_provider_mode_lists_curated_rows_for_a_named_catalog_provider(self):
        result=subprocess.run([BINARY,'runtime-model-list','--provider','openrouter'],check=True,capture_output=True,text=True)
        catalog=json.loads(result.stdout)
        self.assertIs(catalog['account_availability_verified'],False)
        flash=next(row for row in catalog['models'] if row['id']=='deepseek/deepseek-v4-flash')
        self.assertEqual(flash['max_context'],1048576)
        self.assertIn('none',flash['accepted_reasoning_efforts'])
        self.assertEqual(flash['default_reasoning_effort'],'high')
        self.assertIs(flash['supports_tools'],True)
        self.assertIs(flash['supports_streaming'],True)

    def test_provider_mode_rejects_unknown_ids_and_bare_invocations(self):
        unknown=subprocess.run([BINARY,'runtime-model-list','--provider','not-a-provider'],capture_output=True,text=True)
        self.assertNotEqual(unknown.returncode,0)
        self.assertEqual(unknown.stdout,'')
        self.assertIn('not-a-provider',unknown.stderr)
        neither=subprocess.run([BINARY,'runtime-model-list'],capture_output=True,text=True)
        self.assertNotEqual(neither.returncode,0)
        self.assertEqual(neither.stdout,'')


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
