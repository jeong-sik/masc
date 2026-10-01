"""Real isolated Git plus read-only fake GitHub for source approval boundaries."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

FAKE = r'''#!/usr/bin/env python3
import json, os, pathlib, subprocess, sys
root = pathlib.Path(sys.argv[0]).parent
args = sys.argv[1:]
endpoint = next((a for a in args if a.startswith('repos/') or a == 'user'), '')
with (root/'requests.jsonl').open('a') as out: out.write(endpoint+'\n')
fixture_file = root/'fixture.json'
data = json.loads(fixture_file.read_text()) if fixture_file.exists() else {}
if endpoint in data:
    value = data[endpoint]
elif '/compare/' in endpoint:
    base, compared_head = endpoint.rsplit('/', 1)[1].split('...')
    repo_dir = pathlib.Path(os.environ.get('GUARD_REPO_ROOT', str(root/'repo')))
    merge_base = subprocess.check_output(
        ['git', '--no-replace-objects', '-C', str(repo_dir), 'merge-base', base, compared_head],
        text=True
    ).strip()
    value = {'merge_base_commit': {'sha': merge_base}}
else:
    print('unexpected endpoint '+endpoint, file=sys.stderr); sys.exit(3)
if '--jq' in args:
    q = subprocess.run(['jq','-r',args[args.index('--jq')+1]], input=json.dumps(value), text=True, capture_output=True)
    sys.stdout.write(q.stdout); sys.stderr.write(q.stderr); sys.exit(q.returncode)
print(json.dumps(value))
'''


class ApprovedSelectionFixture(unittest.TestCase):
    """Selected heads, real Git tree inputs and live source-review metadata."""
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.repo = self.root/'repo'
        self.repo.mkdir()
        self.git('init','-q','-b','main')
        self.git('config','user.name','Fixture')
        self.git('config','user.email','fixture@example.invalid')
        self.git('config','core.hooksPath','/dev/null')
        self.git('config','commit.gpgSign','false')
        self.git('commit','-q','--allow-empty','-m','base')
        self.base = self.git('rev-parse','HEAD')
        remote = self.root/'remote.git'
        subprocess.run(['git','init','--bare','-q',str(remote)],check=True)
        self.git('remote','add','origin',str(remote))
        self.heads = {}
        for pr,name in [(1,'one'),(2,'two')]:
            self.git('checkout','-q','-b',name,self.base)
            (self.repo/'lib').mkdir(exist_ok=True)
            (self.repo/'lib'/f'{name}.ml').write_text(f'let {name} = {pr}\n')
            self.git('add','lib')
            self.git('commit','-q','-m',name)
            self.heads[pr] = self.git('rev-parse','HEAD')
        self.git('checkout','-q','main')
        self.fake = self.root/'gh'
        self.fake.write_text(FAKE)
        self.fake.chmod(0o755)
        self.fixture = self.root/'fixture.json'
        (self.root/'requests.jsonl').write_text('')
        self.data = {'user':{'login':'operator'},'repos/o/r/commits/main':{'sha':self.base}}
        for pr,head in self.heads.items():
            self.put(f'pulls/{pr}',{'state':'open','draft':False,'merged':False,
                'user':{'login':'writer'},'base':{'ref':'main','sha':self.base},
                'head':{'sha':head,'ref':f'feature/{pr}'}})
            self.put(f'issues/{pr}/comments',[])
        self.fixture.write_text(json.dumps(self.data))
        old_repo_root = os.environ.get('GUARD_REPO_ROOT')
        os.environ['GUARD_REPO_ROOT'] = str(self.repo)
        def restore_env():
            if old_repo_root is None:
                os.environ.pop('GUARD_REPO_ROOT', None)
            else:
                os.environ['GUARD_REPO_ROOT'] = old_repo_root
        self.addCleanup(restore_env)

    def git(self,*args):
        return subprocess.check_output(['git','-C',str(self.repo),*args],text=True).strip()

    def get(self,path):
        return self.data['repos/o/r/'+path]

    def put(self,path,value):
        self.data['repos/o/r/'+path] = value

    def api(self,gh,path):
        return json.loads(json.dumps(self.data[path]))

    def diff(self, base, head):
        env = os.environ | {'GUARD_GH': str(self.fake), 'GUARD_REPO_ROOT': str(self.repo)}
        diff_tool = Path(__file__).with_name('review-diff.py')
        return subprocess.check_output(
            [sys.executable, str(diff_tool), '--repo', 'o/r', '--base', base, '--head', head],
            env=env, text=True).strip()

    def approvals(self, legacy=False):
        for pr,head in self.heads.items():
            footer = '' if legacy else f' · reviewed base `{self.base}` · diff sha256 `{self.diff(self.base, head)}`'
            row = {'id':pr*10,'state':'APPROVED','user':{'login':'reviewer'},
                'author_association':'MEMBER','submitted_at':'2026-09-30T00:00:00Z',
                'body': (f'verdict: PASS head: {head} by: reviewer\n\n'
                         + 'review-scope: ' + json.dumps({'base_ref':'main','base_sha':self.base,'stack':None})
                         + f'\napprove-guard: head `{head}` · source review{footer}')}
            self.put(f'pulls/{pr}/reviews?per_page=100',[row])
            self.put(f'pulls/{pr}/reviews',[row])
            self.put(f'pulls/{pr}/reviews/{row["id"]}',row)
