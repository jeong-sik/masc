"""Acceptance evidence must join an observed Docker listing, not model prose."""
import copy
import importlib.util
import json
from pathlib import Path
import unittest

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
        for value in ({'script': 'pwd; ls -la'}, {'argv': ['sh', '-lc', 'pwd; ls -la']}):
            with self.subTest(value=value):
                trace = listing_trace(value)
                self.assertEqual(acceptance.directory_execution(trace)['completion'], trace[1])

    def test_nonlisting_or_arbitrary_argv_rejected(self):
        for value in ({'script': 'pwd'}, {'script': 'ls -la'},
                      {'argv': ['echo', 'pwd; ls -la']},
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


if __name__ == '__main__':
    unittest.main()
