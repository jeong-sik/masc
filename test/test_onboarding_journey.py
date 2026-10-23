"""Exercise fresh-home and interrupted setup through the shipped journey."""
import contextlib
import importlib.util
import io
import json
import os
import pty
import re
from pathlib import Path
import select
import shlex
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


def observation(base=None, checks=(), opening='needs_journey'):
    # doctor always emits a message per check, so the fixture does too: the
    # journey reads it for any invalid condition. Each check is (id, condition)
    # or (id, condition, message). `opening` is decided by the binary from typed
    # checks (test_onboarding_status.ml pins that rule); a fixture names the
    # answer the journey must follow instead of re-deriving it here.
    rows = [dict(id=name, condition=condition, message=(rest[0] if rest else ''))
            for name, condition, *rest in checks]
    return dict(schema='masc.onboarding_status.v1', scope='configuration_observation',
                base_path=base, opening=opening, checks=rows)

def pdf_readiness(ready=False):
    """The wire shape MASC sends. Belongs anywhere a catalog or receipt is built."""
    return dict(schema='masc.pdf_tools_readiness.v1', status='tools_available' if ready else 'unavailable',
                pdf_inspection='not_run', scope='current_process_environment', checks=[dict(command=name, status='started' if ready else 'missing')
                    for name in ('pdftotext', 'pdftoppm')])


def pdf_readiness_parsed(ready=False):
    """What pdf_tools_status now returns. Parsed from the wire shape above
    rather than hand-built, so a fixture that drifts out of what the decoder
    accepts fails here instead of passing a value production never produces."""
    return SETUP.decode_pdf_tools_readiness(pdf_readiness(ready))

class StepByStep(unittest.TestCase):
    """Cases that walk the journey one screen at a time.

    quick_plan looks for claude on PATH, so a developer's Mac and a CI runner
    would open these cases on different first screens. They are pinned to a
    computer that has no plan to offer; QuickSetup covers the plan.

    The tools step asks the binary what it finds on this computer, and a case
    that walks the sandbox would otherwise spend its stand-in replies on that.
    ImpTools covers the step itself.
    """

    def setUp(self):
        plan = patch.object(SETUP, 'quick_plan', return_value=None)
        plan.start()
        self.addCleanup(plan.stop)
        for name in ('select_imp_tools', 'show_imp_tools'):
            stand_in = patch.object(SETUP, name)
            stand_in.start()
            self.addCleanup(stand_in.stop)


def path_without(command, path):
    """PATH with every directory that holds `command` left out."""
    return os.pathsep.join(entry for entry in path.split(os.pathsep)
                           if entry and not os.path.exists(os.path.join(entry, command)))


class Journey(StepByStep):
    def setUp(self):
        super().setUp()
        renderer = patch.object(SETUP, 'render', return_value=('fixture.native-model', b'', b''))
        renderer.start()
        self.addCleanup(renderer.stop)
        pdf = patch.object(SETUP, 'pdf_tools_status', return_value=pdf_readiness_parsed())
        pdf.start()
        self.addCleanup(pdf.stop)

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
                patch.object(SETUP, 'pick', side_effect=[[0], [5]]), contextlib.redirect_stderr(io.StringIO()):
            self.assertIsNone(SETUP.select_sandbox('/bin/masc', '/workspace'))
        prerequisites.assert_called_once_with('/bin/masc', 'docker', base_path='/workspace', port=8945)

    def test_configuration_error_shows_kind_and_detail(self):
        catalog = dict(schema='masc.sandbox_readiness.v1', configured_selection=None,
            configuration_error=dict(kind='declaration_unreadable', detail='/workspace/.masc/config/keepers/imp.toml: No such file or directory'),
            candidates=[dict(id='docker', state='service_ready', reason='', advanced=False, recommended=True,
                setup_args=['--sandbox-profile', 'docker'], capabilities=dict(network_modes=['none', 'inherit']))])
        response = subprocess.CompletedProcess([], 0, json.dumps(catalog), '')
        with patch.object(SETUP.subprocess, 'run', return_value=response), \
                patch.object(SETUP, 'pick', return_value=[0]), contextlib.redirect_stderr(io.StringIO()) as output:
            SETUP.select_sandbox('/bin/masc', '/workspace')
        self.assertIn('declaration_unreadable: /workspace/.masc/config/keepers/imp.toml: No such file or directory', output.getvalue())

    def test_pdf_tools_use_existing_setup_selection_and_refresh(self):
        catalog = dict(schema='masc.sandbox_readiness.v1', candidates=[dict(
            id='docker', state='service_ready', reason='', advanced=False, recommended=True,
            setup_args=['--sandbox-profile', 'docker'], capabilities=dict(network_modes=['inherit']))])
        response = subprocess.CompletedProcess([], 0, json.dumps(catalog), '')
        labels = []
        def choose(title, options):
            labels.append(options)
            return [3] if len(labels) == 1 else [0]
        with patch.object(SETUP.subprocess, 'run', return_value=response), \
                patch.object(SETUP, 'pdf_tools_status', side_effect=[pdf_readiness_parsed(), pdf_readiness_parsed(True)]), \
                patch.object(SETUP, 'prerequisite_menu', return_value=True) as install, \
                patch.object(SETUP, 'pick', side_effect=choose), contextlib.redirect_stderr(io.StringIO()):
            result = SETUP.select_sandbox('/owned/masc', '/workspace')
        install.assert_called_once_with('/owned/masc', 'pdf-tools', base_path='/workspace', port=8945)
        self.assertIn('install missing tools', labels[0][3])
        self.assertIn('tools available', labels[1][3])
        self.assertEqual(result, ['--sandbox-profile', 'docker', '--network-mode', 'inherit'])

    def test_readiness_is_parsed_into_a_closed_answer(self):
        self.assertTrue(SETUP.decode_pdf_tools_readiness(pdf_readiness(True)).available)
        parsed = SETUP.decode_pdf_tools_readiness(pdf_readiness())
        self.assertFalse(parsed.available)
        self.assertEqual([(row.command, row.status) for row in parsed.checks],
                         [('pdftotext', 'missing'), ('pdftoppm', 'missing')])
        # A word the wire never sends is refused here, rather than read as
        # "not available" by every caller that compares against a literal.
        for status in ('TOOLS_AVAILABLE', 'available', 'tools_available '):
            with self.subTest(status=status), self.assertRaises(SETUP.SetupError):
                SETUP.decode_pdf_tools_readiness(dict(pdf_readiness(True), status=status))

    def test_pdf_install_menu_requires_actual_recheck(self):
        action = dict(id='poppler_install', label='Install PDF tools', detail='Uses the selected package manager',
                      source_url='https://formulae.brew.sh/formula/poppler', requires_admin=False)
        catalog = dict(schema='masc.prerequisite_actions.v1', actions=[action], dependency_readiness=pdf_readiness())
        for ready in (False, True):
            receipt = dict(schema='masc.prerequisite_action_result.v1',
                status='commands_completed' if ready else 'failed',
                readiness='tools_available' if ready else 'unavailable',
                dependency_readiness=pdf_readiness(ready), reason='PDF tools could not start')
            replies = [subprocess.CompletedProcess([], 0, json.dumps(catalog)),
                       subprocess.CompletedProcess([], 0 if ready else 1, json.dumps(receipt))]
            with self.subTest(ready=ready), patch.object(SETUP.subprocess, 'run', side_effect=replies) as run, \
                    patch.object(SETUP, 'pick', return_value=[0]), contextlib.redirect_stderr(io.StringIO()) as output:
                self.assertTrue(SETUP.prerequisite_menu('/owned/masc', 'pdf-tools'))
            self.assertEqual(run.call_args_list[-1].args[0],
                ['/owned/masc', 'prerequisite-actions', 'pdf-tools', '--execute', 'poppler_install'])
            self.assertEqual('both commands started successfully' in output.getvalue(), ready)
        receipt.update(status='commands_completed', readiness='not_checked')
        with patch.object(SETUP.subprocess, 'run', side_effect=[subprocess.CompletedProcess([], 0, json.dumps(catalog)),
                subprocess.CompletedProcess([], 0, json.dumps(receipt))]), \
                patch.object(SETUP, 'pick', return_value=[0]), contextlib.redirect_stderr(io.StringIO()):
            with self.assertRaises(SETUP.SetupError):
                SETUP.prerequisite_menu('/owned/masc', 'pdf-tools')

    @unittest.skipUnless(BINARY, 'requires CI-built native executable')
    def test_native_pdf_install_rechecks_actual_command_start(self):
        import shlex
        for renderer in ('ready', 'missing', 'broken'):
            install_renderer = renderer != 'missing'
            ready = renderer == 'ready'
            with self.subTest(renderer=renderer), tempfile.TemporaryDirectory() as home:
                root = Path(home)
                tools = root / 'tools'
                tools.mkdir()
                def command(name, body):
                    path = tools / name
                    path.write_text('#!/bin/sh\n' + body + '\n')
                    path.chmod(0o700)
                command('uname', 'case "$1" in -m) echo arm64 ;; *) echo Darwin ;; esac')
                command('sw_vers', 'echo 15.0')
                marker = root / 'package-manager-called'
                calls = root / 'pdf-command-calls'
                payload = '#!/bin/sh\n[ "$1" = -v ] || exit 95\nprintf "%s\\n" "$0" >> ' + shlex.quote(str(calls)) + '\necho "fixture PDF command started"\n'
                installer = '[ "$1" = install ] && [ "$2" = poppler ] || exit 94\n: > ' + shlex.quote(str(marker)) + '\n'
                for name in ('pdftotext', 'pdftoppm') if install_renderer else ('pdftotext',):
                    target = shlex.quote(str(tools / name))
                    tool_payload = payload + ('exit 127\n' if name == 'pdftoppm' and renderer == 'broken' else '')
                    installer += 'printf %s ' + shlex.quote(tool_payload) + ' > ' + target + '\n/bin/chmod 700 ' + target + '\n'
                command('brew', installer)
                env = dict(os.environ, HOME=home, PATH=str(tools), XDG_CONFIG_HOME=home)
                def native(*tail):
                    return subprocess.run([BINARY, 'prerequisite-actions', 'pdf-tools', *tail],
                        env=env, capture_output=True, text=True, timeout=20)
                before = native()
                self.assertEqual(before.returncode, 0, before.stderr)
                self.assertFalse(marker.exists(), 'catalog inspection installed a package')
                self.assertEqual(json.loads(before.stdout)['dependency_readiness']['status'], 'unavailable')
                installed = native('--execute', 'poppler_install')
                receipt = json.loads(installed.stdout)
                self.assertTrue(marker.exists())
                self.assertEqual(installed.returncode, 0 if ready else 1, installed.stderr)
                self.assertEqual(receipt['readiness'], 'tools_available' if ready else 'unavailable')
                self.assertEqual(receipt['dependency_readiness']['pdf_inspection'], 'not_run')
                self.assertEqual(len(calls.read_text().splitlines()), 2 if install_renderer else 1)

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
            # The lookup is masc's; here it answers the way the runtime would
            # once the installer has written the file, and nothing before.
            def located(binary, choice, command):
                self.assertEqual((binary, choice, command), ('/owned/masc', 'antigravity', 'agy'))
                return str(target) if target.is_file() else None
            with patch.dict(os.environ, HOME=home), patch.object(SETUP, 'official_client_path', side_effect=located), \
                    patch.object(SETUP, 'prerequisite_menu', side_effect=install) as action, \
                    patch.object(SETUP, 'prepare_antigravity_account', side_effect=lambda row, _: row):
                result = SETUP.prepare_connection('/owned/masc', source, credentials)
            action.assert_called_once_with('/owned/masc', 'antigravity')
            self.assertEqual(result['command'], str(target))

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
                # This case walks step 1; with Claude Code on PATH the journey
                # opens on the quick setup plan instead.
                environment['PATH'] = path_without('claude', environment.get('PATH', ''))
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
                # Esc, not q. Since the picker gained type-to-filter (#35206)
                # every printable byte types into the query -- a model id can
                # start with any letter -- and the picker's own hint line says
                # so: "type to filter · Esc clears · Ctrl-C cancels". Measured
                # on this build: q leaves the picker showing `Filter: q / no
                # matches`, Esc on an empty filter exits 1 writing nothing, and
                # Ctrl-C is taken by the terminal as SIGINT before the loop
                # sees it, so the process dies by signal rather than exiting.
                os.write(fd, b'\x1b')
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
                environment.update(HOME=home, XDG_CONFIG_HOME=home + '/config', TERM='dumb',
                                   PATH=path_without('claude', environment.get('PATH', '')))
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
                # Cancelling the connection question no longer ends the
                # journey: it offers the workspace back rather than losing it.
                # Leaving by the second option is what ends setup, and the
                # exit code is still 1 -- the model connection was not saved.
                until(b'Connection setup')
                os.write(fd, b'2\n')
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
        state = observation('/old', [('workspace', 'satisfied'), ('keeper_persistence', 'satisfied')],
                            opening='open_existing_history')
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
                ['/bin/masc', 'init', '--base-path', base, '--record-default'],
                ['/bin/masc', 'setup', '--base-path', base, '--port', '9876', '--no-tui']])
            opened.assert_called_once_with('/bin/masc', base, 9876)
            self.assertFalse(Path(base).exists())  # renderer did not mutate workspace

    def test_persisted_history_resumes_without_model_reselection(self):
        state = observation('/workspace', [('workspace', 'satisfied'), ('keeper_persistence', 'satisfied')],
                            opening='open_existing_history')
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

    def test_observation_without_an_opening_is_unsupported(self):
        document = dict(schema='masc.onboarding_status.v1', scope='configuration_observation',
                        base_path='/workspace', checks=[])
        for opening in (None, 'open', 'ready'):
            payload = dict(document) if opening is None else dict(document, opening=opening)
            response = subprocess.CompletedProcess([], 0, json.dumps(payload), '')
            with self.subTest(opening=opening), patch.object(SETUP.subprocess, 'run', return_value=response), \
                    self.assertRaises(SETUP.SetupError):
                SETUP.onboarding_status('/bin/masc')

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
         writes='/home/.cache/whisper/ggml-large-v3-turbo.bin',
         effect=dict(kind='run_commands', argv_steps=[
             ['curl', '-fL', '--create-dirs', '-o', '/home/.cache/whisper/ggml-large-v3-turbo.bin.part',
              'https://example/model'],
             ['mv', '/home/.cache/whisper/ggml-large-v3-turbo.bin.part',
              '/home/.cache/whisper/ggml-large-v3-turbo.bin']])),
]))


def korean_terminal():
    # All three, because the reader's locale is the first of them that is set
    # and a shell that exports LC_ALL would otherwise decide this test.
    return patch.dict(os.environ,
                      {'LC_ALL': 'ko_KR.UTF-8', 'LC_MESSAGES': 'ko_KR.UTF-8', 'LANG': 'ko_KR.UTF-8'},
                      clear=False)


class LocalVoice(StepByStep):
    """The voice question the journey asks before the sandbox.

    Speaking needs nothing downloaded -- say is in the base system -- so the
    step exists to pick a name from a list rather than to install anything.
    A name is picked rather than typed because say does not fail on one it
    does not have: it exits 0 speaking in another voice, and the reader hears
    a different voice with no error anywhere.
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

    @unittest.skipUnless(BINARY, 'requires the CI-built native executable')
    def test_the_real_catalog_names_the_final_model_file(self):
        # The fixture above is a copy of the catalog, and a copy can drift: the
        # download moved to a .part beside the final path while the fixture kept
        # the old argv, and this function returned the .part for every real
        # computer with the tests green. So the real binary's catalog is read.
        with tempfile.TemporaryDirectory() as home:
            with patch.dict(os.environ, HOME=home):
                path = SETUP.whisper_model_path(BINARY)
        self.assertIsNotNone(path)
        self.assertEqual(Path(path).name, 'ggml-large-v3-turbo.bin')
        self.assertTrue(path.startswith(home), path)

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

    def test_listening_requires_both_cli_and_a_regular_model_file(self):
        with tempfile.TemporaryDirectory() as directory:
            model = Path(directory) / 'ggml.bin'
            model.write_bytes(b'model fixture')
            for executable, model_path, expected in (
                    (None, str(model), False),
                    ('/fixture/whisper-cli', directory, False),
                    ('/fixture/whisper-cli', str(model), True)):
                with self.subTest(executable=executable, model=model_path), \
                        patch.object(SETUP, 'pick', side_effect=[[0], [0]]), \
                        patch.object(SETUP, 'prerequisite_menu', return_value=False), \
                        patch.object(SETUP, 'whisper_model_path', return_value=model_path), \
                        patch.object(SETUP.shutil, 'which', return_value=executable), \
                        patch.object(SETUP.subprocess, 'run',
                                     side_effect=[completed(VOICES), completed()]) as run, \
                        korean_terminal(), \
                        contextlib.redirect_stderr(io.StringIO()):
                    SETUP.select_local_voice('/bin/masc', '/workspace')
                    arguments = run.call_args_list[-1].args[0]
                    self.assertIn('--voice', arguments)
                    self.assertEqual('--model' in arguments, expected)
                    if expected:
                        self.assertEqual(arguments[-2:], ['--model', str(model)])

    def test_the_listing_is_asked_about_the_workspace_being_set_up(self):
        # Every masc command resolves a workspace first, the listing included.
        # This step runs before the one that records a default, so the list
        # must name the workspace rather than depend on the launcher's env.
        with patch.object(SETUP, 'pick', side_effect=[[1], [1]]), \
                patch.object(SETUP.subprocess, 'run',
                             side_effect=[completed(VOICES), completed()]) as run, \
                korean_terminal(), \
                contextlib.redirect_stderr(io.StringIO()):
            SETUP.select_local_voice('/bin/masc', '/workspace')
        self.assertEqual(run.call_args_list[0].args[0],
                         ['/bin/masc', 'voice-local-setup', '--base-path', '/workspace', '--list-voices'])

    def test_a_listing_that_fails_says_why_instead_of_skipping_silently(self):
        # Measured: with no workspace to resolve the listing exits 1 with its
        # reason as the last stderr line. An empty list used to skip the voice
        # question without a word.
        failed = subprocess.CompletedProcess(
            [], 1, stdout='',
            stderr='[2026-09-13] [INFO] [MCP] Tag registry initialized\n'
                   '[2026-09-13] [ERROR] [Backend] MASC_BASE_PATH is not set.\n')
        with patch.object(SETUP, 'pick') as picker, \
                patch.object(SETUP.subprocess, 'run', side_effect=[failed]) as run, \
                contextlib.redirect_stderr(io.StringIO()) as printed:
            SETUP.select_local_voice('/bin/masc', '/workspace')
        self.assertIn('Could not list the voices on this computer', printed.getvalue())
        self.assertIn('MASC_BASE_PATH is not set', printed.getvalue())
        self.assertNotIn('Tag registry', printed.getvalue())
        picker.assert_not_called()
        self.assertEqual(len(run.call_args_list), 1)

    def test_hearing_without_a_recorder_is_configured_and_says_so(self):
        # Transcribing needs whisper-cli and a model; recording from the
        # microphone needs sox's rec as well. A reader who installed the first
        # two and left sox still gets hearing configured -- a device posting
        # audio needs nothing more -- and is told what the TUI will lack.
        with tempfile.TemporaryDirectory() as directory:
            model = Path(directory) / 'ggml.bin'
            model.write_bytes(b'model fixture')
            for recorder, warned in ((None, True), ('/fixture/rec', False)):
                which = {'whisper-cli': '/fixture/whisper-cli', 'rec': recorder}
                with self.subTest(recorder=recorder), \
                        patch.object(SETUP, 'pick', side_effect=[[0], [0]]), \
                        patch.object(SETUP, 'prerequisite_menu', return_value=False), \
                        patch.object(SETUP, 'whisper_model_path', return_value=str(model)), \
                        patch.object(SETUP.shutil, 'which', side_effect=which.get), \
                        patch.object(SETUP.subprocess, 'run',
                                     side_effect=[completed(VOICES), completed()]) as run, \
                        korean_terminal(), \
                        contextlib.redirect_stderr(io.StringIO()) as printed:
                    SETUP.select_local_voice('/bin/masc', '/workspace')
                    self.assertEqual(run.call_args_list[-1].args[0][-2:], ['--model', str(model)])
                    self.assertEqual("sox's rec" in printed.getvalue(), warned)

    def test_cancelling_the_voice_question_does_not_cancel_setup(self):
        # An optional step cannot fail the thing it is optional to. By the time
        # this runs the workspace and the model are saved and the sandbox step
        # is still ahead, so `q` here means "not this", not "abandon setup".
        with patch.object(SETUP, 'pick', side_effect=SETUP.SetupError('setup cancelled')), \
                patch.object(SETUP.subprocess, 'run', side_effect=[completed(VOICES)]) as run, \
                korean_terminal(), \
                contextlib.redirect_stderr(io.StringIO()) as printed:
            SETUP.select_local_voice('/bin/masc', '/workspace')
        self.assertIn('Continuing without voice', printed.getvalue())
        # Asked for the listing, wrote nothing.
        self.assertEqual([call.args[0][1] for call in run.call_args_list], ['voice-local-setup'])

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


BROWSER_NAMES = {'geckodriver': 'geckodriver', 'firefox': 'Firefox', 'ego-browser': 'ego lite'}
BROWSER_INSTALLS = {'geckodriver': ['brew', 'install', 'geckodriver'],
                    'firefox': ['brew', 'install', '--cask', 'firefox']}


def browser_readiness(program, ready=True):
    """The wire shape MASC sends for geckodriver and Firefox."""
    row = (dict(command=program, status='started', path='/opt/tools/' + program, output=program + ' 1.0')
           if ready else dict(command=program, status='missing'))
    return dict(schema='masc.browser_tools_readiness.v1', program=program,
                status='tools_available' if ready else 'unavailable',
                scope='current_process_environment', checks=[row], lane='not_checked')


def browser_catalog(program, ready=True, admin=False):
    action = dict(id=program + '_brew_install', label='Install ' + BROWSER_NAMES[program] + ' with Homebrew',
                  detail='Install through the existing Homebrew package manager',
                  source_url='https://formulae.brew.sh/' + program, requires_admin=admin,
                  effect=dict(kind='run_commands', argv_steps=[BROWSER_INSTALLS[program]]),
                  completion='recheck_required', writes=None)
    return json.dumps(dict(schema='masc.prerequisite_actions.v1', actions=[action],
                           dependency_readiness=browser_readiness(program, ready)))


def browser_page_catalog(program, ready=False):
    """A host where MASC only knows an official page to open."""
    action = dict(id=program + '_official_page', label='Open the ' + BROWSER_NAMES[program] + ' download page',
                  detail='Open the official page', source_url='https://example.invalid/' + program,
                  requires_admin=False, effect=dict(kind='open_official_installer', url='https://example.invalid/' + program,
                                                    argv=['xdg-open', 'https://example.invalid/' + program]),
                  completion='external_step_pending', writes=None)
    return json.dumps(dict(schema='masc.prerequisite_actions.v1', actions=[action],
                           dependency_readiness=browser_readiness(program, ready)))


def browser_receipt(program, status, readiness, ready=None, **extra):
    receipt = dict(schema='masc.prerequisite_action_result.v1', status=status, readiness=readiness, **extra)
    if ready is not None:
        receipt['dependency_readiness'] = browser_readiness(program, ready)
    return json.dumps(receipt)


SETUP_ARGV = ['/bin/masc', 'browser-lane-setup', '--mode', 'automation', '--base-path', '/workspace']


class BrowserToolReadiness(unittest.TestCase):
    """Reading what MASC says about geckodriver and Firefox.

    The decoder is the one place the wire words are read, so a shape the
    binary stops sending fails here instead of reading as "not installed".
    """

    def test_the_wire_shape_is_read(self):
        found = SETUP.decode_browser_tools_readiness(browser_readiness('geckodriver'), 'geckodriver')
        self.assertEqual((found.available, found.path), (True, '/opt/tools/geckodriver'))
        absent = SETUP.decode_browser_tools_readiness(browser_readiness('firefox', ready=False), 'firefox')
        self.assertEqual((absent.available, absent.path), (False, None))

    def test_a_shape_that_drifted_is_refused_rather_than_read_as_missing(self):
        def drifted(change, program='geckodriver', ready=True):
            value = browser_readiness(program, ready)
            change(value)
            return value
        cases = {
            'another program': lambda v: v.update(program='firefox'),
            'unknown schema': lambda v: v.update(schema='masc.browser_tools_readiness.v2'),
            'a lane already checked': lambda v: v.update(lane='checked'),
            'another scope': lambda v: v.update(scope='workspace'),
            'unknown status': lambda v: v.update(status='ok'),
            'two checks': lambda v: v['checks'].append(dict(v['checks'][0])),
            'started but unavailable': lambda v: v.update(status='unavailable'),
            'available but missing': lambda v: v['checks'][0].update(status='missing'),
            'a relative path': lambda v: v['checks'][0].update(path='bin/geckodriver'),
            'no path': lambda v: v['checks'][0].pop('path'),
        }
        for name, change in cases.items():
            with self.subTest(name):
                with self.assertRaises(SETUP.SetupError):
                    SETUP.decode_browser_tools_readiness(drifted(change), 'geckodriver')
        with self.assertRaises(SETUP.SetupError):
            SETUP.decode_browser_tools_readiness(None, 'geckodriver')

    def execute(self, program, receipt, code=0):
        with patch.object(SETUP.subprocess, 'run', return_value=completed(receipt, code)), \
                contextlib.redirect_stderr(io.StringIO()) as printed:
            return SETUP.execute_prerequisite('/bin/masc', program, program + '_brew_install'), printed.getvalue()

    def test_an_install_that_left_a_program_that_starts_is_completed(self):
        state, printed = self.execute('geckodriver', browser_receipt(
            'geckodriver', 'commands_completed', 'tools_available', ready=True))
        self.assertEqual(state, 'commands_completed')
        self.assertIn('geckodriver is installed and starts', printed)

    def test_an_install_that_left_nothing_that_starts_is_not_completed(self):
        # A receipt that claims success next to a recheck that says otherwise is
        # a contradiction the screen must not report as an install.
        with self.assertRaises(SETUP.SetupError):
            self.execute('firefox', browser_receipt('firefox', 'commands_completed', 'unavailable', ready=False))
        with self.assertRaises(SETUP.SetupError):
            self.execute('firefox', browser_receipt('firefox', 'commands_completed', 'tools_available', ready=False))

    def test_a_completed_install_that_was_never_rechecked_is_not_completed(self):
        # The binary always rechecks a browser install. A receipt that does not
        # carry one is a shape that drifted, and "installed and starts" must not
        # be printed for it (the PDF check already refuses the same input).
        with self.assertRaises(SETUP.SetupError):
            self.execute('geckodriver', browser_receipt('geckodriver', 'commands_completed', 'not_checked'))

    def test_a_receipt_whose_two_fields_disagree_is_unreadable_whatever_its_status(self):
        # The status check above catches a completed install; a failed one
        # carries no such claim, so only the comparison of the two fields can.
        with self.assertRaises(SETUP.SetupError):
            self.execute('firefox', browser_receipt('firefox', 'failed', 'tools_available', ready=False,
                                                    reason='brew exited 1'), code=1)

    def test_a_failed_install_says_why_in_the_reason_it_carries(self):
        for readiness, ready in (('unavailable', False), ('not_checked', None)):
            with self.subTest(readiness=readiness):
                state, printed = self.execute('firefox', browser_receipt(
                    'firefox', 'failed', readiness, ready=ready, reason='brew exited 1'), code=1)
                self.assertEqual(state, 'failed')
                self.assertIn('brew exited 1', printed)

    def test_an_official_page_install_waits_for_the_reader(self):
        state, printed = self.execute('geckodriver', browser_receipt(
            'geckodriver', 'external_step_pending', 'not_checked'))
        self.assertEqual(state, 'external_step_pending')
        self.assertIn('Complete the vendor installation window', printed)


GH_TOKEN_FIXTURE = 'gho_fixturefixturefixturefixturefixture0000'


def gh_status(*accounts):
    """What `gh auth status --json hosts` prints. It never carries the token."""
    return json.dumps(dict(hosts={'github.com': list(accounts)} if accounts else {}))


def gh_account(login='octo', state='success', active=True, source='keyring', scopes='gist, read:org, repo, workflow'):
    return dict(state=state, active=active, host='github.com', login=login, tokenSource=source,
                scopes=scopes, gitProtocol='https')


class ImpTools(unittest.TestCase):
    """The tools checklist: one screen after the sandbox that starts marked.

    Nothing runs until the reader confirms it, and a quick setup runs nothing.
    The login on this computer is pinned to none unless a case says otherwise,
    so a developer's own gh does not decide the rows.
    """

    def setUp(self):
        login = patch.object(SETUP, 'host_github_login', return_value=None)
        self.host_login = login.start()
        self.addCleanup(login.stop)
        # Whether Docker runs here, and whether ZAI_API_KEY is set, decide a
        # row each (the first also costs one more catalog call), so both are
        # pinned to "no row" like the login. SearchChoices covers them.
        for name in ('searxng_row', 'zai_row', 'ego_row'):
            pinned = patch.object(SETUP, name, return_value=None)
            pinned.start()
            self.addCleanup(pinned.stop)

    def catalogs(self, *programs, ready=True, admin=False):
        return [completed(browser_catalog(program, ready, admin)) for program in programs]

    def test_found_programs_make_a_browser_row_that_names_the_command(self):
        with patch.object(SETUP.subprocess, 'run', side_effect=self.catalogs('geckodriver', 'firefox')):
            rows = SETUP.imp_tool_rows('/bin/masc', '/work space')
        self.assertEqual([row.key for row in rows], ['automation', 'bidi', 'extension', 'github', 'web-search'])
        self.assertIn('geckodriver and Firefox found', rows[0].label)
        self.assertEqual(rows[0].command,
                         "masc browser-lane-setup --mode automation --base-path '/work space'")

    def test_a_missing_program_names_its_install_in_the_row_and_the_command(self):
        replies = [completed(browser_catalog('geckodriver', ready=False)),
                   completed(browser_catalog('firefox', ready=False, admin=True))]
        with patch.object(SETUP.subprocess, 'run', side_effect=replies):
            row = SETUP.imp_tool_rows('/bin/masc', '/workspace')[0]
        self.assertIn('geckodriver, Firefox not found', row.label)
        self.assertIn('brew install geckodriver; brew install --cask firefox', row.label)
        self.assertIn('administrator permission', row.label)
        self.assertEqual(row.command, 'brew install geckodriver && brew install --cask firefox && '
                                      'masc browser-lane-setup --mode automation --base-path /workspace')

    def test_only_the_missing_program_is_offered_for_install(self):
        replies = [completed(browser_catalog('geckodriver', ready=False)), completed(browser_catalog('firefox'))]
        with patch.object(SETUP.subprocess, 'run', side_effect=replies):
            row = SETUP.imp_tool_rows('/bin/masc', '/workspace')[0]
        self.assertNotIn('--cask', row.label + row.command)
        self.assertTrue(row.command.startswith('brew install geckodriver && masc browser-lane-setup'))

    def test_a_host_that_only_has_a_page_to_open_prints_no_command_for_it(self):
        # `see https://... && masc ...` is not a command anyone can run.
        replies = [completed(browser_page_catalog('geckodriver')), completed(browser_catalog('firefox'))]
        with patch.object(SETUP.subprocess, 'run', side_effect=replies):
            row = SETUP.imp_tool_rows('/bin/masc', '/workspace')[0]
        self.assertIn('official page https://example.invalid/geckodriver', row.label)
        self.assertEqual(row.command, 'masc browser-lane-setup --mode automation --base-path /workspace')

    def test_an_install_action_in_a_shape_that_drifted_leaves_the_github_row(self):
        # Every field the install menu reads, so a catalog that drops one is
        # refused with the row and not after the reader has marked it.
        for field in ('id', 'label', 'detail', 'source_url', 'requires_admin'):
            with self.subTest(field=field):
                broken = json.loads(browser_catalog('geckodriver', ready=False))
                del broken['actions'][0][field]
                replies = [completed(json.dumps(broken)), completed(browser_catalog('firefox'))]
                with patch.object(SETUP.subprocess, 'run', side_effect=replies), \
                        contextlib.redirect_stderr(io.StringIO()) as printed:
                    rows = SETUP.imp_tool_rows('/bin/masc', '/workspace')
                self.assertEqual([row.key for row in rows], ['github', 'web-search'])
                self.assertIn('unreadable install action', printed.getvalue())

    def test_a_catalog_the_binary_cannot_answer_is_not_read_as_missing_and_leaves_the_github_row(self):
        with patch.object(SETUP.subprocess, 'run', side_effect=[completed('', 1), completed('', 1)]), \
                contextlib.redirect_stderr(io.StringIO()) as printed:
            rows = SETUP.imp_tool_rows('/bin/masc', '/workspace')
        self.assertEqual([row.key for row in rows], ['github', 'web-search'])
        self.assertIn('left out of this list', printed.getvalue())

    def test_the_checklist_starts_marked_and_may_come_back_with_nothing(self):
        replies = self.catalogs('geckodriver', 'firefox') + self.catalogs('geckodriver', 'firefox') + [
            completed(), completed(json.dumps(dict(status='free')))]
        with patch.object(SETUP.subprocess, 'run', side_effect=replies) as run, \
                patch.object(SETUP, 'pick', return_value=[0]) as picker, \
                contextlib.redirect_stderr(io.StringIO()):
            confirmed = SETUP.select_imp_tools('/bin/masc', '/workspace', 8945)
        self.assertEqual([row.key for row in confirmed], ['automation'])
        title, labels = picker.call_args.args[:2]
        self.assertTrue(title.startswith('5 ·'))
        self.assertEqual(len(labels), 5)
        # Only the recommended rows start marked: the automation lane, the
        # GitHub login and the web search check. The two Firefox routes are a
        # thing to choose.
        recommended = [i for i, label in enumerate(labels)
                       if any(word in label for word in ('geckodriver and Firefox found', 'GitHub', 'Web search'))]
        self.assertEqual(len(recommended), 3)
        self.assertEqual(picker.call_args.kwargs, dict(multiple=True, defaults=recommended, allow_empty=True))
        self.assertEqual(run.call_args_list[-2].args[0], SETUP_ARGV)

    def test_unmarking_every_row_confirms_nothing_and_runs_nothing(self):
        with patch.object(SETUP.subprocess, 'run', side_effect=self.catalogs('geckodriver', 'firefox')) as run, \
                patch.object(SETUP, 'pick', return_value=[]), \
                contextlib.redirect_stderr(io.StringIO()):
            self.assertEqual(SETUP.select_imp_tools('/bin/masc', '/workspace'), ())
        self.assertEqual([call.args[0][1] for call in run.call_args_list], ['prerequisite-actions'] * 2)

    def test_only_the_marked_rows_are_confirmed_and_the_github_one_waits_for_imp(self):
        # The GitHub login needs imp, which `masc setup` has not created yet:
        # confirming it runs nothing here.
        with patch.object(SETUP.subprocess, 'run', side_effect=self.catalogs('geckodriver', 'firefox')) as run, \
                patch.object(SETUP, 'pick', return_value=[3]), \
                contextlib.redirect_stderr(io.StringIO()):
            confirmed = SETUP.select_imp_tools('/bin/masc', '/workspace')
        self.assertEqual([row.key for row in confirmed], ['github'])
        self.assertEqual([call.args[0][1] for call in run.call_args_list], ['prerequisite-actions'] * 2)

    # The web search row. Found by what its label says: where it stands in the
    # list is the screen's business, and these cases are about what it does.
    WEB_SEARCH_ARGV = ['/bin/masc', 'web-search-setup', '--base-path', '/workspace']

    @staticmethod
    def marking(*words):
        """A `pick` that marks the rows whose label has any of [words]."""
        return lambda title, labels, **kw: [i for i, label in enumerate(labels) if any(w in label for w in words)]

    def test_the_web_search_row_starts_marked_and_names_a_command_that_writes_nothing(self):
        with patch.object(SETUP.subprocess, 'run', side_effect=self.catalogs('geckodriver', 'firefox')):
            rows = {row.key: row for row in SETUP.imp_tool_rows('/bin/masc', '/work space')}
        row = rows['web-search']
        self.assertTrue(row.checked)
        self.assertEqual(row.command, "masc web-search-setup --base-path '/work space'")
        # No option that writes: only --base-path, so the command stays a look.
        self.assertNotIn('--searxng-url', row.command)
        self.assertNotIn('--provider', row.command)
        # Early in the label: a narrow picker cuts the end of a line, and a row
        # that starts marked must not read as one that writes.
        self.assertIn('writes nothing', row.label[:40])

    def test_a_marked_web_search_row_runs_the_command_with_only_the_base_path(self):
        replies = self.catalogs('geckodriver', 'firefox') + [completed()]
        with patch.object(SETUP.subprocess, 'run', side_effect=replies) as run, \
                patch.object(SETUP, 'pick', side_effect=self.marking('Web search')), \
                contextlib.redirect_stderr(io.StringIO()):
            confirmed = SETUP.select_imp_tools('/bin/masc', '/workspace')
        self.assertEqual([row.key for row in confirmed], ['web-search'])
        self.assertEqual(run.call_args_list[-1].args[0], self.WEB_SEARCH_ARGV)

    def test_a_check_that_succeeds_says_nothing_more_and_shows_the_commands_output(self):
        buffer = io.StringIO()
        with patch.object(SETUP.subprocess, 'run', return_value=completed()) as run, \
                contextlib.redirect_stderr(buffer):
            SETUP.check_web_search('/bin/masc', '/workspace')
        self.assertEqual(buffer.getvalue(), '')
        # The command's table goes where the wizard's own lines go.
        self.assertIs(run.call_args.kwargs['stdout'], buffer)

    def test_the_check_is_run_in_the_environment_the_server_will_have(self):
        # `masc setup` gives the server it starts the workspace's own
        # MASC_BASE_PATH and MASC_CONFIG_DIR. The command resolves its file from
        # those two before the --base-path, so left in, they would make the
        # check read another runtime.toml than the server does. Keys stay.
        environment = {'PATH': '/usr/bin', 'MASC_BASE_PATH': '/elsewhere', 'MASC_CONFIG_DIR': '/elsewhere/config',
                       'TAVILY_API_KEY': 'tvly-fixture'}
        with patch.dict(os.environ, environment, clear=True), \
                patch.object(SETUP.subprocess, 'run', return_value=completed()) as run, \
                contextlib.redirect_stderr(io.StringIO()):
            SETUP.check_web_search('/bin/masc', '/workspace')
        given = run.call_args.kwargs['env']
        self.assertNotIn('MASC_BASE_PATH', given)
        self.assertNotIn('MASC_CONFIG_DIR', given)
        self.assertEqual((given['PATH'], given['TAVILY_API_KEY']), ('/usr/bin', 'tvly-fixture'))

    def test_an_unmarked_web_search_row_runs_nothing(self):
        # Only the GitHub row is marked, which waits for imp: nothing runs here.
        github_only = lambda title, labels, **kw: [i for i, label in enumerate(labels) if 'GitHub' in label]
        with patch.object(SETUP.subprocess, 'run', side_effect=self.catalogs('geckodriver', 'firefox')) as run, \
                patch.object(SETUP, 'pick', side_effect=github_only), \
                contextlib.redirect_stderr(io.StringIO()):
            confirmed = SETUP.select_imp_tools('/bin/masc', '/workspace')
        self.assertEqual([row.key for row in confirmed], ['github'])
        self.assertNotIn('web-search-setup', [call.args[0][1] for call in run.call_args_list])

    def test_a_refused_web_search_check_does_not_end_setup_and_says_how_to_look_again(self):
        replies = self.catalogs('geckodriver', 'firefox') + [completed('', 1)]
        with patch.object(SETUP.subprocess, 'run', side_effect=replies), \
                patch.object(SETUP, 'pick', side_effect=self.marking('Web search')), \
                contextlib.redirect_stderr(io.StringIO()) as printed:
            confirmed = SETUP.select_imp_tools('/bin/masc', '/workspace')
        self.assertEqual([row.key for row in confirmed], ['web-search'])
        self.assertIn('Web search was not checked. Run masc web-search-setup --base-path /workspace to look again.',
                      printed.getvalue())

    def test_a_binary_that_cannot_start_the_check_does_not_end_setup(self):
        replies = self.catalogs('geckodriver', 'firefox') + [OSError('exec format error')]
        with patch.object(SETUP.subprocess, 'run', side_effect=replies), \
                patch.object(SETUP, 'pick', side_effect=self.marking('Web search')), \
                contextlib.redirect_stderr(io.StringIO()) as printed:
            confirmed = SETUP.select_imp_tools('/bin/masc', '/workspace')
        self.assertEqual([row.key for row in confirmed], ['web-search'])
        self.assertIn('exec format error', printed.getvalue())
        self.assertIn('Web search was not checked', printed.getvalue())

    def test_the_web_search_row_does_not_hold_back_the_browser_rows(self):
        # Confirmed together, the check runs and then the browser command does:
        # the check is a look and cannot take the write down with it.
        replies = self.catalogs('geckodriver', 'firefox') + [completed('', 1)] + self.catalogs('geckodriver', 'firefox') \
            + [completed()]
        with patch.object(SETUP.subprocess, 'run', side_effect=replies) as run, \
                patch.object(SETUP, 'pick', side_effect=self.marking('geckodriver and Firefox found', 'Web search')), \
                contextlib.redirect_stderr(io.StringIO()):
            confirmed = SETUP.select_imp_tools('/bin/masc', '/workspace')
        self.assertEqual([row.key for row in confirmed], ['automation', 'web-search'])
        self.assertEqual(run.call_args_list[-1].args[0], SETUP_ARGV)

    def test_the_quick_setup_lists_the_web_search_row_marked_and_runs_nothing_of_it(self):
        with patch.object(SETUP.subprocess, 'run', side_effect=self.catalogs('geckodriver', 'firefox')) as run, \
                contextlib.redirect_stderr(io.StringIO()) as printed:
            SETUP.show_imp_tools('/bin/masc', '/workspace')
        self.assertRegex(printed.getvalue(), r'\[x\] Web search')
        self.assertIn('masc web-search-setup --base-path /workspace', printed.getvalue())
        self.assertNotIn('web-search-setup', [call.args[0][1] for call in run.call_args_list])

    def test_a_cancelled_checklist_names_the_web_search_command_for_later(self):
        with patch.object(SETUP.subprocess, 'run', side_effect=self.catalogs('geckodriver', 'firefox')) as run, \
                patch.object(SETUP, 'pick', side_effect=SETUP.SetupError('setup cancelled')), \
                contextlib.redirect_stderr(io.StringIO()) as printed:
            SETUP.select_imp_tools('/bin/masc', '/workspace')
        self.assertIn('masc web-search-setup --base-path /workspace', printed.getvalue())
        self.assertNotIn('web-search-setup', [call.args[0][1] for call in run.call_args_list])

    def test_a_cancel_continues_without_the_tools(self):
        with patch.object(SETUP.subprocess, 'run', side_effect=self.catalogs('geckodriver', 'firefox')) as run, \
                patch.object(SETUP, 'pick', side_effect=SETUP.SetupError('setup cancelled')), \
                contextlib.redirect_stderr(io.StringIO()) as printed:
            self.assertEqual(SETUP.select_imp_tools('/bin/masc', '/workspace'), ())
        self.assertIn('Continuing without them', printed.getvalue())
        self.assertIn('masc keeper-github login --keeper imp', printed.getvalue())
        self.assertNotIn('browser-lane-setup', [call.args[0][1] for call in run.call_args_list])

    def test_a_browser_step_that_raises_keeps_the_github_login_the_reader_confirmed(self):
        # Ctrl-C in the install menu raises a SetupError. The GitHub row was
        # marked and is still the reader's answer.
        replies = self.catalogs('geckodriver', 'firefox') + [completed(browser_catalog('geckodriver', ready=False))]
        with patch.object(SETUP.subprocess, 'run', side_effect=replies), \
                patch.object(SETUP, 'pick', return_value=[0, 3]), \
                patch.object(SETUP, 'prerequisite_menu', side_effect=SETUP.SetupError('setup cancelled')), \
                contextlib.redirect_stderr(io.StringIO()) as printed:
            confirmed = SETUP.select_imp_tools('/bin/masc', '/workspace')
        self.assertEqual([row.key for row in confirmed], ['automation', 'github'])
        self.assertIn("imp's browser was not set up", printed.getvalue())

    def test_the_command_is_not_told_which_geckodriver_to_use(self):
        # Named, the path replaces a geckodriver the operator already wrote in
        # runtime.toml; left to the command, it keeps that value and finds the
        # same program the catalog did (both take the first one on PATH).
        with patch.object(SETUP.subprocess, 'run',
                          side_effect=self.catalogs('geckodriver', 'firefox') + [completed()]) as run, \
                contextlib.redirect_stderr(io.StringIO()):
            SETUP.prepare_browser_lane('/bin/masc', '/workspace', ('automation',))
        self.assertEqual(run.call_args_list[-1].args[0], SETUP_ARGV)
        self.assertNotIn('--geckodriver', run.call_args_list[-1].args[0])

    def test_a_missing_program_is_installed_through_the_menu_and_checked_again(self):
        replies = [completed(browser_catalog('geckodriver', ready=False)), completed(browser_catalog('geckodriver')),
                   completed(browser_catalog('firefox')), completed()]
        with patch.object(SETUP.subprocess, 'run', side_effect=replies) as run, \
                patch.object(SETUP, 'prerequisite_menu', return_value=True) as menu, \
                contextlib.redirect_stderr(io.StringIO()) as printed:
            SETUP.prepare_browser_lane('/bin/masc', '/workspace', ('automation',))
        menu.assert_called_once_with('/bin/masc', 'geckodriver', base_path='/workspace')
        self.assertIn('geckodriver was not found', printed.getvalue())
        self.assertEqual(run.call_args_list[-1].args[0], SETUP_ARGV)

    def test_leaving_the_install_menu_writes_nothing_and_says_what_to_run(self):
        replies = [completed(browser_catalog('geckodriver', ready=False))]
        with patch.object(SETUP.subprocess, 'run', side_effect=replies) as run, \
                patch.object(SETUP, 'prerequisite_menu', return_value=False), \
                contextlib.redirect_stderr(io.StringIO()) as printed:
            SETUP.prepare_browser_lane('/bin/masc', '/workspace', ('automation',))
        self.assertEqual(len(run.call_args_list), 1)
        self.assertIn('Run masc browser-lane-setup --mode automation --base-path /workspace', printed.getvalue())

    def test_a_refused_write_does_not_end_setup_and_asks_nothing_about_the_server(self):
        with patch.object(SETUP.subprocess, 'run',
                          side_effect=self.catalogs('geckodriver', 'firefox') + [completed('', 1)]) as run, \
                contextlib.redirect_stderr(io.StringIO()) as printed:
            SETUP.prepare_browser_lane('/bin/masc', '/workspace', ('automation',), 8945)
        self.assertIn("imp's browser was not saved", printed.getvalue())
        self.assertNotIn('setup-server', [call.args[0][1] for call in run.call_args_list])

    def note(self, reply):
        with patch.object(SETUP.subprocess, 'run', side_effect=[reply]) as run, \
                contextlib.redirect_stderr(io.StringIO()) as printed:
            SETUP.note_running_server('/bin/masc', '/workspace', 8945)
        return run, printed.getvalue()

    def test_a_server_that_is_already_running_keeps_the_old_setting_and_the_reader_is_told(self):
        # `masc setup` starts a server only when none answers, and a server
        # reads the browser table when it starts.
        run, printed = self.note(completed(json.dumps(dict(status='same_workspace'))))
        self.assertEqual(run.call_args.args[0], ['/bin/masc', 'setup-server', '--base-path', '/workspace', '--port', '8945'])
        self.assertIn('A workspace server is already running. It reads the browser setting only when it starts', printed)
        self.assertIn('restart it', printed)
        self.assertEqual(run.call_args.kwargs['timeout'], SETUP.SETUP_SERVER_PROBE_TIMEOUT_SECONDS)

    def test_no_running_server_of_this_workspace_means_no_note(self):
        # Another workspace's server, or a stranger on the port, is not the
        # server `masc setup` would reuse.
        for status in ('free', 'other_workspace', 'unknown_server'):
            with self.subTest(status=status):
                self.assertEqual(self.note(completed(json.dumps(dict(status=status))))[1], '')

    def test_an_observation_that_cannot_be_read_gives_the_note_in_its_conditional_form(self):
        # It does not know there is no server, so it does not say there is none.
        replies = [completed('', 1), completed('{}'), completed('null'), completed('[]'),
                   completed(json.dumps(dict(status='surprise'))),
                   completed(json.dumps(dict(schema='masc.setup_server_error.v1', error='x')), 1),
                   SETUP.subprocess.TimeoutExpired('masc', 20), FileNotFoundError('masc')]
        for reply in replies:
            with self.subTest(reply=repr(reply)[:40]):
                printed = self.note(reply)[1]
                self.assertIn('If a workspace server is already running, it reads the browser setting', printed)
                self.assertNotIn('A workspace server is already running.', printed)

    def test_the_note_follows_a_successful_write(self):
        replies = self.catalogs('geckodriver', 'firefox') + [completed(), completed(json.dumps(dict(status='same_workspace')))]
        with patch.object(SETUP.subprocess, 'run', side_effect=replies), \
                contextlib.redirect_stderr(io.StringIO()) as printed:
            SETUP.prepare_browser_lane('/bin/masc', '/workspace', ('automation',), 8945)
        self.assertIn('already running', printed.getvalue())

    def test_a_quick_setup_lists_the_rows_and_runs_nothing(self):
        replies = [completed(browser_catalog('geckodriver', ready=False)), completed(browser_catalog('firefox'))]
        with patch.object(SETUP.subprocess, 'run', side_effect=replies) as run, \
                patch.object(SETUP, 'pick') as picker, \
                contextlib.redirect_stderr(io.StringIO()) as printed:
            SETUP.show_imp_tools('/bin/masc', '/workspace')
        picker.assert_not_called()
        self.assertEqual([call.args[0][1:3] for call in run.call_args_list],
                         [['prerequisite-actions', 'geckodriver'], ['prerequisite-actions', 'firefox']])
        self.assertNotIn('--execute', [word for call in run.call_args_list for word in call.args[0]])
        self.assertIn("5 · imp's tools", printed.getvalue())
        self.assertIn('brew install geckodriver && masc browser-lane-setup --mode automation', printed.getvalue())
        self.assertIn('masc keeper-github login --keeper imp', printed.getvalue())

    def test_a_quick_setup_that_cannot_look_at_the_browser_says_so_and_still_lists_github(self):
        # One look per program: geckodriver, then Firefox.
        with patch.object(SETUP.subprocess, 'run', side_effect=[completed('', 1), completed('', 1)]), \
                contextlib.redirect_stderr(io.StringIO()) as printed:
            SETUP.show_imp_tools('/bin/masc', '/workspace')
        self.assertIn('Run masc browser-lane-setup --mode automation', printed.getvalue())
        self.assertIn('geckodriver: ', printed.getvalue())
        self.assertIn('masc keeper-github login --keeper imp', printed.getvalue())


def searxng_readiness(docker=True, container='absent', endpoint='unreachable', url='http://127.0.0.1:8888', **extra):
    """What `masc prerequisite-actions searxng` prints under dependency_readiness."""
    value = dict(schema='masc.searxng_readiness.v1', status='ready' if endpoint == 'answers' else 'unavailable',
                 docker='ready' if docker else 'unavailable', container=container, docker_status=None,
                 endpoint=endpoint, url=url)
    value.update(extra)
    return value


# A stopped container is started, an absent one is made; every other state has no action.
SEARXNG_ACTIONS = dict(absent='searxng_docker_run', stopped='searxng_docker_start_existing')


def searxng_catalog(**state):
    """The catalog: the one action that fits the container, none when it is running."""
    readiness = searxng_readiness(**state)
    action_id = SEARXNG_ACTIONS.get(readiness['container'])
    # What the binary prints: the run effect names its settings file, the start
    # of a stopped container writes nothing and names none.
    if action_id == 'searxng_docker_run':
        effect = dict(kind='run_searxng', settings_file='/workspace/.masc/searxng/settings.yml',
                      argv_steps=[['docker', 'pull', 'fixture'], ['docker', 'run', 'fixture']])
        writes = '/workspace/.masc/searxng/settings.yml'
    else:
        effect = dict(kind='start_existing_searxng', argv_steps=[['docker', 'start', 'masc-searxng']])
        writes = None
    actions = [] if action_id is None else [dict(
        id=action_id, label='Run SearXNG in a Docker container', detail='Starts a container.',
        source_url='https://docs.searxng.org/admin/installation-docker.html', requires_admin=False,
        effect=effect, completion='recheck_required', writes=writes)]
    return json.dumps(dict(schema='masc.prerequisite_actions.v1', actions=actions, dependency_readiness=readiness))


def searxng_receipt(status, **state):
    readiness = searxng_readiness(**state)
    return json.dumps(dict(schema='masc.prerequisite_action_result.v1', status=status,
                           readiness='tools_available' if readiness['endpoint'] == 'answers' else 'unavailable',
                           dependency_readiness=readiness))


class SearxngReadinessDecoding(unittest.TestCase):
    """A readiness the wizard reads is one it can act on, so every field is checked."""

    def test_an_answering_instance_is_available_and_carries_its_address(self):
        value = SETUP.decode_searxng_readiness(searxng_readiness(container='running', endpoint='answers'))
        self.assertTrue(value.available)
        self.assertEqual((value.docker, value.container, value.url), (True, 'running', 'http://127.0.0.1:8888'))

    def test_every_container_word_the_binary_can_say_is_read(self):
        for container in ('absent', 'stopped', 'running', 'paused', 'restarting', 'unusable'):
            with self.subTest(container=container):
                extra = dict(docker_status='dead') if container == 'unusable' else {}
                value = SETUP.decode_searxng_readiness(searxng_readiness(container=container, **extra))
                self.assertEqual(value.container, container)

    def test_dockers_own_word_for_an_unusable_container_is_kept(self):
        value = SETUP.decode_searxng_readiness(searxng_readiness(container='unusable', docker_status='dead'))
        self.assertEqual(value.docker_status, 'dead')
        with self.assertRaises(SETUP.SetupError):
            SETUP.decode_searxng_readiness(searxng_readiness(container='unusable', docker_status=7))

    def test_a_running_container_that_does_not_answer_is_not_available(self):
        for endpoint in ('refuses_json', 'unreachable'):
            with self.subTest(endpoint=endpoint):
                value = SETUP.decode_searxng_readiness(searxng_readiness(container='running', endpoint=endpoint))
                self.assertFalse(value.available)

    def test_every_field_that_drifted_is_refused(self):
        drifted = dict(schema='masc.searxng_readiness.v2', status='maybe', docker='unknown', container='sleeping',
                       endpoint='slow', url='127.0.0.1:8888')
        for field, value in drifted.items():
            with self.subTest(field=field):
                with self.assertRaises(SETUP.SetupError):
                    SETUP.decode_searxng_readiness(dict(searxng_readiness(), **{field: value}))
        for field in ('schema', 'status', 'docker', 'container', 'endpoint', 'url'):
            with self.subTest(missing=field):
                broken = searxng_readiness()
                del broken[field]
                with self.assertRaises(SETUP.SetupError):
                    SETUP.decode_searxng_readiness(broken)
        for value in (None, [], 'ready'):
            with self.subTest(value=value), self.assertRaises(SETUP.SetupError):
                SETUP.decode_searxng_readiness(value)

    def test_a_readiness_the_binary_never_prints_is_refused(self):
        # Fields that each read fine and cannot be true together. The binary
        # asks Docker about the container only when Docker answers, and keeps
        # Docker's own word only for an unusable container.
        for what, value in (
                ('a container beside a Docker that is down', searxng_readiness(docker=False, container='running')),
                ('an unusable container without Docker\'s word', searxng_readiness(container='unusable')),
                ('Docker\'s word on a running container', searxng_readiness(container='running', docker_status='dead')),
                ('an empty word for an unusable container', searxng_readiness(container='unusable', docker_status=''))):
            with self.subTest(what=what), self.assertRaises(SETUP.SetupError):
                SETUP.decode_searxng_readiness(value)

    def test_an_address_that_could_move_the_cursor_or_split_a_command_is_refused(self):
        for url in ('http://127.0.0.1:8888/\x1b[31m', 'http://127.0.0.1:8888 && rm', 'http://', 'ftp://127.0.0.1',
                    'http://127.0.0.1:8888\n'):
            with self.subTest(url=url), self.assertRaises(SETUP.SetupError):
                SETUP.decode_searxng_readiness(searxng_readiness(url=url))

    def test_a_status_that_disagrees_with_the_endpoint_is_refused(self):
        # `ready` is the one word a caller may act on, so it is not taken
        # without the answer that justifies it.
        with self.assertRaises(SETUP.SetupError):
            SETUP.decode_searxng_readiness(searxng_readiness(endpoint='unreachable', status='ready'))
        with self.assertRaises(SETUP.SetupError):
            SETUP.decode_searxng_readiness(searxng_readiness(endpoint='answers', status='unavailable'))


class SearchChoices(unittest.TestCase):
    """The z.ai and SearXNG rows: a choice of where web search goes, unmarked.

    The key-free check stays the marked row. These two are the reader's to
    choose, and each runs the one command that writes what it names.
    """

    ARGV_ZAI = ['/bin/masc', 'web-search-setup', '--provider', 'zai', '--base-path', '/workspace']
    ARGV_URL = ['/bin/masc', 'web-search-setup', '--searxng-url', 'http://127.0.0.1:8888', '--base-path', '/workspace']
    ARGV_START = ['/bin/masc', 'prerequisite-actions', 'searxng', '--execute', 'searxng_docker_run',
                  '--base-path', '/workspace']
    ARGV_LOOK = ['/bin/masc', 'prerequisite-actions', 'searxng', '--base-path', '/workspace']
    KEY = 'zai-fixture-key-0000000000000000'

    def setUp(self):
        login = patch.object(SETUP, 'host_github_login', return_value=None)
        login.start()
        self.addCleanup(login.stop)
        for name, value in (('browser_rows', []), ('ego_row', None)):
            browser = patch.object(SETUP, name, return_value=value)
            browser.start()
            self.addCleanup(browser.stop)
        # The wizard's own environment: no key unless a case sets one.
        self.environment = patch.dict(os.environ, {}, clear=False)
        self.environment.start()
        self.addCleanup(self.environment.stop)
        os.environ.pop(SETUP.ZAI_KEY_VARIABLE, None)

    @staticmethod
    def marking(*words):
        return lambda title, labels, **kw: [i for i, label in enumerate(labels) if any(w in label for w in words)]

    def rows(self, *replies):
        with patch.object(SETUP.subprocess, 'run', side_effect=list(replies)), \
                contextlib.redirect_stderr(io.StringIO()) as printed:
            return {row.key: row for row in SETUP.imp_tool_rows('/bin/masc', '/workspace')}, printed.getvalue()

    # The z.ai row.

    def test_no_key_means_no_z_ai_row(self):
        for value in (None, '', '   '):
            with self.subTest(value=value):
                if value is None:
                    os.environ.pop(SETUP.ZAI_KEY_VARIABLE, None)
                else:
                    os.environ[SETUP.ZAI_KEY_VARIABLE] = value
                rows, _ = self.rows(completed(searxng_catalog(docker=False)))
                self.assertNotIn('zai', rows)

    def test_a_key_in_the_environment_offers_the_row_unmarked_and_never_carries_the_key(self):
        os.environ[SETUP.ZAI_KEY_VARIABLE] = self.KEY
        rows, _ = self.rows(completed(searxng_catalog(docker=False)))
        row = rows['zai']
        self.assertFalse(row.checked)
        self.assertEqual(row.command, "masc web-search-setup --provider zai --base-path /workspace")
        self.assertIn('GLM Coding Plan', row.label)
        for sentence in ('search allowance', 'tried first'):
            self.assertIn(sentence, row.label + row.notice)
        self.assertNotIn(self.KEY, row.label + row.notice + row.command)

    def test_the_z_ai_row_is_run_with_the_provider_option_and_nothing_else(self):
        os.environ[SETUP.ZAI_KEY_VARIABLE] = self.KEY
        replies = [completed(searxng_catalog(docker=False)), completed()]
        with patch.object(SETUP.subprocess, 'run', side_effect=replies) as run, \
                patch.object(SETUP, 'pick', side_effect=self.marking('z.ai')), \
                contextlib.redirect_stderr(io.StringIO()):
            confirmed = SETUP.select_imp_tools('/bin/masc', '/workspace')
        self.assertEqual([row.key for row in confirmed], ['zai'])
        self.assertEqual(run.call_args_list[-1].args[0], self.ARGV_ZAI)
        # The key reaches the command only as the environment variable it
        # already is, never as an argument that `ps` would show.
        self.assertNotIn(self.KEY, ' '.join(run.call_args_list[-1].args[0]))

    def test_an_unmarked_z_ai_row_runs_nothing(self):
        os.environ[SETUP.ZAI_KEY_VARIABLE] = self.KEY
        with patch.object(SETUP.subprocess, 'run', side_effect=[completed(searxng_catalog(docker=False))]) as run, \
                patch.object(SETUP, 'pick', return_value=[]), contextlib.redirect_stderr(io.StringIO()):
            self.assertEqual(SETUP.select_imp_tools('/bin/masc', '/workspace'), ())
        self.assertEqual(len(run.call_args_list), 1)

    def test_a_refused_choice_does_not_end_setup_and_names_the_command(self):
        os.environ[SETUP.ZAI_KEY_VARIABLE] = self.KEY
        replies = [completed(searxng_catalog(docker=False)), completed('', 1)]
        with patch.object(SETUP.subprocess, 'run', side_effect=replies), \
                patch.object(SETUP, 'pick', side_effect=self.marking('z.ai')), \
                contextlib.redirect_stderr(io.StringIO()) as printed:
            confirmed = SETUP.select_imp_tools('/bin/masc', '/workspace')
        self.assertEqual([row.key for row in confirmed], ['zai'])
        self.assertIn('z.ai was not chosen', printed.getvalue())
        self.assertIn('masc web-search-setup --provider zai --base-path /workspace', printed.getvalue())

    def test_the_writing_commands_run_in_the_environment_the_server_will_have(self):
        # The same reason as the check's: `masc web-search-setup` resolves
        # runtime.toml from MASC_CONFIG_DIR ahead of --base-path, so a shell
        # that exports it would send the choice to another workspace's file.
        environment = {'PATH': '/usr/bin', 'MASC_BASE_PATH': '/elsewhere', 'MASC_CONFIG_DIR': '/elsewhere/config',
                       SETUP.ZAI_KEY_VARIABLE: self.KEY}
        with patch.dict(os.environ, environment, clear=True), \
                patch.object(SETUP.subprocess, 'run', return_value=completed()) as run, \
                contextlib.redirect_stderr(io.StringIO()):
            self.assertTrue(SETUP.run_web_search_setup('/bin/masc', '/workspace', ['--provider', 'zai']))
        given = run.call_args.kwargs['env']
        self.assertNotIn('MASC_BASE_PATH', given)
        self.assertNotIn('MASC_CONFIG_DIR', given)
        # The key stays: it is what the command reports as found.
        self.assertEqual(given[SETUP.ZAI_KEY_VARIABLE], self.KEY)

    def test_a_command_that_cannot_start_is_a_refusal_and_not_a_crash(self):
        with patch.object(SETUP.subprocess, 'run', side_effect=OSError('no such file')), \
                contextlib.redirect_stderr(io.StringIO()):
            self.assertFalse(SETUP.run_web_search_setup('/bin/masc', '/workspace', ['--provider', 'zai']))

    # The SearXNG row.

    def test_docker_without_an_instance_offers_the_start_and_the_address_as_one_unmarked_row(self):
        rows, _ = self.rows(completed(searxng_catalog(docker=True, container='absent')))
        row = rows['searxng']
        self.assertFalse(row.checked)
        self.assertIn('pulls an image', row.label)
        self.assertEqual(row.command,
                         'masc prerequisite-actions searxng --execute searxng_docker_run --base-path /workspace'
                         ' && masc web-search-setup --searxng-url http://127.0.0.1:8888 --base-path /workspace')
        # What a reader needs before ticking it: no key, refusals, and the order it takes.
        for sentence in ('needs no key', 'can refuse', 'web_search.searxng_url', 'tried before the providers that need a key',
                         'web_search.provider'):
            self.assertIn(sentence, row.notice)

    def test_a_stopped_container_is_started_and_does_not_pull(self):
        rows, _ = self.rows(completed(searxng_catalog(docker=True, container='stopped')))
        row = rows['searxng']
        self.assertIn('--execute searxng_docker_start_existing', row.command)
        self.assertNotIn('pulls an image', row.label)
        self.assertIn('starts the stopped masc-searxng container', row.label)

    def test_an_instance_that_already_answers_is_only_named_and_pulls_nothing(self):
        rows, _ = self.rows(completed(searxng_catalog(docker=True, container='running', endpoint='answers')))
        row = rows['searxng']
        self.assertFalse(row.checked)
        self.assertIn('already answers', row.label)
        self.assertEqual(row.command, "masc web-search-setup --searxng-url http://127.0.0.1:8888 --base-path /workspace")
        self.assertNotIn('prerequisite-actions', row.command)

    def test_an_answer_works_without_docker_because_the_reader_may_run_it_otherwise(self):
        rows, _ = self.rows(completed(searxng_catalog(docker=False, container='absent', endpoint='answers')))
        self.assertIn('searxng', rows)

    def test_docker_that_is_not_ready_leaves_no_row_and_says_nothing(self):
        rows, printed = self.rows(completed(searxng_catalog(docker=False)))
        self.assertNotIn('searxng', rows)
        self.assertEqual(printed, '')

    def test_a_running_container_that_refuses_json_leaves_no_row_and_names_its_logs(self):
        rows, printed = self.rows(completed(searxng_catalog(docker=True, container='running', endpoint='refuses_json')))
        self.assertNotIn('searxng', rows)
        self.assertIn('docker logs masc-searxng', printed)

    def test_a_container_in_a_state_that_cannot_be_started_leaves_no_row_and_says_what_to_do(self):
        # None of these has an action in the catalog, so the reader is told
        # what is wrong and which Docker command looks at it.
        cases = (('paused', {}, 'docker unpause masc-searxng'),
                 ('restarting', {}, 'docker logs masc-searxng'),
                 ('unusable', dict(docker_status='dead'), 'docker inspect masc-searxng'))
        for container, extra, advice in cases:
            with self.subTest(container=container):
                rows, printed = self.rows(completed(searxng_catalog(docker=True, container=container, **extra)))
                self.assertNotIn('searxng', rows)
                self.assertIn(advice, printed)
        _, printed = self.rows(completed(searxng_catalog(docker=True, container='unusable', docker_status='dead')))
        self.assertIn('(dead)', printed)

    def test_an_unreadable_catalog_leaves_the_other_rows_and_names_the_command_to_look_again(self):
        rows, printed = self.rows(completed('not json'))
        self.assertEqual(list(rows), ['github', 'web-search'])
        self.assertIn('masc prerequisite-actions searxng', printed)

    def test_a_binary_that_cannot_run_leaves_the_other_rows(self):
        with patch.object(SETUP.subprocess, 'run', side_effect=OSError('no such file')), \
                contextlib.redirect_stderr(io.StringIO()):
            rows = {row.key for row in SETUP.imp_tool_rows('/bin/masc', '/workspace')}
        self.assertEqual(rows, {'github', 'web-search'})

    def test_the_rows_follow_the_checked_ones_in_a_fixed_order(self):
        os.environ[SETUP.ZAI_KEY_VARIABLE] = self.KEY
        rows, _ = self.rows(completed(searxng_catalog(docker=True, container='absent')))
        self.assertEqual(list(rows), ['github', 'web-search', 'zai', 'searxng'])
        self.assertEqual([row.checked for row in rows.values()], [True, True, False, False])

    # Running the SearXNG row.

    def run_marked(self, replies, *words):
        with patch.object(SETUP.subprocess, 'run', side_effect=replies) as run, \
                patch.object(SETUP, 'pick', side_effect=self.marking(*words)), \
                contextlib.redirect_stderr(io.StringIO()) as printed:
            confirmed = SETUP.select_imp_tools('/bin/masc', '/workspace')
        return confirmed, [call.args[0] for call in run.call_args_list], printed.getvalue()

    def test_a_started_instance_gets_its_address_written_after_the_start(self):
        absent = completed(searxng_catalog(docker=True, container='absent'))
        replies = [absent, absent, completed(searxng_receipt('commands_completed', container='running',
                                                             endpoint='answers')), completed()]
        confirmed, argvs, printed = self.run_marked(replies, 'SearXNG in Docker')
        self.assertEqual([row.key for row in confirmed], ['searxng'])
        # Row lookup, the fresh look before the start, the start, the address.
        self.assertEqual(argvs, [self.ARGV_LOOK, self.ARGV_LOOK, self.ARGV_START, self.ARGV_URL])
        self.assertIn('answers JSON searches at http://127.0.0.1:8888', printed)

    def test_the_address_is_not_written_when_the_start_failed(self):
        absent = completed(searxng_catalog(docker=True, container='absent'))
        failed = dict(schema='masc.prerequisite_action_result.v1', status='failed', readiness='unavailable',
                      reason='docker exited 125', dependency_readiness=searxng_readiness())
        replies = [absent, absent, completed(json.dumps(failed), 1)]
        _, argvs, printed = self.run_marked(replies, 'SearXNG in Docker')
        self.assertEqual(argvs, [self.ARGV_LOOK, self.ARGV_LOOK, self.ARGV_START])
        self.assertIn('docker exited 125', printed)
        # The container may exist now, so the action it was built with may not
        # be offered any more: the retry names where to look, not that id.
        self.assertIn('SearXNG did not come up', printed)
        self.assertIn('masc prerequisite-actions searxng --base-path /workspace', printed)
        self.assertIn('docker logs masc-searxng', printed)
        self.assertNotIn('--execute', printed)

    def test_a_start_that_says_completed_but_does_not_answer_is_not_written(self):
        # A receipt that claims a finished start while the endpoint is silent
        # is unreadable, not a success: nothing is saved on its word.
        absent = completed(searxng_catalog(docker=True, container='absent'))
        lying = completed(searxng_receipt('commands_completed', container='running', endpoint='unreachable'))
        _, argvs, printed = self.run_marked([absent, absent, lying], 'SearXNG in Docker')
        self.assertNotIn(self.ARGV_URL, argvs)
        self.assertIn('Could not tell whether SearXNG started', printed)

    def test_an_instance_that_started_while_the_reader_chose_is_not_started_again(self):
        absent = completed(searxng_catalog(docker=True, container='absent'))
        answers = completed(searxng_catalog(docker=True, container='running', endpoint='answers'))
        _, argvs, _ = self.run_marked([absent, answers, completed()], 'SearXNG in Docker')
        self.assertEqual(argvs, [self.ARGV_LOOK, self.ARGV_LOOK, self.ARGV_URL])

    def test_an_address_that_could_not_be_saved_is_named_with_its_command(self):
        absent = completed(searxng_catalog(docker=True, container='absent'))
        started = completed(searxng_receipt('commands_completed', container='running', endpoint='answers'))
        _, _, printed = self.run_marked([absent, absent, started, completed('', 1)], 'SearXNG in Docker')
        self.assertIn('its address was not saved', printed)
        self.assertIn('masc web-search-setup --searxng-url http://127.0.0.1:8888 --base-path /workspace', printed)

    def test_nothing_to_start_is_said_and_writes_nothing(self):
        # The row was offered, then Docker stopped before the reader confirmed.
        absent = completed(searxng_catalog(docker=True, container='absent'))
        gone = completed(searxng_catalog(docker=False, container='absent'))
        _, argvs, printed = self.run_marked([absent, gone], 'SearXNG in Docker')
        self.assertEqual(argvs, [self.ARGV_LOOK, self.ARGV_LOOK])
        self.assertIn('SearXNG was not started', printed)

    def test_the_choices_run_before_the_check_so_the_check_shows_their_order(self):
        os.environ[SETUP.ZAI_KEY_VARIABLE] = self.KEY
        absent = completed(searxng_catalog(docker=True, container='absent'))
        started = completed(searxng_receipt('commands_completed', container='running', endpoint='answers'))
        replies = [absent, completed(), absent, started, completed(), completed()]
        _, argvs, _ = self.run_marked(replies, 'z.ai', 'SearXNG in Docker', 'Web search')
        written = [argv[2:] for argv in argvs if argv[1:2] == ['web-search-setup']]
        self.assertEqual(written, [['--provider', 'zai', '--base-path', '/workspace'],
                                   ['--searxng-url', 'http://127.0.0.1:8888', '--base-path', '/workspace'],
                                   ['--base-path', '/workspace']])

    # What a binary that answers in a shape nobody wrote must not do.

    def test_a_catalog_or_receipt_that_is_not_an_object_does_not_end_setup(self):
        for shape in ('[]', 'null', '"text"', '3'):
            with self.subTest(shape=shape):
                with patch.object(SETUP.subprocess, 'run', side_effect=[completed(shape)]), \
                        contextlib.redirect_stderr(io.StringIO()) as printed:
                    rows = {row.key for row in SETUP.imp_tool_rows('/bin/masc', '/workspace')}
                self.assertEqual(rows, {'github', 'web-search'})
                absent = completed(searxng_catalog(docker=True, container='absent'))
                with patch.object(SETUP.subprocess, 'run', side_effect=[absent, completed(shape)]), \
                        contextlib.redirect_stderr(io.StringIO()) as printed:
                    SETUP.start_searxng('/bin/masc', '/workspace')
                self.assertIn('Could not tell whether SearXNG started', printed.getvalue())

    def test_an_action_id_with_a_control_character_is_not_offered_or_printed(self):
        broken = json.loads(searxng_catalog(docker=True, container='absent'))
        broken['actions'][0]['id'] = 'searxng_docker_run\x1b[31m'
        rows, printed = self.rows(completed(json.dumps(broken)))
        self.assertNotIn('searxng', rows)
        self.assertNotIn('\x1b', printed)

    # Commands the reader copies: a workspace path with spaces and quotes.

    AWKWARD = "/work space/it's $HOME"

    def test_every_printed_command_survives_a_path_with_spaces_and_quotes(self):
        import shlex
        os.environ[SETUP.ZAI_KEY_VARIABLE] = self.KEY
        with patch.object(SETUP.subprocess, 'run',
                          side_effect=[completed(searxng_catalog(docker=True, container='absent'))]), \
                contextlib.redirect_stderr(io.StringIO()):
            rows = {row.key: row for row in SETUP.imp_tool_rows('/bin/masc', self.AWKWARD)}
        self.assertEqual(shlex.split(rows['zai'].command),
                         ['masc', 'web-search-setup', '--provider', 'zai', '--base-path', self.AWKWARD])
        tokens = shlex.split(rows['searxng'].command)
        self.assertEqual(tokens.count(self.AWKWARD), 2)
        divider = tokens.index('&&')
        self.assertEqual(tokens[divider - 4:divider],
                         ['--execute', 'searxng_docker_run', '--base-path', self.AWKWARD])
        self.assertEqual(tokens[-4:], ['--searxng-url', 'http://127.0.0.1:8888', '--base-path', self.AWKWARD][:2]
                         + ['--base-path', self.AWKWARD])
        self.assertEqual(shlex.split(SETUP.searxng_look_command(self.AWKWARD)),
                         ['masc', 'prerequisite-actions', 'searxng', '--base-path', self.AWKWARD])

    def test_a_workspace_path_with_an_escape_never_reaches_the_screen_raw(self):
        # The path is the reader's own, but it is printed inside commands that
        # shlex.quote makes safe for a shell and not for a terminal.
        base = '/work/\x1b[31mred'
        os.environ[SETUP.ZAI_KEY_VARIABLE] = self.KEY
        absent = completed(searxng_catalog(docker=True, container='absent'))
        failed = dict(schema='masc.prerequisite_action_result.v1', status='failed', readiness='unavailable',
                      reason='docker exited 125', dependency_readiness=searxng_readiness())
        with patch.object(SETUP.subprocess, 'run', side_effect=[absent, completed(json.dumps(failed), 1)]), \
                contextlib.redirect_stderr(io.StringIO()) as printed:
            SETUP.start_searxng('/bin/masc', base)
        with patch.object(SETUP.subprocess, 'run', return_value=completed('', 1)), \
                contextlib.redirect_stderr(io.StringIO()) as chosen:
            SETUP.choose_zai('/bin/masc', base)
        with patch.object(SETUP.subprocess, 'run', side_effect=[absent, completed(searxng_receipt(
                'commands_completed', container='running', endpoint='answers')), completed('', 1)]), \
                contextlib.redirect_stderr(io.StringIO()) as unsaved:
            SETUP.start_searxng('/bin/masc', base)
        for what, text in (('the retry after a start', printed.getvalue()), ('the z.ai retry', chosen.getvalue()),
                           ('the unsaved address', unsaved.getvalue())):
            with self.subTest(what=what):
                self.assertNotIn('\x1b', text)
                self.assertIn('red', text)

    # What the consent text has to say, and where.

    def test_the_cost_of_the_searxng_row_comes_before_the_part_a_narrow_screen_cuts(self):
        rows, _ = self.rows(completed(searxng_catalog(docker=True, container='absent')))
        label = rows['searxng'].label
        self.assertLess(label.index('pulls an image'), 50)
        self.assertLess(label.index('pulls an image'), label.index('key-free'))
        stopped, _ = self.rows(completed(searxng_catalog(docker=True, container='stopped')))
        self.assertLess(stopped['searxng'].label.index('starts the stopped'), 50)

    def test_both_notices_say_what_they_replace_and_that_an_explicit_order_outranks_them(self):
        os.environ[SETUP.ZAI_KEY_VARIABLE] = self.KEY
        rows, _ = self.rows(completed(searxng_catalog(docker=True, container='absent')))
        for key, replaced in (('zai', 'replacing a provider set there'),
                              ('searxng', 'replacing an address set there')):
            with self.subTest(row=key):
                self.assertIn(replaced, rows[key].notice)
                self.assertIn('web_search.provider_order is set it decides the order', rows[key].notice)
        # The cost the reader takes on with the mark, said before the mark.
        self.assertIn('server runs in an environment that sees ZAI_API_KEY', rows['zai'].notice)
        self.assertIn('about 380 MB', rows['searxng'].notice)
        self.assertIn('restarts the container whenever it starts', rows['searxng'].notice)

    def test_a_container_that_cannot_be_started_is_told_how_it_can_be_removed(self):
        _, printed = self.rows(completed(searxng_catalog(docker=True, container='unusable', docker_status='dead')))
        self.assertIn('docker rm -f masc-searxng', printed)

    def test_an_unmarked_searxng_row_starts_nothing_and_writes_nothing(self):
        absent = completed(searxng_catalog(docker=True, container='absent'))
        with patch.object(SETUP.subprocess, 'run', side_effect=[absent]) as run, \
                patch.object(SETUP, 'pick', return_value=[]), contextlib.redirect_stderr(io.StringIO()):
            self.assertEqual(SETUP.select_imp_tools('/bin/masc', '/workspace'), ())
        # Only the look that built the row. A `--execute` or a write would be a second call.
        self.assertEqual([call.args[0] for call in run.call_args_list], [self.ARGV_LOOK])

    # What the receipt of the start has to say before the wizard believes it.

    def receipt(self, body, code=0):
        with patch.object(SETUP.subprocess, 'run', return_value=completed(json.dumps(body), code)):
            return SETUP.execute_prerequisite('/bin/masc', 'searxng', 'searxng_docker_run',
                                              ['--base-path', '/workspace'], '/workspace')

    def test_a_receipt_whose_word_and_detail_disagree_is_unreadable_whatever_its_status(self):
        # A failed receipt carries no claim of success, so only the comparison
        # of the two fields can catch a word that says "available" over an
        # endpoint that did not answer, or the other way round.
        for word, endpoint in (('tools_available', 'unreachable'), ('unavailable', 'answers')):
            with self.subTest(word=word, endpoint=endpoint):
                body = dict(schema='masc.prerequisite_action_result.v1', status='failed', readiness=word,
                            reason='docker exited 1',
                            dependency_readiness=searxng_readiness(container='running', endpoint=endpoint))
                with self.assertRaises(SETUP.SetupError):
                    self.receipt(body, 1)

    def test_a_finished_start_that_was_not_looked_at_again_is_unreadable(self):
        body = dict(schema='masc.prerequisite_action_result.v1', status='commands_completed', readiness='not_checked')
        with self.assertRaises(SETUP.SetupError):
            self.receipt(body)

    def test_a_failed_start_that_was_not_looked_at_again_is_a_failure_with_its_reason(self):
        body = dict(schema='masc.prerequisite_action_result.v1', status='failed', readiness='not_checked',
                    reason='docker exited 125')
        with contextlib.redirect_stderr(io.StringIO()) as printed:
            self.assertEqual(self.receipt(body, 1), 'failed')
        self.assertIn('docker exited 125', printed.getvalue())

    def test_the_address_written_is_the_one_that_was_looked_at(self):
        # The binary reports its fixed address today. The wizard writes what
        # the readiness it read says, so a different one is not replaced by a
        # constant of the wizard's own.
        other = 'http://localhost:9090'
        absent = completed(searxng_catalog(docker=True, container='absent', url=other))
        started = completed(searxng_receipt('commands_completed', container='running', endpoint='answers',
                                            url=other))
        _, argvs, _ = self.run_marked([absent, absent, started, completed()], 'SearXNG in Docker')
        self.assertEqual(argvs[-1], ['/bin/masc', 'web-search-setup', '--searxng-url', other,
                                     '--base-path', '/workspace'])

    # A quick setup lists and runs nothing.

    def test_a_quick_setup_lists_both_unmarked_with_their_commands_and_runs_nothing_of_them(self):
        os.environ[SETUP.ZAI_KEY_VARIABLE] = self.KEY
        with patch.object(SETUP.subprocess, 'run',
                          side_effect=[completed(searxng_catalog(docker=True, container='absent'))]) as run, \
                contextlib.redirect_stderr(io.StringIO()) as printed:
            SETUP.show_imp_tools('/bin/masc', '/workspace')
        text = printed.getvalue()
        self.assertEqual(run.call_args_list[0].args[0], self.ARGV_LOOK)
        self.assertEqual(len(run.call_args_list), 1)
        self.assertRegex(text, r'\[ \] z\.ai web search through your GLM Coding Plan key')
        self.assertRegex(text, r'\[ \] SearXNG in Docker')
        self.assertIn('masc web-search-setup --provider zai --base-path /workspace', text)
        self.assertNotIn(self.KEY, text)


class PickAllowingNothing(unittest.TestCase):
    """`pick` with allow_empty, the real one, in both of its input modes.

    Without the flag a multiple pick answers the row under the cursor when
    nothing is marked. A consent screen cannot use that: the reader who
    unmarked every row has said no.
    """

    def numbered(self, answer, **options):
        with patch.object(sys, 'stdin', io.StringIO(answer)), contextlib.redirect_stderr(io.StringIO()) as printed:
            return SETUP.pick('Title', ['first', 'second'], multiple=True, **options), printed.getvalue()

    def test_numbered_enter_keeps_the_marked_rows_and_shows_the_marks(self):
        chosen, printed = self.numbered('\n', defaults=[0, 1], allow_empty=True)
        self.assertEqual(chosen, [0, 1])
        self.assertIn('[x] first', printed)
        self.assertIn('0 skips all', printed)

    def test_numbered_zero_skips_all(self):
        self.assertEqual(self.numbered('0\n', defaults=[0, 1], allow_empty=True)[0], [])

    def test_numbered_enter_with_nothing_marked_confirms_nothing(self):
        self.assertEqual(self.numbered('\n', allow_empty=True)[0], [])

    def test_numbered_numbers_choose_the_named_rows(self):
        self.assertEqual(self.numbered('2\n', defaults=[0, 1], allow_empty=True)[0], [1])

    def test_without_the_flag_nothing_marked_still_answers_the_first_row_and_shows_no_marks(self):
        chosen, printed = self.numbered('\n')
        self.assertEqual(chosen, [0])
        self.assertNotIn('[x]', printed)
        self.assertNotIn('[ ]', printed)

    def terminal(self, keys, options):
        driver = ("import importlib.util, sys\n"
                  "spec = importlib.util.spec_from_file_location('setup', sys.argv[1])\n"
                  "module = importlib.util.module_from_spec(spec)\n"
                  "spec.loader.exec_module(module)\n"
                  "chosen = module.pick('Title', ['first', 'second'], multiple=True, " + options + ")\n"
                  "print('RESULT', chosen, file=sys.stderr, flush=True)\n")
        pid, fd = pty.fork()
        if pid == 0:
            os.execve(sys.executable, [sys.executable, '-I', '-c', driver, str(ROOT / 'scripts/install-runtime-setup.py')],
                      {'PATH': os.environ.get('PATH', ''), 'TERM': 'xterm', 'HOME': tempfile.gettempdir()})
        captured = b''

        def until(expected):
            nonlocal captured
            deadline = time.monotonic() + 20
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
            until(b'first')
            for key in keys:
                os.write(fd, key)
                time.sleep(0.2)
            until(b'RESULT')
            time.sleep(0.2)
            try:
                captured += os.read(fd, 65536)
            except OSError:
                pass
        finally:
            os.kill(pid, signal.SIGKILL)
            os.waitpid(pid, 0)
            os.close(fd)
        found = re.findall(rb'RESULT (\[[^\]]*\])', captured)
        self.assertEqual(len(found), 1, captured.decode(errors='replace'))
        return found[0].decode()

    SPACE, DOWN, ENTER = b' ', b'\x1b[B', b'\r'

    def test_a_terminal_that_unmarks_every_row_gets_nothing_back(self):
        # The screen says "0 selected" and Enter must agree with it. This is the
        # keystroke sequence an independent review used to confirm a row the
        # reader had unmarked.
        result = self.terminal([self.SPACE, self.DOWN, self.SPACE, self.ENTER], 'defaults=[0, 1], allow_empty=True')
        self.assertEqual(result, '[]')

    def test_a_terminal_that_leaves_the_marks_gets_them_back(self):
        self.assertEqual(self.terminal([self.ENTER], 'defaults=[0, 1], allow_empty=True'), '[0, 1]')

    def test_without_the_flag_a_terminal_that_unmarks_every_row_gets_the_row_under_the_cursor(self):
        # What the flag exists to avoid, kept so the default stays what the
        # connection pickers rely on.
        result = self.terminal([self.SPACE, self.DOWN, self.SPACE, self.ENTER], 'defaults=[0, 1]')
        self.assertEqual(result, '[1]')


class FirefoxRoutes(unittest.TestCase):
    """The BiDi and extension rows: the first request, a browser connected at install time.

    Both start unmarked (RFC section 4.3): BiDi opens a debugging port with no
    authentication and the extension has to be loaded again after every browser
    start. They are shown only when Firefox was found.
    """

    def setUp(self):
        login = patch.object(SETUP, 'host_github_login', return_value=None)
        login.start()
        self.addCleanup(login.stop)
        for name in ('searxng_row', 'zai_row', 'ego_row'):
            pinned = patch.object(SETUP, name, return_value=None)
            pinned.start()
            self.addCleanup(pinned.stop)

    def rows(self, ready_driver=True, ready_firefox=True):
        replies = [completed(browser_catalog('geckodriver', ready=ready_driver)),
                   completed(browser_catalog('firefox', ready=ready_firefox))]
        with patch.object(SETUP.subprocess, 'run', side_effect=replies):
            return SETUP.imp_tool_rows('/bin/masc', '/work space')

    def test_firefox_found_shows_both_routes_unmarked_with_their_commands(self):
        rows = {row.key: row for row in self.rows()}
        self.assertEqual([key for key in rows], ['automation', 'bidi', 'extension', 'github', 'web-search'])
        self.assertEqual((rows['automation'].checked, rows['github'].checked), (True, True))
        self.assertEqual((rows['bidi'].checked, rows['extension'].checked), (False, False))
        self.assertEqual(rows['bidi'].command,
                         "masc browser-lane-setup --mode bidi --base-path '/work space'")
        self.assertEqual(rows['extension'].command,
                         "masc browser-lane-setup --mode extension --base-path '/work space'")

    def test_the_bidi_notice_names_the_unauthenticated_port_and_the_one_login(self):
        notice = {row.key: row for row in self.rows()}['bidi'].notice
        for sentence in ('no authentication', 'any program on this computer', 'read its cookies',
                         'Log in once', 'profile keeps the login'):
            self.assertIn(sentence, notice)

    def test_the_extension_notice_says_the_add_on_has_to_be_loaded_again(self):
        notice = {row.key: row for row in self.rows()}['extension'].notice
        self.assertIn('removes the add-on', notice)
        self.assertIn('about:debugging', notice)

    def test_no_firefox_means_no_route_is_offered(self):
        # Recommending a browser is not this step's job, and a Zen-only computer
        # is not detected: with nothing to attach to there is nothing to ask.
        rows = self.rows(ready_firefox=False)
        self.assertEqual([row.key for row in rows], ['automation', 'github', 'web-search'])

    def test_a_missing_geckodriver_does_not_hide_the_routes(self):
        # The routes need Firefox, not geckodriver.
        rows = self.rows(ready_driver=False)
        self.assertEqual([row.key for row in rows], ['automation', 'bidi', 'extension', 'github', 'web-search'])

    def run_modes(self, picked, replies=None):
        # The rows look at both programs once. Preparing looks again at what
        # the chosen routes need: both for the automation lane (row 0), the
        # browser alone for the routes. Then the command, then the server note.
        if replies is None:
            looks = ([completed(browser_catalog('geckodriver', ready=True))] if 0 in picked else []) \
                + [completed(browser_catalog('firefox', ready=True))]
            replies = ([completed(browser_catalog('geckodriver', ready=True)),
                        completed(browser_catalog('firefox', ready=True))] + looks
                       + [completed(), completed(json.dumps(dict(status='free')))])
        with patch.object(SETUP.subprocess, 'run', side_effect=replies) as run, \
                patch.object(SETUP, 'pick', return_value=picked), \
                contextlib.redirect_stderr(io.StringIO()) as printed:
            confirmed = SETUP.select_imp_tools('/bin/masc', '/workspace', 8945)
        return confirmed, run, printed.getvalue()

    def setup_calls(self, run):
        return [call.args[0] for call in run.call_args_list
                if len(call.args[0]) > 1 and call.args[0][1] == 'browser-lane-setup']

    def test_one_route_is_written_by_one_command_for_that_route_only(self):
        confirmed, run, _ = self.run_modes([1])
        self.assertEqual([row.key for row in confirmed], ['bidi'])
        self.assertEqual(self.setup_calls(run),
                         [['/bin/masc', 'browser-lane-setup', '--mode', 'bidi', '--base-path', '/workspace']])

    def test_every_chosen_route_goes_to_one_command_in_a_fixed_order(self):
        # One call plans all of them before writing any, and a refused one writes none.
        confirmed, run, _ = self.run_modes([2, 0, 1])
        self.assertEqual([row.key for row in confirmed], ['extension', 'automation', 'bidi'])
        self.assertEqual(self.setup_calls(run),
                         [['/bin/masc', 'browser-lane-setup', '--mode', 'automation', '--mode', 'bidi',
                           '--mode', 'extension', '--base-path', '/workspace']])

    def test_a_route_without_the_automation_lane_does_not_ask_for_geckodriver(self):
        replies = [completed(browser_catalog('geckodriver', ready=True)),
                   completed(browser_catalog('firefox', ready=True)),
                   completed(browser_catalog('firefox', ready=True)),
                   completed(), completed(json.dumps(dict(status='free')))]
        _, run, _ = self.run_modes([2], replies)
        asked = [call.args[0][2] for call in run.call_args_list
                 if call.args[0][1] == 'prerequisite-actions']
        self.assertEqual(asked, ['geckodriver', 'firefox', 'firefox'])

    def test_a_refused_route_does_not_end_setup_and_names_the_command(self):
        replies = [completed(browser_catalog('geckodriver', ready=True)),
                   completed(browser_catalog('firefox', ready=True)),
                   completed(browser_catalog('firefox', ready=True)),
                   completed('', 1)]
        confirmed, _, printed = self.run_modes([1], replies)
        self.assertEqual([row.key for row in confirmed], ['bidi'])
        self.assertIn("imp's browser was not saved", printed)
        self.assertIn("masc browser-lane-setup --mode bidi --base-path /workspace", printed)
        # One route: there is no "one at a time" to offer.
        self.assertNotIn('one route at a time', printed)

    def test_the_notices_of_the_unmarked_rows_are_shown_before_the_checklist_asks(self):
        # The unmarked rows are the ones that need the warning most: the reader
        # marks them or not on what this screen says, and a notice printed only
        # for marked rows would never reach them.
        shown = []
        replies = [completed(browser_catalog('geckodriver', ready=True)),
                   completed(browser_catalog('firefox', ready=True))]
        with patch.object(SETUP.subprocess, 'run', side_effect=replies), \
                patch.object(SETUP, 'pick', side_effect=lambda *a, **k: shown.append((sys.stderr.getvalue(), a[1])) or []), \
                contextlib.redirect_stderr(io.StringIO()):
            SETUP.choose_imp_tools('/bin/masc', '/workspace')
        text, labels = shown[0]
        self.assertIn('That port has no authentication', text)
        self.assertIn('any program on this computer', text)
        self.assertIn('removes the add-on', text)
        # What the list line itself says, which is all a quick setup shows.
        self.assertTrue(any('open debugging port' in label for label in labels))
        self.assertTrue(any('load the add-on after each restart' in label for label in labels))

    def test_the_restart_note_is_for_the_routes_that_write_a_table(self):
        # The extension route writes no table of runtime.toml, and the lane token
        # is read for each request: telling the reader to restart a live server
        # for it would be advice that does nothing.
        for modes, expected in ((('extension',), False), (('bidi',), True),
                                (('automation',), True), (('bidi', 'extension'), True)):
            with self.subTest(modes=modes):
                looks = ([completed(browser_catalog('geckodriver', ready=True))] if 'automation' in modes else []) \
                    + [completed(browser_catalog('firefox', ready=True))]
                replies = looks + [completed(), completed(json.dumps(dict(status='same_workspace')))]
                with patch.object(SETUP.subprocess, 'run', side_effect=replies) as run, \
                        contextlib.redirect_stderr(io.StringIO()) as printed:
                    SETUP.prepare_browser_lane('/bin/masc', '/workspace', modes, 8945)
                asked = any(call.args[0][1] == 'setup-server' for call in run.call_args_list)
                self.assertEqual(asked, expected)
                self.assertEqual('already running' in printed.getvalue(), expected)

    def test_leaving_the_geckodriver_install_drops_the_automation_lane_and_keeps_the_routes(self):
        # The extension never needed geckodriver. Back at its install menu must
        # not take a route the reader also chose down with it.
        replies = [completed(browser_catalog('geckodriver', ready=False)),   # ensure geckodriver
                   completed(browser_catalog('firefox', ready=True)),         # ensure firefox
                   completed()]                                               # the command
        with patch.object(SETUP.subprocess, 'run', side_effect=replies) as run, \
                patch.object(SETUP, 'prerequisite_menu', return_value=False), \
                contextlib.redirect_stderr(io.StringIO()) as printed:
            SETUP.prepare_browser_lane('/bin/masc', '/workspace', ('automation', 'extension'))
        self.assertEqual(self.setup_calls(run),
                         [['/bin/masc', 'browser-lane-setup', '--mode', 'extension', '--base-path', '/workspace']])
        self.assertIn('geckodriver is missing, so this is left out', printed.getvalue())
        self.assertIn('--mode automation', printed.getvalue())

    def test_leaving_the_geckodriver_install_with_only_the_automation_lane_writes_nothing(self):
        replies = [completed(browser_catalog('geckodriver', ready=False))]
        with patch.object(SETUP.subprocess, 'run', side_effect=replies) as run, \
                patch.object(SETUP, 'prerequisite_menu', return_value=False), \
                contextlib.redirect_stderr(io.StringIO()):
            SETUP.prepare_browser_lane('/bin/masc', '/workspace', ('automation',))
        self.assertEqual(self.setup_calls(run), [])

    def test_a_missing_firefox_that_is_not_installed_writes_no_route(self):
        replies = [completed(browser_catalog('firefox', ready=False))]
        with patch.object(SETUP.subprocess, 'run', side_effect=replies) as run, \
                patch.object(SETUP, 'prerequisite_menu', return_value=False), \
                contextlib.redirect_stderr(io.StringIO()) as printed:
            SETUP.prepare_browser_lane('/bin/masc', '/workspace', ('bidi', 'extension'))
        self.assertEqual(self.setup_calls(run), [])
        self.assertIn('Firefox is missing, so this is left out', printed.getvalue())
        self.assertIn('--mode bidi --mode extension', printed.getvalue())

    def test_a_refused_call_with_several_routes_says_none_were_written_and_offers_each(self):
        # The command plans every route before it writes, so one refusal means
        # none were written. The reader can then run the ones that are fine.
        replies = [completed(browser_catalog('firefox', ready=True)), completed('', 1)]
        with patch.object(SETUP.subprocess, 'run', side_effect=replies), \
                contextlib.redirect_stderr(io.StringIO()) as printed:
            SETUP.prepare_browser_lane('/bin/masc', '/workspace', ('bidi', 'extension'), 8945)
        text = printed.getvalue()
        self.assertIn('Nothing was written for any of the routes in that one command', text)
        self.assertIn('masc browser-lane-setup --mode bidi --mode extension --base-path /workspace', text)
        self.assertIn('one route at a time: masc browser-lane-setup --mode bidi --base-path /workspace; '
                      'masc browser-lane-setup --mode extension --base-path /workspace', text)

    def test_an_unreadable_geckodriver_catalog_does_not_hide_the_firefox_routes(self):
        # The routes need Firefox only. The automation row needs both programs.
        replies = [completed('', 1), completed(browser_catalog('firefox', ready=True))]
        with patch.object(SETUP.subprocess, 'run', side_effect=replies), \
                contextlib.redirect_stderr(io.StringIO()) as printed:
            rows = SETUP.imp_tool_rows('/bin/masc', '/workspace')
        self.assertEqual([row.key for row in rows], ['bidi', 'extension', 'github', 'web-search'])
        self.assertIn('left out of this list', printed.getvalue())

    def test_an_unreadable_firefox_catalog_leaves_the_automation_row_out_and_no_route(self):
        replies = [completed(browser_catalog('geckodriver', ready=True)), completed('', 1)]
        with patch.object(SETUP.subprocess, 'run', side_effect=replies), \
                contextlib.redirect_stderr(io.StringIO()):
            rows = SETUP.imp_tool_rows('/bin/masc', '/workspace')
        self.assertEqual([row.key for row in rows], ['github', 'web-search'])

    def test_a_row_has_to_say_whether_it_starts_marked(self):
        # No default: a row that forgot would start marked, and the rows that
        # open a port or copy a token must never be the ones that do.
        with self.assertRaises(TypeError):
            SETUP.ToolRow('x', 'label', 'command')

    def test_the_quick_setup_list_explains_the_marks(self):
        replies = [completed(browser_catalog('geckodriver', ready=True)),
                   completed(browser_catalog('firefox', ready=True))]
        with patch.object(SETUP.subprocess, 'run', side_effect=replies), \
                contextlib.redirect_stderr(io.StringIO()) as printed:
            SETUP.show_imp_tools('/bin/masc', '/workspace')
        self.assertIn('[x] would start marked in the full setup', printed.getvalue())
        self.assertIn('Nothing here has been run', printed.getvalue())

    def test_the_quick_setup_list_shows_what_would_be_marked(self):
        replies = [completed(browser_catalog('geckodriver', ready=True)),
                   completed(browser_catalog('firefox', ready=True))]
        with patch.object(SETUP.subprocess, 'run', side_effect=replies), \
                patch.object(SETUP, 'pick') as picker, \
                contextlib.redirect_stderr(io.StringIO()) as printed:
            SETUP.show_imp_tools('/bin/masc', '/workspace')
        picker.assert_not_called()
        lines = printed.getvalue().splitlines()
        marked = [line for line in lines if line.startswith('  [x] ')]
        unmarked = [line for line in lines if line.startswith('  [ ] ')]
        self.assertEqual((len(marked), len(unmarked)), (3, 2))
        self.assertTrue(all('(BiDi)' in line or 'add-on' in line for line in unmarked))
        self.assertIn('--mode bidi', printed.getvalue())
        self.assertIn('--mode extension', printed.getvalue())


class EgoRoute(unittest.TestCase):
    """The ego lite row (RFC-browser-live-ego section 7).

    It is shown when ego-browser answers, starts unmarked and is written by
    `masc browser-lane-setup --mode ego`. It needs no Firefox, so a Firefox
    that is missing or left out does not take it away, nor the other way round.
    """

    def setUp(self):
        login = patch.object(SETUP, 'host_github_login', return_value=None)
        login.start()
        self.addCleanup(login.stop)
        for name in ('searxng_row', 'zai_row'):
            pinned = patch.object(SETUP, name, return_value=None)
            pinned.start()
            self.addCleanup(pinned.stop)

    def looks(self, firefox=True, ego=True):
        # The rows look at geckodriver, Firefox and then ego-browser, once each.
        return [completed(browser_catalog('geckodriver', ready=True)),
                completed(browser_catalog('firefox', ready=firefox)),
                completed(browser_page_catalog('ego-browser', ready=ego))]

    def rows(self, **found):
        with patch.object(SETUP.subprocess, 'run', side_effect=self.looks(**found)):
            return {row.key: row for row in SETUP.imp_tool_rows('/bin/masc', '/work space')}

    def setup_calls(self, run):
        return [call.args[0] for call in run.call_args_list
                if len(call.args[0]) > 1 and call.args[0][1] == 'browser-lane-setup']

    def prepare(self, modes, replies, port=None, menu=False):
        with patch.object(SETUP.subprocess, 'run', side_effect=replies) as run, \
                patch.object(SETUP, 'prerequisite_menu', return_value=menu), \
                contextlib.redirect_stderr(io.StringIO()) as printed:
            SETUP.prepare_browser_lane('/bin/masc', '/workspace', modes, port)
        return run, printed.getvalue()

    def test_ego_found_shows_its_row_unmarked_with_its_command(self):
        row = self.rows()['ego']
        self.assertFalse(row.checked)
        self.assertEqual(row.command, "masc browser-lane-setup --mode ego --base-path '/work space'")
        self.assertIn('cookies of your ego lite profile', row.notice)

    def test_no_ego_browser_means_no_ego_row(self):
        self.assertNotIn('ego', self.rows(ego=False))

    def test_ego_is_offered_without_firefox(self):
        rows = self.rows(firefox=False)
        self.assertIn('ego', rows)
        self.assertNotIn('bidi', rows)

    def test_an_unreadable_ego_catalog_leaves_the_other_rows_and_names_the_command(self):
        replies = self.looks()[:2] + [completed('', 1)]
        with patch.object(SETUP.subprocess, 'run', side_effect=replies), \
                contextlib.redirect_stderr(io.StringIO()) as printed:
            rows = {row.key for row in SETUP.imp_tool_rows('/bin/masc', '/workspace')}
        self.assertNotIn('ego', rows)
        self.assertTrue({'automation', 'bidi', 'extension', 'github'} <= rows)
        self.assertIn('masc browser-lane-setup --mode ego --base-path /workspace', printed.getvalue())

    def test_marking_the_row_runs_the_ego_mode_and_asks_for_no_firefox(self):
        replies = self.looks() + [completed(browser_page_catalog('ego-browser', ready=True)),
                                  completed(), completed(json.dumps(dict(status='free')))]
        ego = lambda *a, **k: [index for index, label in enumerate(a[1]) if 'ego lite' in label]
        with patch.object(SETUP.subprocess, 'run', side_effect=replies) as run, \
                patch.object(SETUP, 'pick', side_effect=ego), \
                contextlib.redirect_stderr(io.StringIO()):
            confirmed = SETUP.select_imp_tools('/bin/masc', '/workspace', 8945)
        self.assertEqual([row.key for row in confirmed], ['ego'])
        asked = [call.args[0][2] for call in run.call_args_list if call.args[0][1] == 'prerequisite-actions']
        self.assertEqual(asked, ['geckodriver', 'firefox', 'ego-browser', 'ego-browser'])
        self.assertEqual(self.setup_calls(run),
                         [['/bin/masc', 'browser-lane-setup', '--mode', 'ego', '--base-path', '/workspace']])

    def test_a_firefox_left_missing_keeps_the_ego_route(self):
        run, printed = self.prepare(('bidi', 'ego'), [completed(browser_catalog('firefox', ready=False)),
                                                      completed(browser_page_catalog('ego-browser', ready=True)),
                                                      completed()])
        self.assertEqual(self.setup_calls(run),
                         [['/bin/masc', 'browser-lane-setup', '--mode', 'ego', '--base-path', '/workspace']])
        self.assertIn('Firefox is missing, so this is left out. Run masc browser-lane-setup --mode bidi ', printed)

    def test_an_ego_browser_left_missing_keeps_the_firefox_routes(self):
        run, printed = self.prepare(('extension', 'ego'), [completed(browser_catalog('firefox', ready=True)),
                                                           completed(browser_page_catalog('ego-browser', ready=False)),
                                                           completed()])
        self.assertEqual(self.setup_calls(run),
                         [['/bin/masc', 'browser-lane-setup', '--mode', 'extension', '--base-path', '/workspace']])
        self.assertIn('ego-browser is missing, so this is left out. Run masc browser-lane-setup --mode ego ', printed)

    def test_the_ego_route_writes_a_table_so_a_running_server_is_told_to_restart(self):
        run, printed = self.prepare(('ego',), [completed(browser_page_catalog('ego-browser', ready=True)), completed(),
                                               completed(json.dumps(dict(status='same_workspace')))], port=8945)
        self.assertTrue(any(call.args[0][1] == 'setup-server' for call in run.call_args_list))
        self.assertIn('already running', printed)


class HostGithubLoginProbe(unittest.TestCase):
    """What `gh auth status --json hosts` says, read into a login worth offering."""

    def probe(self, output, which='/usr/bin/gh', code=0):
        with patch.object(SETUP.shutil, 'which', return_value=which), \
                patch.object(SETUP.subprocess, 'run', return_value=completed(output, code)) as run, \
                contextlib.redirect_stderr(io.StringIO()) as printed:
            return SETUP.host_github_login(), run, printed.getvalue()

    def test_an_active_account_github_accepts_is_offered_with_where_its_token_lives(self):
        login, run, printed = self.probe(gh_status(gh_account('octo', source='keyring', scopes='repo, workflow')))
        self.assertEqual((login.login, login.source, login.scopes), ('octo', 'keyring', 'repo, workflow'))
        self.assertEqual(run.call_args.args[0], ['gh', 'auth', 'status', '--hostname', 'github.com', '--json', 'hosts'])
        # A gh that hangs on the network must not hold the wizard.
        self.assertEqual(run.call_args.kwargs['timeout'], SETUP.GH_PROBE_TIMEOUT_SECONDS)
        self.assertEqual(printed, '')

    def test_the_active_account_is_chosen_among_several(self):
        login, _, _ = self.probe(gh_status(gh_account('other', active=False), gh_account('octo')))
        self.assertEqual(login.login, 'octo')

    def test_no_login_a_refused_token_and_an_inactive_account_offer_nothing(self):
        cases = {'no host': gh_status(),
                 'refused token': gh_status(gh_account('', state='error', source='GH_TOKEN')),
                 'inactive': gh_status(gh_account('octo', active=False)),
                 'no account name': gh_status(gh_account('')),
                 # A name next to an error: GitHub named the account and then
                 # refused the call, so the token is not known to work.
                 'an error beside a name': gh_status(gh_account('octo', state='error')),
                 'another state': gh_status(gh_account('octo', state='timeout'))}
        for name, output in cases.items():
            with self.subTest(name):
                login, _, printed = self.probe(output)
                self.assertIsNone(login)
                self.assertEqual(printed, '')

    def test_a_computer_without_gh_runs_nothing(self):
        login, run, _ = self.probe(gh_status(gh_account()), which=None)
        self.assertIsNone(login)
        run.assert_not_called()

    def test_output_that_is_not_the_json_says_so(self):
        # An older gh has no --json: the reader is told why imp gets a code.
        for output in ('unknown flag: --json', '[]', json.dumps(dict(hosts=[]))):
            with self.subTest(output=output):
                login, _, printed = self.probe(output, code=1)
                self.assertIsNone(login)
                self.assertIn('one-time code', printed)

    def test_a_gh_that_does_not_answer_in_time_is_not_waited_for(self):
        with patch.object(SETUP.shutil, 'which', return_value='/usr/bin/gh'), \
                patch.object(SETUP.subprocess, 'run', side_effect=SETUP.subprocess.TimeoutExpired('gh', 20)), \
                contextlib.redirect_stderr(io.StringIO()) as printed:
            self.assertIsNone(SETUP.host_github_login())
        self.assertIn('did not answer in time', printed.getvalue())

    def test_a_gh_that_cannot_be_started_is_not_a_login_and_does_not_end_setup(self):
        # A file named gh on PATH that will not run (a broken interpreter line).
        with patch.object(SETUP.shutil, 'which', return_value='/usr/bin/gh'), \
                patch.object(SETUP.subprocess, 'run', side_effect=FileNotFoundError('gh')), \
                contextlib.redirect_stderr(io.StringIO()) as printed:
            self.assertIsNone(SETUP.host_github_login())
        self.assertIn('could not be started', printed.getvalue())


class ImpGithubLogin(unittest.TestCase):
    """The GitHub row and its hand-over, once imp exists."""

    def row(self, login):
        with patch.object(SETUP, 'host_github_login', return_value=login):
            return SETUP.github_row('/work space')

    def test_a_login_on_this_computer_is_offered_and_the_reader_is_told_what_it_means(self):
        row = self.row(SETUP.HostGithubLogin('octo', 'repo, workflow', 'keyring'))
        self.assertIn('account octo', row.label)
        for sentence in ('account octo on github.com', 'token from keyring', 'scopes repo, workflow',
                         'pushes and opens pull requests as octo', 'workflow files', 'copy of the token',
                         'other keepers are not given'):
            self.assertIn(sentence, row.notice)
        # The account is named, so the token read later is that account's.
        self.assertEqual(row.command, "gh auth token --hostname github.com --user octo | masc keeper-github "
                                      "set-token --keeper imp --hostname github.com --base-path '/work space'")
        # Building the row only reads the account. The token is read at the
        # moment it is handed over, so nothing token-shaped can be in the text.
        self.assertNotIn(GH_TOKEN_FIXTURE, row.label + row.notice + row.command)
        self.assertIsNone(re.search(r'gh[a-z]_|github_pat_', row.label + row.notice + row.command))

    def test_building_the_row_runs_nothing(self):
        with patch.object(SETUP.subprocess, 'run') as run:
            self.row(SETUP.HostGithubLogin('octo', 'repo', 'keyring'))
            self.row(None)
        run.assert_not_called()

    def test_the_notice_is_shown_before_the_checklist_asks(self):
        # The mark is the reader's consent to hand imp a copy of the token, so
        # what that means has to be on the screen when the question is asked.
        shown = []
        login = SETUP.HostGithubLogin('octo', 'repo, workflow', 'keyring')
        with patch.object(SETUP, 'host_github_login', return_value=login), \
                patch.object(SETUP, 'browser_rows', side_effect=SETUP.SetupError('no browser tools')), \
                patch.object(SETUP, 'searxng_row', return_value=None), \
                patch.object(SETUP, 'zai_row', return_value=None), \
                patch.object(SETUP, 'ego_row', return_value=None), \
                patch.object(SETUP, 'pick', side_effect=lambda *a, **k: shown.append(sys.stderr.getvalue()) or [0]), \
                contextlib.redirect_stderr(io.StringIO()):
            SETUP.choose_imp_tools('/bin/masc', '/workspace')
        self.assertEqual(len(shown), 1)
        self.assertIn('copy of the token', shown[0])
        self.assertIn('account octo on github.com', shown[0])

    def test_without_a_login_the_row_is_the_one_time_code(self):
        row = self.row(None)
        self.assertIn('one-time code', row.label)
        self.assertEqual(row.notice, '')
        self.assertEqual(row.command, "masc keeper-github login --keeper imp --hostname github.com "
                                      "--base-path '/work space'")

    def hand_over(self, row, replies):
        with patch.object(SETUP.subprocess, 'run', side_effect=replies) as run, \
                contextlib.redirect_stderr(io.StringIO()) as printed:
            SETUP.finish_imp_tools('/bin/masc', '/workspace', (row,))
        return run, printed.getvalue()

    def test_the_token_goes_to_the_command_on_its_standard_input_and_nowhere_else(self):
        row = self.row(SETUP.HostGithubLogin('octo', 'repo', 'keyring'))
        run, printed = self.hand_over(row, [completed(GH_TOKEN_FIXTURE + '\n'), completed()])
        # The account the reader agreed to, not whichever one is active by now.
        self.assertEqual(run.call_args_list[0].args[0],
                         ['gh', 'auth', 'token', '--hostname', 'github.com', '--user', 'octo'])
        self.assertEqual(run.call_args_list[0].kwargs['timeout'], SETUP.GH_PROBE_TIMEOUT_SECONDS)
        argv = run.call_args_list[1].args[0]
        self.assertEqual(argv, ['/bin/masc', 'keeper-github', 'set-token', '--keeper', 'imp',
                                '--hostname', 'github.com', '--base-path', '/workspace'])
        self.assertEqual(run.call_args_list[1].kwargs['input'], GH_TOKEN_FIXTURE)
        for call in run.call_args_list:
            self.assertNotIn(GH_TOKEN_FIXTURE, ' '.join(call.args[0]))
        self.assertNotIn(GH_TOKEN_FIXTURE, printed)

    def test_a_token_from_the_environment_is_read_without_naming_an_account(self):
        # `gh auth token --user` finds only a stored login. For GH_TOKEN it
        # would exit 1 after the reader had agreed and `masc setup` had run.
        for source in ('GH_TOKEN', 'GITHUB_TOKEN', 'GH_ENTERPRISE_TOKEN'):
            with self.subTest(source=source):
                row = self.row(SETUP.HostGithubLogin('octo', 'repo', source))
                run, _ = self.hand_over(row, [completed(GH_TOKEN_FIXTURE), completed()])
                self.assertEqual(run.call_args_list[0].args[0], ['gh', 'auth', 'token', '--hostname', 'github.com'])
                self.assertNotIn('--user', row.command)

    def test_a_stored_login_is_read_for_its_account(self):
        for source in ('keyring', 'oauth_token', 'hosts.yml'):
            with self.subTest(source=source):
                row = self.row(SETUP.HostGithubLogin('octo', 'repo', source))
                run, _ = self.hand_over(row, [completed(GH_TOKEN_FIXTURE), completed()])
                self.assertEqual(run.call_args_list[0].args[0],
                                 ['gh', 'auth', 'token', '--hostname', 'github.com', '--user', 'octo'])
                self.assertIn('--user octo', row.command)

    def test_the_token_is_not_printed_to_standard_output_either(self):
        row = self.row(SETUP.HostGithubLogin('octo', 'repo', 'keyring'))
        with patch.object(SETUP.subprocess, 'run', side_effect=[completed(GH_TOKEN_FIXTURE), completed()]), \
                contextlib.redirect_stdout(io.StringIO()) as out, contextlib.redirect_stderr(io.StringIO()):
            SETUP.finish_imp_tools('/bin/masc', '/workspace', (row,))
        self.assertEqual(out.getvalue(), '')

    def test_without_a_login_the_command_asks_for_a_code_and_the_reader_approves_it(self):
        run, _ = self.hand_over(self.row(None), [completed()])
        self.assertEqual(run.call_args_list[0].args[0],
                         ['/bin/masc', 'keeper-github', 'login', '--keeper', 'imp',
                          '--hostname', 'github.com', '--base-path', '/workspace'])
        self.assertNotIn('input', run.call_args_list[0].kwargs)

    def test_a_refused_hand_over_says_what_to_run_and_does_not_end_setup(self):
        row = self.row(SETUP.HostGithubLogin('octo', 'repo', 'keyring'))
        _, printed = self.hand_over(row, [completed(GH_TOKEN_FIXTURE), completed('', 1)])
        self.assertIn("imp's GitHub login was not saved", printed)
        self.assertIn('masc keeper-github login --keeper imp --hostname github.com --base-path /workspace', printed)
        self.assertNotIn(GH_TOKEN_FIXTURE, printed)

    def test_a_gh_that_gives_no_token_stops_before_the_command_runs(self):
        row = self.row(SETUP.HostGithubLogin('octo', 'repo', 'keyring'))
        run, printed = self.hand_over(row, [completed('', 1)])
        self.assertEqual(len(run.call_args_list), 1)
        self.assertIn('gh did not give the GitHub token of octo', printed)
        self.assertIn("imp's GitHub login was not saved", printed)

    def test_a_gh_that_cannot_be_started_does_not_end_setup(self):
        row = self.row(SETUP.HostGithubLogin('octo', 'repo', 'keyring'))
        _, printed = self.hand_over(row, FileNotFoundError('gh'))
        self.assertIn("imp's GitHub login was not saved", printed)

    def test_only_the_github_row_waits_for_imp(self):
        browser = SETUP.ToolRow(SETUP.AUTOMATION_TOOL, 'browser', 'cmd', checked=True)
        with patch.object(SETUP.subprocess, 'run') as run:
            SETUP.finish_imp_tools('/bin/masc', '/workspace', (browser,))
        run.assert_not_called()

    def test_a_reader_who_leaves_before_imp_exists_is_reminded_of_the_login_they_confirmed(self):
        github = self.row(SETUP.HostGithubLogin('octo', 'repo', 'keyring'))
        browser = SETUP.ToolRow(SETUP.AUTOMATION_TOOL, 'browser', 'cmd', checked=True)
        with contextlib.redirect_stderr(io.StringIO()) as printed:
            SETUP.remind_imp_tools((browser, github))
        self.assertIn('Once imp is running, run: gh auth token', printed.getvalue())
        self.assertEqual(printed.getvalue().count('Once imp is running'), 1)
        with contextlib.redirect_stderr(io.StringIO()) as quiet:
            SETUP.remind_imp_tools((browser,))
        self.assertEqual(quiet.getvalue(), '')


class ImpToolsInTheJourney(unittest.TestCase):
    """Where the step sits: after the sandbox, before `masc setup` starts the server.

    The server reads the browser table when it starts, so a table written
    after `masc setup` would wait for a restart nobody asked for. The GitHub
    login is the other way round: imp is created by `masc setup`.
    """

    def walk(self, quick, sandbox, code=0):
        order = []

        def ran(argv, **_):
            order.append(argv[1])
            return subprocess.CompletedProcess([], code)
        with patch.object(SETUP, 'select_sandbox', side_effect=lambda *a, **k: order.append('sandbox') or sandbox), \
                patch.object(SETUP, 'select_imp_tools', side_effect=lambda *a: order.append('tools') or ('row',)) as asked, \
                patch.object(SETUP, 'show_imp_tools', side_effect=lambda *a: order.append('list')), \
                patch.object(SETUP, 'finish_imp_tools', side_effect=lambda *a: order.append('finish')) as finish, \
                patch.object(SETUP, 'remind_imp_tools', side_effect=lambda *a: order.append('remind')), \
                patch.object(SETUP, 'open_workspace', side_effect=lambda *a: order.append('open') or 0), \
                patch.object(SETUP, 'pick', return_value=[1]), \
                patch.object(SETUP.subprocess, 'run', side_effect=ran), \
                contextlib.redirect_stderr(io.StringIO()):
            SETUP.sandbox_journey('/bin/masc', '/workspace', 8945, quick=quick)
        return order, finish, asked

    def test_the_checklist_comes_after_the_sandbox_and_before_setup_and_the_login_after_it(self):
        order, finish, asked = self.walk(quick=False, sandbox=[])
        self.assertEqual(order, ['sandbox', 'tools', 'setup', 'finish', 'open'])
        self.assertEqual(finish.call_args.args, ('/bin/masc', '/workspace', ('row',)))
        # The port is how a running server is recognised after the table is written.
        self.assertEqual(asked.call_args.args, ('/bin/masc', '/workspace', 8945))

    def test_a_quick_setup_lists_instead_of_asking_and_confirms_nothing(self):
        order, finish, _ = self.walk(quick=True, sandbox=[])
        self.assertEqual(order, ['sandbox', 'list', 'setup', 'finish', 'open'])
        self.assertEqual(finish.call_args.args[2], ())

    def test_leaving_at_the_sandbox_does_not_open_the_step(self):
        self.assertEqual(self.walk(quick=False, sandbox=None)[0], ['sandbox'])

    def test_a_setup_that_failed_gives_imp_no_login_and_reminds_the_reader_who_leaves(self):
        # imp is not running yet, so there is nothing to give a login to. The
        # reader who picks "Finish later" is told what is still to do.
        order, _, _ = self.walk(quick=False, sandbox=[], code=1)
        self.assertEqual(order, ['sandbox', 'tools', 'setup', 'remind'])


def isolated_environment(root, tools):
    """Only HOME and PATH. `masc browser-lane-setup` resolves runtime.toml from
    MASC_CONFIG_DIR ahead of the base path, so a shell that exports it would
    send these tests' writes to the operator's live configuration."""
    return {'HOME': str(root / 'home'), 'PATH': str(tools) + os.pathsep + '/usr/bin:/bin'}


@unittest.skipUnless(BINARY, 'requires the CI-built native executable')
class ImpToolsAgainstTheBinary(unittest.TestCase):
    """The wizard, the catalog and the command agree, as the real binary says them.

    The fixtures above are copies of what the binary prints, and a copy can
    drift. Here geckodriver and Firefox are scripts on PATH, so the catalog
    finds them, and the command the wizard runs writes a real runtime.toml.
    """

    RUNTIME = ('[providers."deepseek"]\ndisplay-name = "Fixture"\nprotocol = "openai-compatible-http"\n'
               'endpoint = "https://fixture.invalid/v1"\n[providers."deepseek".credentials]\ntype = "inline"\n'
               'value = "fixture-key"\n[models.chat]\napi-name = "deepseek-v4-pro"\n["deepseek".chat]\n'
               '[runtime]\ndefault = "deepseek.chat"\n')

    def workspace(self, root, extra=''):
        tools = root / 'tools'
        tools.mkdir()
        for name, banner in (('geckodriver', 'geckodriver 0.0'), ('firefox', 'Mozilla Firefox 0.0')):
            (tools / name).write_text("#!/bin/sh\necho '" + banner + "'\n")
            (tools / name).chmod(0o755)
        base = root / 'workspace'
        (base / '.masc/config').mkdir(parents=True)
        (base / '.masc/config/runtime.toml').write_text(self.RUNTIME + extra)
        (root / 'home').mkdir()
        return tools, base

    def test_a_found_pair_is_written_into_the_workspace(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            tools, base = self.workspace(root)
            # A file, not a StringIO: the command's output goes to this stderr's
            # descriptor, which a StringIO does not have.
            with open(root / 'stderr.txt', 'w') as sink, \
                    patch.dict(os.environ, isolated_environment(root, tools), clear=True), \
                    contextlib.redirect_stderr(sink):
                rows = SETUP.imp_tool_rows(BINARY, str(base))
                SETUP.prepare_browser_lane(BINARY, str(base), ('automation',))
            self.assertIn('geckodriver and Firefox found', rows[0].label)
            written = (base / '.masc/config/runtime.toml').read_text()
            self.assertIn('geckodriver = "' + str(tools / 'geckodriver') + '"', written)
            self.assertNotIn('was not saved', (root / 'stderr.txt').read_text())

    def with_host_on_path(self, root, tools):
        """The command installs the host from a `masc-browser-host` beside it or on PATH."""
        built = Path(BINARY).parent / 'masc_browser_host.exe'
        if not built.is_file():
            self.skipTest('the built masc_browser_host.exe is not beside the executable')
        host = tools / 'masc-browser-host'
        host.write_bytes(built.read_bytes())
        host.chmod(0o755)

    def run_routes(self, root, base, tools, modes):
        with open(root / 'stderr.txt', 'w') as sink, \
                patch.dict(os.environ, isolated_environment(root, tools), clear=True), \
                contextlib.redirect_stderr(sink):
            SETUP.prepare_browser_lane(BINARY, str(base), modes)
        return (root / 'stderr.txt').read_text()

    def test_the_bidi_route_writes_the_firefox_table_and_the_host_and_no_other_table(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            tools, base = self.workspace(root)
            self.with_host_on_path(root, tools)
            printed = self.run_routes(root, base, tools, ('bidi',))
            written = (base / '.masc/config/runtime.toml').read_text()
            self.assertIn('[browser.live.bidi]', written.splitlines())
            self.assertIn('firefox = "' + str(tools / 'firefox') + '"', written)
            self.assertNotIn('[browser.automation]', written.splitlines())
            self.assertTrue((base / '.masc/browser-lane/host/masc-browser-host').is_file())
            self.assertNotIn('was not saved', printed)
            # The command's own sentence about the port with no authentication.
            self.assertIn('no authentication', printed)

    def test_the_extension_route_writes_the_add_on_and_no_runtime_table(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            tools, base = self.workspace(root)
            self.with_host_on_path(root, tools)
            before = (base / '.masc/config/runtime.toml').read_text()
            printed = self.run_routes(root, base, tools, ('extension',))
            self.assertTrue((base / '.masc/browser-lane/extension/manifest.json').is_file())
            self.assertEqual((base / '.masc/config/runtime.toml').read_text(), before)
            self.assertIn('about:debugging', printed)
            self.assertNotIn('was not saved', printed)

    def test_two_routes_in_one_run_write_both_tables_through_one_command(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            tools, base = self.workspace(root)
            self.with_host_on_path(root, tools)
            printed = self.run_routes(root, base, tools, ('automation', 'bidi'))
            written = (base / '.masc/config/runtime.toml').read_text().splitlines()
            self.assertIn('[browser.automation]', written)
            self.assertIn('[browser.live.bidi]', written)
            self.assertNotIn('was not saved', printed)

    def test_a_geckodriver_the_operator_already_wrote_is_kept(self):
        # The wizard used to name the path it had found, and the command then
        # replaced the operator's value with it.
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            tools = root / 'tools'
            (root / 'chosen').mkdir()
            chosen = root / 'chosen' / 'geckodriver'
            chosen.write_text("#!/bin/sh\necho 'geckodriver 0.0 (the operator choice)'\n")
            chosen.chmod(0o755)
            tools, base = self.workspace(root, '[browser.automation]\ngeckodriver = "' + str(chosen) + '"\n')
            with open(root / 'stderr.txt', 'w') as sink, \
                    patch.dict(os.environ, isolated_environment(root, tools), clear=True), \
                    contextlib.redirect_stderr(sink):
                SETUP.prepare_browser_lane(BINARY, str(base), ('automation',))
            written = (base / '.masc/config/runtime.toml').read_text()
        self.assertIn(str(chosen), written)
        self.assertNotIn(str(tools / 'geckodriver'), written)

    def test_a_kept_geckodriver_that_is_gone_is_said_on_the_wizards_screen(self):
        # The wizard found a geckodriver on PATH and calls the command, which
        # keeps the value the operator wrote. If that path is gone (a brew
        # upgrade), the reader is told on this screen and not by the server
        # failing later.
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            gone = root / 'removed' / 'geckodriver'
            tools, base = self.workspace(root, '[browser.automation]\ngeckodriver = "' + str(gone) + '"\n')
            runtime = base / '.masc/config/runtime.toml'
            before = runtime.read_text()
            with open(root / 'stderr.txt', 'w') as sink, \
                    patch.dict(os.environ, isolated_environment(root, tools), clear=True), \
                    contextlib.redirect_stderr(sink):
                SETUP.prepare_browser_lane(BINARY, str(base), ('automation',))
            printed = (root / 'stderr.txt').read_text()
            self.assertEqual(runtime.read_text(), before, 'the value is kept')
        self.assertIn('is not an executable file now', printed)
        self.assertIn(str(gone), printed)
        self.assertIn('--geckodriver', printed)

    def run_web_search_check(self, root, base, tools, **extra_environment):
        with open(root / 'stderr.txt', 'w') as sink, \
                patch.dict(os.environ, dict(isolated_environment(root, tools), **extra_environment), clear=True), \
                contextlib.redirect_stderr(sink):
            SETUP.check_web_search(BINARY, str(base))
        return (root / 'stderr.txt').read_text()

    def test_the_web_search_check_shows_each_provider_and_writes_nothing(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            tools, base = self.workspace(root)
            runtime = base / '.masc/config/runtime.toml'
            before = runtime.read_text()
            files = sorted(str(path.relative_to(root)) for path in root.rglob('*') if path.name != 'stderr.txt')
            printed = self.run_web_search_check(root, base, tools)
            self.assertEqual(runtime.read_text(), before)
            self.assertEqual(files, sorted(str(path.relative_to(root)) for path in root.rglob('*')
                                           if path.name != 'stderr.txt'), 'no file appeared')
        self.assertIn('Web search settings in', printed)
        self.assertIn('Providers, as this shell and runtime.toml leave them:', printed)
        # The isolated environment holds no key, so the table says what to export.
        line = next(line for line in printed.splitlines() if line.lstrip().startswith('tavily'))
        self.assertIn('missing', line)
        self.assertIn('TAVILY_API_KEY', line)
        self.assertNotIn('Web search was not checked', printed)

    def test_a_key_exported_where_the_wizard_runs_is_the_one_the_check_sees(self):
        # `masc setup` starts the server from this environment, so a key here
        # is the key the server will have.
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            tools, base = self.workspace(root)
            printed = self.run_web_search_check(root, base, tools, TAVILY_API_KEY='tvly-fixture')
        line = next(line for line in printed.splitlines() if line.lstrip().startswith('tavily'))
        self.assertIn('ready', line)
        self.assertNotIn('tvly-fixture', printed, 'a key is never printed')

    def test_an_exported_config_dir_does_not_decide_which_runtime_toml_is_shown(self):
        # The server `masc setup` starts reads the workspace's file, so the
        # check shows that one even when the terminal exports MASC_CONFIG_DIR.
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            tools, base = self.workspace(root)
            other = root / 'other-config'
            other.mkdir()
            (other / 'runtime.toml').write_text(self.RUNTIME + '[web_search]\nsearxng_url = "http://other.invalid:8080"\n')
            printed = self.run_web_search_check(root, base, tools, MASC_CONFIG_DIR=str(other))
        self.assertIn(str(base / '.masc/config/runtime.toml'), printed)
        self.assertNotIn('other.invalid', printed)

    def test_a_workspace_without_a_runtime_toml_is_said_and_the_journey_goes_on(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            tools, base = self.workspace(root)
            (base / '.masc/config/runtime.toml').unlink()
            # The command's own refusal goes to its standard error, which is
            # this process's descriptor 2 and not the redirected sys.stderr.
            saved = os.dup(2)
            try:
                with open(root / 'command-stderr.txt', 'w') as sink:
                    os.dup2(sink.fileno(), 2)
                    try:
                        printed = self.run_web_search_check(root, base, tools)
                    finally:
                        os.dup2(saved, 2)
            finally:
                os.close(saved)
            printed += (root / 'command-stderr.txt').read_text()
        self.assertIn('No masc workspace', printed)
        self.assertIn('Web search was not checked. Run masc web-search-setup --base-path', printed)

    def test_the_github_hand_over_reaches_the_keeper_lookup_with_the_token_on_standard_input(self):
        # No imp exists in this scratch workspace, so the command ends at
        # "not found". It gets there only after its options parsed and the
        # token came in on standard input: an unknown option stops it at
        # parsing, and an empty standard input stops it at "token must not be
        # empty". A real success needs a running server to create the keeper.
        token = 'gho_fixturefixturefixturefixture9999'
        status = gh_status(gh_account('octo'))
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            tools = root / 'tools'
            tools.mkdir()
            (tools / 'gh').write_text(
                "#!/bin/sh\ncase \"$*\" in\n"
                "  'auth status --hostname github.com --json hosts') echo '" + status + "';;\n"
                "  'auth token --hostname github.com --user octo') echo '" + token + "';;\n"
                "  *) echo \"unexpected: $*\" >&2; exit 2;;\nesac\n")
            (tools / 'gh').chmod(0o755)
            (root / 'home').mkdir()
            base = root / 'workspace'
            base.mkdir()
            record, output = root / 'stderr.txt', root / 'stdout.txt'
            saved, saved_output, saved_input = os.dup(2), os.dup(1), os.dup(0)
            sink = os.open(str(record), os.O_WRONLY | os.O_CREAT | os.O_TRUNC)
            sink_output = os.open(str(output), os.O_WRONLY | os.O_CREAT | os.O_TRUNC)
            nothing = os.open(os.devnull, os.O_RDONLY)
            try:
                # The command's own stderr is descriptor 2, which the wizard's
                # redirect of the Python object does not reach. Its standard
                # input is empty unless the wizard supplies the token: a missing
                # token fails this test at once instead of waiting on a terminal.
                # Standard output is kept too, to see that the token is not on it.
                os.dup2(sink, 2)
                os.dup2(sink_output, 1)
                os.dup2(nothing, 0)
                with patch.dict(os.environ, isolated_environment(root, tools), clear=True):
                    login = SETUP.host_github_login()
                    for offered in (login, None):
                        with patch.object(SETUP, 'host_github_login', return_value=offered):
                            SETUP.finish_imp_tools(BINARY, str(base), (SETUP.github_row(str(base)),))
            finally:
                # Python buffers what it prints: without this a token printed by
                # the wizard itself would reach the real descriptor after the
                # capture was already read.
                sys.stdout.flush()
                sys.stderr.flush()
                os.dup2(saved, 2)
                os.dup2(saved_output, 1)
                os.dup2(saved_input, 0)
                for descriptor in (saved, saved_output, saved_input, sink, sink_output, nothing):
                    os.close(descriptor)
            printed, printed_output = record.read_text(), output.read_text()
        self.assertEqual((login.login, login.source), ('octo', 'keyring'))
        self.assertEqual(printed.count('keeper "imp" not found'), 2, printed)
        self.assertEqual(printed.count("imp's GitHub login was not saved"), 2, printed)
        self.assertNotIn('token must not be empty', printed)
        self.assertNotIn('unknown option', printed)
        self.assertNotIn(token, printed + printed_output)


@unittest.skipUnless(BINARY, 'requires the CI-built native executable')
class SearchChoicesAgainstTheBinary(unittest.TestCase):
    """The wizard's two search choices, as the real binary answers them.

    Docker is a script on PATH that answers `info` and `inspect` as the case
    says, so the catalog is the binary's own and no container is touched. The
    address `127.0.0.1:8888` is the binary's fixed probe; a case that needs it
    silent is skipped on a computer where something answers there.
    """

    ADDRESS = ('127.0.0.1', 8888)

    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name).resolve()
        self.tools = self.root / 'tools'
        self.tools.mkdir()
        self.base = self.root / 'workspace'
        (self.base / '.masc/config').mkdir(parents=True)
        (self.base / '.masc/config/runtime.toml').write_text(ImpToolsAgainstTheBinary.RUNTIME)
        (self.root / 'home').mkdir()
        self.record = self.root / 'docker-calls.txt'
        login = patch.object(SETUP, 'host_github_login', return_value=None)
        login.start()
        self.addCleanup(login.stop)

    def docker(self, info_ok=True, inspect=None, others_ok=True):
        """`inspect` is what `docker inspect` prints, or None for no such container."""
        lines = ['#!/bin/sh', 'echo "$@" >> ' + shlex.quote(str(self.record)), 'case "$1" in',
                 '  info) exit ' + ('0' if info_ok else '1') + ' ;;']
        lines.append('  inspect) exit 1 ;;' if inspect is None else '  inspect) echo ' + inspect + '; exit 0 ;;')
        lines.append("  *) " + ("exit 0" if others_ok else "echo 'docker: refused' >&2; exit 1") + " ;;")
        lines.append('esac')
        script = self.tools / 'docker'
        script.write_text('\n'.join(lines) + '\n')
        script.chmod(0o755)

    def environment(self, **extra):
        return patch.dict(os.environ, dict(isolated_environment(self.root, self.tools), **extra), clear=True)

    def something_answers_at_the_probe_address(self):
        """A listener that is not SearXNG does not change these cases: the
        binary reads only a JSON object with `results` as an answer."""
        import urllib.request
        url = 'http://%s:%d/search?q=masc&format=json' % self.ADDRESS
        try:
            with urllib.request.urlopen(url, timeout=3) as answer:
                return answer.status == 200 and 'results' in json.loads(answer.read().decode('utf-8', 'replace'))
        except (OSError, ValueError):
            return False

    def plan(self):
        with self.environment():
            return SETUP.searxng_plan(BINARY, str(self.base))

    def test_the_plan_names_the_action_that_fits_each_container_state(self):
        for inspect, container, action in ((None, 'absent', 'searxng_docker_run'),
                                           ('exited', 'stopped', 'searxng_docker_start_existing')):
            with self.subTest(container=container):
                self.docker(inspect=inspect)
                readiness, action_id = self.plan()
                self.assertTrue(readiness.docker)
                self.assertEqual(readiness.container, container)
                self.assertEqual(action_id, action)
                self.assertEqual(readiness.url, 'http://127.0.0.1:8888')

    def test_a_running_container_has_no_action_to_start(self):
        self.docker(inspect='running')
        readiness, action_id = self.plan()
        self.assertEqual((readiness.docker, readiness.container, action_id), (True, 'running', None))

    def test_docker_that_does_not_answer_is_not_ready(self):
        self.docker(info_ok=False)
        readiness, _ = self.plan()
        self.assertFalse(readiness.docker)

    def test_the_rows_are_the_ones_the_catalogs_make(self):
        if self.something_answers_at_the_probe_address():
            self.skipTest('something answers on ' + str(self.ADDRESS[1]))
        self.docker()
        with self.environment(**{SETUP.ZAI_KEY_VARIABLE: 'zai-fixture-key'}), \
                patch.object(SETUP, 'browser_rows', return_value=[]), contextlib.redirect_stderr(io.StringIO()):
            rows = {row.key: row for row in SETUP.imp_tool_rows(BINARY, str(self.base))}
        self.assertEqual(list(rows), ['github', 'web-search', 'zai', 'searxng'])
        self.assertIn('--execute searxng_docker_run', rows['searxng'].command)
        self.assertFalse(rows['zai'].checked or rows['searxng'].checked)

    def test_both_choices_are_written_by_options_the_binary_accepts(self):
        with open(self.root / 'stderr.txt', 'w') as sink, self.environment(), contextlib.redirect_stderr(sink):
            SETUP.choose_zai(BINARY, str(self.base))
            self.assertTrue(SETUP.run_web_search_setup(BINARY, str(self.base),
                                                       ['--searxng-url', 'http://127.0.0.1:8888']))
        written = (self.base / '.masc/config/runtime.toml').read_text().splitlines()
        self.assertIn('provider = "zai"', written)
        self.assertIn('searxng_url = "http://127.0.0.1:8888"', written)
        self.assertNotIn('was not chosen', (self.root / 'stderr.txt').read_text())

    def test_a_start_that_docker_refuses_is_said_and_no_address_is_written(self):
        if self.something_answers_at_the_probe_address():
            self.skipTest('something answers on ' + str(self.ADDRESS[1]))
        self.docker(others_ok=False)
        with open(self.root / 'stderr.txt', 'w') as sink, self.environment(), contextlib.redirect_stderr(sink):
            SETUP.start_searxng(BINARY, str(self.base))
        printed = (self.root / 'stderr.txt').read_text()
        self.assertIn('SearXNG did not come up', printed)
        self.assertNotIn('searxng_url', (self.base / '.masc/config/runtime.toml').read_text())
        # The pull was tried, so the receipt that came back is one the wizard read.
        self.assertIn('pull', self.record.read_text())
        self.assertNotIn('could not return a readable result', printed)


class PdfToolsProbe(unittest.TestCase):
    # Journey replaces pdf_tools_status for every case, so the probe itself is
    # exercised here, without that stand-in.
    def test_readiness_probe_that_never_answers_is_a_setup_error(self):
        # The sandbox menu asks before every draw, so an unbounded probe would
        # hold the setup screen. The bound reaches subprocess.run, and running
        # out of it is refused rather than read as some readiness.
        expired = subprocess.TimeoutExpired(['/owned/masc'], SETUP.PDF_TOOLS_PROBE_TIMEOUT_SECONDS)
        with patch.object(SETUP.subprocess, 'run', side_effect=expired) as run, \
                self.assertRaisesRegex(SETUP.SetupError, 'did not answer about PDF tool availability in time'):
            SETUP.pdf_tools_status('/owned/masc')
        self.assertEqual(run.call_args.kwargs['timeout'], SETUP.PDF_TOOLS_PROBE_TIMEOUT_SECONDS)


class InvalidWorkspaceDiagnostic(StepByStep):
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
            ('runtime_configuration', 'invalid', 'The workspace runtime.toml is unreadable.'),
            ('keeper_persistence', 'satisfied', 'Persisted Keeper history: imp.')))

    def test_invalid_check_is_named_with_its_reason(self):
        errors = io.StringIO()
        with patch.object(SETUP, 'onboarding_status', return_value=self.broken()), \
                patch.object(SETUP, 'pick', return_value=[2]), \
                contextlib.redirect_stderr(errors):
            SETUP.journey('masc', '/workspace', None, 30, resume=True)
        self.assertIn('runtime_configuration', errors.getvalue())
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
            ('keeper_persistence', 'satisfied')), opening='open_existing_history')
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

    def test_advisory_invalid_check_is_named_and_history_still_opens(self):
        # Measured 2026-09-15: a browser lane launcher on 64850 against a
        # workspace connection on 61372 sent every bare `masc` back to question 1
        # although imp's history was readable. The binary now says the lane is
        # advisory; the journey prints it and opens the conversation.
        state = observation('/workspace', (
            ('workspace', 'satisfied'),
            ('keeper_persistence', 'satisfied'),
            ('browser_lane', 'invalid', 'The browser lane launcher targets port 64850 '
             'while the workspace connection port is 61372.')), opening='open_existing_history')
        errors = io.StringIO()
        with patch.object(SETUP, 'onboarding_status', return_value=state), \
                patch.object(SETUP, 'workspace_port', return_value=61372), \
                patch.object(SETUP, 'select_setup_server', return_value=61372), \
                patch.object(SETUP, 'open_workspace', return_value=0) as open_workspace, \
                patch.object(SETUP, 'pick') as pick, \
                contextlib.redirect_stderr(errors):
            code = SETUP.journey('masc', '/workspace', None, 30, resume=True)
        self.assertEqual(code, 0)
        open_workspace.assert_called_once_with('masc', '/workspace', 61372)
        pick.assert_not_called()
        self.assertIn('browser_lane', errors.getvalue())
        self.assertIn('64850', errors.getvalue())

    def test_fresh_workspace_still_opens_the_wizard(self):
        state = observation(None, (
            ('workspace', 'needs_setup'),))
        with patch.object(SETUP, 'onboarding_status', return_value=state), \
                patch.object(SETUP, 'pick', return_value=[2]) as pick, \
                contextlib.redirect_stderr(io.StringIO()):
            code = SETUP.journey('masc', None, None, 30, resume=True)
        self.assertEqual(code, 0)
        pick.assert_called_once()


class FailedSaveReporting(StepByStep):
    """A save that died in validation is not the operator deferring the step.

    Both paths leave the wizard without a model connection, but only one of
    them wrote anything. Reporting a saved workspace and exit 0 for the other
    makes the last line the operator reads a false one.
    """

    def run_journey(self, wizard_result):
        fresh = observation(None, (
            ('workspace', 'needs_setup'),))
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

    def test_usage_limited_save_goes_on_to_the_sandbox_step(self):
        # The model was saved; only its check was declined for the account's
        # usage. That is not the operator finishing later.
        with patch.object(SETUP, 'select_local_voice'), \
                patch.object(SETUP, 'sandbox_journey', return_value=0) as sandbox:
            code, errors = self.run_journey(
                dict(configured=True, readiness='usage_limited', base_path='/workspace'))
        self.assertEqual(code, 0)
        sandbox.assert_called_once()
        self.assertNotIn('workspace is saved', errors)

APPLE_ARGS = ['--sandbox-profile', 'microvm', '--microvm-backend', 'apple_container']


def sandbox_row(backend, state, reason=''):
    return dict(id=backend, state=state, reason=reason,
                setup_args=APPLE_ARGS if backend == 'apple_container' else ['--sandbox-profile', 'docker'],
                capabilities=dict(network_modes=['none', 'inherit']))


def sandbox_catalog_of(*rows, configured=None):
    return dict(schema='masc.sandbox_readiness.v1', candidates=list(rows), configured_selection=configured)


def actions_of(*ids):
    return dict(schema='masc.prerequisite_actions.v1', actions=[dict(id=value) for value in ids])


class OfficialClientLookup(unittest.TestCase):
    """The wizard asks masc where a client runs from and looks for none itself,
    so its list, its selection and the runtime's verification agree (#37747).
    """

    def receipt(self, path, schema='masc.runtime_client_path.v1', code=0):
        return completed(json.dumps(dict(schema=schema, client='claude-code', command='claude', path=path)), code)

    def test_the_path_is_masc_s_answer(self):
        with patch.object(SETUP.subprocess, 'run', return_value=self.receipt('/home/u/.local/bin/claude')) as run:
            self.assertEqual(SETUP.official_client_path('/owned/masc', 'claude_code', 'claude'),
                             '/home/u/.local/bin/claude')
        self.assertEqual(run.call_args.args[0],
                         ['/owned/masc', 'runtime-client-path', '--client', 'claude-code', '--command', 'claude'])
        with patch.object(SETUP.subprocess, 'run', return_value=self.receipt(None)):
            self.assertIsNone(SETUP.official_client_path('/owned/masc', 'claude_code', 'claude'))

    def test_an_http_connection_asks_nothing(self):
        with patch.object(SETUP.subprocess, 'run') as run:
            self.assertIsNone(SETUP.official_client_path('/owned/masc', 'openai_compatible', ''))
            self.assertIsNone(SETUP.official_client_path('/owned/masc', 'ollama', 'ollama'))
        run.assert_not_called()

    def test_an_answer_that_is_not_the_lookup_s_is_an_error_not_an_absence(self):
        for broken in (self.receipt(None, code=1), self.receipt(None, schema='other'), completed('not json')):
            with self.subTest(stdout=broken.stdout, code=broken.returncode), \
                    patch.object(SETUP.subprocess, 'run', return_value=broken), \
                    self.assertRaises(SETUP.SetupError):
                SETUP.official_client_path('/owned/masc', 'claude_code', 'claude')

    def test_the_list_says_what_the_lookup_found(self):
        inventory = dict(runtimes=[], integrations=[
            dict(id='claude-code', display_name='Claude Code', protocol='claude-code', command='claude',
                 origin='runtime_config', setup_support='new_connection')])
        for muse_path in (None, '/home/u/.local/bin/muse'):
            with self.subTest(muse_path=muse_path):
                located = {('claude_code', 'claude'): '/home/u/.local/bin/claude',
                           ('codex', 'codex'): None, ('muse', 'muse'): muse_path}
                with patch.object(SETUP, 'official_client_path',
                                  side_effect=lambda binary, choice, command: located[(choice, command)]):
                    sources = SETUP.connection_sources('/owned/masc', inventory)
                claude = next(source for source in sources if source['choice'] == 'claude_code')
                self.assertEqual(claude['command_path'], '/home/u/.local/bin/claude')
                self.assertIn('CLI found', SETUP.source_label(claude))
                self.assertFalse(any(source['choice'] == 'codex' for source in sources))
                muse = [source for source in sources if source['choice'] == 'muse']
                if muse_path is None:
                    self.assertEqual(muse, [])
                else:
                    self.assertEqual(len(muse), 1)
                    self.assertEqual(muse[0]['command_path'], muse_path)
                    self.assertIn('CLI found', SETUP.source_label(muse[0]))
                claude['command_path'] = None
                self.assertIn('CLI needs installation', SETUP.source_label(claude))

    @unittest.skipUnless(BINARY, 'requires CI-built native executable')
    def test_masc_finds_the_client_the_shell_has_not_yet(self):
        """The issue's shape: the installer wrote ~/.local/bin/claude as a link,
        and the shell masc runs from has no ~/.local/bin on PATH."""
        with tempfile.TemporaryDirectory() as home:
            versions = Path(home, '.local/share/claude/versions/2.0.0')
            versions.mkdir(parents=True)
            real = versions / 'claude'
            real.write_text('#!/bin/sh\necho fixture\n')
            real.chmod(0o700)
            link = Path(home, '.local/bin/claude')
            link.parent.mkdir(parents=True)
            link.symlink_to(real)
            elsewhere = Path(home, 'elsewhere')
            elsewhere.mkdir()
            on_path = elsewhere / 'claude'
            on_path.write_text('#!/bin/sh\necho other\n')
            on_path.chmod(0o700)
            def ask(path, *arguments):
                env = dict(os.environ, HOME=home, PATH=path)
                result = subprocess.run([BINARY, 'runtime-client-path', '--client', 'claude-code'] + list(arguments),
                                        env=env, cwd=home, capture_output=True, text=True, timeout=30)
                self.assertEqual(result.returncode, 0, result.stderr)
                receipt = json.loads(result.stdout)
                self.assertEqual(receipt['schema'], 'masc.runtime_client_path.v1')
                return receipt['path']
            self.assertEqual(ask('/usr/bin:/bin'), str(link), 'the vendor directory, and the link as the link')
            self.assertEqual(ask(str(elsewhere) + ':/usr/bin:/bin'), str(on_path), 'PATH first, as the shell finds it')
            self.assertIsNone(ask('/usr/bin:/bin', '--command', 'my-claude'),
                              'a custom name is not looked for in the vendor directory')


    @unittest.skipUnless(BINARY, 'requires CI-built native executable')
    def test_a_subcommand_spawns_the_client_the_lookup_finds(self):
        """The web setup path hands a configured command to these subcommands,
        which spawn it. With ~/.local/bin off PATH the spawn used to fail as
        "not found"; the fake client publishes its own effort metadata."""
        with tempfile.TemporaryDirectory() as home:
            marker = Path(home, 'spawned')
            client = Path(home, '.local/bin/codex')
            client.parent.mkdir(parents=True)
            client.write_text('''#!/usr/bin/env python3
import json, os, pathlib, sys
(pathlib.Path(os.environ['HOME']) / 'spawned').write_text('spawned')
for line in sys.stdin:
    request = json.loads(line)
    method = request['method']
    if method == 'initialized': continue
    if method == 'initialize': result = {'userAgent':'journey-fixture/1'}
    elif method == 'account/read': result = {'account':{'type':'apiKey'}, 'requiresOpenaiAuth':True}
    elif method == 'model/list': result = {'data':[{
        'id':'journey-ui-id', 'model':'journey-model', 'displayName':'Journey model', 'isDefault':True,
        'supportedReasoningEfforts':[
            {'reasoningEffort':'medium', 'description':'Everyday tasks'},
            {'reasoningEffort':'future-effort', 'description':'New account-specific level'}],
        'defaultReasoningEffort':'future-effort'}], 'nextCursor':None}
    else: raise AssertionError('unexpected operation ' + method)
    print(json.dumps({'id':request['id'],'result':result}), flush=True)
''')
            client.chmod(0o700)
            env = dict(os.environ, HOME=home, PATH='/usr/bin:/bin')
            env.pop('CODEX_INSTALL_DIR', None)
            result = subprocess.run([BINARY, 'runtime-codex-models', '--cli-path', 'codex'],
                                    env=env, cwd=home, capture_output=True, text=True, timeout=60)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertTrue(marker.is_file(),
                            'masc did not spawn the client in the vendor directory: ' + result.stderr)
            receipt = json.loads(result.stdout)
            self.assertEqual(receipt['models'][0]['id'], 'journey-model')
            self.assertEqual(receipt['models'][0]['supported_reasoning_efforts'],
                             ['medium', 'future-effort'])
            self.assertEqual(receipt['models'][0]['default_reasoning_effort'], 'future-effort')


class QuickSetup(unittest.TestCase):
    """One screen, then straight through: workspace, Claude Code, text only, sandbox.

    A fresh Mac asked eleven questions before imp answered (2026-09-15). The
    plan is offered only where it has a model to go to, and every step that
    cannot decide on its own hands back to the screen that step already has.
    """

    def test_without_claude_code_there_is_no_plan(self):
        with patch.object(SETUP, 'official_client_path', return_value=None) as located, \
                patch.object(SETUP, 'sandbox_catalog') as catalog:
            self.assertIsNone(SETUP.quick_plan('masc', '/workspace'))
        located.assert_called_once_with('masc', 'claude_code', 'claude')
        catalog.assert_not_called()

    def test_a_lookup_that_cannot_run_offers_no_plan(self):
        with patch.object(SETUP, 'official_client_path', side_effect=SETUP.SetupError('no masc')), \
                patch.object(SETUP, 'sandbox_catalog') as catalog:
            self.assertIsNone(SETUP.quick_plan('masc', '/workspace'))
        catalog.assert_not_called()

    def test_the_plan_goes_to_apple_container_wherever_the_host_supports_it(self):
        catalog = sandbox_catalog_of(sandbox_row('apple_container', 'missing_prerequisite'),
                                     sandbox_row('docker', 'service_ready'))
        with patch.object(SETUP, 'official_client_path', return_value='/bin/claude'), \
                patch.object(SETUP, 'sandbox_catalog', return_value=catalog):
            plan = SETUP.quick_plan('masc', '/workspace')
        self.assertEqual(plan, dict(model='claude-sonnet-5-5', sandbox='apple_container', sandbox_ready=False))

    def test_elsewhere_the_plan_takes_a_running_docker_or_leaves_the_sandbox_to_step_4(self):
        unsupported = sandbox_row('apple_container', 'unsupported_host')
        for docker, expected in ((sandbox_row('docker', 'service_ready'), 'docker'),
                                 (sandbox_row('docker', 'probe_failed'), None)):
            with patch.object(SETUP, 'official_client_path', return_value='/bin/claude'), \
                    patch.object(SETUP, 'sandbox_catalog', return_value=sandbox_catalog_of(unsupported, docker)):
                self.assertEqual(SETUP.quick_plan('masc', '/workspace')['sandbox'], expected)

    def test_an_unreadable_sandbox_catalog_offers_no_plan(self):
        with patch.object(SETUP, 'official_client_path', return_value='/bin/claude'), \
                patch.object(SETUP, 'sandbox_catalog', side_effect=SETUP.SetupError('unreadable')):
            self.assertIsNone(SETUP.quick_plan('masc', '/workspace'))

    def journey(self, choices, plan):
        with patch.object(SETUP, 'onboarding_status', return_value=observation()), \
                patch.object(SETUP, 'quick_plan', return_value=plan), \
                patch.object(SETUP, 'pick', side_effect=choices) as picker, \
                patch.object(SETUP, 'workspace_check', return_value=dict(base_path='/workspace')), \
                patch.object(SETUP, 'workspace_port', return_value=8945), \
                patch.object(SETUP, 'select_setup_server', return_value=8945), \
                patch.object(SETUP, 'wizard', return_value=dict(readiness='verified')) as models, \
                patch.object(SETUP, 'select_local_voice') as voice, \
                patch.object(SETUP, 'sandbox_journey', return_value=0) as sandbox, \
                patch.object(SETUP.subprocess, 'run', return_value=subprocess.CompletedProcess([], 0)), \
                contextlib.redirect_stderr(io.StringIO()) as errors:
            code = SETUP.journey('/bin/masc', None, 8945, 10)
        return code, picker, models, voice, sandbox, errors.getvalue()

    def test_quick_setup_is_one_question_before_imp(self):
        plan = dict(model='claude-sonnet-5', sandbox='apple_container', sandbox_ready=False)
        code, picker, models, voice, sandbox, errors = self.journey([[0]], plan)
        self.assertEqual(code, 0)
        self.assertEqual([call.args[0] for call in picker.call_args_list], ['Quick setup'])
        models.assert_called_once_with('/bin/masc', '/workspace', 10, quick_model='claude-sonnet-5')
        voice.assert_not_called()
        sandbox.assert_called_once_with('/bin/masc', '/workspace', 8945, quick_backend='apple_container', quick=True)
        self.assertIn('Claude Code / claude-sonnet-5', errors)

    def test_choosing_each_step_is_the_journey_as_it_was(self):
        plan = dict(model='claude-sonnet-5', sandbox='apple_container', sandbox_ready=False)
        code, picker, models, voice, sandbox, _ = self.journey([[1], [0]], plan)
        self.assertEqual(code, 0)
        self.assertEqual([call.args[0] for call in picker.call_args_list], ['Quick setup', '1 \u00b7 Your workspace'])
        models.assert_called_once_with('/bin/masc', '/workspace', 10, quick_model=None)
        voice.assert_called_once()
        sandbox.assert_called_once_with('/bin/masc', '/workspace', 8945, quick_backend=None, quick=False)

    def test_finishing_later_from_the_plan_writes_nothing(self):
        plan = dict(model='claude-sonnet-5', sandbox=None, sandbox_ready=False)
        code, picker, models, _, sandbox, _ = self.journey([[2]], plan)
        self.assertEqual(code, 0)
        models.assert_not_called()
        sandbox.assert_not_called()

    def test_the_quick_model_skips_both_connection_screens_and_is_still_checked(self):
        runtime = 'fixture.native-model'
        spec = dict(choice='claude_code', command='/owned/claude', model='claude-sonnet-5',
                    max_context=200000, tools=True, streaming=False)
        with patch.object(SETUP, 'render', return_value=(runtime, b'', b'')), \
                patch.object(SETUP, 'configured_inventory', return_value=dict(runtimes=[], setup_revision='a' * 64)), \
                patch.object(SETUP, 'quick_connection', return_value=([runtime], [spec], {runtime: 'Claude Code / claude-sonnet-5'})), \
                patch.object(SETUP, 'select_connections') as screens, \
                patch.object(SETUP, 'pick') as picker, \
                patch.object(SETUP, 'configure_many', return_value=dict(readiness='verified')) as verify, \
                contextlib.redirect_stderr(io.StringIO()):
            result = SETUP.wizard('/bin/masc', '/workspace', 10, quick_model='claude-sonnet-5')
        self.assertEqual(result['readiness'], 'verified')
        screens.assert_not_called()
        picker.assert_not_called()
        self.assertEqual(verify.call_args.args[3], [runtime])
        self.assertTrue(verify.call_args.kwargs['verify'])

    def test_a_quick_model_that_fails_its_check_goes_back_to_the_screens_once(self):
        runtime = 'fixture.native-model'
        spec = dict(choice='claude_code', command='/owned/claude', model='claude-sonnet-5',
                    max_context=200000, tools=True, streaming=False)
        chosen = ([runtime], [spec], {runtime: 'Claude Code / claude-sonnet-5'})
        with patch.object(SETUP, 'render', return_value=(runtime, b'', b'')), \
                patch.object(SETUP, 'configured_inventory', return_value=dict(runtimes=[], setup_revision='a' * 64)), \
                patch.object(SETUP, 'quick_connection', return_value=chosen) as quick, \
                patch.object(SETUP, 'select_connections', return_value=([runtime], [spec], dict(chosen[2]))) as screens, \
                patch.object(SETUP, 'pick', side_effect=[[2], [0]]), \
                patch.object(SETUP, 'configure_many', side_effect=[SETUP.VerificationError(runtime), dict(readiness='verified')]), \
                contextlib.redirect_stderr(io.StringIO()):
            result = SETUP.wizard('/bin/masc', '/workspace', 10, quick_model='claude-sonnet-5')
        self.assertEqual(result['readiness'], 'verified')
        quick.assert_called_once()
        screens.assert_called_once()

    def test_the_quick_connection_needs_claude_code_and_the_model_in_its_catalog(self):
        claude = dict(choice='claude_code', label='Claude Code')
        with patch.object(SETUP, 'connection_sources', return_value=[]), contextlib.redirect_stderr(io.StringIO()):
            self.assertIsNone(SETUP.quick_connection('masc', {}, 10, None, 'claude-sonnet-5'))
        with patch.object(SETUP, 'connection_sources', return_value=[claude]), \
                patch.object(SETUP, 'prepare_connection', side_effect=lambda _binary, source, _: source), \
                patch.object(SETUP, 'source_models', return_value=([dict(id='claude-opus-5-5')], 'catalog')), \
                contextlib.redirect_stderr(io.StringIO()):
            self.assertIsNone(SETUP.quick_connection('masc', {}, 10, None, 'claude-sonnet-5'))
        with patch.object(SETUP, 'connection_sources', return_value=[claude]), \
                patch.object(SETUP, 'prepare_connection', side_effect=lambda _binary, source, _: source), \
                patch.object(SETUP, 'source_models', return_value=([dict(id='claude-sonnet-5')], 'catalog')), \
                patch.object(SETUP, 'resolve_model_spec', return_value=('rid', dict(model='claude-sonnet-5'))):
            self.assertEqual(SETUP.quick_connection('masc', {}, 10, None, 'claude-sonnet-5'),
                             (['rid'], [dict(model='claude-sonnet-5')], {'rid': 'Claude Code / claude-sonnet-5'}))

    def quick_sandbox(self, catalogs, actions, which, outcome='commands_completed_recheck_required'):
        with patch.object(SETUP, 'sandbox_catalog', side_effect=catalogs), \
                patch.object(SETUP, 'prerequisite_catalog', side_effect=actions), \
                patch.object(SETUP.shutil, 'which', side_effect=which), \
                patch.object(SETUP, 'execute_prerequisite', return_value=outcome) as execute, \
                contextlib.redirect_stderr(io.StringIO()):
            arguments = SETUP.quick_sandbox('/bin/masc', '/workspace', 'apple_container')
        return arguments, [call.args[2] for call in execute.call_args_list]

    def test_a_fresh_mac_gets_apple_container_installed_started_and_building_without_rosetta(self):
        missing = actions_of('apple_container_verified_install', 'apple_container_official_install', 'apple_container_start')
        installed = iter([None, '/usr/local/bin/container', '/usr/local/bin/container'])
        arguments, steps = self.quick_sandbox(
            [sandbox_catalog_of(sandbox_row('apple_container', 'missing_prerequisite', 'container: executable missing')),
             sandbox_catalog_of(sandbox_row('apple_container', 'probe_failed', 'check failed')),
             sandbox_catalog_of(sandbox_row('apple_container', 'missing_prerequisite', 'Image builds use Rosetta')),
             sandbox_catalog_of(sandbox_row('apple_container', 'service_ready'))],
            [missing, missing, actions_of('apple_container_build_without_rosetta', 'rosetta_install')],
            lambda _name: next(installed))
        self.assertEqual(steps, ['apple_container_verified_install', 'apple_container_start',
                                 'apple_container_build_without_rosetta'])
        self.assertEqual(arguments, APPLE_ARGS + ['--network-mode', 'inherit'])

    def test_a_failed_step_hands_the_sandbox_back_to_step_4(self):
        arguments, steps = self.quick_sandbox(
            [sandbox_catalog_of(sandbox_row('apple_container', 'missing_prerequisite'))],
            [actions_of('apple_container_verified_install', 'apple_container_start')],
            lambda _name: None, outcome='failed')
        self.assertIsNone(arguments)
        self.assertEqual(steps, ['apple_container_verified_install'])

    def test_each_action_runs_once_so_a_service_that_never_answers_ends_at_step_4(self):
        stuck = sandbox_catalog_of(sandbox_row('apple_container', 'probe_failed'))
        offered = actions_of('apple_container_verified_install', 'apple_container_start')
        arguments, steps = self.quick_sandbox([stuck] * 3, [offered] * 3, lambda _name: '/usr/local/bin/container')
        self.assertIsNone(arguments)
        self.assertEqual(steps, ['apple_container_start', 'apple_container_verified_install'])

    def test_a_configured_apple_container_keeps_its_network_policy(self):
        ready = sandbox_catalog_of(sandbox_row('apple_container', 'service_ready'),
                                   configured=dict(backend='apple_container', network_mode='none'))
        arguments, steps = self.quick_sandbox([ready], [], lambda _name: None)
        self.assertEqual(arguments, APPLE_ARGS)
        self.assertEqual(steps, [])

    def test_the_sandbox_screen_takes_over_when_quick_setup_cannot_finish(self):
        with patch.object(SETUP, 'quick_sandbox', return_value=None), \
                patch.object(SETUP, 'select_sandbox', return_value=None) as screen, \
                contextlib.redirect_stderr(io.StringIO()):
            self.assertEqual(SETUP.sandbox_journey('/bin/masc', '/workspace', 8945, quick_backend='apple_container'), 0)
        screen.assert_called_once_with('/bin/masc', '/workspace', port=8945)


if __name__ == '__main__':
    unittest.main()
