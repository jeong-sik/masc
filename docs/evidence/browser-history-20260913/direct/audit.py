from pathlib import Path
import json,hashlib,re,base64
p=Path(__file__).resolve().parent
load=lambda n:json.loads((p/n).read_text())
r=load('report.json');assert r['source_commit']=='78049dd1685e531445af721c506c2e92cf3b6958'
assert r['via_automation'] is False and r['capture_exit']==0 and r['server_exit']==-9
assert r['health_build']['binary_commit']==r['source_commit'] and r['health_build']['executable_sha256']==r['server_sha256']
assert r['clients']['data']['clients']==[]
rows={x['execution_id']:x for x in load('tool-calls.json')['entries'] if x.get('execution_id')}
contexts=load('contexts.json');assert len(contexts)==len({c['execution_id'] for c in contexts})==4
for i,c in enumerate(contexts):
 row=rows[c['execution_id']];ref=c['artifact']['_blob'];raw=(p.parent/'observations'/ref['sha256']).read_bytes();scene=json.loads(raw)
 assert hashlib.sha256(raw).hexdigest()==ref['sha256'] and len(raw)==ref['bytes']
 assert c['artifact'] in row['artifact_refs'] and c['keeper']==r['keeper']
 assert c['kind']=='retained_browser_observation' and c['current'] is False
 assert c['observed_at']==row['ts'] and c['documentId']==scene['documentId'] and c['url']==scene['url'] and c['truncated']==scene['truncated']
 osc=re.findall(rb'\x1b\]52;c;([A-Za-z0-9+/=]+)\x07',(p/f'observation-{i}.pty').read_bytes());assert json.loads(base64.b64decode(osc[-1]))==c
b=load('boundary.json');assert (p/'overview-complete.pty').read_bytes()==(p/b['source']).read_bytes()[:b['prefix_bytes']]
text=(p/'overview.txt').read_text();assert contexts[3]['url'] in text and 'Observation 4/4' in text and 'Text 1/4' in text
assert not any(s in text for s in ['Mina','Hana','Cedar','Text 1/18'])
lines=text.splitlines();footer=next(i for i,l in enumerate(lines) if 'Text 1/4' in l);assert all(not l.strip() for l in lines[footer+1:32])
for line in (p/'SHA256SUMS').read_text().splitlines():
 sha,name=line.split(None,1);assert hashlib.sha256((p/name).read_bytes()).hexdigest()==sha,name
print('PASS direct h: 4 authenticated receipt/context/blob matches and clean full overview replay')
