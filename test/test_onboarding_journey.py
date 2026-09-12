"""Exercise fresh-home and interrupted setup through the shipped journey."""
import contextlib
import importlib.util
import io
import json
import os
import pty
from pathlib import Path
import select
import signal
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
SPEC = importlib.util.spec_from_file_location('setup', ROOT / 'scripts/install-runtime-setup.py')
SETUP = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(SETUP)


def observation(base=None, checks=()):
    # doctor always emits a message per check, so the fixture does too: the
    # journey reads it for any invalid condition. Each check is (id, condition)
    # or (id, condition, message).
    rows = [dict(id=name, condition=condition, message=(rest[0] if rest else ''))
            for name, condition, *rest in checks]
    return dict(schema='masc.onboarding_status.v1', scope='configuration_observation',
                base_path=base, checks=rows)

class Journey(unittest.TestCase):
    def setUp(self):
        renderer = patch.object(SETUP, 'render', return_value=('fixture.native-model', b'', b''))
        renderer.start()
        self.addCleanup(renderer.stop)

    def test_group_session_restarts_old_owner_instead_of_reusing_its_groups(self):
        def receipt(schema, **values):
            return subprocess.CompletedProcess([], 0, json.dumps(dict(schema=schema, **values)))
        same = dict(status='same_workspace', read_only=True, installed_version='0.35.5', server_version='0.35.5')
        replies = [receipt('masc.setup_server.v1', **same),
                   receipt('masc.setup_server_stopped.v1', owner_stopped=True),
                   receipt('masc.setup_server.v1', status='free', read_only=True)]
        with patch.object(SETUP.subprocess, 'run', side_effect=replies) as run, \
                patch.object(SETUP, 'pick', return_value=[0]) as pick, contextlib.redirect_stderr(io.StringIO()):
            self.assertEqual(SETUP.select_setup_server('/owned/masc', '/saved', 9123, require_new_owner=True), 9123)
        self.assertEqual([call.args[0][1] for call in run.call_args_list],
                         ['setup-server', 'setup-stop-previous-owner', 'setup-server'])
        self.assertEqual(run.call_args_list[1].args[0][-2:], ['--expected-version', '0.35.5'])
        self.assertEqual(len(pick.call_args.args[1]), 2)
        self.assertTrue(pick.call_args.args[1][0].startswith('Restart'))

    def test_group_session_restarts_reclaims_port_when_stop_reports_available(self):
        def receipt(schema, **values):
            return subprocess.CompletedProcess([], 0, json.dumps(dict(schema=schema, **values)))
        same = dict(status='same_workspace', read_only=True, installed_version='0.35.5', server_version='0.35.5')
        replies = [receipt('masc.setup_server.v1', **same),
                   receipt('masc.setup_server_stopped.v1', owner_stopped=True, port_available=True)]
        with patch.object(SETUP.subprocess, 'run', side_effect=replies) as run, \
                patch.object(SETUP, 'pick', return_value=[0]) as pick, contextlib.redirect_stderr(io.StringIO()):
            self.assertEqual(SETUP.select_setup_server('/owned/masc', '/saved', 9123, require_new_owner=True), 9123)
        self.assertEqual([call.args[0][1] for call in run.call_args_list],
                         ['setup-server', 'setup-stop-previous-owner'])

    def test_group_session_restarts_rechecks_port_when_stop_reports_busy(self):
        def receipt(schema, **values):
            return subprocess.CompletedProcess([], 0, json.dumps(dict(schema=schema, **values)))
        same = dict(status='same_workspace', read_only=True, installed_version='0.35.5', server_version='0.35.5')
        replies = [receipt('masc.setup_server.v1', **same),
                   receipt('masc.setup_server_stopped.v1', owner_stopped=True, port_available=False),
                   receipt('masc.setup_server.v1', status='free', read_only=True)]
        with patch.object(SETUP.subprocess, 'run', side_effect=replies) as run, \
                patch.object(SETUP, 'pick', return_value=[0]) as pick, contextlib.redirect_stderr(io.StringIO()):
            self.assertEqual(SETUP.select_setup_server('/owned/masc', '/saved', 9123, require_new_owner=True), 9123)
        self.assertEqual([call.args[0][1] for call in run.call_args_list],
                         ['setup-server', 'setup-stop-previous-owner', 'setup-server'])

    def test_group_session_owner_pause_never_prepares_or_reselects_models(self):
        with patch.object(SETUP, 'select_setup_server', return_value=None) as owner, \
                patch.object(SETUP, 'select_sandbox') as sandbox, patch.object(SETUP, 'wizard') as models:
            self.assertEqual(SETUP.sandbox_journey('/owned/masc', '/saved', 9123, refresh_owner=True), 1)
        owner.assert_called_once_with('/owned/masc', '/saved', 9123, require_new_owner=True)
        sandbox.assert_not_called()
        models.assert_not_called()

    def test_saved_sandbox_step_never_reselects_models_or_workspace(self):
        with patch.object(SETUP, 'wizard') as models, \
                patch.object(SETUP, 'workspace_check') as workspace, \
                patch.object(SETUP, 'select_sandbox', return_value=['--sandbox-profile', 'docker']) as sandbox, \
                patch.object(SETUP, 'open_workspace', return_value=0) as opened, \
                patch.object(SETUP.subprocess, 'run', return_value=subprocess.CompletedProcess([], 0)) as run, \
                contextlib.redirect_stderr(io.StringIO()):
            self.assertEqual(SETUP.sandbox_journey('/owned/masc', '/saved workspace', 9123), 0)
        models.assert_not_called()
        workspace.assert_not_called()
        sandbox.assert_called_once_with('/owned/masc', '/saved workspace', port=9123)
        self.assertEqual(run.call_args.args[0], ['/owned/masc', 'setup', '--base-path', '/saved workspace',
                                               '--port', '9123', '--no-tui', '--sandbox-profile', 'docker'])
        opened.assert_called_once_with('/owned/masc', '/saved workspace', 9123)

    def test_finished_group_session_exits_old_parent_without_repreparation(self):
        result = subprocess.CompletedProcess([], 0, json.dumps(dict(
            schema='masc.docker_account_action_result.v1', status='session_finished', readiness='not_checked')))
        with patch.object(SETUP.subprocess, 'run', return_value=result) as run:
            with self.assertRaises(SETUP.SetupSessionFinished):
                SETUP.docker_account_action('/owned/masc', '/saved workspace', 9123, 'handoff')
        self.assertEqual(run.call_args.args[0][-4:], ['--base-path', '/saved workspace', '--port', '9123'])
        self.assertNotIn('stderr', run.call_args.kwargs)
        with patch.object(sys, 'argv', ['setup', '--binary', '/owned/masc', '--base-path', '/saved workspace', '--sandbox-step']), \
                patch.object(SETUP, 'sandbox_journey', side_effect=SETUP.SetupSessionFinished), \
                patch.object(SETUP, 'journey') as initial:
            with self.assertRaises(SystemExit) as exited:
                SETUP.main()
        self.assertEqual(exited.exception.code, 0)
        initial.assert_not_called()

    def test_failed_group_session_preserves_saved_tail_and_never_claims_ready(self):
        result = subprocess.CompletedProcess([], 0, json.dumps(dict(
            schema='masc.docker_account_action_result.v1', status='reauthentication_required',
            reason='Retry this session', readiness='not_checked')))
        with patch.object(SETUP.subprocess, 'run', return_value=result), \
                contextlib.redirect_stderr(io.StringIO()) as output:
            self.assertTrue(SETUP.docker_account_action('/owned/masc', '/saved', 9123, 'handoff'))
        self.assertIn('Retry this session', output.getvalue())

    def test_docker_privilege_detail_precedes_selection_and_only_selected_action_runs(self):
        replies = [subprocess.CompletedProcess([], 0, json.dumps(dict(
            schema='masc.prerequisite_actions.v1', actions=[]))),
            subprocess.CompletedProcess([], 0, json.dumps(dict(schema='masc.docker_account_actions.v1',
                actions=[dict(id='grant', label='Allow Docker', detail='Grants root-level control through Docker.',
                              source_url='https://docs.docker.com/engine/install/linux-postinstall/', requires_admin=True)])))]
        with contextlib.redirect_stderr(io.StringIO()) as output:
            def choose(*_):
                self.assertIn('root-level control', output.getvalue())
                return [0]
            with patch.object(SETUP.subprocess, 'run', side_effect=replies) as run, \
                    patch.object(SETUP, 'pick', side_effect=choose), \
                    patch.object(SETUP, 'docker_account_action', return_value=True) as execute:
                self.assertTrue(SETUP.prerequisite_menu('/owned/masc', 'docker', base_path='/saved', port=9123))
        self.assertTrue(all('--execute' not in call.args[0] for call in run.call_args_list))
        execute.assert_called_once_with('/owned/masc', '/saved', 9123, 'grant')

    @unittest.skipUnless(BINARY, 'native binary supplied only by CI')
    def test_native_group_resume_rejects_root_identity_before_helper_or_docker(self):
        with tempfile.TemporaryDirectory() as home:
            env = dict(os.environ, HOME=home, XDG_CONFIG_HOME=home, PATH='')
            result = subprocess.run([BINARY, 'docker-session-resume', '--base-path', home,
                                     '--port', '9123', '--expected-uid', '0'],
                                    env=env, capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertNotIn('Welcome', result.stdout + result.stderr)
            self.assertFalse(Path(home, '.masc').exists())


    def test_antigravity_context_observation_avoids_numeric_input(self):
        source = dict(choice='antigravity', command='/owned/agy', endpoint='', api_key_env='',
                      credential_kind='file', credential_file='/private/account', provider_timeout_s=300.)
        result = subprocess.CompletedProcess([], 0, json.dumps(dict(
            source='antigravity_statusline', model='selected-model', context=1048576, invocation_verified=False)), '')
        with patch.object(SETUP.subprocess, 'run', return_value=result) as run, \
                patch.object(SETUP, 'pick') as picker, contextlib.redirect_stderr(io.StringIO()):
            _, spec = SETUP.resolve_model_spec(source, dict(id='selected-model', context=None), 10, binary='/owned/masc')
        self.assertEqual(spec['max_context'], 1048576)
        self.assertTrue(spec['streaming'])
        self.assertEqual(run.call_args.args[0][-2:], ['--model', 'selected-model'])
        picker.assert_not_called()

    def test_antigravity_account_models_are_selectable_without_model_id_entry(self):
        catalog = dict(source='antigravity_cli_models', account_availability_verified=False,
                       models=[dict(id='exact-model-high', label='Exact model (High)', effective_context=None)])
        rows = SETUP.antigravity_catalog_rows(catalog)
        self.assertEqual(rows, [dict(id='exact-model-high', label='Exact model (High)', context=None)])
        source = dict(choice='antigravity', command='/owned/agy', rows=[], endpoint='', api_key_env='',
                      credential_file='/private/account', credential_kind='file', account_catalog=rows)
        observed, _ = SETUP.source_models('/owned/masc', source, 10)
        self.assertEqual(observed[0]['id'], 'exact-model-high')
        self.assertIsNone(observed[0]['context'])  # architecture capacity is never substituted

    @unittest.skipUnless(BINARY, 'requires the CI-built native executable')
    def test_native_antigravity_account_import_keeps_original_and_lists_exact_models(self):
        with tempfile.TemporaryDirectory() as home:
            base = Path(home, 'workspace')
            (base / '.masc').mkdir(parents=True, mode=0o700)
            original = Path(home, '.gemini/antigravity-cli/antigravity-oauth-token')
            original.parent.mkdir(parents=True)
            original.write_text('fixture-private-oauth-never-print')
            original.chmod(0o600)
            catalog = dict(status='SUCCESS', num_turns=0, usage=dict(total_tokens=0),
                           command=dict(name='models', data=dict(models=[dict(id='account-only-id', label='Account only model')])))
            client = Path(home, 'fake-agy')
            client.write_text('#!/usr/bin/env python3\nimport json,os,sys\n'
                              'assert sys.argv[1:] == ["--output-format","json","models"]\n'
                              'assert os.environ["HOME"] != ' + repr(home) + '\n'
                              'print(' + repr(json.dumps(catalog)) + ')\n')
            client.chmod(0o700)
            env = dict(os.environ, HOME=home, XDG_CONFIG_HOME=home + '/config')
            result = subprocess.run([BINARY, 'runtime-antigravity-account', '--base-path', str(base),
                                     '--cli-path', str(client)], env=env, capture_output=True, text=True, timeout=30)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            receipt = json.loads(result.stdout)
            self.assertFalse(receipt['invocation_verified'])
            self.assertEqual(receipt['catalog']['models'][0]['id'], 'account-only-id')
            selected = Path(receipt['credential_file'])
            self.assertNotEqual(selected, original)
            self.assertEqual(selected.read_bytes(), original.read_bytes())
            self.assertEqual(selected.stat().st_mode & 0o777, 0o600)
            self.assertEqual(original.read_text(), 'fixture-private-oauth-never-print')
            self.assertNotIn(original.read_text(), result.stdout + result.stderr)
    def test_upgrade_selection_uses_reviewed_digest_and_stops_after_failed_file(self):
        plans = [dict(keeper_name=name, plan=dict(activation_mode='on_demand', source_sha256=name + '-digest'))
                 for name in ('imp', 'helper', 'third')]
        with patch.object(SETUP, 'pick', return_value=[0, 1, 2]), \
                patch.object(SETUP, 'workspace_upgrade_action', side_effect=[True, False]) as apply, \
                contextlib.redirect_stderr(io.StringIO()):
            SETUP.select_workspace_upgrades('/owned/masc', '/workspace', plans)
        self.assertEqual(apply.call_count, 2)
        self.assertEqual(apply.call_args_list[0].args[2], ['--apply', 'imp', '--source-sha256', 'imp-digest'])

    @unittest.skipUnless(BINARY, 'requires the CI-built native executable')
    def test_native_released_configuration_upgrade_and_backup_recovery(self):
        with tempfile.TemporaryDirectory() as home:
            base = Path(home, 'workspace')
            keepers = base / '.masc/config/keepers'
            keepers.mkdir(parents=True)
            path = keepers / 'imp.toml'
            original = ('# Preserve this exact prompt.\n[keeper]\nname = "imp"\n'
                        'instructions = "Remember the user"\nautoboot_enabled = true\n'
                        'proactive_enabled = false\nsandbox_profile = "microvm"\n'
                        'microvm_backend = "apple_container"\n[keeper.tools]\nnative = "read"\n')
            path.write_text(original)
            env = dict(os.environ, HOME=home, XDG_CONFIG_HOME=home + '/config',
                       MASC_BASE_PATH_LEASE_DIR=home + '/leases')
            Path(env['MASC_BASE_PATH_LEASE_DIR']).mkdir()
            def command(*args):
                return subprocess.run([BINARY, 'workspace-upgrade', '--base-path', str(base), *args],
                                      env=env, capture_output=True, text=True, timeout=30)
            listed = command()
            self.assertEqual(listed.returncode, 0, listed.stderr)
            plan = json.loads(listed.stdout)['keepers'][0]['plan']
            self.assertEqual(path.read_text(), original)
            rejected = command('--apply', 'imp', '--source-sha256', 'wrong-reviewed-digest')
            self.assertEqual(rejected.returncode, 1)
            self.assertEqual(path.read_text(), original)
            self.assertFalse((base / '.masc/upgrades').exists())
            applied = command('--apply', 'imp', '--source-sha256', plan['source_sha256'])
            self.assertEqual(applied.returncode, 0, applied.stdout + applied.stderr)
            backup = Path(json.loads(applied.stdout)['backup_path'])
            self.assertEqual(backup.read_text(), original)
            self.assertEqual(backup.stat().st_mode & 0o777, 0o600)
            updated = path.read_text()
            self.assertIn('activation_mode = "on_demand"', updated)
            backups = json.loads(command().stdout)['backups']
            self.assertEqual(len(backups), 1)
            backup_id = backups[0]['backup_id']
            path.write_text(updated + '# a later user edit\n')
            self.assertEqual(command('--restore', backup_id).returncode, 1)
            self.assertTrue(path.read_text().endswith('# a later user edit\n'))
            path.write_text(updated)
            restored = command('--restore', backup_id)
            self.assertEqual(restored.returncode, 0, restored.stdout + restored.stderr)
            self.assertEqual(path.read_text(), original)
            self.assertEqual(backup.read_text(), original)

    def test_final_workspace_owns_port_resolution_before_server_contact(self):
        events = []
        def check(*_):
            events.append('workspace'); return dict(base_path='/chosen-new')
        def port(binary, base, requested, save=False):
            self.assertEqual(base, '/chosen-new')
            events.append('save' if save else 'port'); return 19300
        def server(binary, base, selected):
            self.assertEqual((base, selected), ('/chosen-new', 19300))
            events.append('server'); return 19301
        with patch.object(SETUP, 'onboarding_status', return_value=observation('/old')), \
                patch.object(SETUP, 'pick', return_value=[0]), \
                patch.object(SETUP, 'workspace_check', side_effect=check), \
                patch.object(SETUP, 'workspace_port', side_effect=port) as connection, \
                patch.object(SETUP, 'select_setup_server', side_effect=server), \
                patch.object(SETUP, 'wizard', return_value=dict(readiness='deferred')), \
                patch.object(SETUP.subprocess, 'run', return_value=subprocess.CompletedProcess([], 0)), \
                contextlib.redirect_stderr(io.StringIO()):
            self.assertEqual(SETUP.journey('/owned/masc', None, None, 10), 0)
        self.assertEqual(events, ['workspace', 'port', 'server', 'save'])
        self.assertEqual(connection.call_args.args, ('/owned/masc', '/chosen-new', 19301))
        self.assertTrue(connection.call_args.kwargs['save'])

    def test_current_owner_history_quick_open_still_observes_identity(self):
        result = subprocess.CompletedProcess([], 0, json.dumps(dict(schema='masc.setup_server.v1',
            read_only=True, status='same_workspace', installed_version='0.35.5', server_version='0.35.5')))
        with patch.object(SETUP.subprocess, 'run', return_value=result) as run, patch.object(SETUP, 'pick') as pick:
            self.assertEqual(SETUP.select_setup_server('/owned/masc', '/saved', 19301, resume_existing=True), 19301)
        self.assertEqual(run.call_args.args[0], ['/owned/masc', 'setup-server', '--base-path', '/saved', '--port', '19301'])
        pick.assert_not_called()

    def test_sandbox_selection_uses_native_backend_arguments(self):
        catalog = dict(schema='masc.sandbox_readiness.v1', candidates=[dict(
            id='apple_container', state='service_ready', reason='service only', advanced=False,
            recommended=True, setup_args=['--sandbox-profile', 'microvm', '--microvm-backend', 'apple_container'],
            capabilities=dict(network_modes=['none', 'inherit', 'policy']))])
        response = subprocess.CompletedProcess([], 0, json.dumps(catalog), '')
        with patch.object(SETUP.subprocess, 'run', return_value=response), \
                patch.object(SETUP, 'pick', return_value=[0]):
            self.assertEqual(SETUP.select_sandbox('/bin/masc', '/workspace'), [
                '--sandbox-profile', 'microvm', '--microvm-backend', 'apple_container', '--network-mode', 'inherit'])

    def test_existing_network_policy_is_preserved_unless_explicitly_changed(self):
        for mode in ('none', 'policy', 'inherit'):
            catalog = dict(schema='masc.sandbox_readiness.v1', configured_selection=dict(
                backend='apple_container', network_mode=mode), candidates=[dict(
                id='apple_container', state='service_ready', reason='service only', advanced=False,
                recommended=True, setup_args=['--sandbox-profile','microvm','--microvm-backend','apple_container'],
                capabilities=dict(network_modes=['none','inherit','policy']))])
            response = subprocess.CompletedProcess([], 0, json.dumps(catalog), '')
            with self.subTest(mode=mode), patch.object(SETUP.subprocess, 'run', return_value=response), \
                    patch.object(SETUP, 'pick', return_value=[0]), contextlib.redirect_stderr(io.StringIO()):
                result = SETUP.select_sandbox('/bin/masc', '/workspace')
                self.assertNotIn('--network-mode', result)
        # Open Advanced, select the same backend, explicitly select offline.
        with patch.object(SETUP.subprocess, 'run', return_value=response), \
                patch.object(SETUP, 'pick', side_effect=[[2], [0], [2]]), contextlib.redirect_stderr(io.StringIO()):
            self.assertEqual(SETUP.select_sandbox('/bin/masc', '/workspace')[-2:], ['--network-mode','none'])

    def test_unavailable_sandbox_never_selects_host_or_another_backend(self):
        catalog = dict(schema='masc.sandbox_readiness.v1', candidates=[dict(
            id='docker', state='missing_prerequisite', reason='Docker is missing', advanced=False,
            recommended=False, setup_args=['--sandbox-profile', 'docker'],
            capabilities=dict(network_modes=['none', 'inherit']))])
        response = subprocess.CompletedProcess([], 0, json.dumps(catalog), '')
        with patch.object(SETUP.subprocess, 'run', return_value=response), \
                patch.object(SETUP, 'prerequisite_menu', return_value=False) as prerequisites, \
                patch.object(SETUP, 'pick', side_effect=[[0], [3]]), contextlib.redirect_stderr(io.StringIO()):
            self.assertIsNone(SETUP.select_sandbox('/bin/masc', '/workspace'))
        prerequisites.assert_called_once_with('/bin/masc', 'docker', base_path='/workspace', port=8945)

    @unittest.skipUnless(BINARY, 'requires CI-built native executable')
    def test_native_official_client_install_rechecks_without_auth_or_model(self):
        import shlex
        import sys
        for dependency, client in [('codex', 'codex'), ('claude-code', 'claude'), ('antigravity', 'agy')]:
            with self.subTest(client=client), tempfile.TemporaryDirectory() as home:
                root = Path(home)
                tools = root / 'tools'
                tools.mkdir()
                downloaded = root / 'downloaded-path'
                target = root / '.local/bin' / client
                payload = '#!/bin/sh\n[ "$1" = --version ] || exit 77\necho fixture-client-version\n'
                script = '#!/bin/sh\nmkdir -p ' + shlex.quote(str(target.parent)) + '\nprintf %s ' + shlex.quote(payload) + ' > ' + shlex.quote(str(target)) + '\nchmod 700 ' + shlex.quote(str(target)) + '\n'
                curl = tools / 'curl'
                curl.write_text('#!' + sys.executable + '\nimport pathlib,sys\n'
                    'args=sys.argv[1:]\nassert args[args.index("--proto")+1]=="=https"\n'
                    'assert args[args.index("--proto-redir")+1]=="=https"\n'
                    'assert args[-1] in ["https://chatgpt.com/codex/install.sh","https://claude.ai/install.sh","https://antigravity.google/cli/install.sh"]\n'
                    'path=pathlib.Path(args[args.index("--output")+1])\npath.write_text(' + repr(script) + ')\n'
                    'pathlib.Path(' + repr(str(downloaded)) + ').write_text(str(path))\n')
                curl.chmod(0o700)
                env = dict(os.environ, HOME=home, CODEX_INSTALL_DIR=str(target.parent), PATH=str(tools)+':/usr/bin:/bin')
                result = subprocess.run([BINARY, 'prerequisite-actions', dependency, '--execute', client+'_native_install'],
                    env=env, cwd=home, capture_output=True, text=True, timeout=30)
                self.assertEqual(result.returncode, 0, result.stderr)
                receipt = json.loads(result.stdout)
                self.assertEqual(receipt['status'], 'commands_completed_recheck_required')
                self.assertEqual(receipt['readiness'], 'not_checked')
                self.assertTrue(target.is_file())
                self.assertFalse(Path(downloaded.read_text()).exists())
                self.assertNotIn('fixture-client-version', result.stdout)

    def test_missing_antigravity_uses_installer_then_detects_user_binary_without_path(self):
        with tempfile.TemporaryDirectory() as home:
            source = dict(choice='antigravity', command='agy', label='Antigravity')
            target = Path(home, '.local/bin/agy')
            def install(*args):
                target.parent.mkdir(parents=True)
                target.write_text('#!/bin/sh\necho fixture\n')
                target.chmod(0o700)
                return True
            credentials = type('Credentials', (), {'binary':'/owned/masc'})()
            with patch.dict(os.environ, HOME=home), patch.object(SETUP.shutil, 'which', return_value=None), \
                    patch.object(SETUP, 'prerequisite_menu', side_effect=install) as action, \
                    patch.object(SETUP, 'prepare_antigravity_account', side_effect=lambda row, _: row):
                result = SETUP.prepare_connection(source, credentials)
            action.assert_called_once_with('/owned/masc', 'antigravity')
            self.assertEqual(result['command'], str(target.resolve()))

    def test_prerequisite_runs_only_selected_action_with_terminal_prompts(self):
        catalog = dict(schema='masc.prerequisite_actions.v1', actions=[
            dict(id='vendor_guide', label='Official guide', requires_admin=False,
                 detail='Read the vendor steps', source_url='https://example.org/guide'),
            dict(id='install', label='Install selected dependency', requires_admin=True,
                 detail='Install then recheck', source_url='https://example.org/install')])
        for status, code in [('external_step_pending', 0),
                             ('commands_completed_recheck_required', 0), ('failed', 1)]:
            responses = [subprocess.CompletedProcess([], 0, json.dumps(catalog), ''),
                         subprocess.CompletedProcess([], code, json.dumps(dict(
                             schema='masc.prerequisite_action_result.v1', status=status,
                             readiness='not_checked')), '')]
            with self.subTest(status=status), patch.object(SETUP.subprocess, 'run', side_effect=responses) as run, \
                    patch.object(SETUP, 'pick', return_value=[1]), contextlib.redirect_stderr(io.StringIO()) as output:
                self.assertTrue(SETUP.prerequisite_menu('/owned/masc', 'docker'))
            self.assertEqual(run.call_args.args[0], ['/owned/masc', 'prerequisite-actions', 'docker', '--execute', 'install'])
            self.assertNotIn('stdin', run.call_args.kwargs)  # inherit the operator's terminal
            self.assertNotIn('stderr', run.call_args.kwargs)
            if status == 'external_step_pending':
                self.assertIn('Complete the vendor installation window', output.getvalue())
            elif status == 'failed':
                self.assertIn('did not finish', output.getvalue())

    def test_prerequisite_failure_keeps_safe_reason_visible(self):
        catalog = dict(schema='masc.prerequisite_actions.v1', actions=[dict(
            id='install', label='Install', requires_admin=True,
            detail='Verify package', source_url='https://example.org/install')])
        for reason, expected in [('Package publisher mismatch\x1b[2J', 'Package publisher mismatch'),
                                 (None, 'The selected step did not finish')]:
            receipt = dict(schema='masc.prerequisite_action_result.v1', status='failed',
                           readiness='not_checked', reason=reason)
            responses = [subprocess.CompletedProcess([], 0, json.dumps(catalog)),
                         subprocess.CompletedProcess([], 1, json.dumps(receipt))]
            with self.subTest(reason=reason), patch.object(SETUP.subprocess, 'run', side_effect=responses), \
                    patch.object(SETUP, 'pick', return_value=[0]), contextlib.redirect_stderr(io.StringIO()) as output:
                self.assertTrue(SETUP.prerequisite_menu('/owned/masc', 'apple_container'))
            self.assertIn(expected, output.getvalue())
            self.assertNotIn('\x1b', output.getvalue())

    def test_prerequisite_refresh_and_back_never_execute(self):
        catalog = dict(schema='masc.prerequisite_actions.v1', actions=[])
        response = subprocess.CompletedProcess([], 0, json.dumps(catalog), '')
        for choice, expected in [(0, True), (1, False)]:
            with self.subTest(choice=choice), patch.object(SETUP.subprocess, 'run', return_value=response) as run, \
                    patch.object(SETUP, 'pick', return_value=[choice]):
                self.assertEqual(SETUP.prerequisite_menu('/owned/masc', 'docker'), expected)
            self.assertEqual(run.call_count, 1)

    @unittest.skipUnless(BINARY, 'requires the CI-built native executable')
    def test_native_prerequisite_listing_and_unknown_action_have_no_install_effect(self):
        with tempfile.TemporaryDirectory() as home:
            env = dict(os.environ, HOME=home, XDG_CONFIG_HOME=home + '/config')
            listed = subprocess.run([BINARY, 'prerequisite-actions', 'codex'], env=env,
                                    capture_output=True, text=True, check=True)
            catalog = json.loads(listed.stdout)
            self.assertEqual(catalog['schema'], 'masc.prerequisite_actions.v1')
            self.assertTrue(catalog['actions'])
            rejected = subprocess.run([BINARY, 'prerequisite-actions', 'codex', '--execute', 'not-an-action'],
                                      env=env, capture_output=True, text=True)
            self.assertEqual(rejected.returncode, 1)
            self.assertEqual(list(Path(home).iterdir()), [])

    @unittest.skipUnless(BINARY, 'requires the CI-built native executable')
    def test_native_setup_embeds_journey_and_new_home_cancels_without_writes(self):
        with tempfile.TemporaryDirectory() as home:
            pid, fd = pty.fork()
            if pid == 0:
                environment = dict(os.environ, HOME=home, XDG_CONFIG_HOME=home + '/config', TERM='xterm')
                for key in list(environment):
                    if key.startswith('MASC_') or key.startswith('AGENT_CORE_'):
                        environment.pop(key)
                os.chdir(home)  # helper cannot depend on the source checkout
                os.execve(BINARY, [BINARY, 'setup'], environment)
            captured = b''
            exited = False
            try:
                deadline = time.monotonic() + 30
                while b'Your workspace' not in captured and time.monotonic() < deadline:
                    if select.select([fd], [], [], 0.2)[0]:
                        try:
                            chunk = os.read(fd, 65536)
                        except OSError:
                            break
                        if not chunk:
                            break
                        captured += chunk
                self.assertIn(b'Your workspace', captured, captured.decode(errors='replace'))
                os.write(fd, b'q')
                deadline = time.monotonic() + 10
                while time.monotonic() < deadline:
                    waited, status = os.waitpid(pid, os.WNOHANG)
                    if waited == pid:
                        exited = True
                        self.assertTrue(os.WIFEXITED(status), captured.decode(errors='replace'))
                        self.assertEqual(os.WEXITSTATUS(status), 1, captured.decode(errors='replace'))
                        break
                    if select.select([fd], [], [], 0.1)[0]:
                        try:
                            captured += os.read(fd, 65536)
                        except OSError:
                            pass
                self.assertTrue(exited, 'q did not terminate setup naturally: ' + captured.decode(errors='replace'))
                self.assertFalse(Path(home, 'MASC').exists())
                self.assertFalse(Path(home, '.masc').exists())
            finally:
                os.close(fd)
                if not exited:
                    try:
                        os.kill(pid, signal.SIGTERM)
                    except ProcessLookupError:
                        pass
                    os.waitpid(pid, 0)

    def test_cancel_fresh_home_does_not_initialize_or_select_models(self):
        with patch.object(SETUP, 'onboarding_status', return_value=observation()), \
                patch.object(SETUP, 'pick', return_value=[2]), \
                patch.object(SETUP, 'workspace_check') as preflight, \
                patch.object(SETUP, 'wizard') as models, contextlib.redirect_stderr(io.StringIO()):
            self.assertEqual(SETUP.journey('/bin/masc', None, 8945, 10), 0)
        preflight.assert_not_called()
        models.assert_not_called()

    @unittest.skipUnless(BINARY, 'requires the CI-built native executable')
    def test_native_setup_can_leave_remembered_workspace_with_invalid_port(self):
        with tempfile.TemporaryDirectory() as home:
            old = Path(home, 'old')
            config = old / '.masc/config/connection.toml'
            config.parent.mkdir(parents=True)
            invalid = '[server]\nhttp_port = "invalid"\n'
            config.write_text(invalid)
            record = Path(home, 'config/masc/default-base-path')
            record.parent.mkdir(parents=True)
            record.write_text(str(old) + '\n')
            chosen = Path(home, 'chosen')
            pid, fd = pty.fork()
            if pid == 0:
                environment = {key: value for key, value in os.environ.items()
                               if not key.startswith(('MASC_', 'AGENT_CORE_'))}
                environment.update(HOME=home, XDG_CONFIG_HOME=home + '/config', TERM='dumb')
                os.chdir(home)
                os.execve(BINARY, [BINARY, 'setup'], environment)
            captured = b''
            exited = False

            def until(expected):
                nonlocal captured
                deadline = time.monotonic() + 30
                while expected not in captured and time.monotonic() < deadline:
                    if select.select([fd], [], [], 0.2)[0]:
                        try:
                            chunk = os.read(fd, 65536)
                        except OSError:
                            break
                        if not chunk:
                            break
                        captured += chunk
                self.assertIn(expected, captured, captured.decode(errors='replace'))

            try:
                until(b'Your workspace')
                os.write(fd, b'2\n')
                until(b'Workspace directory')
                os.write(fd, str(chosen).encode() + b'\n')
                until(b'Connect a model')
                os.write(fd, b'q\n')
                deadline = time.monotonic() + 10
                while time.monotonic() < deadline:
                    waited, status = os.waitpid(pid, os.WNOHANG)
                    if waited == pid:
                        exited = True
                        self.assertTrue(os.WIFEXITED(status))
                        self.assertEqual(os.WEXITSTATUS(status), 1, captured.decode(errors='replace'))
                        break
                    if select.select([fd], [], [], 0.1)[0]:
                        try:
                            captured += os.read(fd, 65536)
                        except OSError:
                            pass
                self.assertTrue(exited, captured.decode(errors='replace'))
                self.assertTrue((chosen / '.masc/config/connection.toml').is_file())
                self.assertEqual(config.read_text(), invalid)
            finally:
                os.close(fd)
                if not exited:
                    try:
                        os.kill(pid, signal.SIGTERM)
                    except ProcessLookupError:
                        pass
                    os.waitpid(pid, 0)

    def test_resume_invalid_saved_port_returns_to_workspace_selection(self):
        state = observation('/old', [('workspace', 'satisfied'), ('keeper_persistence', 'satisfied')])
        with patch.object(SETUP, 'onboarding_status', return_value=state), \
                patch.object(SETUP, 'workspace_port', side_effect=SETUP.SetupError('Invalid saved port')), \
                patch.object(SETUP, 'pick', return_value=[2]) as picker, \
                patch.object(SETUP, 'select_setup_server') as owner, \
                contextlib.redirect_stderr(io.StringIO()):
            self.assertEqual(SETUP.journey('/bin/masc', None, None, 10, resume=True), 0)
        picker.assert_called_once()
        owner.assert_not_called()

    def test_default_workspace_is_selected_without_path_typing_and_native_owns_preparation(self):
        with tempfile.TemporaryDirectory() as home:
            base = str(Path(home) / 'MASC')
            with patch.object(SETUP, 'onboarding_status', return_value=observation()), \
                    patch.object(SETUP.Path, 'home', return_value=Path(home)), \
                    patch.object(SETUP, 'pick', return_value=[0]) as picker, \
                    patch.object(SETUP, 'workspace_check', return_value=dict(base_path=base)) as preflight, \
                    patch.object(SETUP, 'select_setup_server', return_value=9876), \
                    patch.object(SETUP, 'workspace_port', return_value=9876), \
                    patch.object(SETUP, 'wizard', return_value=dict(readiness='verified')), \
                    patch.object(SETUP, 'select_sandbox', return_value=[]), \
                    patch.object(SETUP, 'select_local_voice'), \
                    patch.object(SETUP, 'open_workspace', return_value=0) as opened, \
                    patch.object(SETUP.subprocess, 'run', return_value=subprocess.CompletedProcess([], 0)) as run, \
                    contextlib.redirect_stderr(io.StringIO()):
                self.assertEqual(SETUP.journey('/bin/masc', None, 9876, 10), 0)
            self.assertEqual(picker.call_args.args[1][0], 'Use ' + base)
            preflight.assert_called_once_with('/bin/masc', base)
            self.assertEqual([call.args[0] for call in run.call_args_list], [
                ['/bin/masc', 'init', '--base-path', base],
                ['/bin/masc', 'setup', '--base-path', base, '--port', '9876', '--no-tui']])
            opened.assert_called_once_with('/bin/masc', base, 9876)
            self.assertFalse(Path(base).exists())  # renderer did not mutate workspace

    def test_persisted_history_resumes_without_model_reselection(self):
        state = observation('/workspace', [('workspace', 'satisfied'), ('keeper_persistence', 'satisfied')])
        with patch.object(SETUP, 'onboarding_status', return_value=state), \
                patch.object(SETUP, 'workspace_port', return_value=8945), \
                patch.object(SETUP, 'select_setup_server', return_value=8945) as owner, \
                patch.object(SETUP, 'open_workspace', return_value=0) as opened, \
                patch.object(SETUP, 'pick') as picker:
            self.assertEqual(SETUP.journey('/bin/masc', None, 8945, 10, resume=True), 0)
        opened.assert_once_with('/bin/masc', '/workspace', 8945) if hasattr(opened, 'assert_once_with') else opened.assert_called_once_with('/bin/masc', '/workspace', 8945)
        owner.assert_called_once_with('/bin/masc', '/workspace', 8945, resume_existing=True)
        picker.assert_not_called()

    def test_declaration_alone_never_skips_first_preparation(self):
        state = observation('/workspace', [('workspace', 'satisfied'), ('keeper_declaration', 'satisfied')])
        with patch.object(SETUP, 'onboarding_status', return_value=state), \
                patch.object(SETUP, 'pick', return_value=[2]), \
                patch.object(SETUP, 'workspace_port', return_value=8945), \
                patch.object(SETUP, 'open_workspace') as opened, contextlib.redirect_stderr(io.StringIO()):
            self.assertEqual(SETUP.journey('/bin/masc', None, 8945, 10, resume=True), 0)
        opened.assert_not_called()

    def test_failed_preparation_does_not_open_tui_or_repeat_model_selection(self):
        with patch.object(SETUP, 'onboarding_status', return_value=observation('/workspace')), \
                patch.object(SETUP, 'pick', side_effect=[[0], [1]]), \
                patch.object(SETUP, 'workspace_check', return_value=dict(base_path='/workspace')), \
                patch.object(SETUP, 'workspace_port', return_value=8945), \
                patch.object(SETUP, 'select_setup_server', return_value=8945), \
                patch.object(SETUP, 'wizard', return_value=dict(readiness='verified')) as models, \
                patch.object(SETUP, 'select_sandbox', return_value=[]), \
                patch.object(SETUP, 'select_local_voice'), \
                patch.object(SETUP, 'open_workspace') as opened, \
                patch.object(SETUP.subprocess, 'run', side_effect=[subprocess.CompletedProcess([], 0), subprocess.CompletedProcess([], 1)]), \
                contextlib.redirect_stderr(io.StringIO()):
            self.assertEqual(SETUP.journey('/bin/masc', None, 8945, 10), 1)
        models.assert_called_once()
        opened.assert_not_called()

    def test_official_login_retains_selected_models_and_reverifies(self):
        spec = dict(choice='claude_code', command='/owned/claude', model='account-model',
                    max_context=100000, tools=True, streaming=False)
        runtime = SETUP.render(spec)[0]
        with patch.object(SETUP, 'configured_inventory', return_value=dict(runtimes=[], setup_revision="a" * 64)), \
                patch.object(SETUP, 'select_connections', return_value=([runtime], [spec], {runtime: 'Claude'})) as select, \
                patch.object(SETUP, 'pick', side_effect=[[0], [4]]), \
                patch.object(SETUP, 'configure_many', side_effect=[SETUP.VerificationError(runtime), dict(readiness='verified')]) as verify, \
                patch.object(SETUP.subprocess, 'run', return_value=subprocess.CompletedProcess([], 0)) as login, \
                contextlib.redirect_stderr(io.StringIO()):
            self.assertEqual(SETUP.wizard('/bin/masc', '/workspace', 10)['readiness'], 'verified')
        select.assert_called_once()
        self.assertEqual(verify.call_count, 2)
        self.assertEqual(verify.call_args_list[0], verify.call_args_list[1])
        self.assertEqual(login.call_args.args[0], ['/owned/claude', 'auth', 'login'])

    def test_unrecognized_status_never_becomes_ready(self):
        response = subprocess.CompletedProcess([], 0, json.dumps(dict(status='ready')), '')
        with patch.object(SETUP.subprocess, 'run', return_value=response):
            with self.assertRaises(SETUP.SetupError):
                SETUP.onboarding_status('/bin/masc')


def completed(stdout='', code=0):
    return subprocess.CompletedProcess([], code, stdout=stdout)


VOICES = json.dumps(dict(voices=[
    dict(id='Albert', name='Albert', language='en_US'),
    dict(id='Yuna', name='Yuna', language='ko_KR'),
    dict(id='Eddy (\ud55c\uad6d\uc5b4(\ud55c\uad6d))', name='Eddy (\ud55c\uad6d\uc5b4(\ud55c\uad6d))', language='ko_KR'),
]))

WHISPER_ACTIONS = json.dumps(dict(schema='masc.prerequisite_actions.v1', actions=[
    dict(id='whisper_cli_brew_install', label='Install whisper.cpp with Homebrew', detail='', source_url='',
         requires_admin=False, completion='recheck_required',
         effect=dict(kind='run_commands', argv_steps=[['brew', 'install', 'whisper-cpp']])),
    dict(id='whisper_model_download', label='Download the whisper model masc asks for', detail='', source_url='',
         requires_admin=False, completion='recheck_required',
         effect=dict(kind='run_commands', argv_steps=[
             ['curl', '-L', '--create-dirs', '-o', '/home/.cache/whisper/ggml-large-v3-turbo.bin', 'https://example/model']])),
]))


def korean_terminal():
    # All three, because the reader's locale is the first of them that is set
    # and a shell that exports LC_ALL would otherwise decide this test.
    return patch.dict(os.environ,
                      {'LC_ALL': 'ko_KR.UTF-8', 'LC_MESSAGES': 'ko_KR.UTF-8', 'LANG': 'ko_KR.UTF-8'},
                      clear=False)


class LocalVoice(unittest.TestCase):
    """The voice question the journey asks before the sandbox.

    Speaking needs nothing downloaded -- say is in the base system -- so the
    step exists to pick a name from a list rather than to install anything.
    A name is picked rather than typed because say does not fail on one it
    does not have: it exits 0 in the system voice, and the reader hears a
    different voice with no error anywhere.
    """

    def test_a_voice_is_saved_by_the_name_the_listing_printed(self):
        with patch.object(SETUP, 'pick', side_effect=[[1], [1]]) as picker, \
                patch.object(SETUP.subprocess, 'run',
                             side_effect=[completed(VOICES), completed()]) as run, \
                korean_terminal(), \
                contextlib.redirect_stderr(io.StringIO()):
            SETUP.select_local_voice('/bin/masc', '/workspace')
        # ko_KR first because the terminal says Korean, and the parenthesised
        # name is kept whole: dropping the parenthesis selects another
        # language's voice of the same name.
        self.assertEqual(picker.call_args_list[0].args[1][:2],
                         ['Yuna \u2014 ko_KR', 'Eddy (\ud55c\uad6d\uc5b4(\ud55c\uad6d)) \u2014 ko_KR'])
        self.assertEqual(run.call_args_list[-1].args[0],
                         ['/bin/masc', 'voice-local-setup', '--base-path', '/workspace',
                          '--voice', 'Eddy (\ud55c\uad6d\uc5b4(\ud55c\uad6d))'])

    def test_staying_text_only_writes_nothing(self):
        with patch.object(SETUP, 'pick', return_value=[3]), \
                patch.object(SETUP.subprocess, 'run', side_effect=[completed(VOICES)]) as run, \
                korean_terminal(), \
                contextlib.redirect_stderr(io.StringIO()):
            SETUP.select_local_voice('/bin/masc', '/workspace')
        self.assertEqual([call.args[0][1] for call in run.call_args_list], ['voice-local-setup'])

    def test_a_computer_with_no_catalogue_is_not_asked(self):
        # Not a failure to report: a computer whose say publishes no voices
        # has none to offer, and the journey carries on to the sandbox.
        with patch.object(SETUP, 'pick') as picker, \
                patch.object(SETUP.subprocess, 'run', side_effect=[completed('', 1)]), \
                contextlib.redirect_stderr(io.StringIO()):
            SETUP.select_local_voice('/bin/masc', '/workspace')
        picker.assert_not_called()

    def test_hearing_names_the_file_the_download_wrote(self):
        # The path is read from the action that writes it, so the section
        # cannot name a file the download put somewhere else.
        with patch.object(SETUP.subprocess, 'run', side_effect=[completed(WHISPER_ACTIONS)]):
            self.assertEqual(SETUP.whisper_model_path('/bin/masc'),
                             '/home/.cache/whisper/ggml-large-v3-turbo.bin')

    def test_a_model_that_is_not_there_leaves_speaking_on(self):
        # Saying nothing about the model is not the same as saying nothing at
        # all: a keeper that speaks and does not listen is the better half of
        # the feature, and refusing the whole write would lose it.
        with patch.object(SETUP, 'pick', side_effect=[[0], [0]]), \
                patch.object(SETUP, 'prerequisite_menu', return_value=False), \
                patch.object(SETUP, 'whisper_model_path', return_value='/nowhere/ggml.bin'), \
                patch.object(SETUP.subprocess, 'run',
                             side_effect=[completed(VOICES), completed()]) as run, \
                korean_terminal(), \
                contextlib.redirect_stderr(io.StringIO()):
            SETUP.select_local_voice('/bin/masc', '/workspace')
        self.assertEqual(run.call_args_list[-1].args[0],
                         ['/bin/masc', 'voice-local-setup', '--base-path', '/workspace',
                          '--voice', 'Yuna'])

    def test_the_journey_asks_before_the_sandbox(self):
        # A reader who leaves at the sandbox step still leaves with a keeper
        # that can speak.
        order = []
        with patch.object(SETUP, 'onboarding_status', return_value=observation('/workspace')), \
                patch.object(SETUP, 'pick', return_value=[0]), \
                patch.object(SETUP, 'workspace_check', return_value=dict(base_path='/workspace')), \
                patch.object(SETUP, 'workspace_port', return_value=8945), \
                patch.object(SETUP, 'select_setup_server', return_value=8945), \
                patch.object(SETUP, 'wizard', return_value=dict(readiness='verified')), \
                patch.object(SETUP, 'select_local_voice', side_effect=lambda *_: order.append('voice')), \
                patch.object(SETUP, 'select_sandbox', side_effect=lambda *a, **k: order.append('sandbox')), \
                patch.object(SETUP.subprocess, 'run', return_value=subprocess.CompletedProcess([], 0)), \
                contextlib.redirect_stderr(io.StringIO()):
            SETUP.journey('/bin/masc', None, 8945, 10)
        self.assertEqual(order, ['voice', 'sandbox'])


class InvalidWorkspaceDiagnostic(unittest.TestCase):
    """An invalid check is named on screen, and every exit stays open.

    `invalid` is not one condition. A dangling assignment is repaired by saving
    a selection — runtime-default-set rewrites the staged file and that rewrite
    is what publishes — while a dangling binding is refused ahead of it, because
    validate_no_dangling_bindings is materialize_config's first check. Both
    reach this journey as the same string, so blocking on it would strand the
    repairable ones and close the only way to leave a broken workspace.
    """

    def broken(self):
        return observation('/workspace', (
            ('workspace', 'satisfied', 'Workspace found.'),
            ('model_connection', 'invalid', 'The workspace runtime.toml is unreadable.'),
            ('keeper_persistence', 'satisfied', 'imp has persisted history.')))

    def test_invalid_check_is_named_with_its_reason(self):
        errors = io.StringIO()
        with patch.object(SETUP, 'onboarding_status', return_value=self.broken()), \
                patch.object(SETUP, 'pick', return_value=[2]), \
                contextlib.redirect_stderr(errors):
            SETUP.journey('masc', '/workspace', None, 30, resume=True)
        self.assertIn('model_connection', errors.getvalue())
        self.assertIn('unreadable', errors.getvalue())

    def test_invalid_check_still_offers_another_workspace(self):
        # Leaving a broken workspace behind is only possible through question 1,
        # which test_native_setup_can_leave_remembered_workspace_with_invalid_port
        # pins for the invalid-port path.
        with patch.object(SETUP, 'onboarding_status', return_value=self.broken()), \
                patch.object(SETUP, 'pick', return_value=[2]) as pick, \
                patch.object(SETUP, 'open_workspace') as open_workspace, \
                contextlib.redirect_stderr(io.StringIO()):
            code = SETUP.journey('masc', '/workspace', None, 30, resume=True)
        self.assertEqual(code, 0)
        open_workspace.assert_not_called()
        self.assertEqual(pick.call_args[0][0], '1 \u00b7 Your workspace')
        self.assertIn('Choose another directory', pick.call_args[0][1])

    def test_readable_workspace_resumes_without_a_diagnostic(self):
        state = observation('/workspace', (
            ('workspace', 'satisfied'),
            ('model_connection', 'needs_verification'),
            ('sandbox', 'needs_verification'),
            ('keeper_persistence', 'satisfied')))
        errors = io.StringIO()
        with patch.object(SETUP, 'onboarding_status', return_value=state), \
                patch.object(SETUP, 'workspace_port', return_value=8935), \
                patch.object(SETUP, 'select_setup_server', return_value=8935), \
                patch.object(SETUP, 'open_workspace', return_value=0) as open_workspace, \
                patch.object(SETUP, 'pick') as pick, \
                contextlib.redirect_stderr(errors):
            code = SETUP.journey('masc', '/workspace', None, 30, resume=True)
        self.assertEqual(code, 0)
        open_workspace.assert_called_once()
        pick.assert_not_called()
        self.assertEqual(errors.getvalue(), '')

    def test_fresh_workspace_still_opens_the_wizard(self):
        state = observation(None, (
            ('workspace', 'needs_setup'),
            ('model_connection', 'needs_setup')))
        with patch.object(SETUP, 'onboarding_status', return_value=state), \
                patch.object(SETUP, 'pick', return_value=[2]) as pick, \
                contextlib.redirect_stderr(io.StringIO()):
            code = SETUP.journey('masc', None, None, 30, resume=True)
        self.assertEqual(code, 0)
        pick.assert_called_once()


class FailedSaveReporting(unittest.TestCase):
    """A save that died in validation is not the operator deferring the step.

    Both paths leave the wizard without a model connection, but only one of
    them wrote anything. Reporting a saved workspace and exit 0 for the other
    makes the last line the operator reads a false one.
    """

    def run_journey(self, wizard_result):
        fresh = observation(None, (
            ('workspace', 'needs_setup'),
            ('model_connection', 'needs_setup')))
        errors = io.StringIO()
        with patch.object(SETUP, 'onboarding_status', return_value=fresh), \
                patch.object(SETUP, 'pick', return_value=[0]), \
                patch.object(SETUP, 'workspace_check', return_value={'base_path': '/workspace'}), \
                patch.object(SETUP, 'workspace_port', return_value=8935), \
                patch.object(SETUP, 'select_setup_server', return_value=8935), \
                patch.object(SETUP, 'wizard', return_value=wizard_result), \
                patch.object(SETUP.subprocess, 'run',
                             return_value=subprocess.CompletedProcess([], 0)), \
                contextlib.redirect_stderr(errors):
            code = SETUP.journey('masc', '/workspace', None, 30, resume=True)
        return code, errors.getvalue()

    def test_failed_save_is_not_reported_as_saved(self):
        code, errors = self.run_journey(
            dict(configured=False, readiness='failed', base_path='/workspace'))
        self.assertEqual(code, 1)
        self.assertIn('was not saved', errors)
        self.assertNotIn('workspace is saved', errors)

    def test_deferred_step_still_reports_the_saved_workspace(self):
        code, errors = self.run_journey(
            dict(configured=False, readiness='deferred', base_path='/workspace'))
        self.assertEqual(code, 0)
        self.assertIn('workspace is saved', errors)

if __name__ == '__main__':
    unittest.main()
