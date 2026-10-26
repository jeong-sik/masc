#!/usr/bin/env python3
"""Exercise collection, planning, request effects and reconciliation offline."""
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

HERE = Path(__file__).resolve().parent
HEAD, BASE = "a" * 40, "b" * 40
SPEC = importlib.util.spec_from_file_location("review_worklist", HERE / "review-worklist.py")
M = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = M
SPEC.loader.exec_module(M)


def pull(number=1):
    return {"number": number, "title": f"PR {number}", "html_url": f"https://github.example/o/r/pull/{number}",
            "state": "open", "draft": False, "user": {"login": "author"},
            "head": {"sha": HEAD, "ref": f"fix/{number}"},
            "base": {"sha": BASE, "ref": "main"}, "stack": None,
            "created_at": f"2026-10-26T10:{number:02d}:00Z",
            "requested_reviewers": [], "requested_teams": []}


FAKE = r'''#!/usr/bin/env python3
import json, os, pathlib, sys
p = pathlib.Path(os.environ['WORKLIST_FIXTURE'])
s = json.loads(p.read_text())
args = sys.argv[1:]
assert args.pop(0) == 'api', args
paginated = '--paginate' in args
post = '--method' in args and args[args.index('--method')+1] == 'POST'
path = next(a for a in args if a.startswith('repos/'))
endpoint = path.removeprefix('repos/o/r/').split('?')[0]
s.setdefault('calls', []).append(('POST ' if post else 'GET ') + endpoint)
def done(value=None, error=None):
    p.write_text(json.dumps(s))
    if error:
        print(error, file=sys.stderr); sys.exit(1)
    print(json.dumps(value)); sys.exit(0)
if endpoint == s.get('fail_get') and not post:
    done(error='simulated read failure')
if endpoint == 'pulls':
    done(s.get('list_pages', [[v for v in s['pulls'].values() if v['state']=='open']]))
parts = endpoint.split('/')
number = parts[1]
pr = s['pulls'][number]
if parts[0] == 'issues':
    if number == s.get('fail_preflight_number') and s.get('detail_reads',{}).get(number,0) >= 2:
        done(error='late preflight failure')
    done(s.get('comment_pages', {}).get(number, [[]]))
if len(parts) == 2:
    counts = s.setdefault('detail_reads', {})
    counts[number] = counts.get(number, 0) + 1
    if counts[number] == 2:
        pr.update(s.get('preflight_change', {}))
    done(pr)
if parts[2] == 'reviews':
    done(s.get('review_pages', {}).get(number, [[]]))
assert parts[2] == 'requested_reviewers'
if not post:
    if s.get('post_seen') and s.get('readback_error'):
        done(error='simulated readback failure')
    done({'users':pr['requested_reviewers'], 'teams':pr['requested_teams']})
body = json.load(sys.stdin)
s.setdefault('posts', []).append({'number':int(number), **body})
s['post_seen'] = True
if s.get('post_error') != 'unapplied':
    existing = {r['login'] for r in pr['requested_reviewers']}
    pr['requested_reviewers'] += [{'login':r} for r in body['reviewers'] if r not in existing]
if s.get('after_post_change'):
    pr.update(s['after_post_change'])
if s.get('post_error'):
    done(error='simulated transport failure')
done(pr)
'''


class WorklistFlow(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="review-worklist-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.data = self.root / "state.json"
        self.fake = self.root / "gh"
        self.fake.write_text(FAKE)
        self.fake.chmod(0o755)
        self.state = {"pulls": {"1": pull()}}

    def run_cli(self, *, request=False):
        self.data.write_text(json.dumps(self.state))
        args = [sys.executable, "-B", str(HERE / "review-worklist.py"),
                "--repo", "o/r", "--gh", str(self.fake),
                "--reviewer", "reviewer-a", "--reviewer", "reviewer-b"]
        if request:
            args.append("--request")
        result = subprocess.run(args, text=True, capture_output=True,
            env=dict(os.environ, WORKLIST_FIXTURE=str(self.data)))
        return result, json.loads(result.stdout), json.loads(self.data.read_text())

    def test_default_only_plans_and_balances_all_pages(self):
        self.state['pulls']['2'] = pull(2)
        self.state['list_pages'] = [[pull(1)], [pull(2)]]
        result, out, state = self.run_cli()
        self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
        planned = [a for a in out['actions'] if a['assignment']=='proposed_user']
        self.assertEqual({a['number'] for a in planned}, {1, 2})
        self.assertEqual({a['account'] for a in planned}, {'reviewer-a', 'reviewer-b'})
        self.assertNotIn('posts', state)

    def test_request_and_readback_then_rerun_adds_no_request(self):
        result, out, state = self.run_cli(request=True)
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertEqual(out['requests'][0]['state'], 'requested')
        self.assertEqual(state['posts'], [{'number':1, 'reviewers':['reviewer-a']}])
        self.state = state
        result, out, state = self.run_cli(request=True)
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertEqual(out['requests'], [])
        self.assertEqual(len(state['posts']), 1)

    def test_later_page_cr_routes_to_actual_owner(self):
        cr = {'id':12, 'state':'CHANGES_REQUESTED', 'commit_id':'c'*40,
              'user':{'login':'reviewer-b'}, 'body':'Please fix the finding.',
              'submitted_at':'2026-10-26T09:00:00Z'}
        comment = cr | {'id':13, 'state':'COMMENTED', 'commit_id':HEAD,
                        'submitted_at':'2026-10-26T10:00:00Z'}
        self.state['review_pages'] = {'1':[[cr], [comment]]}
        result, out, state = self.run_cli(request=True)
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertEqual(state['posts'], [{'number':1, 'reviewers':['reviewer-b']}])

    def test_closed_draft_or_changed_head_before_post_skips(self):
        for change in ({'state':'closed'}, {'draft':True},
                       {'head':{'sha':'c'*40, 'ref':'fix/1'}},
                       {'base':{'sha':'c'*40, 'ref':'main'}}):
            with self.subTest(change=change):
                self.state = {'pulls':{'1':pull()}, 'preflight_change':change}
                result, out, state = self.run_cli(request=True)
                self.assertEqual(result.returncode, 0, result.stdout)
                self.assertEqual(out['requests'][0]['state'], 'snapshot_changed')
                self.assertNotIn('posts', state)

    def test_read_failure_aborts_before_any_post(self):
        self.state['pulls']['2'] = pull(2)
        self.state['fail_get'] = 'issues/2/comments'
        result, out, state = self.run_cli(request=True)
        self.assertEqual(result.returncode, 1)
        self.assertEqual(out['status'], 'unavailable')
        self.assertNotIn('posts', state)

    def test_uncertain_post_is_read_back_once_and_not_retried(self):
        for mode, expected in (('applied','observed_after_error'),
                               ('unapplied','request_unconfirmed')):
            with self.subTest(mode=mode):
                self.state = {'pulls':{'1':pull(), '2':pull(2)}, 'post_error':mode}
                result, out, state = self.run_cli(request=True)
                self.assertEqual(result.returncode, 0, result.stdout)
                self.assertEqual([r['state'] for r in out['requests']],
                                 [expected, 'not_attempted'])
                self.assertEqual(len(state['posts']), 1)

    def test_readback_error_never_claims_request_confirmation(self):
        self.state['readback_error'] = True
        result, out, state = self.run_cli(request=True)
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertEqual(out['requests'][0]['state'], 'request_unconfirmed')
        self.assertEqual(len(state['posts']), 1)

    def test_later_preflight_failure_preserves_earlier_receipt(self):
        self.state['pulls'].update({'2':pull(2), '3':pull(3)})
        self.state['fail_preflight_number'] = '2'
        result, out, state = self.run_cli(request=True)
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertEqual([r['state'] for r in out['requests']],
                         ['requested', 'unavailable', 'not_attempted'])
        self.assertEqual(state['posts'], [{'number':1, 'reviewers':['reviewer-a']}])

    def test_request_does_not_claim_a_head_pin_after_race(self):
        self.state['after_post_change'] = {'head':{'sha':'c'*40, 'ref':'fix/1'}}
        result, out, state = self.run_cli(request=True)
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertEqual(out['requests'][0]['state'], 'requested_scope_changed')
        self.assertEqual(len(state['posts']), 1)

    def test_approved_path_uses_selected_gh_for_complete_admission(self):
        for code in (0, 2):
            with self.subTest(code=code):
                with patch.object(M, 'command', side_effect=[
                        M.CommandResult(code, '', 'admission result')]) as run:
                    result = M.GitHub('o/r', '/fake/gh').admission(pull(), [{'state':'APPROVED'}])
                    self.assertEqual(result, code == 0)
                    for call in run.call_args_list:
                        self.assertEqual(call.kwargs['env']['GUARD_GH'], '/fake/gh')

    def test_unreadable_diff_or_admission_never_means_unreviewed(self):
        for results in ([M.CommandResult(1, '', 'diff unavailable')],
                        [M.CommandResult(1, '', 'API unavailable')]):
            with self.subTest(results=results):
                with patch.object(M, 'command', side_effect=results):
                    with self.assertRaises(M.Unavailable):
                        M.GitHub('o/r', '/fake/gh').admission(pull(), [{'state':'APPROVED'}])


if __name__ == '__main__':
    unittest.main()
