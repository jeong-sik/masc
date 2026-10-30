#!/usr/bin/env python3
"""Prove dev-source mapping and one source edit/readback in an owned Gecko fixture.
Requires an already-running Vite dev server for this checkout. No build is run.
"""
import argparse, base64, hashlib, json, socket, subprocess, time, urllib.error, urllib.request
from pathlib import Path

p = argparse.ArgumentParser()
p.add_argument('--driver', required=True)
p.add_argument('--browser', required=True)
p.add_argument('--url', required=True)
p.add_argument('--out', type=Path, required=True)
a = p.parse_args()
a.out.mkdir(parents=True, exist_ok=True)
root = Path(__file__).resolve().parents[1]
runtime = (root/'lib/browser_scene_script.ml').read_text().split('let runtime = {js|',1)[1].split('|js}',1)[0]
interaction = (root/'lib/browser_interaction.ml').read_text().split('let script = {js|',1)[1].split('|js}',1)[0]
with socket.socket() as sock:
    sock.bind(('127.0.0.1',0))
    port = sock.getsockname()[1]
log = (a.out/'driver.log').open('wb')
process = subprocess.Popen([a.driver,'--host','127.0.0.1','--port',str(port),'--websocket-port','0'],stdout=log,stderr=log)
base = f'http://127.0.0.1:{port}'
sid = None
changed_file = None
original = None
checks = []

def call(method,path,body=None):
    req = urllib.request.Request(base+path, method=method,
        data=None if body is None else json.dumps(body).encode(), headers={'Content-Type':'application/json'})
    try:
        with urllib.request.urlopen(req,timeout=30) as response: raw = response.read()
    except urllib.error.HTTPError as error: raw = error.read()
    value = json.loads(raw)['value']
    if isinstance(value,dict) and 'error' in value:
        raise RuntimeError(value['error']+': '+value.get('message',''))
    return value

def js(script,args=None):
    return call('POST',f'/session/{sid}/execute/sync',{'script':script,'args':args or []})

def check(name,condition):
    if not condition: raise AssertionError(name)
    checks.append(name)

def ready():
    deadline=time.monotonic()+30
    while not js("return !!document.querySelector('[data-proof=counter]');"):
        if time.monotonic()>deadline: raise RuntimeError('fixture did not render')
        time.sleep(.1)

def observe():
    return js(runtime+'\nreturn browserScene(arguments[0]);',[{'mode':'read','maxChars':50000}])

def click(scene,node):
    return js(runtime+interaction,[{'action':'click','documentId':scene['documentId'],
        'nodeId':node['nodeId'],'expectedUrl':scene['url']}])

def screenshot(name):
    png=base64.b64decode(call('GET',f'/session/{sid}/screenshot'),validate=True)
    (a.out/name).write_bytes(png)
    return {'file':name,'bytes':len(png),'sha256':hashlib.sha256(png).hexdigest()}

try:
    deadline=time.monotonic()+10
    while True:
        try: call('GET','/status'); break
        except (urllib.error.URLError,ConnectionError):
            if time.monotonic()>deadline: raise
            time.sleep(.1)
    caps=call('POST','/session',{'capabilities':{'alwaysMatch':{'browserName':'firefox',
        'moz:firefoxOptions':{'binary':a.browser,'args':['-headless']}}}})
    sid=caps['sessionId']
    call('POST',f'/session/{sid}/window/rect',{'width':1280,'height':1000})
    call('POST',f'/session/{sid}/url',{'url':a.url})
    ready()
    scene=observe()
    (a.out/'scene-before.json').write_text(json.dumps(scene,ensure_ascii=False,indent=2))
    button=next(node for node in scene['nodes'] if node['text']=='Count 0')
    source=button['sourceContext']
    check('scene exposes source for observed control',source['schema']=='masc.source.v1' and source['kind']=='template')
    candidates=js("return Array.from(document.querySelectorAll('[data-proof]'),el=>({id:el.dataset.proof,source:JSON.parse(el.getAttribute('data-masc-source'))}));")
    # Open the dialog so the measured inventory includes a mounted modal.
    click(scene,next(node for node in scene['nodes'] if node['text']=='Open dialog'))
    modal=js("return Array.from(document.querySelectorAll('dialog [data-proof],dialog[data-proof]'),el=>({id:el.dataset.proof,source:JSON.parse(el.getAttribute('data-masc-source'))}));")
    candidates.extend(modal)
    check('at least twenty mounted source targets',len(candidates)>=20)
    for candidate in candidates:
        context=candidate['source']
        path=(root/context['file']).resolve()
        check('checkout containment '+candidate['id'],path.is_relative_to(root))
        text=path.read_text()
        check('original file hash '+candidate['id'],hashlib.sha256(path.read_bytes()).hexdigest()==context['digest'])
        line=text.splitlines()[context['line']-1]
        position=line[context['column']-1:]
        check('declared source position '+candidate['id'],position.startswith('html`') if context['kind']=='template' else position.startswith('<button'))
    check('JSX gets element precision',next(c['source']['kind'] for c in candidates if c['id']=='jsx')=='element')
    fresh=observe()
    click(fresh,next(node for node in fresh['nodes'] if node['text']=='Close dialog'))
    click(scene,button)
    check('handler still works after instrumentation',js("return document.querySelector('[data-proof=counter]').textContent;")=='Count 1')
    before=screenshot('before.png')
    changed_file=(root/source['file']).resolve()
    check('selected source belongs to owned fixture',changed_file==root/'dashboard/src/demo/browser-source-fixture.tsx')
    original=changed_file.read_bytes()
    check('source digest matches immediately before edit',hashlib.sha256(original).hexdigest()==source['digest'])
    check('single exact edit anchor',original.count(b'Count ${count}')==1)
    changed_file.write_bytes(original.replace(b'Count ${count}',b'Clicks ${count}'))
    call('POST',f'/session/{sid}/refresh',{})
    ready()
    # Vite file watching and HMR can finish after the first post-edit load.
    # Wait for the observed source digest, not just an already-mounted button.
    deadline=time.monotonic()+30
    expected_digest=hashlib.sha256(changed_file.read_bytes()).hexdigest()
    while True:
        latest=observe()
        new=next((node for node in latest['nodes'] if node['text'].startswith('Clicks ')
            and node['sourceContext'] and node['sourceContext'].get('digest')==expected_digest),None)
        if new: break
        if time.monotonic()>deadline: raise RuntimeError('edited source never appeared in browser')
        time.sleep(.1)
    count_before=int(new['text'].split(' ')[1])
    check('source change reaches browser on reload',new['sourceContext']['digest']==hashlib.sha256(changed_file.read_bytes()).hexdigest())
    check('old source digest is now stale',source['digest']!=new['sourceContext']['digest'])
    try:
        click(scene,button)
        raise AssertionError('stale document reference accepted')
    except RuntimeError as error:
        check('old document cannot actuate the new source','scene_document_changed' in str(error))
    click(latest,new)
    check('changed implementation remains interactive',js("return document.querySelector('[data-proof=counter]').textContent;")==f'Clicks {count_before+1}')
    after=screenshot('after.png')
    report={'checks':checks,'mapped_targets':len(candidates),'source_targets':candidates,
        'browserVersion':caps['capabilities']['browserVersion'],'screenshots':[before,after],
        'scope':'real Vite instrumentation + Gecko shared scene script + exact source edit + reload + interaction; not a new OCaml/TUI binary or autonomous Keeper benchmark'}
    (a.out/'proof.json').write_text(json.dumps(report,ensure_ascii=False,indent=2))
    print(json.dumps({'mapped_targets':len(candidates),'checks':len(checks),'scope':report['scope']}))
finally:
    if changed_file is not None and original is not None: changed_file.write_bytes(original)
    if sid:
        try: call('DELETE',f'/session/{sid}')
        except (urllib.error.URLError,RuntimeError): pass
    process.terminate();process.wait(timeout=5);log.close()
