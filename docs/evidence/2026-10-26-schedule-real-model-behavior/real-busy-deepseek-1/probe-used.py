#!/usr/bin/env python3
"""Actual installed server, disposable workspace, scheduled arrival while the same Keeper is already executing work."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import socket
import subprocess
import tempfile
import time
import urllib.error
import urllib.request

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--output', type=Path, required=True)
parser.add_argument('--binary', type=Path, required=True)
parser.add_argument('--image-reference', required=True)
parser.add_argument('--provider', choices=['ollama_cloud','glm-coding'], required=True)
args = parser.parse_args()
output = args.output.resolve()
output.mkdir(parents=True, exist_ok=False)
repo = Path.cwd()
binary = args.binary.resolve(strict=True)
records = []
checks = []


def save():
    (output / 'api-records.json').write_text(json.dumps(records, indent=2) + '\n')
    (output / 'checks.json').write_text(json.dumps(checks, indent=2) + '\n')


def check(name, condition, detail=None):
    checks.append({'name': name, 'passed': bool(condition), 'detail': detail})
    save()
    print(('PASS ' if condition else 'FAIL ') + name, flush=True)
    if not condition:
        raise RuntimeError(name)


def command(argv, env):
    result = subprocess.run(argv, env=env, capture_output=True, text=True)
    if result.returncode:
        raise RuntimeError(str(argv[:2]) + ' failed: ' + result.stderr[-2000:])
    # login output contains a credential and is intentionally never retained.
    return result.stdout


def request(path, token=None, body=None):
    headers = {'Content-Type': 'application/json'}
    if token:
        headers['Authorization'] = 'Bearer ' + token
    req = urllib.request.Request(url + path, headers=headers,
          data=None if body is None else json.dumps(body).encode())
    try:
        with urllib.request.urlopen(req, timeout=20) as response:
            status, data = response.status, json.load(response)
    except urllib.error.HTTPError as error:
        status = error.code
        raw = error.read().decode()
        try:
            data = json.loads(raw)
        except json.JSONDecodeError:
            data = {'body': raw}
    records.append({'stage': stage, 'path': path, 'body': body, 'status': status, 'response': data})
    save()
    return status, data


sessions = {}
request_id = 0


def mcp_roundtrip(token, payload, session=None):
    headers = {'Content-Type': 'application/json', 'Accept': 'application/json, text/event-stream',
               'Authorization': 'Bearer ' + token, 'Mcp-Protocol-Version': '2025-11-25'}
    if session:
        headers['Mcp-Session-Id'] = session
    req = urllib.request.Request(url + '/mcp', headers=headers, data=json.dumps(payload).encode())
    try:
        response = urllib.request.urlopen(req, timeout=30)
    except urllib.error.HTTPError as error:
        response = error
    with response:
        raw = response.read().decode()
        try:
            data = json.loads(raw)
        except json.JSONDecodeError:
            events = [json.loads(line[5:].strip()) for line in raw.splitlines() if line.startswith('data:')]
            data = next((event for event in events if event.get('id') == payload.get('id')), {'raw': raw})
        records.append({'stage': stage, 'path': '/mcp', 'body': payload, 'status': response.status, 'response': data})
        save()
        return response.status, data, response.headers.get('Mcp-Session-Id')


def tool(name, body, token=None):
    global request_id
    selected = admin_token if token is None else token
    if selected not in sessions:
        request_id += 1
        status, result, session = mcp_roundtrip(selected, {'jsonrpc': '2.0', 'id': request_id,
            'method': 'initialize', 'params': {'protocolVersion': '2025-11-25',
            'capabilities': {}, 'clientInfo': {'name': 'schedule-api-audit', 'version': '1'}}})
        if status != 200 or not session or 'error' in result:
            raise RuntimeError('MCP initialize failed: ' + json.dumps(result))
        sessions[selected] = session
    request_id += 1
    status, result, _ = mcp_roundtrip(selected, {'jsonrpc': '2.0', 'id': request_id,
        'method': 'tools/call', 'params': {'name': name, 'arguments': body}}, sessions[selected])
    if 'error' in result:
        data = {'isError': True, 'data': result['error']}
    else:
        reply = result.get('result', {})
        payload = reply.get('structuredContent')
        if payload is None:
            blocks = reply.get('content', [])
            text = next((block['text'] for block in blocks if block.get('type') == 'text'), '')
            try:
                payload = json.loads(text)
            except json.JSONDecodeError:
                payload = {'text': text}
        data = {'isError': reply.get('isError', False), 'data': payload}
    print(name, status, 'isError=' + str(data['isError']), flush=True)
    return status, data


def unwrap(result):
    if isinstance(result, dict) and isinstance(result.get('data'), dict):
        return result['data']
    if isinstance(result, dict) and isinstance(result.get('message'), str):
        try:
            decoded = json.loads(result['message'])
            return decoded if isinstance(decoded, dict) else result
        except json.JSONDecodeError:
            return result
    return result



import tomllib
import uuid
stage = 'setup'
source_config=tomllib.loads((repo/'config/runtime.toml').read_text())
model={'ollama_cloud':'ollama-cloud-deepseek-v4-1-flash','glm-coding':'glm-5-3'}[args.provider]
runtime_id=args.provider+'.'+model
provider=source_config['providers'][args.provider]
credential_name=provider['credentials']['key']
if provider['credentials']['type']!='env' or not os.environ.get(credential_name):
    raise RuntimeError('required configured provider credential is unavailable')
keeper='audit-live-'+('deepseek' if args.provider=='ollama_cloud' else 'glm')
schedule_id='audit-real-model-'+uuid.uuid4().hex
marker='SCHEDULE_EFFECT_'+uuid.uuid4().hex
base=(output/'workspace').resolve()
base.mkdir()
env={k:v for k,v in os.environ.items() if k in ['PATH','HOME','LANG','LC_ALL','TMPDIR',credential_name]}
env.update(MASC_BASE_PATH=str(base),MASC_KEEPER_AUTONOMOUS_ENABLED='false',MASC_SCHEDULE_RUNNER_INTERVAL_SEC='1')
command([str(binary),'init','--base-path',str(base)],env)

def table(name,values):
    rows=['['+name+']']
    for key,value in values.items():
        if not isinstance(value,dict): rows.append(key+' = '+json.dumps(value))
    for key,value in values.items():
        if isinstance(value,dict):rows.append(table(name+'.'+key,value))
    return '\n'.join(rows)+'\n'

# Derive the selected provider/model from the checked-in canonical config.
# Required lanes come from the existing isolated boot fixture. No invented defaults.
fixture=tomllib.loads((repo/'scripts/fixtures/release-evidence/runtime.toml').read_text())
text=table('runtime',{'default':runtime_id})
for lane in fixture['runtime']['exact_output_lanes']:
    text+=table('runtime.exact_output_lanes.'+lane,{'slots':[runtime_id]})
selected_provider={k:provider[k] for k in ['display-name','protocol','endpoint','connect-timeout-s','exact-body-timeout-s','credentials'] if k in provider}
text+=table('providers.'+args.provider,selected_provider)
text+=table('models.'+model,source_config['models'][model])
text+=table(args.provider+'.'+model,source_config[args.provider][model])
(base/'.masc/config/runtime.toml').write_text(text)
(output/'runtime-config.toml').write_text(text) # credential name only, never its value
command([str(binary),'sandbox-image','promote','--base-path',str(base),'--runtime','apple_container','base',args.image_reference],env)
with socket.socket() as sock:
    sock.bind(('127.0.0.1',0));port=sock.getsockname()[1]
url='http://127.0.0.1:'+str(port)
command([str(binary),'login','--base-path',str(base),'--host','127.0.0.1','--port',str(port),
         '--agent','schedule-audit-observer','--role','admin','--client-env','MASC_SCHEDULE_AUDIT_TOKEN','--no-expiry','--json'],env)
admin_token=(base/'.masc/auth/schedule-audit-observer.token').read_text().strip()
meta={'checkout_head':subprocess.check_output(['git','rev-parse','HEAD'],text=True).strip(),
      'binary':str(binary),'executable_sha256':hashlib.sha256(binary.read_bytes()).hexdigest(),
      'runtime_id':runtime_id,'provider_endpoint':provider['endpoint'],'schedule_id':schedule_id,'keeper':keeper,
      'script_sha256':hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
      'marker':marker,'base_path':str(base),'url':url,'credential_name':credential_name,
      'note':'Two owned workspace note effects requested; second schedule is submitted during the first live turn.'}
(output/'provenance.json').write_text(json.dumps(meta,indent=2)+'\n')
log=(output/'server.log').open('w')
server=subprocess.Popen([str(binary),'start','--base-path',str(base),'--host','127.0.0.1','--port',str(port)],env=env,stdout=log,stderr=log,cwd=base,start_new_session=True)
process={'pid':server.pid,'started_at_unix':time.time(),'url':url,'base_path':str(base)}
(output/'process.json').write_text(json.dumps(process,indent=2)+'\n')
print('Owned live-provider server started',server.pid,url,flush=True)


def successful_tool(name,args):
    status,result=tool(name,args)
    if status!=200 or result.get('isError') is not False:
        raise RuntimeError(name+' refused: '+json.dumps(unwrap(result)))
    data=unwrap(result)
    return data.get('schedule',data)

def observe_snapshot():
    notes=successful_tool('masc_schedule_notes_list',{'schedule_id':schedule_id})
    status,history=request('/api/v1/dashboard/scheduled-automation?schedule_id='+schedule_id,admin_token)
    if status!=200:raise RuntimeError('schedule history observation unavailable')
    status,turns=request('/api/v1/keepers/turns',admin_token)
    if status!=200:raise RuntimeError('live turn observation unavailable')
    owner=successful_tool('masc_keeper_status',{'name':keeper,'fast':True})
    snapshot={'notes':notes,'history':history,'turns':turns,
              'owner':{k:owner.get(k) for k in ['paused','live','keepalive_running','meta','execution_context','last_reply']}}
    (output/'last-observation.json').write_text(json.dumps(snapshot,indent=2)+'\n')
    return snapshot


second_id=schedule_id+'-second'
second_marker=marker+'_SECOND'
meta.update(second_schedule_id=second_id,second_marker=second_marker)
(output/'provenance.json').write_text(json.dumps(meta,indent=2)+'\n')

def create_request(identity,effect):
    return successful_tool('masc_schedule_create',{'schedule_id':identity,'keeper_name':keeper,'due_in_sec':2,
        'message':'Scheduled verification: append exactly one durable note to schedule_id "'+identity+'" with body "'+effect+'" using masc_schedule_note_add. Read back that same schedule note, then finish. Do not post elsewhere or create work. If another authorized scheduled request arrives, retain both requests and perform each exact note once.'})

def history_and_notes(identity):
    status,h=request('/api/v1/dashboard/scheduled-automation?schedule_id='+identity,admin_token)
    if status!=200:raise RuntimeError('history observation unavailable')
    n=successful_tool('masc_schedule_notes_list',{'schedule_id':identity})
    return {'history':h,'notes':n}

def exact_queue(snap,created):
    q=(snap['history'].get('request') or {}).get('keeper_queue_evidence') or {}
    exact=(q.get('schedule_id')==created['schedule_id'] and q.get('schedule_instance_id')==created['schedule_instance_id'] and q.get('keeper_name')==keeper)
    return q if exact else {}

try:
    while True:
        if server.poll() is not None:raise RuntimeError('owned server exited during startup')
        try:
            status,health=request('/health?full=1')
            if status==200 and health.get('startup',{}).get('state_ready'):break
        except (urllib.error.URLError,TimeoutError):pass
        time.sleep(.3)
    check('server serves the owned base',health['paths']['effective_base_path']==str(base))
    check('binary identity is measured',health['build']['executable_sha256']==meta['executable_sha256'],health['build'])
    meta['build']=health['build'];(output/'provenance.json').write_text(json.dumps(meta,indent=2)+'\n')
    status,gate=request('/api/v1/dashboard/gate/mode',admin_token,{'mode':'always_allow'})
    check('owned workspace gate accepts setting',status==200,gate)
    successful_tool('masc_keeper_up',{'name':keeper,'create_only':True,'sandbox_profile':'microvm','sandbox_image':'base',
        'microvm_backend':'apple_container','network_mode':'none','activation_mode':'manual','runtime_id':runtime_id,
        'skills':{'names':[]},'instructions':'You are an isolated scheduled-job evidence Keeper. Perform each authorized scheduled note request exactly once and preserve unfinished work when another request arrives. Use schedule tools directly. Do not execute shell commands, contact people, or create other work. Do not ask for confirmation for these authorized internal notes.'})
    status,approval=request('/api/v1/keepers/tool-approval-mode',admin_token,{'name':keeper,'mode':'yolo'})
    check('owned Keeper tool approval accepts setting',status==200,approval)
    first=create_request(schedule_id,marker)
    while True:
        if server.poll() is not None:raise RuntimeError('producer exited before first turn')
        status,turns=request('/api/v1/keepers/turns',admin_token)
        first_state=history_and_notes(schedule_id)
        matching=[row for row in turns.get('keepers',[]) if row.get('keeper_name')==keeper and row.get('turn') is not None]
        reaction=(first_state['history'].get('request') or {}).get('keeper_reaction_evidence') or {}
        if matching and reaction.get('turn_started_seen') is True and reaction.get('turn_finished_seen') is False:
            busy={'turns':turns,'first':first_state};(output/'first-busy.json').write_text(json.dumps(busy,indent=2)+'\n')
            break
        time.sleep(.2)
    check('first exact scheduled source is in a live unfinished turn',True,busy)
    second=create_request(second_id,second_marker)
    (output/'created.json').write_text(json.dumps({'first':first,'second':second},indent=2)+'\n')
    observed_overlap=False
    effects_checked=set()
    while True:
        if server.poll() is not None:raise RuntimeError('producer exited during busy observation')
        try:
            a=history_and_notes(schedule_id);b=history_and_notes(second_id)
            status,turns=request('/api/v1/keepers/turns',admin_token)
        except (urllib.error.URLError,TimeoutError) as exc:
            print('Observation unavailable; retaining same producer',type(exc).__name__,flush=True);time.sleep(2);continue
        aq=exact_queue(a,first);bq=exact_queue(b,second)
        ar=(a['history'].get('request') or {}).get('keeper_reaction_evidence') or {}
        first_still_live=ar.get('turn_started_seen') is True and ar.get('turn_finished_seen') is False
        if not observed_overlap and bq.get('matched_bucket')=='pending' and first_still_live:
            overlap={'first':a,'second':b,'turns':turns};(output/'overlap.json').write_text(json.dumps(overlap,indent=2)+'\n')
            check('second exact occurrence is queued while the first turn remains unfinished',True,overlap)
            observed_overlap=True
        final={'first':a,'second':b,'turns':turns,'overlap_observed':observed_overlap}
        (output/'last-observation.json').write_text(json.dumps(final,indent=2)+'\n')
        all_effects=True
        for label,snap,identity,effect in [('first',a,schedule_id,marker),('second',b,second_id,second_marker)]:
            found=[n for n in snap['notes'].get('notes',[]) if n.get('body')==effect]
            all_effects=all_effects and len(found)==1
            if found and label not in effects_checked:
                check(label+' effect appears once with correct Keeper author',len(found)==1 and found[0].get('author_id')==keeper,found)
                effects_checked.add(label)
        if all_effects and aq.get('terminal_outcome')=='completed' and bq.get('terminal_outcome')=='completed':
            check('both exact sources finish with durable completion',True,final)
            check('busy-overlap precondition was observed',observed_overlap)
            break
        if aq.get('terminal_outcome') in ['failed','cancelled'] or bq.get('terminal_outcome') in ['failed','cancelled']:
            check('both scheduled effects complete without terminal source failure',False,final)
        time.sleep(1)
    status,calls=request('/api/v1/keepers/'+keeper+'/tool-calls?limit=50',admin_token)
    (output/'tool-calls.json').write_text(json.dumps({'status':status,'response':calls},indent=2)+'\n')
    process['stop_reason']='two required effects and exact durable completions observed'
    server.terminate();server.wait(timeout=15)
    process['returncode']=server.returncode;process['stopped_at_unix']=time.time()
    (output/'process-ended.json').write_text(json.dumps(process,indent=2)+'\n')
    print('Owned server stopped',server.pid,server.returncode,flush=True)
except BaseException:
    process['returncode_at_observation_error']=server.poll()
    (output/'observation-error-process.json').write_text(json.dumps(process,indent=2)+'\n')
    save();raise
