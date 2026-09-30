"""Exercise admission with a fake GitHub transport, including mutation races."""
import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path
from typing import Any

HERE = Path(os.environ.get('GUARD_SCRIPTS', str(Path(__file__).resolve().parent)))
DIFF_TOOL = Path(__file__).resolve().parent / 'review-diff.py'
HEAD = 'a' * 40
OTHER = 'b' * 40
FAKE = r'''#!/usr/bin/env python3
import json, os, pathlib, subprocess, sys
state = json.loads(pathlib.Path(os.environ['REVIEW_FIXTURE']).read_text())
args = sys.argv[1:]
endpoint = next((a for a in args if a.startswith('repos/') or a == 'user'), '')
log = pathlib.Path(os.environ['REVIEW_CALLS'])
with log.open('a') as f: f.write(('POST ' if '-X' in args and args[args.index('-X')+1]=='POST' else '') + endpoint + '\n')
head = state['head']
if args[:2] == ['pr','list']:
    data = [{'number':1,'author':{'login':'writer'},'baseRefName':state.get('base','stack/parent'),'headRefOid':head,'headRefName':state.get('branch','stack/change'),'isDraft':False},{'number':2,'author':{'login':'parent-writer'},'baseRefName':'main','headRefOid':'d'*40,'headRefName':'stack/parent','isDraft':True}]
elif endpoint.endswith('/pulls/1'):
    count = log.read_text().splitlines().count(endpoint)
    current = state.get('moved', head) if count >= state.get('move_after', 100000) else head
    data = {'state':'open','draft':False,'merged':False,'user':{'login':state.get('author','writer')},'base':{'ref':state.get('base','stack/parent'),'sha':state['base_sha']},'head':{'sha':current,'ref':state.get('branch','stack/change')}}
elif '/compare/' in endpoint:
    base, compared_head = endpoint.rsplit('/',1)[1].split('...')
    merge_base = subprocess.check_output(['git','-C',os.environ['GUARD_REPO_ROOT'],'merge-base',base,compared_head],text=True).strip()
    data = {'merge_base_commit':{'sha':None if state.get('bad_compare') else merge_base}}
elif endpoint == 'user': data = {'login':'reviewer'}
elif '/actions/runs?' in endpoint:
    reads = sum('/actions/runs?' in row for row in log.read_text().splitlines())
    run_id = 43 if state.get('run_moves') and reads >= 2 else 42
    data = {'workflow_runs':[{'id':run_id,'status':'completed','conclusion':state.get('ci','success'),'head_sha':head,'head_branch':state.get('branch','stack/change'),'path':state.get('workflow','.github/workflows/release-candidate.yml')}]}
elif endpoint.endswith('/jobs?per_page=100'):
    names = (['verification / Release checks passed','behavior / test suite','release']
             if state.get('workflow') == '.github/workflows/release.yml' else
             ['compile / Release checks passed','behavior / test suite','installation / release','Record candidate verification'])
    data = {'jobs':[{'id':i+1,'name':n,'status':'completed','conclusion':state.get('job','success')}
                    for i,n in enumerate(names) if n != state.get('missing_job')]}
    data['jobs'].append({'id':100,'name':'Validate manual Release ref','status':'completed','conclusion':'skipped'})
    if state.get('workflow') != '.github/workflows/release.yml':
        data['jobs'].extend([{'id':101,'name':'installation / verification','status':'completed','conclusion':'skipped'},
                            {'id':102,'name':'installation / behavior','status':'completed','conclusion':'skipped'}])
elif endpoint.endswith('/comments'):
    data = state.get('comments', [])
elif endpoint.endswith('/reviews?per_page=100') or endpoint.endswith('/reviews'):
    data = state.get('reviews', []) + ([state['posted']] if 'posted' in state else [])
    if '-X' in args:
        body = sys.stdin.read()
        posted = {'id':99,'state':'APPROVED','commit_id':head,'body':body,'author_association':'MEMBER','user':{'login':'reviewer'},'submitted_at':'2026-09-30T00:00:00Z'}
        state['posted']=posted
        pathlib.Path(os.environ['REVIEW_FIXTURE']).write_text(json.dumps(state))
        data = posted
elif '/reviews/' in endpoint:
    rid = int(endpoint.rsplit('/',1)[1])
    data = state.get('posted') if rid == 99 else next(r for r in state.get('reviews',[]) if r['id']==rid)
elif endpoint.endswith('/merge-async'):
    print(json.dumps({'merged':True})); sys.exit(0)
else:
    print('Unexpected API ' + endpoint, file=sys.stderr); sys.exit(3)
query = args[args.index('--jq')+1]
result = subprocess.run(['jq','-r',query],input=json.dumps(data),text=True,capture_output=True)
sys.stdout.write(result.stdout); sys.stderr.write(result.stderr); sys.exit(result.returncode)
'''


class SourceReviewPolicy(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.fake = self.root / 'gh'
        self.fake.write_text(FAKE)
        self.fake.chmod(0o755)
        self.fixture = self.root / 'fixture.json'
        self.calls = self.root / 'calls'
        self.calls.write_text('')
        self.env = dict(os.environ, GUARD_GH=str(self.fake), LEDGER_GH=str(self.fake),
                        REVIEW_FIXTURE=str(self.fixture), REVIEW_CALLS=str(self.calls))
        global HEAD, OTHER
        self.git_root = self.root / 'repo'
        self.git_root.mkdir()
        self.git('init', '-q')
        self.git('config', 'user.email', 'fixture@example.test')
        self.git('config', 'user.name', 'fixture')
        self.commit_file('root.txt', 'root')
        OTHER = self.git('rev-parse', 'HEAD')
        self.commit_file('parent.txt', 'parent')
        self.base = self.git('rev-parse', 'HEAD')
        self.commit_file('feature-a.txt', 'feature A')
        self.narrowed_base = self.git('rev-parse', 'HEAD')
        self.commit_file('feature-b.txt', 'feature B')
        HEAD = self.git('rev-parse', 'HEAD')
        self.env['GUARD_REPO_ROOT'] = str(self.git_root)
        self.state: dict[str, Any] = {'head':HEAD, 'base':'main', 'base_sha':self.base}
        self.digest = self.identity(self.base)

    def git(self, *args):
        return subprocess.check_output(['git','-C',str(self.git_root),*args],text=True,
            env={**os.environ, 'GIT_AUTHOR_DATE':'2026-09-30T00:00:00Z',
                 'GIT_COMMITTER_DATE':'2026-09-30T00:00:00Z'}).strip()

    def commit_file(self, path, content):
        (self.git_root / path).write_text(content)
        self.git('add', '--', path)
        self.git('commit', '-qm', path)

    def identity(self, base, head=None):
        head = HEAD if head is None else head
        self.fixture.write_text(json.dumps(self.state))
        return subprocess.check_output(
            ['python3', str(DIFF_TOOL), '--repo','team/repo','--base',base,'--head',head],
            env=self.env, text=True).strip()

    def review(self, state='APPROVED', author='reviewer', verdict='PASS', run=False):
        line = f'verdict: {verdict} head: {HEAD}' + (' run: 42' if run else '') + ' by: independent'
        footer = f' · reviewed base `{self.base}` · diff sha256 `{self.digest}`'
        return {'id':12,'state':state,'body':line+f'\n\n---\napprove-guard: head `{HEAD}` · source review'+footer,
                'user':{'login':author},'author_association':'MEMBER','submitted_at':'2026-09-30T00:00:00Z'}

    def invoke(self, script, *args):
        if '--body' in args and '--review-base' not in args:
            args = (*args, '--review-base', self.base, '--review-diff', self.digest)
        self.fixture.write_text(json.dumps(self.state))
        return subprocess.run(['bash',str(HERE/script),'--repo','team/repo','--pr','1','--head',HEAD,*args],
                              env=self.env,text=True,capture_output=True,check=False)

    def assert_ok(self, result):
        self.assertEqual(result.returncode,0,result.stdout+result.stderr)

    def test_retarget_expanding_complete_diff_refuses_old_approval(self):
        self.state['reviews'] = [self.review()]
        self.state.update(base='older-parent', base_sha=OTHER)
        self.assertNotEqual(self.identity(OTHER), self.digest)
        result = self.invoke('approve-guard.sh', '--merge-check', '--receipt-json')
        self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
        self.assertNotIn('/actions/', self.calls.read_text())

    def test_parent_landing_narrowing_diff_refuses_old_approval(self):
        self.state['reviews'] = [self.review()]
        self.state['base_sha'] = self.narrowed_base
        self.assertNotEqual(self.identity(self.narrowed_base), self.digest)
        result = self.invoke('merge-guard.sh', '--check')
        self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
        self.assertNotIn('/merge-async', self.calls.read_text())

    def test_base_and_ref_moving_with_identical_diff_keeps_approval(self):
        self.git('checkout', '-qb', 'unrelated-base', self.base)
        self.commit_file('unrelated.txt', 'unrelated base change')
        moved_base = self.git('rev-parse', 'HEAD')
        self.state.update(base='renamed-parent', base_sha=moved_base, reviews=[self.review()])
        self.assertEqual(self.identity(moved_base), self.digest)
        result = self.invoke('approve-guard.sh', '--merge-check', '--receipt-json')
        self.assert_ok(result)
        self.assertEqual(json.loads(result.stdout)['approval_ids'], [12])
        self.assertNotIn('POST ', self.calls.read_text())
        self.assertNotIn('/actions/', self.calls.read_text())

    def test_head_only_approval_is_never_backfilled(self):
        review = self.review()
        review['body'] = review['body'].split(' · reviewed base')[0]
        self.state['reviews'] = [review]
        result = self.invoke('approve-guard.sh', '--merge-check')
        self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
        self.assertNotIn('POST ', self.calls.read_text())

    def test_old_review_scope_cannot_be_stamped_with_current_diff(self):
        body = self.root / 'body'
        body.write_text(f'verdict: PASS head: {HEAD} by: independent\nOld source review.')
        self.state['base_sha'] = OTHER
        result = self.invoke('approve-guard.sh', '--body', str(body))
        self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
        self.assertNotIn('POST ', self.calls.read_text())

    def test_approval_requires_explicit_review_snapshot(self):
        body = self.root / 'body'
        body.write_text(f'verdict: PASS head: {HEAD} by: independent\nOld source review.')
        result = self.invoke('approve-guard.sh', '--body', str(body), '--review-base', '',
                             '--review-diff', '')
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn('POST ', self.calls.read_text())

    def test_real_producer_then_fresh_consumer_checks_changed_and_same_diff(self):
        body = self.root / 'body'
        body.write_text(f'verdict: PASS head: {HEAD} by: independent\nReviewed both feature files.')
        self.assert_ok(self.invoke('approve-guard.sh', '--body', str(body)))
        self.state = json.loads(self.fixture.read_text())
        original_body = self.state['posted']['body']
        self.assertIn(f' · diff sha256 `{self.digest}`', original_body)
        self.assert_ok(self.invoke('approve-guard.sh', '--merge-check', '--receipt-json'))
        self.state['base_sha'] = OTHER
        result = self.invoke('approve-guard.sh', '--merge-check', '--receipt-json')
        self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
        self.assertEqual(json.loads(self.fixture.read_text())['posted']['body'], original_body)
        self.state['base_sha'] = self.base
        self.assert_ok(self.invoke('merge-guard.sh', '--check'))
        self.assertEqual(self.calls.read_text().count('POST '), 1)

    def test_unreadable_complete_diff_refuses(self):
        self.state.update(bad_compare=True, reviews=[self.review()])
        result = self.invoke('approve-guard.sh','--merge-check')
        self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
        self.assertIn('complete review diff unavailable', result.stderr)
        self.assertNotIn('POST ',self.calls.read_text())

    def test_latest_fail_still_blocks_matching_diff(self):
        self.state['reviews'] = [self.review()]
        self.state['comments'] = [{'created_at':'2026-09-30T00:01:00Z',
            'body':f'verdict: FAIL head: {HEAD} by: independent','author_association':'MEMBER'}]
        self.assertEqual(self.invoke('merge-guard.sh','--check').returncode, 2)

    def test_complete_identity_includes_binary_mode_and_odd_paths(self):
        self.git('checkout', '-q', HEAD)
        odd = self.git_root / 'binary\npath'
        odd.write_bytes(b'\0before')
        self.git('add', '--', odd.name)
        self.git('commit', '-qm', 'binary')
        before = self.identity(self.base, self.git('rev-parse', 'HEAD'))
        odd.write_bytes(b'\0after')
        self.git('add', '--', odd.name)
        self.git('commit', '-qm', 'binary content')
        after_binary = self.identity(self.base, self.git('rev-parse', 'HEAD'))
        self.assertNotEqual(before, after_binary)
        odd.chmod(0o755)
        self.git('add', '--', odd.name)
        self.git('commit', '-qm', 'executable mode only')
        after_mode = self.identity(self.base, self.git('rev-parse', 'HEAD'))
        self.assertNotEqual(after_binary, after_mode)
        self.git('config','diff.orderFile', str(self.root / 'order'))
        (self.root / 'order').write_text('feature-b.txt\nfeature-a.txt\n')
        self.assertEqual(self.identity(self.base), self.digest)

    def test_bottom_stack_merges_without_actions(self):
        self.state['reviews']=[self.review()]
        result=self.invoke('merge-guard.sh','--check')
        self.assert_ok(result)
        self.assertIn('WOULD MERGE',result.stdout)
        self.assertNotIn('/actions/',self.calls.read_text())

    def test_source_approval_is_posted_on_exact_head_without_actions(self):
        self.state['base']='stack/parent'
        body=self.root/'body'
        body.write_text(f'verdict: PASS head: {HEAD} by: independent\nNo P0/P1/P2 findings.')
        self.assert_ok(self.invoke('approve-guard.sh','--body',str(body)))
        posted=json.loads(self.fixture.read_text())['posted']
        self.assertEqual(posted['commit_id'],HEAD)
        self.assertNotIn('/actions/',self.calls.read_text())

    def test_same_head_approval_is_idempotent_but_new_hold_refuses(self):
        self.state['reviews']=[self.review()]
        body=self.root/'body'
        body.write_text(f'verdict: PASS head: {HEAD} by: independent\nNo P0/P1/P2 findings.')
        result=self.invoke('approve-guard.sh','--body',str(body))
        self.assert_ok(result)
        self.assertIn('SKIP',result.stdout)
        self.state['comments']=[{'created_at':'2026-09-30T00:01:00Z',
            'body':f'verdict: HOLD head: {HEAD} by: independent','author_association':'MEMBER'}]
        self.assertEqual(self.invoke('approve-guard.sh','--body',str(body)).returncode,2)
        self.assertNotIn('POST ',self.calls.read_text())
        self.assertNotIn('/actions/',self.calls.read_text())

    def test_head_movement_refuses(self):
        self.state.update(reviews=[self.review()],moved=OTHER,move_after=2)
        self.assertEqual(self.invoke('merge-guard.sh','--check').returncode,2)

    def test_author_approval_is_not_counted(self):
        self.state['reviews']=[self.review(author='writer')]
        self.assertEqual(self.invoke('merge-guard.sh','--check').returncode,2)

    def test_open_change_request_blocks(self):
        self.state['reviews']=[self.review(),dict(self.review(state='CHANGES_REQUESTED',author='second'),id=13)]
        self.assertEqual(self.invoke('merge-guard.sh','--check').returncode,2)

    def test_newer_hold_overrides_approval(self):
        self.state['reviews']=[self.review()]
        self.state['comments']=[{'created_at':'2026-09-30T00:01:00Z','updated_at':'2026-09-30T00:01:00Z',
            'body':f'verdict: HOLD head: {HEAD} by: independent','author_association':'MEMBER'}]
        self.assertEqual(self.invoke('merge-guard.sh','--check').returncode,2)

    def test_release_failed_ci_refuses(self):
        self.state.update(branch='release/v1',reviews=[self.review(run=True)],ci='failure')
        self.assertEqual(self.invoke('merge-guard.sh','--check','--run','42').returncode,2)

    def test_release_failed_job_refuses(self):
        self.state.update(branch='release/v1',reviews=[self.review(run=True)],job='skipped')
        self.assertEqual(self.invoke('merge-guard.sh','--check','--run','42').returncode,2)

    def test_queue_reports_parent_after_source_review_without_actions(self):
        self.state.update(base='stack/parent',reviews=[self.review()])
        self.fixture.write_text(json.dumps(self.state))
        result=subprocess.run(['bash',str(HERE/'queue-ledger.sh'),'--repo','team/repo'],
                              env=self.env,text=True,capture_output=True,check=False)
        self.assert_ok(result)
        self.assertIn('parent #2',result.stdout)
        self.assertNotIn('/actions/',self.calls.read_text())

    def test_untrusted_approval_is_not_counted(self):
        review=self.review()
        review['author_association']='NONE'
        self.state['reviews']=[review]
        self.assertEqual(self.invoke('merge-guard.sh','--check').returncode,2)

    def test_approval_footer_names_old_head(self):
        review=self.review()
        review['body']=review['body'].replace(f'head `{HEAD}`', f'head `{OTHER}`')
        self.state['reviews']=[review]
        self.assertEqual(self.invoke('merge-guard.sh','--check').returncode,2)

    def test_child_merge_and_check_wait_for_parent(self):
        self.state.update(base='stack/parent',reviews=[self.review()])
        for args in [(), ('--check',)]:
            with self.subTest(args=args):
                result=self.invoke('merge-guard.sh',*args)
                self.assertEqual(result.returncode,2,result.stdout+result.stderr)
                self.assertIn('WAITING PARENT',result.stderr)
                self.assertNotIn('WOULD MERGE',result.stdout)
        self.assertNotIn('/merge-async',self.calls.read_text())

    def test_bottom_merge_write_is_pinned_to_reviewed_head(self):
        self.state['reviews']=[self.review()]
        self.assert_ok(self.invoke('merge-guard.sh'))
        self.assertIn('/merge-async',self.calls.read_text())
        self.assertNotIn('/actions/',self.calls.read_text())

    def test_release_missing_summary_refuses_even_with_success_run(self):
        for workflow,summary in [('.github/workflows/release-candidate.yml','compile / Release checks passed'),
                                 ('.github/workflows/release.yml','verification / Release checks passed')]:
            with self.subTest(workflow=workflow):
                self.state.update(branch='release/v1',reviews=[self.review(run=True)],
                                  workflow=workflow,missing_job=summary)
                self.assertEqual(self.invoke('merge-guard.sh','--check','--run','42').returncode,2)

    def test_release_tag_inventory_allows_expected_skipped_extras(self):
        self.state.update(branch='release/v1',reviews=[self.review(run=True)],workflow='.github/workflows/release.yml')
        self.assert_ok(self.invoke('merge-guard.sh','--check','--run','42'))

    def test_release_run_movement_refuses_before_approval_post(self):
        self.state.update(branch='release/v1',run_moves=True)
        body=self.root/'body'
        body.write_text(f'verdict: PASS head: {HEAD} run: 42 by: independent\nFull release review.')
        result=self.invoke('approve-guard.sh','--body',str(body))
        self.assertEqual(result.returncode,2,result.stdout+result.stderr)
        self.assertNotIn('POST ',self.calls.read_text())
        self.assertNotIn('posted',json.loads(self.fixture.read_text()))

    def test_release_approval_posts_consistent_run_evidence(self):
        self.state.update(branch='release/v1')
        body=self.root/'body'
        body.write_text(f'verdict: PASS head: {HEAD} run: 42 by: independent\nFull release review.')
        self.assert_ok(self.invoke('approve-guard.sh','--body',str(body)))
        posted=json.loads(self.fixture.read_text())['posted']['body']
        self.assertIn('run: 42',posted.splitlines()[0])
        self.assertIn('release run 42',posted.splitlines()[-1])

    def test_release_full_ci_passes(self):
        self.state.update(branch='release/v1',reviews=[self.review(run=True)])
        self.assert_ok(self.invoke('merge-guard.sh','--check','--run','42'))
        self.assertIn('/actions/',self.calls.read_text())

if __name__=='__main__': unittest.main()
