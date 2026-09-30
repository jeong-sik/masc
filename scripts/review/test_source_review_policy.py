#!/usr/bin/env python3
"""Exercise admission with a fake GitHub transport, including mutation races."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

HERE = Path(__file__).resolve().parent
HEAD = 'a' * 40
OTHER = 'b' * 40
FAKE = r'''#!/usr/bin/env python3
import json, os, pathlib, re, subprocess, sys
state = json.loads(pathlib.Path(os.environ['REVIEW_FIXTURE']).read_text())
args = sys.argv[1:]
endpoint = next((a for a in args if a.startswith('repos/') or a == 'user'), '')
log = pathlib.Path(os.environ['REVIEW_CALLS'])
with log.open('a') as f: f.write((args[args.index('-X')+1]+' ' if '-X' in args else '') + endpoint + '\n')
fixture = state
match = re.search(r'/(?:pulls|issues)/(\d+)', endpoint)
number = int(match.group(1)) if match else 1
state = dict(state, **state.get('prs', {}).get(str(number), {}))
head = state['head']
if '/actions/runs?' in endpoint:
    state = next((dict(fixture, **item) for item in fixture.get('prs',{}).values() if item['head'] in endpoint), state)
    head = state['head']
if args[:2] == ['pr','list']:
    data = [{'number':1,'author':{'login':'writer'},'baseRefName':state.get('base','stack/parent'),'headRefOid':head,'headRefName':state.get('branch','stack/change'),'isDraft':False},{'number':2,'author':{'login':'parent-writer'},'baseRefName':'main','headRefOid':'d'*40,'headRefName':'stack/parent','isDraft':True}]
elif re.search(r'/pulls/\d+$', endpoint):
    count = log.read_text().splitlines().count(endpoint)
    current = state.get('moved', head) if count >= state.get('move_after', 100000) else head
    data = {'state':state.get('pr_state','open'),'draft':state.get('draft',False),'merged':state.get('merged',False),'user':{'login':state.get('author','writer')},'base':{'ref':state.get('base','stack/parent'),'sha':'c'*40},'head':{'sha':current,'ref':state.get('branch','stack/change')}}
    if count >= state.get('base_move_after', 100000): data['base']['sha'] = 'f'*40
    if fixture.get('native'):
        members = fixture.get('members', [2,1,3])
        data['stack'] = {'id':99,'number':10,'position':members.index(number)+1,'size':len(members),'base':{'ref':fixture.get('stack_base','main'),'sha':'c'*40}}
elif endpoint.endswith('/stacks/10'):
    members = fixture.get('members', [2,1,3])
    if fixture.get('membership_moves') and log.read_text().splitlines().count(endpoint) > 1:
        members = [1,2,3]
    data = {'id':99,'number':10,'base':{'ref':fixture.get('stack_base','main')},'pull_requests':[]}
    for n in members:
        item = dict(fixture, **fixture.get('prs',{}).get(str(n),{}))
        data['pull_requests'].append({'number':n,'state':item.get('pr_state','open'),'head':{'sha':item['head']}})
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
    data = state.get('reviews', [])
    if '-X' in args:
        body = sys.stdin.read()
        posted = {'id':99,'state':'APPROVED','commit_id':head,'body':body,'author_association':'MEMBER','user':{'login':'reviewer'}}
        state['posted']=posted
        pathlib.Path(os.environ['REVIEW_FIXTURE']).write_text(json.dumps(state))
        data = posted
elif '/reviews/' in endpoint:
    rid = int(endpoint.rsplit('/',1)[1])
    data = state.get('posted') if rid == 99 else next(r for r in state.get('reviews',[]) if r['id']==rid)
elif endpoint.endswith('/merge-async'):
    print(json.dumps({'status':'pending','details':{'uuid':'fixture-request'}})); sys.exit(0)
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
        self.state = {'head':HEAD, 'base':'main'}

    def review(self, state='APPROVED', author='reviewer', verdict='PASS', run=False):
        line = f'verdict: {verdict} head: {HEAD}' + (' run: 42' if run else '') + ' by: independent'
        return {'id':12,'state':state,'body':line+f'\n\n---\napprove-guard: head `{HEAD}` · source review',
                'user':{'login':author},'author_association':'MEMBER','submitted_at':'2026-09-30T00:00:00Z'}

    def invoke(self, script, *args):
        self.fixture.write_text(json.dumps(self.state))
        return subprocess.run(['bash',str(HERE/script),'--repo','team/repo','--pr','1','--head',HEAD,*args],
                              env=self.env,text=True,capture_output=True)

    def assert_ok(self, result):
        self.assertEqual(result.returncode,0,result.stdout+result.stderr)

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
                              env=self.env,text=True,capture_output=True)
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


    def native_stack(self):
        lower_review = self.review()
        lower_review['body'] = lower_review['body'].replace(HEAD, OTHER)
        self.state.update(native=True,base='stack/parent',reviews=[self.review()],
                          prs={'2':{'head':OTHER,'base':'main','branch':'stack/parent','reviews':[lower_review]},
                               '3':{'head':'d'*40,'base':'stack/change','branch':'stack/upper','reviews':[],'draft':True}})

    def test_native_middle_admits_lower_and_selected_without_upper_review(self):
        self.native_stack()
        result = self.invoke('merge-guard.sh','--check')
        self.assert_ok(result)
        self.assertIn('WOULD MERGE #2, #1 through #1', result.stdout)
        calls = self.calls.read_text()
        self.assertIn('/pulls/2/reviews', calls)
        self.assertNotIn('/pulls/3/reviews', calls)
        self.assertNotIn('PUT ', calls)
        self.assertNotIn('POST ', calls)
        self.assertNotIn('/actions/', calls)

    def test_native_lower_blockers_prevent_write(self):
        for change in ({'reviews':[]}, {'reviews':[self.review(state='CHANGES_REQUESTED')]},
                       {'draft':True}, {'comments':[{'created_at':'2026-10-01T00:00:00Z',
                           'body':f'verdict: HOLD head: {OTHER} by: independent','author_association':'MEMBER'}]}):
            with self.subTest(change=change):
                self.native_stack()
                self.state['prs']['2'].update(change)
                result = self.invoke('merge-guard.sh')
                self.assertEqual(result.returncode,2,result.stdout+result.stderr)
                self.assertNotIn('PUT ', self.calls.read_text())

    def test_native_lower_head_drift_prevents_write(self):
        self.native_stack()
        self.state['prs']['2'].update(moved='e'*40,move_after=8)
        result = self.invoke('merge-guard.sh')
        self.assertEqual(result.returncode,2,result.stdout+result.stderr)
        self.assertNotIn('PUT ', self.calls.read_text())

    def test_native_lower_base_drift_prevents_write(self):
        self.native_stack()
        self.state['prs']['2']['base_move_after'] = 8
        result = self.invoke('merge-guard.sh')
        self.assertEqual(result.returncode,2,result.stdout+result.stderr)
        self.assertNotIn('PUT ', self.calls.read_text())

    def test_native_lower_release_requires_its_own_ci(self):
        self.native_stack()
        review = self.review(run=True)
        review['body'] = review['body'].replace(HEAD, OTHER)
        self.state['prs']['2'].update(branch='release/v1',ci='failure',reviews=[review])
        result = self.invoke('merge-guard.sh')
        self.assertEqual(result.returncode,2,result.stdout+result.stderr)
        self.assertIn('/actions/runs?', self.calls.read_text())
        self.assertNotIn('PUT ', self.calls.read_text())

    def test_native_custom_base_and_closed_lower_member(self):
        self.native_stack()
        self.state['stack_base'] = 'trunk'
        self.state['prs']['2'].update(base='trunk',pr_state='closed',merged=True,reviews=[])
        result = self.invoke('merge-guard.sh','--check')
        self.assert_ok(result)
        self.assertIn('WOULD MERGE #1 through #1', result.stdout)
        self.assertNotIn('/pulls/2/reviews', self.calls.read_text())

    def test_native_membership_drift_prevents_write(self):
        self.native_stack()
        self.state['membership_moves'] = True
        result = self.invoke('merge-guard.sh')
        self.assertEqual(result.returncode,2,result.stdout+result.stderr)
        self.assertNotIn('PUT ', self.calls.read_text())

    def test_native_async_acceptance_is_receipt_not_completion(self):
        self.native_stack()
        result = self.invoke('merge-guard.sh')
        self.assert_ok(result)
        self.assertIn('ASYNC MERGE RECEIPT for #2, #1', result.stdout)
        self.assertIn('fixture-request', result.stdout)
        self.assertIn('PUT repos/team/repo/pulls/1/merge-async', self.calls.read_text())
        self.assertNotIn('PUT repos/team/repo/pulls/2', self.calls.read_text())

    def test_native_queue_reports_scope_not_parent_wait(self):
        self.native_stack()
        self.fixture.write_text(json.dumps(self.state))
        result = subprocess.run(['bash',str(HERE/'queue-ledger.sh'),'--repo','team/repo'],
                                env=self.env,text=True,capture_output=True)
        self.assert_ok(result)
        self.assertIn('merge native stack through #1', result.stdout)
        self.assertNotIn('parent #2', result.stdout)

if __name__=='__main__': unittest.main()
