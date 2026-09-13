from pathlib import Path
import json,hashlib,base64,re
p=Path(__file__).resolve().parent
load=lambda n:json.loads((p/n).read_text())
def png(frame):
 parts=None
 for header,data in re.findall(rb'\x1b_G([^;]+);([^\x1b]*)\x1b\\',frame):
  fields=dict(x.split(b'=',1) for x in header.split(b',') if b'=' in x)
  if fields.get(b'a')==b'T':assert fields[b'f']==b'100';parts=[data]
  elif parts is not None and b'm' in fields:parts.append(data)
  if parts is not None and fields.get(b'm')==b'0':return base64.b64decode(b''.join(parts),validate=True)
 raise AssertionError('missing PNG')
r=load('report.json');t=load('tui-gestures.json');b=load('bundle.json')
assert r['result']==t['result']=='passed' and t['tui_exit']==0 and t['cleanup_errors']==[]
assert r['build']['binary_commit']==b['source_commit']==r['live_extension']['source_commit']
assert r['binary_sha256']==b['binaries']['masc-macos-arm64']
assert t['tui_sha256']==b['binaries']['masc-tui-macos-arm64']
assert r['live_extension']['native_host_sha256']==b['binaries']['masc-browser-host-macos-arm64']
client=load('01-live-clients.json')['data']['clients'][0]['clientId']
actions=[x for x in t['receipts'] if x['path'].endswith('/interact')]
assert [x['input']['action'] for x in actions]==['click_at','scroll_at','scroll_at']
assert all(x['status']==200 and x['response']['ok'] and x['input']['lane']=='live' and x['input']['clientId']==client for x in actions)
assert len({x['input']['tabId'] for x in actions})==1
captures=[x for x in t['receipts'] if x['path'].endswith('/screenshot') and x['status']==200 and x['response']['ok']]
assert captures
for captured in captures:
 data=captured['response']['data']
 assert data['source']=='live' and data['clientId']==client
 assert data['tabId']==actions[0]['input']['tabId']
for action in actions:
 assert any(c['completed_monotonic']<action['completed_monotonic']
            and c['response']['data']['viewport']==action['input']['viewport']
            and c['response']['data']['url']==action['input']['expectedUrl'] for c in captures)
raw=(p/'tui-gestures.pty').read_bytes();start=0
for image in t['images']:
 data=(p/('tui-image-'+image['name']+'.png')).read_bytes()
 assert hashlib.sha256(data).hexdigest()==image['png_sha256'] and png(raw[start:image['pty_prefix_bytes']])==data
 assert any(c['response']['data']['data']['sha256']==image['png_sha256'] for c in captures)
 start=image['pty_prefix_bytes']
for name,text in [('click-observed-1.json','Details opened by link click'),('scroll-observed-2.json','Gesture Lab; Pane scroll=120'),('new-document-scroll-observed-5.json','Gesture Lab; Pane scroll=120')]:
 scene=load(name)['data'];assert any(n['text']==text for n in scene['nodes'])
 assert scene['clientId']==client
stale=load('stale-viewport-probe.json');assert stale['status']==400 and stale['response']=={'ok':False,'error':'page_url_changed'}
assert stale['input']==actions[1]['input']
fresh=load('external-navigation-observed-4.json')['data']
assert actions[-1]['input']['expectedUrl']==fresh['url']
assert actions[-1]['input']['viewport']['documentId']==fresh['documentId']!=actions[1]['input']['viewport']['documentId']
assert {x['name']:x['exit'] for x in r['cleanup'] if isinstance(x,dict)}=={'server':0,'driver':0}
assert 'owned live Firefox profile closed' in r['cleanup'] and 'owned unique native host manifest removed' in r['cleanup']
for line in (p/'SHA256SUMS').read_text().splitlines():
 sha,name=line.split(None,1);assert hashlib.sha256((p/name).read_bytes()).hexdigest()==sha,name
print('PASS actual live viewport click, nested scroll, stale guard, fresh document, PNG and cleanup joins')
