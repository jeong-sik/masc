"""Offline context/receipt/blob/replayed-text correlation; never contacts a runtime."""
from pathlib import Path
import hashlib,json,base64,re
p=Path(__file__).resolve().parent
load=lambda name:json.loads((p/name).read_text())
report=load('report.json');contexts=load('contexts.json');rows={r['execution_id']:r for r in load('tool-calls.json')['entries'] if r.get('execution_id')}
assert report['capture_exit']==0 and report['server_exit']==0 and report['via_automation'] is True
assert report['clients']['data']['clients']==[] and len(contexts)==4
assert len({c['execution_id'] for c in contexts})==4
for index,c in enumerate(contexts):
 row=rows[c['execution_id']];blob=c['artifact']['_blob'];raw=(p/'observations'/blob['sha256']).read_bytes();scene=json.loads(raw)
 assert hashlib.sha256(raw).hexdigest()==blob['sha256'] and len(raw)==blob['bytes']
 assert c['artifact'] in row['artifact_refs']
 assert c['kind']=='retained_browser_observation' and c['current'] is False
 assert c['keeper']==report['keeper'] and c['observed_at']==row['ts']
 assert c['documentId']==scene['documentId'] and c['url']==scene['url'] and c['truncated']==scene['truncated']
 pty=(p/f'observation-{index}.pty').read_bytes()
 copies=re.findall(rb'\x1b\]52;c;([A-Za-z0-9+/=]+)\x07',pty)
 assert json.loads(base64.b64decode(copies[-1]))==c
 text=(p/('overview-render-settled.txt' if index==3 else f'observation-{index}.txt')).read_text()
 assert scene['url'] in text and scene['title'] in text and 'Historical read' in text
 channel=scene['url'].rsplit('/',1)[-1].split('.')[0]
 needles={'alpha':'accessibility checklist Monday','beta':'client payload before migration starts','gamma':'end-to-end QA Wednesday','index':'Channels'}
 assert needles[channel] in ' '.join(text.split())
 if channel=='index':
  assert not any(old in text for old in ['Mina','Hana','Cedar','Text 1/18','Current decision','Superseded'])
  lines=text.splitlines();footer=next(i for i,line in enumerate(lines) if 'Text 1/4' in line)
  assert all(not line.strip() for line in lines[footer+1:32]), 'stale body below scoped navigation'
boundary=load('replay-boundary.json')
assert (p/'observation-3-complete.pty').read_bytes()==(p/boundary['source']).read_bytes()[:boundary['prefix_bytes']]
for line in (p/'SHA256SUMS').read_text().splitlines():
 sha,name=line.split(None,1);assert hashlib.sha256((p/name).read_bytes()).hexdigest()==sha,name
print('PASS: four exact copied contexts, receipts, blob hashes and replayed page/body combinations')
