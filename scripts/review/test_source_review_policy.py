"""Exercise admission with a fake GitHub transport, including mutation races."""
import json
import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path
from typing import Any

HERE = Path(os.environ.get('GUARD_SCRIPTS', str(Path(__file__).resolve().parent)))
DIFF_TOOL = Path(__file__).resolve().parent / 'review-diff.py'
HEAD = 'a' * 40
OTHER = 'b' * 40
GIT_SUPPORTS_NO_LAZY_FETCH = subprocess.run(
    ['git', '--no-lazy-fetch', 'version'],
    stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False
).returncode == 0
FAKE = r'''#!/usr/bin/env python3
import json, os, pathlib, re, subprocess, sys
state = json.loads(pathlib.Path(os.environ['REVIEW_FIXTURE']).read_text())
args = sys.argv[1:]
if args[:2] == ['auth', 'git-credential']:
    with pathlib.Path(os.environ['REVIEW_CALLS']).open('a') as f: f.write('CREDENTIAL\n')
    sys.stdin.read()
    print('username=fixture\npassword=offline-unused')
    sys.exit(0)
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
    data = {'state':state.get('pr_state','open'),'draft':state.get('draft',False),'merged':state.get('merged',False),'user':{'login':state.get('author','writer')},'base':{'ref':state.get('base','stack/parent'),'sha':state['base_sha']},'head':{'sha':current,'ref':state.get('branch','stack/change')}}
    if count >= state.get('base_move_after', 100000): data['base']['sha'] = state.get('moved_base', fixture['head'])
    if fixture.get('native'):
        members = fixture.get('members', [2,1,3])
        if fixture.get('stack_target_moves') and count > 1:
            fixture['stack_base'] = fixture['stack_target_moves']
            pathlib.Path(os.environ['REVIEW_FIXTURE']).write_text(json.dumps(fixture))
        data['stack'] = {'id':99,'number':10,'position':members.index(number)+1,'size':len(members),'base':{'ref':fixture.get('stack_base','main'),'sha':fixture.get('stack_base_sha',fixture['base_sha'])}}
elif endpoint.endswith('/stacks/10'):
    members = fixture.get('members', [2,1,3])
    if fixture.get('membership_moves') and log.read_text().splitlines().count(endpoint) > 1:
        members = [1,2,3]
    data = {'id':99,'number':10,'base':{'ref':fixture.get('stack_base','main')},'pull_requests':[]}
    for n in members:
        item = dict(fixture, **fixture.get('prs',{}).get(str(n),{}))
        data['pull_requests'].append({'number':n,'state':item.get('pr_state','open'),'head':{'sha':item['head']}})
elif '/compare/' in endpoint:
    base, compared_head = endpoint.rsplit('/',1)[1].split('...')
    merge_base = subprocess.check_output(['git','--no-replace-objects','-C',os.environ.get('FAKE_COMPARE_REPO', os.environ['GUARD_REPO_ROOT']),'merge-base',base,compared_head],text=True).strip()
    data = {'merge_base_commit':{'sha':None if state.get('bad_compare') else merge_base}}
    compares = sum('/compare/' in row for row in log.read_text().splitlines())
    if compares == state.get('compare_move_after'):
        fixture['base_sha'] = fixture['compare_moved_base']
        pathlib.Path(os.environ['REVIEW_FIXTURE']).write_text(json.dumps(fixture))
    if compares == state.get('compare_block_after'):
        fixture.update(fixture['compare_block_update'])
        pathlib.Path(os.environ['REVIEW_FIXTURE']).write_text(json.dumps(fixture))
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
        global HEAD, OTHER
        self.git_root = self.root / 'repo'
        self.git_root.mkdir()
        self.git('init', '-q', '-b', 'review-fixture')
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
        return {'id':12,'state':state,'body':line+'\n\n---\nreview-scope: '+json.dumps({'base_ref':self.state.get('base','main'),'base_sha':self.state['base_sha'],'stack':None},separators=(',',':'))+f'\napprove-guard: head `{HEAD}` · source review'+footer,
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

    def test_replacement_refs_cannot_change_named_head_or_base_identity(self):
        self.git('replace', HEAD, self.narrowed_base)
        self.assertEqual(self.identity(self.base), self.digest)
        self.git('replace', '-d', HEAD)
        self.git('replace', self.base, OTHER)
        self.assertEqual(self.identity(self.base), self.digest)

    def test_producer_retarget_during_final_compare_refuses_before_post(self):
        body = self.root / 'body'
        body.write_text(f'verdict: PASS head: {HEAD} by: independent\nReviewed source.')
        self.calls.write_text('')
        self.state.update(compare_move_after=3, compare_moved_base=OTHER)
        result = self.invoke('approve-guard.sh', '--body', str(body))
        self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
        self.assertIn('identity moved during review', result.stderr)
        self.assertEqual(sum('/compare/' in line for line in self.calls.read_text().splitlines()), 3)
        self.assertNotIn('POST ', self.calls.read_text())

    def test_producer_rechecks_authority_after_final_compare(self):
        for change in ('CR', 'FAIL', 'HOLD'):
            with self.subTest(change=change):
                self.calls.write_text('')
                body = self.root / 'body'
                body.write_text(f'verdict: PASS head: {HEAD} by: independent\nReviewed source.')
                self.state = dict(head=HEAD, base='main', base_sha=self.base)
                update = (
                    {'reviews': [dict(self.review(state='CHANGES_REQUESTED', author='other'), id=13)]}
                    if change == 'CR' else {'comments': [{
                        'created_at':'2026-10-01T00:00:00Z', 'author_association':'MEMBER',
                        'body': f'verdict: {change} head: {HEAD} by: independent'}]})
                self.state.update(compare_block_after=3, compare_block_update=update)
                result = self.invoke('approve-guard.sh', '--body', str(body))
                self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
                self.assertNotIn('POST ', self.calls.read_text())
                self.assertEqual(sum('/compare/' in line for line in self.calls.read_text().splitlines()), 3)

    def test_merge_rechecks_authority_after_final_compare(self):
        for change in ('CR', 'FAIL', 'HOLD', 'noapproval'):
            with self.subTest(change=change):
                self.calls.write_text('')
                self.state = dict(head=HEAD, base='main', base_sha=self.base,
                                  reviews=[self.review()])
                update = {'reviews': []} if change == 'noapproval' else (
                    {'reviews': [self.review(), dict(self.review(state='CHANGES_REQUESTED', author='other'), id=13)]}
                    if change == 'CR' else {'comments': [{
                        'created_at':'2026-10-01T00:00:00Z', 'author_association':'MEMBER',
                        'body': f'verdict: {change} head: {HEAD} by: independent'}]})
                self.state.update(compare_block_after=2, compare_block_update=update)
                result = self.invoke('approve-guard.sh', '--merge-check', '--receipt-json')
                self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
                self.assertEqual(result.stdout, '')
                self.assertNotIn('POST ', self.calls.read_text())
                self.assertEqual(sum('/compare/' in line for line in self.calls.read_text().splitlines()), 2)

    def test_missing_objects_fetch_uses_gh_credentials_without_prompting(self):
        self.assert_authenticated_object_fetch('shallow')

    def test_missing_root_and_nested_trees_use_isolated_authenticated_fetch(self):
        for kind in ('tree:0', 'tree:1'):
            with self.subTest(kind=kind):
                self.assert_authenticated_object_fetch(kind)

    def assert_authenticated_object_fetch(self, kind):
        # Use a real filtered repository and real object fetches. Only the remote
        # transport is redirected to our local fixture; no network is contacted.
        original = self.git_root
        self.calls.write_text('')
        self.env.update(GUARD_GH=str(self.fake), GUARD_REPO_ROOT=str(original), PATH=os.environ['PATH'])
        if kind != 'shallow':
            global HEAD
            (original / 'nested').mkdir(exist_ok=True)
            self.commit_file('nested/feature.txt', kind)
            HEAD = self.git('rev-parse', 'HEAD')
            self.state['head'] = HEAD
            self.digest = self.identity(self.base)
        empty = self.root / kind.replace(':', '-')
        subprocess.run(['git', '-C', str(original), 'config', 'uploadpack.allowFilter', 'true'], check=True)
        clone_args = ['--depth=1'] if kind == 'shallow' else ['--no-checkout', '--filter='+kind]
        subprocess.run(['git', 'clone', '--quiet', *clone_args, '--no-local', str(original), str(empty)], check=True)
        shallow = empty / '.git/shallow'
        before_shallow = shallow.read_bytes() if shallow.exists() else None
        before_config = (empty / '.git/config').read_bytes()
        lazy_flag = ['--no-lazy-fetch'] if GIT_SUPPORTS_NO_LAZY_FETCH else []
        no_lazy_env = {} if GIT_SUPPORTS_NO_LAZY_FETCH else {'GIT_NO_LAZY_FETCH': '1'}
        if kind != 'shallow':
            for commit in (self.base, HEAD):
                subprocess.run(['git', *lazy_flag, '-C', str(empty), 'cat-file', '-e', commit], check=True, env={**os.environ, **no_lazy_env})
            missing_tree = subprocess.run(['git', *lazy_flag, '-C', str(empty), 'ls-tree', '-r', HEAD], capture_output=True, env={**os.environ, **no_lazy_env})
            self.assertNotEqual(missing_tree.returncode, 0, 'fixture must contain commits but lack required trees')
        helper_dir = self.root / ("credential helper's directory " + kind.replace(':', '-'))
        helper_dir.mkdir()
        helper = helper_dir / 'gh'
        helper.write_text(FAKE)
        helper.chmod(0o755)
        commands = empty / 'git-commands.jsonl'
        real_git = shutil.which('git')
        wrapper_dir = empty / 'bin'
        wrapper_dir.mkdir()
        wrapper = wrapper_dir / 'git'
        wrapper.write_text("#!/usr/bin/env python3\n" +
            "import json, os, subprocess, sys\n" +
            f"real_git={real_git!r}\nremote={str(original)!r}\nrecord={str(commands)!r}\n" +
            "args=sys.argv[1:]\n" +
            "if 'fetch' in args:\n" +
            "    with open(record, 'a') as f: f.write(json.dumps({'args':args,'env':{k:os.environ.get(k) for k in ['GIT_TERMINAL_PROMPT','GIT_ASKPASS','SSH_ASKPASS','GCM_INTERACTIVE']}})+'\\n')\n" +
            "    prefix=args[:args.index('fetch')]\n" +
            "    auth=subprocess.run([real_git,*prefix,'credential','fill'],input='protocol=https\\nhost=github.com\\n\\n',text=True,capture_output=True)\n" +
            "    if auth.returncode or 'username=fixture' not in auth.stdout: sys.exit(7)\n" +
            "    args=['file://'+remote if a.startswith('https://github.com/') else a for a in args]\n" +
            "rc=subprocess.run([real_git,*args]).returncode\n" +
            "if 'fetch' in args and rc == 0:\n" +
            "    kinds=subprocess.check_output([real_git,*args[:args.index('fetch')],'cat-file','--batch-all-objects','--batch-check=%(objecttype)'],text=True).splitlines()\n" +
            "    with open(record+'.objects', 'a') as f: f.write(json.dumps(kinds)+'\\n')\n" +
            "sys.exit(rc)\n")
        wrapper.chmod(0o755)
        self.env.update(GUARD_GH=str(helper), GUARD_REPO_ROOT=str(empty),
                        FAKE_COMPARE_REPO=str(original),
                        PATH=str(wrapper_dir) + os.pathsep + os.environ['PATH'])
        before_objects = subprocess.check_output(
            [real_git, '-C', str(empty), 'cat-file', '--batch-all-objects', '--batch-check=%(objectname) %(objecttype)'],
            text=True,
        ).splitlines()
        self.assertEqual(self.identity(self.base), self.digest)
        after_objects = subprocess.check_output(
            [real_git, '-C', str(empty), 'cat-file', '--batch-all-objects', '--batch-check=%(objectname) %(objecttype)'],
            text=True,
        ).splitlines()
        self.assertEqual(before_objects, after_objects, 'caller repository must not receive any new objects')
        fetched = [json.loads(line) for line in commands.read_text().splitlines()]
        self.assertEqual(len(fetched), 2)
        object_snapshots = [json.loads(line) for line in Path(str(commands)+'.objects').read_text().splitlines()]
        self.assertEqual([kinds.count('commit') for kinds in object_snapshots], [1, 2])
        self.assertTrue(all('blob' not in kinds for kinds in object_snapshots),
                        'raw diff fetch needs trees and exact commits, not file contents')
        for call in fetched:
            self.assertIn('--no-replace-objects', call['args'])
            if GIT_SUPPORTS_NO_LAZY_FETCH:
                self.assertIn('--no-lazy-fetch', call['args'])
            else:
                self.assertNotIn('--no-lazy-fetch', call['args'])
            fetched_root = Path(call['args'][call['args'].index('-C')+1])
            self.assertNotEqual(fetched_root, empty)
            self.assertIn('--depth=1', call['args'])
            self.assertIn('--filter=blob:none', call['args'])
            self.assertIn('credential.helper=', call['args'])
            self.assertEqual(call['env'], {'GIT_TERMINAL_PROMPT':'0','GIT_ASKPASS':'false',
                                          'SSH_ASKPASS':'false','GCM_INTERACTIVE':'Never'})
        self.assertEqual(self.calls.read_text().splitlines().count('CREDENTIAL'), 2)
        self.assertEqual(shallow.read_bytes() if shallow.exists() else None, before_shallow)
        self.assertEqual((empty / '.git/config').read_bytes(), before_config)
        missing_args = ['cat-file', '-e', self.base] if kind == 'shallow' else ['ls-tree', '-r', HEAD]
        still_missing = subprocess.run([real_git, *lazy_flag, '-C', str(empty), *missing_args], capture_output=True, env={**os.environ, **no_lazy_env})
        self.assertNotEqual(still_missing.returncode, 0, 'isolated fetch must not hydrate or deepen caller history')
        persisted = subprocess.run([real_git, '-C', str(empty), 'config', '--local',
                                    '--get-all', 'credential.helper'], capture_output=True)
        self.assertEqual(persisted.returncode, 1)
        self.assertEqual(persisted.stdout, b'')

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
        scope = next(line.removeprefix('review-scope: ') for line in posted['body'].splitlines()
                     if line.startswith('review-scope: '))
        self.assertEqual(json.loads(scope), {'base_ref':'stack/parent','base_sha':self.state['base_sha'],'stack':None})
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

    def test_retargeted_same_head_can_receive_fresh_scoped_approval(self):
        self.state['reviews']=[self.review()]
        self.state['base']='stack/new-parent'
        body=self.root/'body'
        body.write_text(f'verdict: PASS head: {HEAD} by: independent\nReviewed the changed diff.')
        self.assert_ok(self.invoke('approve-guard.sh','--body',str(body)))
        posted=json.loads(self.fixture.read_text())['posted']
        self.assertIn('"base_ref":"stack/new-parent"', posted['body'])

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


    def native_lower_review(self, *, run=False, state="APPROVED"):
        review = self.review(run=run, state=state)
        review['commit_id'] = self.base
        review['body'] = review['body'].replace(HEAD, self.base)
        review['body'] = review['body'].replace(
            f" · reviewed base `{self.base}` · diff sha256 `{self.digest}`",
            f" · reviewed base `{OTHER}` · diff sha256 `{self.identity(OTHER, self.base)}`")
        return review

    def native_stack(self):
        lower_review = self.native_lower_review()
        self.state.update(native=True, base='stack/parent', stack_base_sha=OTHER,
                          reviews=[self.review()],
                          prs={'2':{'head':self.base, 'base':'main', 'base_sha':OTHER,
                                    'branch':'stack/parent','reviews':[lower_review]},
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
        for change in ({'reviews':[]}, {'reviews':[self.native_lower_review(state='CHANGES_REQUESTED')]},
                       {'draft':True}, {'comments':[{'created_at':'2026-10-01T00:00:00Z',
                           'body':f'verdict: HOLD head: {self.base} by: independent','author_association':'MEMBER'}]}):
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
        review = self.native_lower_review(run=True)
        self.state['prs']['2'].update(branch='release/v1',ci='failure',reviews=[review])
        result = self.invoke('merge-guard.sh')
        self.assertEqual(result.returncode,2,result.stdout+result.stderr)
        self.assertIn('/actions/runs?', self.calls.read_text())
        self.assertNotIn('PUT ', self.calls.read_text())

    def test_native_custom_base_and_merged_lower_member(self):
        self.native_stack()
        self.state['stack_base'] = 'feature/integration'
        self.state['prs']['2'].update(base='feature/integration',pr_state='closed',merged=True,reviews=[])
        result = self.invoke('merge-guard.sh','--check')
        self.assert_ok(result)
        self.assertIn('WOULD MERGE #1 through #1 into feature/integration', result.stdout)
        self.assertNotIn('/pulls/2/reviews', self.calls.read_text())

    def test_native_closed_unmerged_lower_member_prevents_write(self):
        for args in (('--check',), ()):
            with self.subTest(args=args):
                self.native_stack()
                self.state['prs']['2'].update(pr_state='closed', merged=False, reviews=[])
                result = self.invoke('merge-guard.sh', *args)
                self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
                self.assertIn('#2 is closed without merging', result.stderr)
                self.assertNotIn('WOULD MERGE', result.stdout)
                calls = self.calls.read_text()
                self.assertNotIn('PUT ', calls)
                self.assertNotIn('POST ', calls)

    def test_native_closed_unmerged_upper_member_is_outside_scope(self):
        self.native_stack()
        self.state['prs']['3'].update(pr_state='closed', merged=False)
        result = self.invoke('merge-guard.sh', '--check')
        self.assert_ok(result)
        self.assertIn('WOULD MERGE #2, #1 through #1', result.stdout)
        calls = self.calls.read_text()
        self.assertNotIn('/pulls/3', calls)
        self.assertNotIn('PUT ', calls)
        self.assertNotIn('POST ', calls)

    def test_native_membership_drift_prevents_write(self):
        self.native_stack()
        self.state['membership_moves'] = True
        result = self.invoke('merge-guard.sh')
        self.assertEqual(result.returncode,2,result.stdout+result.stderr)
        self.assertNotIn('PUT ', self.calls.read_text())

    def test_native_async_acceptance_is_receipt_not_completion(self):
        self.native_stack()
        self.state['stack_base'] = 'feature/integration'
        result = self.invoke('merge-guard.sh')
        self.assert_ok(result)
        self.assertIn('ASYNC MERGE RECEIPT for #2, #1 (preflight target: feature/integration; accepted destination unconfirmed', result.stdout)
        self.assertIn('fixture-request', result.stdout)
        self.assertIn('PUT repos/team/repo/pulls/1/merge-async', self.calls.read_text())
        self.assertNotIn('PUT repos/team/repo/pulls/2', self.calls.read_text())

    def test_native_queue_uses_guard_target_after_initial_read(self):
        self.native_stack()
        self.state.update(stack_base='feature/old', stack_target_moves='feature/current')
        self.fixture.write_text(json.dumps(self.state))
        result=subprocess.run(['bash',str(HERE/'queue-ledger.sh'),'--repo','team/repo'],
            env=self.env,text=True,capture_output=True)
        self.assert_ok(result)
        self.assertIn('merge native stack through #1 into feature/current', result.stdout)
        self.assertNotIn('feature/old', result.stdout)
        self.assertNotIn('PUT ', self.calls.read_text())

    def test_native_queue_escapes_markdown_target_only(self):
        for fmt, expected in [('md', r'feature/a\|b'), ('tsv', 'feature/a|b')]:
            self.native_stack()
            self.state['stack_base']='feature/a|b'
            self.fixture.write_text(json.dumps(self.state))
            result=subprocess.run(['bash',str(HERE/'queue-ledger.sh'),'--repo','team/repo','--format',fmt],
                env=self.env,text=True,capture_output=True)
            self.assert_ok(result)
            self.assertIn('merge native stack through #1 into '+expected, result.stdout)

    def test_guard_json_requires_read_only_check(self):
        result=self.invoke('merge-guard.sh','--scope-json')
        self.assertNotEqual(result.returncode,0)
        self.assertNotIn('PUT ', self.calls.read_text())

    def test_native_queue_reports_scope_not_parent_wait(self):
        self.native_stack()
        self.state['stack_base'] = 'feature/integration'
        self.fixture.write_text(json.dumps(self.state))
        result = subprocess.run(['bash',str(HERE/'queue-ledger.sh'),'--repo','team/repo'],
                                env=self.env,text=True,capture_output=True)
        self.assert_ok(result)
        self.assertIn('merge native stack through #1 into feature/integration', result.stdout)
        self.assertNotIn('parent #2', result.stdout)

if __name__=='__main__': unittest.main()
