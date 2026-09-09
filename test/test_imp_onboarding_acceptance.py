"""Acceptance evidence must join an observed Docker listing, not model prose."""
import copy
import importlib.util
import json
from pathlib import Path
import unittest
from unittest.mock import patch
from types import SimpleNamespace
import tempfile

spec = importlib.util.spec_from_file_location(
    'imp_acceptance', Path(__file__).parents[1] / 'scripts/imp-onboarding-acceptance.py')
acceptance = importlib.util.module_from_spec(spec)
spec.loader.exec_module(acceptance)


def listing_trace(tool_input):
    identity = dict(worker_run_id='worker', session_id='session', tool_use_id='tool',
                    tool_name='Execute')
    result = dict(ok=True, via='docker', sandbox_profile='docker',
                  status=dict(kind='exit', code=0), cwd='/home/keeper/playground/imp',
                  output_completeness='complete', output=(
                      '/home/keeper/playground/imp\n'
                      'drwxr-xr-x 2 keeper keeper 4096 Sep 9 12:00 .\n'
                      'drwxr-xr-x 3 keeper keeper 4096 Sep 9 12:00 ..\n'))
    return [dict(identity, record_type='tool_execution_started', tool_input=tool_input),
            dict(identity, record_type='tool_execution_finished', tool_error=False,
                 tool_result=json.dumps(result))]


class DirectoryEvidence(unittest.TestCase):
    def test_script_and_observed_shell_argv(self):
        inputs = [{'script': 'pwd; ls -la'}] + [
            {'argv': [shell, flag, 'pwd; ls -la']}
            for shell in ('sh', 'bash', '/bin/sh', '/bin/bash')
            for flag in ('-c', '-lc')]
        for value in inputs:
            with self.subTest(value=value):
                trace = listing_trace(value)
                self.assertEqual(acceptance.directory_execution(trace)['completion'], trace[1])

    def test_separate_calls_require_same_turn_and_cwd(self):
        pwd = listing_trace({'argv': ['pwd']})
        ls = listing_trace({'argv': ['ls', '-la']})
        for event in ls:
            event['tool_use_id'] = 'listing-tool'
        result = json.loads(pwd[1]['tool_result'])
        result['output'] = '/home/keeper/playground/imp\n'
        pwd[1]['tool_result'] = json.dumps(result)
        result = json.loads(ls[1]['tool_result'])
        result['output'] = result['output'].split('\n', 1)[1]
        ls[1]['tool_result'] = json.dumps(result)
        proof = acceptance.directory_execution(pwd + ls)
        self.assertEqual(proof['pwd']['completion'], pwd[1])
        self.assertEqual(proof['listing']['completion'], ls[1])
        for field in ('worker_run_id', 'session_id'):
            mismatched = copy.deepcopy(ls)
            for event in mismatched:
                event[field] = 'another-turn'
            with self.subTest(field=field), self.assertRaises(RuntimeError):
                acceptance.directory_execution(pwd + mismatched)
        for field, value in [('cwd', '/tmp'), ('via', 'host'),
                             ('status', dict(kind='exit', code=1)),
                             ('output_completeness', 'truncated')]:
            mismatched = copy.deepcopy(ls)
            result = json.loads(mismatched[1]['tool_result'])
            result[field] = value
            mismatched[1]['tool_result'] = json.dumps(result)
            with self.subTest(field=field), self.assertRaises(RuntimeError):
                acceptance.directory_execution(pwd + mismatched)

    def test_nonlisting_or_arbitrary_argv_rejected(self):
        for value in ({'script': 'pwd'}, {'script': 'ls -la'},
                      {'argv': ['echo', 'pwd; ls -la']},
                      {'argv': ['sh', '-x', 'pwd; ls -la']},
                      {'argv': ['env', 'sh', '-lc', 'pwd; ls -la']},
                      {'argv': ['sh', '-lc', 'pwd; ls -la', 'extra']},
                      {'argv': ['sh', '-lc', 'pwd; ls /tmp']},
                      {'argv': ['sh', '-lc', 'pwd | ls -la']}):
            with self.subTest(value=value), self.assertRaises(RuntimeError):
                acceptance.directory_execution(listing_trace(value))

    def test_completion_and_identity_must_match(self):
        original = listing_trace({'argv': ['sh', '-lc', 'pwd; ls -la']})
        for field, value in [('via', 'host'), ('sandbox_profile', 'remote_ssh'),
                             ('status', dict(kind='exit', code=1)),
                             ('cwd', '/tmp'), ('output_completeness', 'truncated'),
                             ('output', '/home/keeper/playground/imp\n')]:
            trace = copy.deepcopy(original)
            result = json.loads(trace[1]['tool_result'])
            result[field] = value
            trace[1]['tool_result'] = json.dumps(result)
            with self.subTest(field=field), self.assertRaises(RuntimeError):
                acceptance.directory_execution(trace)
        for field in ('worker_run_id', 'session_id', 'tool_use_id'):
            trace = copy.deepcopy(original)
            trace[1][field] = 'unrelated'
            with self.subTest(field=field), self.assertRaises(RuntimeError):
                acceptance.directory_execution(trace)


class ExistingWorkspace(unittest.TestCase):
    def seed(self, root):
        root = root.resolve()
        base, home, output = root / 'workspace', root / 'home', root / 'evidence'
        for path in (base, home, output):
            path.mkdir()
        for name in acceptance.PRESERVED_CONFIGURATION:
            path = base / '.masc/config' / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text('preserve chosen runtime and imp: ' + name)
        auth = home / '.codex/auth.json'
        auth.parent.mkdir()
        auth.write_text('test-only-credential')
        args = SimpleNamespace(existing_base=str(base), existing_home=str(home),
            codex_auth=str(auth), work_parent=str(root), binary='/unused/masc',
            output=str(output), model='test-model', context=128000)
        return args, base, home, output

    def test_existing_measure_reaches_server_without_init_copy_or_runtime_setup(self):
        with tempfile.TemporaryDirectory() as directory:
            args, base, home, output = self.seed(Path(directory))
            before = acceptance.configuration_hashes(base)
            auth = home / '.codex/auth.json'
            inode = auth.stat().st_ino
            class ServerBoundary(Exception):
                pass
            with patch.object(acceptance.subprocess, 'run', side_effect=AssertionError('reconfigured')) as run, \
                 patch.object(acceptance.shutil, 'copyfile', side_effect=AssertionError('copied auth')), \
                 patch.object(acceptance.subprocess, 'Popen', side_effect=ServerBoundary) as start:
                with self.assertRaises(ServerBoundary):
                    acceptance.measure(args)
                run.assert_not_called()
                self.assertEqual(start.call_args.args[0][:4], ['/unused/masc', 'start', '--base-path', str(base)])
                self.assertEqual(start.call_args.kwargs['env']['HOME'], str(home))
            self.assertEqual(auth.stat().st_ino, inode)
            self.assertEqual(acceptance.configuration_hashes(base), before)
            receipt = json.loads((output / 'configuration-continuity.json').read_text())
            self.assertTrue(receipt['existing_workspace'])
            self.assertTrue(receipt['configuration_preserved'])
            self.assertEqual(receipt['sha256_before'], receipt['sha256_after'])
            self.assertNotIn(str(base), json.dumps(receipt))
            self.assertFalse((output / 'receipt.json').exists())

    def test_required_config_mutation_fails_but_generated_resources_do_not(self):
        with tempfile.TemporaryDirectory() as directory:
            args, base, _home, output = self.seed(Path(directory))
            with acceptance.acceptance_workspace(args, output):
                (base / '.masc/config/generated-cache.json').write_text('{}')
            with self.assertRaisesRegex(RuntimeError, 'changed'):
                with acceptance.acceptance_workspace(args, output):
                    (base / '.masc/config/runtime.toml').write_text('different runtime')
            self.assertFalse(json.loads((output / 'configuration-continuity.json').read_text())['configuration_preserved'])
            self.assertTrue(base.exists())

    def test_existing_mode_requires_both_paths_and_auth(self):
        with tempfile.TemporaryDirectory() as directory:
            args, _base, home, output = self.seed(Path(directory))
            args.existing_home = None
            with self.assertRaisesRegex(RuntimeError, 'together'):
                with acceptance.acceptance_workspace(args, output):
                    self.fail('unpaired path accepted')
            args.existing_home = str(home)
            (home / '.codex/auth.json').unlink()
            with self.assertRaisesRegex(RuntimeError, 'authentication'):
                with acceptance.acceptance_workspace(args, output):
                    self.fail('missing copied authentication accepted')

    def test_fresh_mode_still_copies_auth_and_removes_disposable_workspace(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / 'auth.json'
            source.write_text('test-only-credential')
            args = SimpleNamespace(existing_base=None, existing_home=None,
                                   codex_auth=str(source), work_parent=str(root))
            with acceptance.acceptance_workspace(args, root) as (base, home, continuity):
                self.assertEqual((home / '.codex/auth.json').read_text(), source.read_text())
                self.assertFalse(continuity['existing_workspace'])
                self.assertFalse(continuity['configuration_preserved'])
            self.assertFalse(base.exists())
            self.assertTrue(source.exists())


if __name__ == '__main__':
    unittest.main()
