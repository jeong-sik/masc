"""Acceptance evidence must join an observed Docker listing, not model prose."""
import copy
import importlib.util
import json
from pathlib import Path
import sqlite3
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

    def test_prior_history_rejected_before_server_or_reconfiguration(self):
        for kind in ('raw-traces', 'turn-records', 'execution-receipts'):
            with self.subTest(kind=kind), tempfile.TemporaryDirectory() as directory:
                args, base, _home, output = self.seed(Path(directory))
                history = base / '.masc/keepers/imp' / kind / 'prior.jsonl'
                history.parent.mkdir(parents=True)
                history.write_text(json.dumps(dict(record_type='tool_execution_finished',
                    tool_name='WebFetch', tool_error=False)) + '\n')
                before = acceptance.configuration_hashes(base)
                with patch.object(acceptance.subprocess, 'Popen') as start:
                    with self.assertRaisesRegex(RuntimeError, 'prior imp history'):
                        acceptance.measure(args)
                    start.assert_not_called()
                self.assertEqual(acceptance.configuration_hashes(base), before)
                self.assertFalse((output / 'receipt.json').exists())

    def test_each_invocation_gets_distinct_request_ids(self):
        all_ids = set()
        for _ in range(2):
            with tempfile.TemporaryDirectory() as directory:
                args, _base, _home, output = self.seed(Path(directory))
                with patch.object(acceptance.subprocess, 'Popen', side_effect=RuntimeError('stop')):
                    with self.assertRaisesRegex(RuntimeError, 'stop'):
                        acceptance.measure(args)
                record = json.loads((output / 'invocation.json').read_text())
                ids = record['request_ids']
                self.assertEqual(len(set(ids)), 4)
                self.assertTrue(all(record['invocation_id'] in value for value in ids))
                self.assertFalse(set(ids) & all_ids)
                all_ids.update(ids)

    def test_observed_model_requires_each_prompt_and_rejects_mismatch(self):
        prompts = ['hello', 'fetch']
        traces = [dict(record_type='run_started', prompt=prompt, model='chosen-model')
                  for prompt in prompts]
        self.assertEqual(acceptance.observed_model(traces, prompts, 'chosen-model'), 'chosen-model')
        for rows in (traces[:1], traces + [dict(record_type='run_started',
                prompt='fetch', model='other-model')],
                [dict(row, model=None) for row in traces]):
            with self.subTest(rows=rows), self.assertRaisesRegex(RuntimeError, 'observed imp runtime'):
                acceptance.observed_model(rows, prompts, 'chosen-model')

    def test_existing_board_and_tasks_are_captured_before_new_evidence(self):
        with tempfile.TemporaryDirectory() as directory:
            _args, base, _home, _output = self.seed(Path(directory))
            self.assertEqual(acceptance.persisted_ids(base), (set(), set()))
            (base / '.masc/board_posts.jsonl').write_text('{"id":"old-post"}\n')
            (base / '.masc/tasks').mkdir()
            (base / '.masc/tasks/backlog.json').write_text('{"tasks":[{"id":"old-task"}]}')
            self.assertEqual(acceptance.persisted_ids(base), ({'old-post'}, {'old-task'}))

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


class QueuedChatOperations(unittest.TestCase):
    """A workspace whose queue still holds work is not an unmeasured workspace.

    The record directories hold what a past run finished. An operation that
    never ran leaves them empty and waits in the keeper's own queue, which the
    server drains on the next boot -- and a raw-trace record carries no request
    id, so a drained leftover is counted as this run's result.
    """

    def workspace(self, states=None):
        base = Path(tempfile.mkdtemp())
        keeper = base / '.masc/keepers/imp'
        keeper.mkdir(parents=True)
        if states is not None:
            connection = sqlite3.connect(keeper / 'chat-operations.sqlite3')
            connection.execute(
                'CREATE TABLE operations (operation_id TEXT PRIMARY KEY, state TEXT NOT NULL)')
            for index, state in enumerate(states):
                connection.execute('INSERT INTO operations VALUES (?, ?)',
                                   (f'op-{index}', state))
            connection.commit()
            connection.close()
        return base

    def test_a_workspace_with_no_queue_is_accepted(self):
        acceptance.require_unmeasured_workspace(self.workspace())

    def test_a_drained_queue_is_accepted(self):
        acceptance.require_unmeasured_workspace(
            self.workspace(['succeeded', 'failed', 'cancelled']))

    def test_outstanding_operations_are_refused(self):
        for states in (['queued'], ['running'], ['succeeded', 'queued']):
            with self.subTest(states=states):
                with self.assertRaises(RuntimeError) as raised:
                    acceptance.require_unmeasured_workspace(self.workspace(states))
                self.assertIn('waiting to run', str(raised.exception))

    def test_an_unreadable_queue_is_not_called_empty(self):
        base = self.workspace()
        (base / '.masc/keepers/imp/chat-operations.sqlite3').write_text('not a database')
        with self.assertRaises(RuntimeError) as raised:
            acceptance.require_unmeasured_workspace(base)
        self.assertIn('cannot read the chat operation queue', str(raised.exception))


class SiblingBrowserOracle(unittest.TestCase):
    def test_custom_oracle_directory_selects_its_own_browser_bytes(self):
        with tempfile.TemporaryDirectory() as directory:
            folder = Path(directory) / 'custom-oracles'
            folder.mkdir()
            script = folder / 'imp-onboarding-acceptance.py'
            script.write_bytes(Path(acceptance.__file__).read_bytes())
            selected = importlib.util.spec_from_file_location('relocated_acceptance', script)
            relocated = importlib.util.module_from_spec(selected)
            selected.loader.exec_module(relocated)
            self.assertEqual(relocated.BROWSER_SCRIPT, folder / 'imp-onboarding-browser.cjs')
            self.assertNotEqual(relocated.BROWSER_SCRIPT, Path(directory) / 'scripts/imp-onboarding-browser.cjs')


if __name__ == '__main__':
    unittest.main()
