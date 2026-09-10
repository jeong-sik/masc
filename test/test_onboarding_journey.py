"""Exercise fresh-home and interrupted setup through the shipped journey."""
import contextlib
import importlib.util
import io
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location('setup', ROOT / 'scripts/install-runtime-setup.py')
SETUP = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(SETUP)


def observation(base=None, checks=()):
    return dict(schema='masc.onboarding_status.v1', scope='configuration_observation',
                base_path=base, checks=[dict(id=name, condition=value) for name, value in checks])


class Journey(unittest.TestCase):
    def test_cancel_fresh_home_does_not_initialize_or_select_models(self):
        with patch.object(SETUP, 'onboarding_status', return_value=observation()), \
                patch.object(SETUP, 'pick', return_value=[2]), \
                patch.object(SETUP, 'workspace_check') as preflight, \
                patch.object(SETUP, 'wizard') as models, contextlib.redirect_stderr(io.StringIO()):
            self.assertEqual(SETUP.journey('/bin/masc', None, 8945, 10), 0)
        preflight.assert_not_called()
        models.assert_not_called()

    def test_default_workspace_is_selected_without_path_typing_and_native_owns_preparation(self):
        with tempfile.TemporaryDirectory() as home:
            base = str(Path(home) / 'MASC')
            with patch.object(SETUP, 'onboarding_status', return_value=observation()), \
                    patch.object(SETUP.Path, 'home', return_value=Path(home)), \
                    patch.object(SETUP, 'pick', return_value=[0]) as picker, \
                    patch.object(SETUP, 'workspace_check', return_value=dict(base_path=base)) as preflight, \
                    patch.object(SETUP, 'wizard', return_value=dict(readiness='verified')), \
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
                patch.object(SETUP, 'open_workspace', return_value=0) as opened, \
                patch.object(SETUP, 'pick') as picker:
            self.assertEqual(SETUP.journey('/bin/masc', None, 8945, 10, resume=True), 0)
        opened.assert_called_once_with('/bin/masc', '/workspace', 8945)
        picker.assert_not_called()

    def test_declaration_alone_never_skips_first_preparation(self):
        state = observation('/workspace', [('workspace', 'satisfied'), ('keeper_declaration', 'satisfied')])
        with patch.object(SETUP, 'onboarding_status', return_value=state), \
                patch.object(SETUP, 'pick', return_value=[2]), \
                patch.object(SETUP, 'open_workspace') as opened, contextlib.redirect_stderr(io.StringIO()):
            self.assertEqual(SETUP.journey('/bin/masc', None, 8945, 10, resume=True), 0)
        opened.assert_not_called()

    def test_failed_preparation_does_not_open_tui_or_repeat_model_selection(self):
        with patch.object(SETUP, 'onboarding_status', return_value=observation('/workspace')), \
                patch.object(SETUP, 'pick', side_effect=[[0], [1]]), \
                patch.object(SETUP, 'workspace_check', return_value=dict(base_path='/workspace')), \
                patch.object(SETUP, 'wizard', return_value=dict(readiness='verified')) as models, \
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
        with patch.object(SETUP, 'configured_inventory', return_value=dict(runtimes=[])), \
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


if __name__ == '__main__':
    unittest.main()
