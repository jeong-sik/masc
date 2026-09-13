from pathlib import Path
import json,hashlib,re,base64
p=Path(__file__).resolve().parent;c=p/'corrected'
load=lambda name:json.loads((c/name).read_text())
r=load('report.json');t=load('tui-gestures.json');bundle=load('bundle.json')
assert r['result']==t['result']=='passed' and t['tui_exit']==0 and not r['cleanup_errors'] and not t['cleanup_errors']
assert r['source_commit']==r['health_build']['binary_commit']==bundle['source_commit']
assert r['health_build']['executable_sha256']==bundle['binaries']['masc-macos-arm64']
assert t['tui_sha256']==bundle['binaries']['masc-tui-macos-arm64']
a=[x for x in t['receipts'] if x['path'].endswith('/interact')];assert len(a)==1
a=a[0];assert a['status']==200 and a['input']['action']=='drag' and a['input']['lane']=='live' and a['input']['clientId']==r['client_id']
screenshots=[x for x in t['receipts'] if x['path'].endswith('/screenshot') and x['status']==200]
initial=screenshots[0]['response']['data']
assert initial['viewport']==a['input']['viewport'] and initial['url']==a['input']['expectedUrl']
assert initial['clientId']==a['input']['clientId'] and initial['tabId']==a['input']['tabId']
bidi_screens=[x for x in load('bidi.json') if x['request']['method']=='browsingContext.captureScreenshot']
assert len(bidi_screens)==len(screenshots)
for http,bidi in zip(screenshots,bidi_screens):
 data=http['response']['data']
 assert http['input']['clientId']==data['clientId']==r['client_id']
 assert http['input']['tabId']==data['tabId']
 assert bidi['request']['params']['context']==r['mapping'][str(data['tabId'])]
 assert bidi['reply']['id']==bidi['request']['id'] and bidi['reply']['type']=='success'
 captured=base64.b64decode(bidi['reply']['result']['data'],validate=True)
 assert hashlib.sha256(captured).hexdigest()==data['data']['sha256'] and len(captured)==data['data']['bytes']
transport=[x for x in load('transport.json') if x['request']['verb']=='page.interact'];assert len(transport)==1
wire=transport[0];assert wire['request']['args']=={k:v for k,v in a['input'].items() if k not in ['lane','clientId']}
assert wire['reply']['ok'] and wire['request']['id']==wire['reply']['id']
actions=[x for x in load('bidi.json') if x['request']['method']=='input.performActions'];assert len(actions)==1
assert actions[0]['request']['params']['context']==r['mapping'][str(a['input']['tabId'])]
assert actions[0]['reply']['type']=='success'
assert actions[0]['reply']['id']==actions[0]['request']['id']
vp=a['input']['viewport'];origin=a['input']['from'];target=a['input']['to']
expected_steps=[{'type':'pointerMove','x':int(origin['x']*vp['width']),'y':int(origin['y']*vp['height'])},{'type':'pointerDown','button':0},{'type':'pointerMove','duration':180,'x':int(target['x']*vp['width']),'y':int(target['y']*vp['height'])},{'type':'pointerUp','button':0}]
assert actions[0]['request']['params']['actions']==[{'type':'pointer','id':'mouse','parameters':{'pointerType':'mouse'},'actions':expected_steps}]
session=next(x for x in load('bidi.json') if x['request']['method']=='session.new')
assert session['reply']['result']==r['session']
assert load('helper-source-proof.json')['revision']==r['source_commit']
assert {x['name']:x['exit'] for x in r['cleanup']}=={'masc':0,'firefox':-15}
assert 'Card moved; down trusted=true; up trusted=true' in r['after']['1']['text']
assert r['before']['2']==r['after']['2'] and r['before']['1']['url']==r['before']['2']['url']
assert r['stale_rejection']=='observed_viewport_changed'
raw=(c/'tui-gestures.pty').read_bytes();start=0;hashes=[]
for image in t['images']:
 parts=None;decoded=None
 for header,payload in re.findall(rb'\x1b_G([^;]+);([^\x1b]*)\x1b\\',raw[start:image['pty_prefix_bytes']]):
  fields=dict(x.split(b'=',1) for x in header.split(b',') if b'=' in x)
  if fields.get(b'a')==b'T':parts=[payload]
  elif parts is not None and b'm' in fields:parts.append(payload)
  if parts is not None and fields.get(b'm')==b'0':decoded=base64.b64decode(b''.join(parts));break
 png=(c/('tui-image-'+image['name']+'.png')).read_bytes();assert decoded==png
 assert hashlib.sha256(png).hexdigest()==image['png_sha256'];hashes.append(image['png_sha256']);start=image['pty_prefix_bytes']
assert len(set(hashes))==2
screens=[x['response']['data']['data'] for x in t['receipts'] if x['path'].endswith('/screenshot') and x['status']==200]
for digest in hashes:
 assert any(ref['sha256']==digest and ref['bytes']==len((c/('http-image-'+digest+'.png')).read_bytes()) for ref in screens)
 assert hashlib.sha256((c/('http-image-'+digest+'.png')).read_bytes()).hexdigest()==digest
for line in (p/'SHA256SUMS').read_text().splitlines():
 sha,name=line.split(None,1);assert hashlib.sha256((p/name).read_bytes()).hexdigest()==sha,name
print('PASS experimental HTTP/poll/context/BiDi drag route, trusted DOM, other-context isolation and PTY images')
