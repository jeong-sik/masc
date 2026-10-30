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
import zlib
from unittest.mock import patch

HERE = Path(__file__).resolve().parent
HEAD, BASE = "a" * 40, "b" * 40
SPEC = importlib.util.spec_from_file_location("review_worklist", HERE / "review-worklist.py")
M = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = M
SPEC.loader.exec_module(M)


def uid(name):
    return zlib.crc32(name.casefold().encode()) + 1


def user(name):
    return {'login':name, 'id':uid(name)}


def pull(number=1):
    return {"number": number, "title": f"PR {number}", "html_url": f"https://github.example/o/r/pull/{number}",
            "state": "open", "draft": False, "user": user("author"),
            "head": {"sha": HEAD, "ref": f"fix/{number}"},
            "base": {"sha": BASE, "ref": "main"}, "stack": None,
            "created_at": f"2026-10-26T10:{number:02d}:00Z",
            "requested_reviewers": [], "requested_teams": []}


def comparison(commits, total=None):
    return {'base_commit':{'sha':BASE}, 'total_commits':len(commits) if total is None else total,
            'commits':commits}


def commit(number, author='author', committer='author'):
    return {'sha':f'{number:040x}', 'author':None if author is None else user(author),
            'committer':None if committer is None else user(committer)}


FAKE = r'''#!/usr/bin/env python3
import json, os, pathlib, sys, zlib
p = pathlib.Path(os.environ['WORKLIST_FIXTURE'])
s = json.loads(p.read_text())
args = sys.argv[1:]
assert args.pop(0) == 'api', args
paginated = '--paginate' in args
post = '--method' in args and args[args.index('--method')+1] == 'POST'
path = next(a for a in args if a.startswith('repos/') or a.startswith('users/'))
def uid(name): return zlib.crc32(name.casefold().encode()) + 1
if path.startswith('users/'):
    name = path.removeprefix('users/')
    s.setdefault('calls', []).append('GET ' + path)
    reads = s.setdefault('user_reads', {})
    reads[name] = reads.get(name, 0) + 1
    value = s.get('later_user_ids', {}).get(name, uid(name)) if reads[name] > 1 else uid(name)
    p.write_text(json.dumps(s))
    print(json.dumps({'login':name, 'id':value})); sys.exit(0)
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
if endpoint.startswith('compare/'):
    if s.get('post_seen') and s.get('fail_post_compare'):
        done(error='simulated post-request comparison failure')
    base, head = endpoint.removeprefix('compare/').split('...')
    counts = s.setdefault('compare_reads', {})
    counts[endpoint] = counts.get(endpoint, 0) + 1
    if s.get('post_seen') and s.get('after_post_compare_change'):
        s['pulls']['1'].update(s['after_post_compare_change'])
    page_sets = s.get('compare_page_sets')
    if page_sets:
        done(page_sets[min(counts[endpoint] - 1, len(page_sets) - 1)])
    done([{'base_commit':{'sha':base}, 'total_commits':1,
           'commits':[{'sha':head, 'author':{'login':'author','id':uid('author')},
                       'committer':{'login':'author','id':uid('author')}}]}])
parts = endpoint.split('/')
number = parts[1]
pr = s['pulls'][number]
if parts[0] == 'issues':
    if number == s.get('fail_preflight_number') and s.get('detail_reads',{}).get(number,0) >= 2:
        done(error='late preflight failure')
    if number == s.get('invalid_comment_number') and s.get('detail_reads',{}).get(number,0) >= 2:
        done([[None]])
    done(s.get('comment_pages', {}).get(number, [[]]))
if len(parts) == 2:
    counts = s.setdefault('detail_reads', {})
    counts[number] = counts.get(number, 0) + 1
    if counts[number] == s.get('detail_fail_at', {}).get(number):
        done(error='simulated detail read failure')
    if counts[number] == 2:
        pr.update(s.get('preflight_changes_by_number', {}).get(number, s.get('preflight_change', {})))
    done(pr)
if parts[2] == 'reviews':
    if number == s.get('invalid_review_number') and s.get('detail_reads',{}).get(number,0) >= 2:
        done([[None]])
    done(s.get('review_pages', {}).get(number, [[]]))
assert parts[2] == 'requested_reviewers'
if not post:
    if s.get('post_seen') and s.get('readback_error'):
        done(error='simulated readback failure')
    if s.get('post_seen') and s.get('readback_bad_number') == number:
        done(None)
    done({'users':pr['requested_reviewers'], 'teams':pr['requested_teams']})
body = json.load(sys.stdin)
s.setdefault('posts', []).append({'number':int(number), **body})
s['post_seen'] = True
if s.get('post_error') != 'unapplied':
    existing = {r['login'] for r in pr['requested_reviewers']}
    pr['requested_reviewers'] += [{'login':r, 'id':uid(r) + (1 if s.get('post_wrong_identity') else 0)}
                                  for r in body['reviewers'] if r not in existing]
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
              'user':user('reviewer-b'), 'body':'Please fix the finding.',
              'submitted_at':'2026-10-26T09:00:00Z'}
        comment = cr | {'id':13, 'state':'COMMENTED', 'commit_id':HEAD,
                        'submitted_at':'2026-10-26T10:00:00Z'}
        self.state['review_pages'] = {'1':[[cr], [comment]]}
        result, out, state = self.run_cli(request=True)
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertEqual(state['posts'], [{'number':1, 'reviewers':['reviewer-b']}])

    def test_multiple_owned_crs_request_once_and_keep_all_ids(self):
        def cr(rid, when):
            return {'id':rid, 'state':'CHANGES_REQUESTED', 'commit_id':'c'*40,
                    'user':user('reviewer-b'), 'body':'Please fix the finding.',
                    'submitted_at':when}
        self.state['review_pages'] = {'1':[[cr(12, '2026-10-26T09:00:00Z'),
                                             cr(13, '2026-10-26T09:00:00Z')],
                                            [cr(14, '2026-10-26T10:00:00Z')]]}
        result, out, state = self.run_cli(request=True)
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertEqual(state['posts'], [{'number':1, 'reviewers':['reviewer-b']}])
        [action] = [a for a in out['actions'] if a['reason'] == 'changed_head_cr']
        self.assertEqual(action['review_ids'], [12, 13, 14])

    def test_ambiguous_latest_cr_time_never_posts(self):
        cr = {'id':12, 'state':'CHANGES_REQUESTED', 'commit_id':'c'*40,
              'user':user('reviewer-b'), 'body':'Please fix the finding.',
              'submitted_at':'2026-10-26T09:00:00Z'}
        self.state['review_pages'] = {'1':[[cr, cr | {'id':13}]]}
        result, out, state = self.run_cli(request=True)
        self.assertEqual(result.returncode, 1, result.stdout)
        self.assertEqual(out['status'], 'unavailable')
        self.assertIn('ambiguous submission times', out['reason'])
        self.assertNotIn('posts', state)

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

    def test_comparison_includes_all_pages_beyond_250_commits(self):
        commits = [commit(i) for i in range(1, 251)] + [commit(251, committer='REVIEWER-A')]
        pages = [comparison(commits[:100], 251), comparison(commits[100:200], 251),
                 comparison(commits[200:], 251)]
        self.state['compare_page_sets'] = [pages]
        result, out, state = self.run_cli(request=True)
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertEqual(state['posts'], [{'number':1, 'reviewers':['reviewer-b']}])

    def test_commit_account_id_excludes_renamed_login_from_proposal(self):
        renamed = commit(1, author='old-reviewer-a')
        renamed['author']['id'] = uid('reviewer-a')
        self.state['compare_page_sets'] = [[comparison([renamed])]]
        result, out, state = self.run_cli(request=True)
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertEqual(state['posts'], [{'number':1, 'reviewers':['reviewer-b']}])

    def test_incomplete_or_unlinked_commit_identity_cannot_post(self):
        missing_id = commit(1)
        del missing_id['author']['id']
        pages = [[comparison([commit(1)], 2)], [comparison([commit(1, author=None)])],
                 [comparison([missing_id])]]
        for page_set in pages:
            with self.subTest(pages=page_set):
                self.state = {'pulls':{'1':pull()}, 'compare_page_sets':[page_set]}
                result, out, state = self.run_cli(request=True)
                self.assertEqual(result.returncode, 0, result.stdout)
                self.assertEqual(out['actions'][0]['reason'], 'commit_identity_unknown')
                self.assertNotIn('posts', state)

    def test_identity_mapping_change_at_same_head_skips_request(self):
        before = [comparison([commit(1)])]
        after = [comparison([commit(1, committer='reviewer-a')])]
        self.state['compare_page_sets'] = [before, after]
        result, out, state = self.run_cli(request=True)
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertEqual(out['requests'][0]['state'], 'snapshot_changed')
        self.assertNotIn('posts', state)

    def test_candidate_login_reassigned_before_post_skips_request(self):
        self.state['later_user_ids'] = {'reviewer-a':uid('reviewer-a') + 1}
        result, out, state = self.run_cli(request=True)
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertEqual(out['requests'][0]['state'], 'snapshot_changed')
        self.assertNotIn('posts', state)

    def test_wrong_user_id_in_request_readback_is_not_success_and_stops(self):
        self.state = {'pulls':{'1':pull(), '2':pull(2)}, 'post_wrong_identity':True}
        result, out, state = self.run_cli(request=True)
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertEqual([r['state'] for r in out['requests']],
                         ['requested_wrong_identity', 'not_attempted'])
        self.assertFalse(out['requests'][0]['observed'])
        self.assertEqual(len(state['posts']), 1)

    def test_identity_mapping_change_after_post_is_reported_at_same_head(self):
        stable = [comparison([commit(1)])]
        changed = [comparison([commit(1, committer='reviewer-a')])]
        for error, expected in ((None, 'requested_identity_changed'),
                                ('applied', 'observed_after_error_identity_changed')):
            with self.subTest(error=error):
                self.state = {'pulls':{'1':pull()}, 'compare_page_sets':[stable, stable, changed]}
                if error:
                    self.state['post_error'] = error
                result, out, state = self.run_cli(request=True)
                self.assertEqual(result.returncode, 0, result.stdout)
                self.assertEqual(out['requests'][0]['state'], expected)
                self.assertTrue(out['requests'][0]['observed'])
                self.assertFalse(out['requests'][0]['identities_unchanged'])
                self.assertEqual(len(state['posts']), 1)

    def test_head_change_during_post_comparison_is_reported(self):
        self.state['after_post_compare_change'] = {'head':{'sha':'c'*40, 'ref':'fix/1'}}
        result, out, state = self.run_cli(request=True)
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertEqual(out['requests'][0]['state'], 'requested_scope_changed')
        self.assertTrue(out['requests'][0]['observed'])

    def test_final_scope_read_failure_preserves_observed_request_and_stops(self):
        self.state = {'pulls':{'1':pull(), '2':pull(2)}, 'detail_fail_at':{'1':4}}
        result, out, state = self.run_cli(request=True)
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertEqual([r['state'] for r in out['requests']],
                         ['requested_scope_unconfirmed', 'not_attempted'])
        self.assertTrue(out['requests'][0]['observed'])
        self.assertIsNone(out['requests'][0]['scope_unchanged'])
        self.assertEqual(len(state['posts']), 1)

    def test_post_readback_failure_keeps_observed_request_but_stops(self):
        self.state = {'pulls':{'1':pull(), '2':pull(2)}, 'fail_post_compare':True}
        result, out, state = self.run_cli(request=True)
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertEqual([r['state'] for r in out['requests']],
                         ['requested_identity_unconfirmed', 'not_attempted'])
        self.assertTrue(out['requests'][0]['observed'])
        self.assertIsNone(out['requests'][0]['identities_unchanged'])
        self.assertEqual(len(state['posts']), 1)

    def test_conflicting_existing_request_is_kept_when_alternative_is_requested(self):
        self.state['pulls']['1']['requested_reviewers'] = [user('reviewer-a')]
        self.state['compare_page_sets'] = [[comparison([commit(1, author='reviewer-a')])]]
        result, out, state = self.run_cli(request=True)
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertEqual(out['requests'][0]['state'], 'requested')
        self.assertEqual(state['posts'], [{'number':1, 'reviewers':['reviewer-b']}])
        self.assertEqual({r['login'] for r in state['pulls']['1']['requested_reviewers']},
                         {'reviewer-a', 'reviewer-b'})

    def test_new_independent_or_team_request_prevents_duplicate_proposal(self):
        for change in ({'requested_reviewers':[user('reviewer-a'), user('reviewer-b')]},
                       {'requested_reviewers':[user('reviewer-a')],
                        'requested_teams':[{'slug':'team'}]}):
            with self.subTest(change=change):
                pr = pull()
                pr['requested_reviewers'] = [user('reviewer-a')]
                self.state = {'pulls':{'1':pr}, 'preflight_change':change,
                              'compare_page_sets':[[comparison([commit(1, author='reviewer-a')])]]}
                result, out, state = self.run_cli(request=True)
                self.assertEqual(result.returncode, 0, result.stdout)
                self.assertIn(out['requests'][0]['state'], ('already_requested', 'assignment_changed'))
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

    def test_uncertain_post_with_changed_head_reports_both_facts(self):
        self.state['post_error'] = 'applied'
        self.state['after_post_change'] = {'head':{'sha':'c'*40, 'ref':'fix/1'}}
        result, out, state = self.run_cli(request=True)
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertEqual(out['requests'][0]['state'], 'observed_after_error_scope_changed')
        self.assertEqual(len(state['posts']), 1)

    def test_readback_error_never_claims_request_confirmation(self):
        self.state['readback_error'] = True
        result, out, state = self.run_cli(request=True)
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertEqual(out['requests'][0]['state'], 'request_unconfirmed')
        self.assertEqual(len(state['posts']), 1)

    def test_malformed_later_readback_keeps_prior_request_receipt(self):
        self.state['pulls'].update({'2':pull(2), '3':pull(3)})
        self.state['readback_bad_number'] = '2'
        result, out, state = self.run_cli(request=True)
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertEqual([r['state'] for r in out['requests']],
                         ['requested', 'request_unconfirmed', 'not_attempted'])
        self.assertEqual(len(state['posts']), 2)

    def test_later_preflight_failure_preserves_earlier_receipt(self):
        self.state['pulls'].update({'2':pull(2), '3':pull(3)})
        self.state['fail_preflight_number'] = '2'
        result, out, state = self.run_cli(request=True)
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertEqual([r['state'] for r in out['requests']],
                         ['requested', 'unavailable', 'not_attempted'])
        self.assertEqual(state['posts'], [{'number':1, 'reviewers':['reviewer-a']}])

    def test_later_invalid_assignment_preserves_earlier_receipt(self):
        self.state['pulls'].update({'2':pull(2), '3':pull(3)})
        self.state['preflight_changes_by_number'] = {'2':{'requested_reviewers':[{'login':'', 'id':1}]}}
        result, out, state = self.run_cli(request=True)
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertEqual([r['state'] for r in out['requests']],
                         ['requested', 'unavailable', 'not_attempted'])
        self.assertEqual(state['posts'], [{'number':1, 'reviewers':['reviewer-a']}])

    def test_later_invalid_review_or_comment_preserves_earlier_receipt(self):
        for key in ('invalid_review_number', 'invalid_comment_number'):
            with self.subTest(kind=key):
                self.state = {'pulls':{'1':pull(), '2':pull(2), '3':pull(3)}, key:'2'}
                result, out, state = self.run_cli(request=True)
                self.assertEqual(result.returncode, 0, result.stdout)
                self.assertEqual([r['state'] for r in out['requests']],
                                 ['requested', 'unavailable', 'not_attempted'])
                self.assertEqual(len(state['posts']), 1)

    def test_request_does_not_claim_a_head_pin_after_race(self):
        self.state['after_post_change'] = {'head':{'sha':'c'*40, 'ref':'fix/1'}}
        result, out, state = self.run_cli(request=True)
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertEqual(out['requests'][0]['state'], 'requested_scope_changed')
        self.assertEqual(len(state['posts']), 1)

    def test_approved_path_uses_selected_gh_and_requires_independent_receipt(self):
        review = {'id':7, 'state':'APPROVED', 'user':user('reviewer-a'), 'commit_id':HEAD}
        receipt = json.dumps({'pr':1, 'head':HEAD, 'approval_ids':[7],
                              'scope':M.review_scope(pull()), 'policy':'source'})
        for code in (0, 2):
            with self.subTest(code=code):
                with patch.object(M, 'command', side_effect=[
                        M.CommandResult(code, receipt, 'admission result')]) as run:
                    result = M.GitHub('o/r', '/fake/gh').admission(pull(), [review], [('author',uid('author'))], True)
                    self.assertEqual(result, code == 0)
                    for call in run.call_args_list:
                        self.assertEqual(call.kwargs['env']['GUARD_GH'], '/fake/gh')
        with patch.object(M, 'command', return_value=M.CommandResult(0, receipt, '')):
            self.assertFalse(M.GitHub('o/r').admission(pull(), [review], [('old-login',uid('reviewer-a'))], True))
            self.assertFalse(M.GitHub('o/r').admission(pull(), [review | {'commit_id':'e'*40}], [], True))
            missing_commit = {k:v for k,v in review.items() if k != 'commit_id'}
            self.assertFalse(M.GitHub('o/r').admission(pull(), [missing_commit], [], True))
            with self.assertRaises(M.Unavailable):
                M.GitHub('o/r').admission(pull(), [review | {'id':8}], [], True)
        stale = json.dumps({'pr':1, 'head':HEAD, 'approval_ids':[7],
                            'scope':{'base_ref':'main', 'base_sha':'c'*40, 'stack':None}, 'policy':'source'})
        with patch.object(M, 'command', return_value=M.CommandResult(0, stale, '')):
            with self.assertRaises(M.Unavailable):
                M.GitHub('o/r').admission(pull(), [review], [], True)
        wrong_policy = json.dumps({'pr':1, 'head':HEAD, 'approval_ids':[7],
                                   'scope':M.review_scope(pull()), 'policy':'release'})
        with patch.object(M, 'command', return_value=M.CommandResult(0, wrong_policy, '')):
            with self.assertRaises(M.Unavailable):
                M.GitHub('o/r').admission(pull(), [review], [], True)

    def test_independent_source_approval_preserves_separate_conflicting_cr(self):
        digest = 'd' * 64
        body = (f'verdict: PASS head: {HEAD} by: reviewer-b\n\n'
                f'review-scope: {{"base_ref":"main","base_sha":"{BASE}","stack":null}}\n'
                f'approve-guard: head `{HEAD}` · source review · reviewed base `{BASE}` · diff sha256 `{digest}`')
        approved = {'id':10, 'state':'APPROVED', 'user':user('reviewer-b'), 'body':body, 'commit_id':HEAD,
                    'author_association':'MEMBER', 'submitted_at':'2026-10-26T09:00:00Z'}
        cr = {'id':11, 'state':'CHANGES_REQUESTED', 'user':user('reviewer-a'),
              'commit_id':HEAD, 'body':'source finding', 'submitted_at':'2026-10-26T09:00:00Z'}
        pr = pull()
        pr['requested_reviewers'] = [user('reviewer-a')]
        accounts = [('reviewer-a', uid('reviewer-a'))]
        with patch.object(M, 'command', return_value=M.CommandResult(0, digest, '')) as run:
            self.assertTrue(M.GitHub('o/r', '/fake/gh').independent_source_review(pr, [cr, approved], [], accounts, True))
            self.assertEqual(run.call_args.kwargs['env']['GUARD_GH'], '/fake/gh')
            stale = approved | {'body':body.replace(HEAD, 'e'*40)}
            self.assertFalse(M.GitHub('o/r').independent_source_review(pr, [cr, stale], [], accounts, True))
            old_commit = approved | {'commit_id':'e'*40}
            self.assertFalse(M.GitHub('o/r').independent_source_review(pr, [cr, old_commit], [], accounts, True))
            missing_commit = {k:v for k,v in approved.items() if k != 'commit_id'}
            self.assertFalse(M.GitHub('o/r').independent_source_review(pr, [cr, missing_commit], [], accounts, True))
            superseded = approved | {'id':12, 'state':'CHANGES_REQUESTED', 'submitted_at':'2026-10-26T10:00:00Z'}
            self.assertFalse(M.GitHub('o/r').independent_source_review(pr, [cr, approved, superseded], [], accounts, True))
            self.assertFalse(M.GitHub('o/r').independent_source_review(pr, [cr, approved], [], accounts, False))
            release = pr | {'head':{'sha':HEAD, 'ref':'release/v1'}}
            self.assertFalse(M.GitHub('o/r').independent_source_review(release, [cr, approved], [], accounts, True))
            later_fail = {'id':13, 'user':user('reviewer-b'), 'body':f'verdict: FAIL head: {HEAD} by: reviewer-b',
                          'created_at':'2026-10-26T10:00:00Z', 'updated_at':'2026-10-26T10:00:00Z'}
            self.assertFalse(M.GitHub('o/r').independent_source_review(pr, [cr, approved], [later_fail], accounts, True))
            other_keeper_fail = later_fail | {
                'body': f'verdict: FAIL head: {HEAD} by: another-keeper',
                'created_at': '2026-10-26T08:00:00Z', 'updated_at': '2026-10-26T08:00:00Z'}
            self.assertFalse(M.GitHub('o/r').independent_source_review(
                pr, [cr, approved], [other_keeper_fail], accounts, True))
            other_fail = later_fail | {'user':user('reviewer-a')}
            self.assertTrue(M.GitHub('o/r').independent_source_review(pr, [cr, approved], [other_fail], accounts, True))
            unknown_fail = later_fail | {'user':None}
            self.assertFalse(M.GitHub('o/r').independent_source_review(pr, [cr, approved], [unknown_fail], accounts, True))
            invalid_id = later_fail | {'user':{'login':'unknown','id':0}}
            self.assertFalse(M.GitHub('o/r').independent_source_review(pr, [cr, approved], [invalid_id], accounts, True))
            invalid_known_login = later_fail | {'user':{'login':'reviewer-a','id':0}}
            self.assertFalse(M.GitHub('o/r').independent_source_review(pr, [cr, approved], [invalid_known_login], accounts, True))
            later_pass = later_fail | {'id':14, 'user':user('reviewer-a'),
                                       'body':f'verdict: PASS head: {HEAD} by: reviewer-a',
                                       'author_association':'MEMBER', 'created_at':'2026-10-26T11:00:00Z',
                                       'updated_at':'2026-10-26T11:00:00Z'}
            self.assertFalse(M.GitHub('o/r').independent_source_review(
                pr, [cr, approved], [invalid_known_login, later_pass], accounts, True))
            valid_fail = later_fail | {'user':user('reviewer-a')}
            invalid_pass = later_pass | {'user':{'login':'reviewer-a','id':0}}
            self.assertFalse(M.GitHub('o/r').independent_source_review(
                pr, [cr, approved], [valid_fail, invalid_pass], accounts, True))
            renamed_commit = accounts + [('old-reviewer-b', uid('reviewer-b'))]
            self.assertFalse(M.GitHub('o/r').independent_source_review(pr, [cr, approved], [], renamed_commit, True))

    def test_independent_source_approval_requires_unique_latest_submission(self):
        digest = 'd' * 64
        body = (f'verdict: PASS head: {HEAD} by: reviewer-b\n\n'
                f'review-scope: {{"base_ref":"main","base_sha":"{BASE}","stack":null}}\n'
                f'approve-guard: head `{HEAD}` · source review · reviewed base `{BASE}` · diff sha256 `{digest}`')
        approved = {'id':90, 'state':'APPROVED', 'user':user('reviewer-b'), 'body':body,
                    'commit_id':HEAD, 'author_association':'MEMBER',
                    'submitted_at':'2026-10-26T09:00:00Z'}
        dismissed = approved | {'id':77, 'state':'DISMISSED', 'body':'',
                                'submitted_at':'2026-10-26T10:00:00Z'}
        pr = pull()
        pr['requested_reviewers'] = [user('reviewer-a')]
        accounts = [('reviewer-a', uid('reviewer-a'))]
        github = M.GitHub('o/r', '/fake/gh')
        with patch.object(M, 'command', return_value=M.CommandResult(0, digest, '')):
            self.assertFalse(github.independent_source_review(pr, [approved, dismissed], [], accounts, True))
            newer_approval = approved | {'id':77, 'submitted_at':'2026-10-26T10:00:00Z'}
            older_dismissed = dismissed | {'id':90, 'submitted_at':'2026-10-26T09:00:00Z'}
            self.assertTrue(github.independent_source_review(pr, [newer_approval, older_dismissed], [], accounts, True))
            older_tie = older_dismissed | {'id':88}
            self.assertTrue(github.independent_source_review(pr, [older_tie, older_dismissed, newer_approval], [], accounts, True))
            for at in ('2026-10-26T09:00:00Z', None, 'invalid'):
                with self.subTest(at=at), self.assertRaises(M.Unavailable):
                    github.independent_source_review(pr, [approved, dismissed | {'submitted_at':at}], [], accounts, True)

    def test_unreplaced_commit_actor_cr_remains_a_conflict_after_another_approval(self):
        digest = 'd' * 64
        body = (f'verdict: PASS head: {HEAD} by: reviewer-b\n\n'
                f'review-scope: {{"base_ref":"main","base_sha":"{BASE}","stack":null}}\n'
                f'approve-guard: head `{HEAD}` · source review · reviewed base `{BASE}` · diff sha256 `{digest}`')
        approved = {'id':90, 'state':'APPROVED', 'user':user('reviewer-b'), 'body':body,
                    'commit_id':HEAD, 'author_association':'MEMBER',
                    'submitted_at':'2026-10-26T11:00:00Z'}
        old_cr = {'id':11, 'state':'CHANGES_REQUESTED', 'user':user('reviewer-a'),
                  'body':f'verdict: FAIL head: {HEAD} by: keeper-one', 'commit_id':HEAD,
                  'submitted_at':'2026-10-26T09:00:00Z'}
        other_approval = approved | {'id':12, 'user':user('reviewer-a'),
                                     'body':'unrelated approval', 'submitted_at':'2026-10-26T10:00:00Z'}
        with patch.object(M, 'command', return_value=M.CommandResult(0, digest, '')):
            self.assertTrue(M.GitHub('o/r', '/fake/gh').independent_source_review(
                pull(), [old_cr, other_approval, approved], [], [('reviewer-a', uid('reviewer-a'))], True))

    def test_unreadable_diff_or_admission_never_means_unreviewed(self):
        for results in ([M.CommandResult(1, '', 'diff unavailable')],
                        [M.CommandResult(1, '', 'API unavailable')]):
            with self.subTest(results=results):
                with patch.object(M, 'command', side_effect=results):
                    with self.assertRaises(M.Unavailable):
                        M.GitHub('o/r', '/fake/gh').admission(pull(), [{'state':'APPROVED'}], [], True)

    def test_admitted_scope_and_identity_must_remain_stable_after_guard(self):
        review = {'id':7, 'state':'APPROVED', 'user':user('reviewer-a'), 'commit_id':HEAD,
                  'body':'', 'submitted_at':'2026-10-26T09:00:00Z'}
        initial = (('author', uid('author')),)
        changed = (('author', uid('author')), ('reviewer-a', uid('reviewer-a')))
        for after_pr, after_accounts in ((pull(), changed),
                                         (pull() | {'head':{'sha':HEAD, 'ref':'release/v1'}}, initial)):
            with self.subTest(after_pr=after_pr, after_accounts=after_accounts):
                github = M.GitHub('o/r')
                with patch.object(github, 'collection', side_effect=[[review], [], [review], []]), \
                     patch.object(github, 'commit_accounts', side_effect=[(initial, True), (after_accounts, True)]), \
                     patch.object(github, 'admission', return_value=True), \
                     patch.object(github, 'api', return_value=after_pr):
                    with self.assertRaises(M.Unavailable):
                        github.collect_pr(pull())

        github = M.GitHub('o/r')
        changed_final = pull() | {'head':{'sha':'c'*40, 'ref':'fix/1'}}
        with patch.object(github, 'collection', side_effect=[[review], [], [review], []]), \
             patch.object(github, 'commit_accounts', side_effect=[(initial, True), (initial, True)]), \
             patch.object(github, 'admission', return_value=True), \
             patch.object(github, 'api', side_effect=[pull(), changed_final]):
            with self.assertRaises(M.Unavailable):
                github.collect_pr(pull())

        github = M.GitHub('o/r')
        with patch.object(github, 'collection', side_effect=[[review], [], [review], [{'id':99}]]), \
             patch.object(github, 'commit_accounts', side_effect=[(initial, True), (initial, True)]), \
             patch.object(github, 'admission', return_value=False), \
             patch.object(github, 'independent_source_review', return_value=True), \
             patch.object(github, 'api', return_value=pull()):
            with self.assertRaises(M.Unavailable):
                github.collect_pr(pull())


if __name__ == '__main__':
    unittest.main()
