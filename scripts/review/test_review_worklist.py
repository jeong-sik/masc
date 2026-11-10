#!/usr/bin/env python3
"""Exercise collection, planning, request effects and reconciliation offline."""
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import threading
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
import fcntl, json, os, pathlib, sys, zlib
p = pathlib.Path(os.environ['WORKLIST_FIXTURE'])
lock = open(str(p) + '.lock', 'a+')
fcntl.flock(lock, fcntl.LOCK_EX)
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
    if number == s.get('fail_preflight_number') and s.get('detail_reads',{}).get(number,0) >= 2:
        done(error='late preflight failure')
    if number == s.get('invalid_review_number') and s.get('detail_reads',{}).get(number,0) >= 2:
        done([[None]])
    pages = s.get('review_pages', {}).get(number, [[]])
    if s.get('detail_reads',{}).get(number,0) >= 2:
        pages = s.get('preflight_review_pages', {}).get(number, pages)
    done(pages)
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

    def test_draft_exposes_current_comment_without_calling_it_an_approval(self):
        self.state['pulls']['1'] = pull() | {'draft': True}
        old = {'id': 12, 'state': 'COMMENTED', 'commit_id': 'c' * 40,
               'user': user('reviewer-a'), 'body': 'Earlier scope.',
               'submitted_at': '2026-10-26T09:00:00Z'}
        current = old | {'id': 13, 'commit_id': HEAD,
                         'submitted_at': '2026-10-26T10:00:00Z'}
        pending = current | {'id': 14, 'state': 'PENDING', 'submitted_at': None}
        unknown_head = current | {'id': 15, 'commit_id': None}
        self.state['review_pages'] = {'1': [[old], [current, pending, unknown_head]]}
        result, out, state = self.run_cli()
        self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
        [action] = out['actions']
        self.assertEqual(action['reason'], 'draft')
        self.assertEqual(action.get('current_head_submissions'), [
            {'review_id': 13, 'state': 'COMMENTED', 'head': HEAD,
             'observed_login': 'reviewer-a', 'account_id': uid('reviewer-a'),
             'submitted_at': '2026-10-26T10:00:00Z'}])
        self.assertEqual(action['approval_ids'], [])
        self.assertNotIn('posts', state)

    def test_comment_with_unavailable_identity_does_not_block_formal_routing(self):
        cr = {'id': 12, 'state': 'CHANGES_REQUESTED', 'commit_id': HEAD,
              'user': user('reviewer-b'), 'body': 'Please fix this head.',
              'submitted_at': '2026-10-26T09:00:00Z'}
        comment = {'id': 13, 'state': 'COMMENTED', 'commit_id': HEAD,
                   'user': None, 'submitted_at': None}
        self.state['review_pages'] = {'1': [[cr], [comment]]}
        result, out, state = self.run_cli()
        self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
        [action] = out['actions']
        self.assertEqual((action['reason'], action['review_ids'], action['approval_ids']),
                         ('awaiting_author', [12], []))
        self.assertEqual(action.get('current_head_submissions'), [
            {'review_id': 12, 'state': 'CHANGES_REQUESTED', 'head': HEAD,
             'observed_login': 'reviewer-b', 'account_id': uid('reviewer-b'),
             'submitted_at': '2026-10-26T09:00:00Z'},
            {'review_id': 13, 'state': 'COMMENTED', 'head': HEAD,
             'observed_login': None, 'account_id': None, 'submitted_at': None}])
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

    def test_request_processes_older_rereview_before_new_first_review(self):
        self.state['pulls']['2'] = pull(2)
        comment = {'id':12, 'state':'COMMENTED', 'commit_id':'c'*40,
                   'user':user('reviewer-b'), 'body':'Earlier review.',
                   'submitted_at':'2026-10-26T09:00:00Z'}
        self.state['review_pages'] = {'1':[[comment]]}
        self.state['post_error'] = 'applied'
        result, out, state = self.run_cli(request=True)
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertEqual(state['posts'][0]['number'], 1)
        self.assertEqual([r['state'] for r in out['requests']],
                         ['observed_after_error', 'not_attempted'])

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

    def test_reused_review_login_requests_verified_current_account_id(self):
        cr = {'id':12, 'state':'CHANGES_REQUESTED', 'commit_id':'c'*40,
              'user':{'login':'reviewer-a', 'id':uid('reviewer-b')},
              'body':'Please fix the finding.', 'submitted_at':'2026-10-26T09:00:00Z'}
        self.state['review_pages'] = {'1':[[cr]]}
        result, out, state = self.run_cli(request=True)
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertEqual(state['posts'], [{'number':1, 'reviewers':['reviewer-b']}])
        [action] = out['actions']
        self.assertEqual(action['review_authors'],
                         [{'account_id':uid('reviewer-b'), 'observed_login':'reviewer-a'}])

    def test_multiple_crs_on_one_account_route_only_latest(self):
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
        self.assertEqual(action['review_ids'], [14])

    def test_ambiguous_review_does_not_stop_other_prs(self):
        cr = {'id':12, 'state':'CHANGES_REQUESTED', 'commit_id':'c'*40,
              'user':user('reviewer-b'), 'body':'Please fix the finding.',
              'submitted_at':'2026-10-26T09:00:00Z'}
        approved = cr | {'id':13, 'state':'APPROVED', 'commit_id':HEAD}
        self.state['pulls']['2'] = pull(2)
        self.state['review_pages'] = {'1':[[cr, approved]]}
        result, out, state = self.run_cli(request=True)
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertEqual(out['status'], 'requests_processed')
        [uncertain] = [a for a in out['actions'] if a['number'] == 1]
        self.assertEqual(uncertain['reason'], 'ambiguous_review')
        self.assertEqual(uncertain['ambiguous_review_ids'], [12, 13])
        self.assertEqual([r['state'] for r in uncertain['ambiguous_reviews']],
                         ['CHANGES_REQUESTED', 'APPROVED'])
        self.assertEqual(state['posts'], [{'number':2, 'reviewers':['reviewer-a']}])

    def test_identical_tied_native_approvals_do_not_abort_or_trigger_request(self):
        approved = {'id':12, 'state':'APPROVED', 'commit_id':HEAD,
                    'user':user('reviewer-b'), 'body':'Looks good.',
                    'submitted_at':'2026-10-26T09:00:00Z'}
        self.state['review_pages'] = {'1':[[approved, approved | {'id':13}]]}
        result, out, state = self.run_cli(request=True)
        self.assertEqual(result.returncode, 0, result.stdout)
        [action] = out['actions']
        self.assertEqual((action['reason'], action['approval_ids'], action['ambiguous_review_ids']),
                         ('approved', [12, 13], []))
        self.assertEqual(out['requests'], [])
        self.assertNotIn('posts', state)

    def test_ambiguous_account_keeps_another_accounts_cr_actionable(self):
        cr = {'id':12, 'state':'CHANGES_REQUESTED', 'commit_id':'c'*40,
              'user':user('reviewer-a'), 'body':'Please fix the finding.',
              'submitted_at':'2026-10-26T09:00:00Z'}
        approved = cr | {'id':13, 'state':'APPROVED', 'commit_id':HEAD}
        other_cr = cr | {'id':14, 'user':user('reviewer-b'),
                         'submitted_at':'2026-10-26T10:00:00Z'}
        self.state['review_pages'] = {'1':[[cr, approved, other_cr]]}
        result, out, state = self.run_cli(request=True)
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertEqual({(a['reason'], a['account']) for a in out['actions']}, {
            ('ambiguous_review', None), ('changed_head_cr', 'reviewer-b')})
        self.assertEqual(state['posts'], [{'number':1, 'reviewers':['reviewer-b']}])

    def test_other_accounts_approval_is_visible_beside_ambiguous_history(self):
        first = {'id':12, 'state':'APPROVED', 'commit_id':HEAD,
                 'user':user('reviewer-a'), 'body':'Reviewed.',
                 'submitted_at':'2026-10-26T09:00:00Z'}
        dismissed = first | {'id':13, 'state':'DISMISSED'}
        approved = first | {'id':14, 'user':user('reviewer-b')}
        self.state['review_pages'] = {'1':[[first, dismissed, approved]]}
        result, out, state = self.run_cli(request=True)
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertEqual({a['reason'] for a in out['actions']}, {'ambiguous_review', 'approved'})
        self.assertTrue(all(a['approval_ids'] == [14] for a in out['actions']))
        self.assertTrue(all(a['ambiguous_review_ids'] == [12, 13] for a in out['actions']))
        self.assertTrue(all(
            [(r['review_id'], r['state']) for r in a['current_head_submissions']]
            == [(12, 'APPROVED'), (13, 'DISMISSED'), (14, 'APPROVED')]
            for a in out['actions']))
        self.assertEqual(out['requests'], [])
        self.assertNotIn('posts', state)

    def test_pending_and_comment_leave_cr_owned_but_dismissal_clears_it(self):
        cr = {'id':12, 'state':'CHANGES_REQUESTED', 'commit_id':'c'*40,
              'user':user('reviewer-b'), 'body':'Please fix the finding.',
              'submitted_at':'2026-10-26T09:00:00Z'}
        pending = cr | {'id':13, 'state':'PENDING', 'commit_id':None, 'submitted_at':None}
        comment = cr | {'id':14, 'state':'COMMENTED', 'submitted_at':'2026-10-26T10:00:00Z'}
        dismissed = cr | {'id':15, 'state':'DISMISSED', 'submitted_at':'2026-10-26T11:00:00Z'}
        self.state['review_pages'] = {'1':[[cr, pending], [comment]]}
        result, out, state = self.run_cli(request=True)
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertEqual(state['posts'], [{'number':1, 'reviewers':['reviewer-b']}])
        [action] = [a for a in out['actions'] if a['reason'] == 'changed_head_cr']
        self.assertEqual(action['review_ids'], [12])
        self.state = {'pulls':{'1':pull()}, 'review_pages':{'1':[[cr, pending], [comment, dismissed]]}}
        result, out, state = self.run_cli(request=True)
        self.assertEqual(result.returncode, 0, result.stdout)
        [action] = out['actions']
        self.assertEqual(action['reason'], 'review_needed')
        self.assertEqual(state['posts'], [{'number':1, 'reviewers':['reviewer-a']}])

    def test_changed_review_body_or_time_before_post_is_not_requested(self):
        original = {'id':12, 'state':'CHANGES_REQUESTED', 'commit_id':'c'*40,
                    'user':user('reviewer-b'), 'body':'Please fix the finding.',
                    'submitted_at':'2026-10-26T09:00:00Z'}
        for change in ({'body':'Updated finding.'},
                       {'submitted_at':'2026-10-26T09:00:01Z'},
                       {'submitted_at':None}):
            with self.subTest(change=change):
                self.state = {'pulls':{'1':pull()}, 'review_pages':{'1':[[original]]},
                              'preflight_review_pages':{'1':[[original | change]]}}
                result, out, state = self.run_cli(request=True)
                self.assertEqual(result.returncode, 0, result.stdout)
                self.assertEqual(out['requests'][0]['state'],
                                 'unavailable' if change.get('submitted_at', True) is None else 'snapshot_changed')
                self.assertNotIn('posts', state)

    def test_closed_draft_or_changed_head_before_post_skips(self):
        for change in ({'state':'closed'}, {'draft':True},
                       {'head':{'sha':'c'*40, 'ref':'fix/1'}},
                       {'base':{'sha':'c'*40, 'ref':'main'}},
                       {'stack':{'number':46935, 'position':5, 'base_ref':'main'}}):
            with self.subTest(change=change):
                self.state = {'pulls':{'1':pull()}, 'preflight_change':change}
                result, out, state = self.run_cli(request=True)
                self.assertEqual(result.returncode, 0, result.stdout)
                self.assertEqual(out['requests'][0]['state'], 'snapshot_changed')
                self.assertNotIn('posts', state)

    def test_read_failure_aborts_before_any_post(self):
        self.state['pulls']['2'] = pull(2)
        self.state['fail_get'] = 'pulls/2/reviews'
        result, out, state = self.run_cli(request=True)
        self.assertEqual(result.returncode, 1)
        self.assertEqual(out['status'], 'unavailable')
        self.assertNotIn('posts', state)

    def test_shared_commit_account_does_not_disqualify_review_request(self):
        self.state['compare_page_sets'] = [[comparison([commit(1, author='reviewer-a')])]]
        result, out, state = self.run_cli(request=True)
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertEqual(out['requests'][0]['state'], 'requested')
        self.assertEqual(state['posts'], [{'number':1, 'reviewers':['reviewer-a']}])
        self.assertFalse(any('compare/' in call for call in state['calls']))

    def test_snapshot_collects_concurrently_and_preserves_list_order(self):
        github = M.GitHub('o/r')
        barrier = threading.Barrier(2, timeout=5)
        def read(path):
            barrier.wait()
            return {'number':int(path.split('/')[-1])}
        with patch.object(github, 'collection', return_value=[{'number':2}, {'number':1}]), \
             patch.object(github, 'api', side_effect=read), \
             patch.object(github, 'collect_pr', side_effect=lambda pr:pr):
            self.assertEqual(github.snapshot(), ({'number':2}, {'number':1}))

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

    def test_post_readback_does_not_depend_on_commit_account_comparison(self):
        for error, expected in ((None, 'requested'), ('applied', 'observed_after_error')):
            with self.subTest(error=error):
                self.state = {'pulls':{'1':pull()}, 'fail_post_compare':True}
                if error:
                    self.state['post_error'] = error
                result, out, state = self.run_cli(request=True)
                self.assertEqual(result.returncode, 0, result.stdout)
                self.assertEqual(out['requests'][0]['state'], expected)
                self.assertTrue(out['requests'][0]['observed'])
                self.assertEqual(len(state['posts']), 1)
                self.assertFalse(any('compare/' in call for call in state['calls']))

    def test_final_scope_read_failure_preserves_observed_request_and_stops(self):
        self.state = {'pulls':{'1':pull(), '2':pull(2)}, 'detail_fail_at':{'1':4}}
        result, out, state = self.run_cli(request=True)
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertEqual([r['state'] for r in out['requests']],
                         ['requested_scope_unconfirmed', 'not_attempted'])
        self.assertTrue(out['requests'][0]['observed'])
        self.assertIsNone(out['requests'][0]['scope_unchanged'])
        self.assertEqual(len(state['posts']), 1)

    def test_conflicting_existing_request_is_kept_when_alternative_is_requested(self):
        self.state['pulls']['1']['user'] = user('reviewer-a')
        self.state['pulls']['1']['requested_reviewers'] = [user('reviewer-a')]
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
                pr['user'] = user('reviewer-a')
                pr['requested_reviewers'] = [user('reviewer-a')]
                self.state = {'pulls':{'1':pr}, 'preflight_change':change}
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

    def test_later_invalid_review_preserves_earlier_receipt(self):
        for key in ('invalid_review_number',):
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

    def test_native_approval_on_source_and_release(self):
        for branch in ('fix/1', 'release/v1'):
            for body in ('', None, 'Looks good.', 'Reviewed the changes.'):
                with self.subTest(branch=branch, body=body):
                    pr = pull()
                    pr['head']['ref'] = branch
                    approved = {'id':7, 'state':'APPROVED', 'user':user('reviewer-a'),
                                'author_association':'MEMBER',
                                'commit_id':HEAD, 'body':body,
                                'submitted_at':'2026-10-26T09:00:00Z'}
                    self.state = {'pulls':{'1':pr}, 'review_pages':{'1':[[approved]]},
                                  'fail_get':'issues/1/comments'}
                    result, out, state = self.run_cli(request=True)
                    self.assertEqual(result.returncode, 0, result.stdout)
                    [action] = out['actions']
                    self.assertEqual(action['reason'], 'approved')
                    self.assertEqual(action['approval_ids'], [7])
                    self.assertNotIn('independent_source_review', action)
                    self.assertEqual(out['requests'], [])
                    self.assertNotIn('posts', state)
                    self.assertFalse(any('compare/' in c or 'issues/' in c for c in state['calls']))

    def test_latest_plain_approval_replaces_shared_account_cr(self):
        cr = {'id':10, 'state':'CHANGES_REQUESTED', 'user':user('reviewer-b'),
              'commit_id':'c'*40, 'body':'Please fix this issue.',
              'submitted_at':'2026-10-26T09:00:00Z'}
        approved = cr | {'id':11, 'state':'APPROVED', 'commit_id':HEAD, 'author_association':'MEMBER',
                         'body':'Reviewed and approved.',
                         'submitted_at':'2026-10-26T10:00:00Z'}
        self.state['review_pages'] = {'1':[[cr], [approved]]}
        result, out, state = self.run_cli(request=True)
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertEqual(out['actions'][0]['reason'], 'approved')
        self.assertEqual(out['actions'][0]['approval_ids'], [11])
        self.assertEqual(out['actions'][0]['superseded_change_requests'], [{
            'review_id':10, 'account_id':uid('reviewer-b'), 'observed_login':'reviewer-b',
            'finding_resolution':'unverified'}])
        self.assertEqual(out['requests'], [])
        self.assertNotIn('posts', state)

    def test_approval_without_author_association_needs_no_new_review(self):
        approved = {'id':7, 'state':'APPROVED', 'user':user('reviewer-a'),
                    'commit_id':HEAD, 'body':'Looks good.',
                    'submitted_at':'2026-10-26T09:00:00Z'}
        for record in (approved, approved | {'author_association':'NONE'}):
            with self.subTest(record=record):
                self.state = {'pulls':{'1':pull()}, 'review_pages':{'1':[[record]]}}
                result, out, state = self.run_cli(request=True)
                self.assertEqual(result.returncode, 0, result.stdout)
                self.assertEqual(out['actions'][0]['reason'], 'approved')
                self.assertEqual(out['actions'][0]['approval_ids'], [7])
                self.assertEqual(out['requests'], [])
                self.assertNotIn('posts', state)

    def test_approval_does_not_clear_another_accounts_cr(self):
        cr = {'id':10, 'state':'CHANGES_REQUESTED', 'user':user('reviewer-b'),
              'commit_id':'c'*40, 'body':'Please fix.',
              'submitted_at':'2026-10-26T09:00:00Z'}
        approved = cr | {'id':11, 'state':'APPROVED', 'user':user('reviewer-a'), 'author_association':'MEMBER',
                         'commit_id':HEAD, 'body':'Approved.',
                         'submitted_at':'2026-10-26T10:00:00Z'}
        self.state['review_pages'] = {'1':[[cr], [approved]]}
        result, out, state = self.run_cli(request=True)
        self.assertEqual(result.returncode, 0, result.stdout)
        [action] = out['actions']
        self.assertEqual((action['reason'], action['review_ids'], action['approval_ids']),
                         ('changed_head_cr', [10], [11]))
        self.assertEqual(state['posts'], [{'number':1, 'reviewers':['reviewer-b']}])

    def test_new_cr_routes_after_approval_and_keeps_previous_cr_history(self):
        cr = {'id':10, 'state':'CHANGES_REQUESTED', 'user':user('reviewer-b'),
              'commit_id':'c'*40, 'body':'First finding.',
              'submitted_at':'2026-10-26T09:00:00Z'}
        approved = cr | {'id':11, 'state':'APPROVED', 'commit_id':HEAD,
                         'body':'Approved.', 'submitted_at':'2026-10-26T10:00:00Z'}
        later = cr | {'id':12, 'body':'New finding.', 'submitted_at':'2026-10-26T11:00:00Z'}
        self.state['review_pages'] = {'1':[[cr, approved], [later]]}
        result, out, state = self.run_cli(request=True)
        self.assertEqual(result.returncode, 0, result.stdout)
        [action] = out['actions']
        self.assertEqual((action['reason'], action['review_ids'], action['approval_ids']),
                         ('changed_head_cr', [12], []))
        self.assertEqual(action['superseded_change_requests'], [{
            'review_id':10, 'account_id':uid('reviewer-b'), 'observed_login':'reviewer-b',
            'finding_resolution':'unverified'}])
        self.assertEqual(state['posts'], [{'number':1, 'reviewers':['reviewer-b']}])

    def test_stale_or_malformed_native_approval_does_not_count(self):
        approved = {'id':7, 'state':'APPROVED', 'user':user('reviewer-a'), 'author_association':'MEMBER',
                    'commit_id':'c'*40, 'body':'ok',
                    'submitted_at':'2026-10-26T09:00:00Z'}
        self.state['review_pages'] = {'1':[[approved]]}
        result, out, state = self.run_cli(request=True)
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertEqual(out['actions'][0]['reason'], 'review_needed')
        self.assertEqual(len(state['posts']), 1)
        self.state = {'pulls':{'1':pull()}, 'review_pages':{'1':[[approved | {'commit_id':None}]]}}
        result, out, state = self.run_cli(request=True)
        self.assertEqual(result.returncode, 1, result.stdout)
        self.assertEqual(out['status'], 'unavailable')
        self.assertNotIn('posts', state)

    def test_approved_scope_and_review_evidence_must_remain_stable(self):
        review = {'id':7, 'state':'APPROVED', 'user':user('reviewer-a'), 'commit_id':HEAD,
                  'author_association':'MEMBER',
                  'body':'', 'submitted_at':'2026-10-26T09:00:00Z'}
        for after_pr in (pull() | {'head':{'sha':HEAD, 'ref':'release/v1'}},
                         pull() | {'base':{'sha':'c'*40, 'ref':'main'}}):
            with self.subTest(after_pr=after_pr):
                github = M.GitHub('o/r')
                with patch.object(github, 'collection', side_effect=[[review], [review]]), \
                     patch.object(github, 'api', return_value=after_pr):
                    with self.assertRaises(M.Unavailable):
                        github.collect_pr(pull())
        github = M.GitHub('o/r')
        with patch.object(github, 'collection', side_effect=[[review], [review | {'body':'changed'}]]), \
             patch.object(github, 'api', return_value=pull()):
            with self.assertRaises(M.Unavailable):
                github.collect_pr(pull())
        github = M.GitHub('o/r')
        changed_final = pull() | {'head':{'sha':'c'*40, 'ref':'fix/1'}}
        with patch.object(github, 'collection', side_effect=[[review], [review]]), \
             patch.object(github, 'api', side_effect=[pull(), changed_final]):
            with self.assertRaises(M.Unavailable):
                github.collect_pr(pull())


if __name__ == '__main__':
    unittest.main()
