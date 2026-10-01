"""Real isolated Git plus read-only fake GitHub for source approval boundaries."""
import json
import subprocess
import tempfile
import unittest
from pathlib import Path

FAKE = r'''#!/usr/bin/env python3
import json, pathlib, subprocess, sys
root = pathlib.Path(sys.argv[0]).parent
args = sys.argv[1:]
endpoint = next((a for a in args if a.startswith('repos/') or a == 'user'), '')
with (root/'requests.jsonl').open('a') as out: out.write(endpoint+'\n')
data = json.loads((root/'fixture.json').read_text())
if endpoint not in data:
    print('unexpected endpoint '+endpoint, file=sys.stderr); sys.exit(3)
value = data[endpoint]
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

    def git(self,*args):
        return subprocess.check_output(['git','-C',str(self.repo),*args],text=True).strip()

    def get(self,path):
        return self.data['repos/o/r/'+path]

    def put(self,path,value):
        self.data['repos/o/r/'+path] = value

    def api(self,gh,path):
        return json.loads(json.dumps(self.data[path]))

    def approvals(self):
        for pr,head in self.heads.items():
            row = {'id':pr*10,'state':'APPROVED','user':{'login':'reviewer'},
                'author_association':'MEMBER','submitted_at':'2026-09-30T00:00:00Z',
                'body': (f'verdict: PASS head: {head} by: reviewer\n\n'
                         + 'review-scope: ' + json.dumps({'base_ref':'main','base_sha':self.base,'stack':None})
                         + f'\napprove-guard: head `{head}` · source review')}
            self.put(f'pulls/{pr}/reviews?per_page=100',[row])
            self.put(f'pulls/{pr}/reviews',[row])
            self.put(f'pulls/{pr}/reviews/{row["id"]}',row)
