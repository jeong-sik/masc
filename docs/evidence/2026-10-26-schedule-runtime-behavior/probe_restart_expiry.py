#!/usr/bin/env python3
"""Actual installed server, disposable workspace, no reachable model provider."""
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


stage = 'setup'
metadata = {'checkout_head': subprocess.check_output(['git', 'rev-parse', 'HEAD'], text=True).strip(),
            'executable_sha256': hashlib.sha256(binary.read_bytes()).hexdigest(),
            'binary': str(binary), 'provider': 'dead loopback endpoint',
            'schedule_runner_interval_sec': 1.0, 'image_reference': args.image_reference,
            'not_proven': ['provider success', 'destination delivery', 'running lease fault recovery', 'TUI execution']}
processes = []
server = None


def stop_server():
    global server
    if server is None:
        return
    owned = server
    if owned.poll() is None:
        owned.terminate()
        try:
            owned.wait(timeout=15)
        except subprocess.TimeoutExpired:
            owned.kill()
            owned.wait()
    processes[-1]['returncode'] = owned.returncode
    processes[-1]['stopped_at_unix'] = time.time()
    (output / 'processes.json').write_text(json.dumps(processes, indent=2))
    server = None
    print('Owned server stopped', owned.pid, owned.returncode, flush=True)


def start_server(label):
    global server, stage
    stage = label
    sessions.clear()
    processes.append({'stage': label, 'started_at_unix': time.time()})
    server = subprocess.Popen([str(binary), 'start', '--base-path', str(base),
                '--host', '127.0.0.1', '--port', str(port)], env=env, stdout=log, stderr=log, cwd=base)
    processes[-1]['pid'] = server.pid
    (output / 'processes.json').write_text(json.dumps(processes, indent=2))
    print('Owned server started', label, server.pid, flush=True)
    deadline = time.monotonic() + 90
    while True:
        if server.poll() is not None:
            raise RuntimeError('owned server exited during startup')
        try:
            status, health = request('/health?full=1')
            if status == 200 and health.get('startup', {}).get('state_ready'):
                break
        except (urllib.error.URLError, TimeoutError):
            pass
        if time.monotonic() >= deadline:
            raise RuntimeError('owned startup observation deadline')
        time.sleep(0.2)
    check(label + ' serves the owned base', health['paths']['effective_base_path'] == str(base))
    check(label + ' executable matches the measured binary', health['build']['executable_sha256'] == metadata['executable_sha256'], health['build'])
    metadata.setdefault('launches', []).append({'stage':label, 'build':health['build'], 'base':str(base)})
    (output / 'provenance.json').write_text(json.dumps(metadata, indent=2))
    return health


def successful_tool(name, args):
    status, result = tool(name, args)
    if status != 200 or result.get('isError') is not False:
        raise RuntimeError(name + ' refused: ' + json.dumps(unwrap(result)))
    data = unwrap(result)
    return data.get('schedule', data)


def inventory():
    status, data = request('/api/v1/keepers/audit-restart-a/waiting-inventory', admin_token)
    if status != 200:
        raise RuntimeError('inventory unavailable')
    return data


def pending(data):
    return [row['detail'] for row in data.get('rows', [])
            if row.get('source') == 'event_queue_pending' and row.get('waiting_on') == 'schedule_due']


with tempfile.TemporaryDirectory(prefix='masc-schedule-restart-') as directory:
    base = Path(directory).resolve()
    env = {k:v for k,v in os.environ.items() if k in ['PATH','HOME','LANG','LC_ALL','TMPDIR']}
    env.update(MASC_BASE_PATH=str(base), MASC_KEEPER_AUTONOMOUS_ENABLED='false', MASC_SCHEDULE_RUNNER_INTERVAL_SEC='1')
    command([str(binary),'init','--base-path',str(base)], env)
    shutil.copyfile(repo/'scripts/fixtures/release-evidence/runtime.toml', base/'.masc/config/runtime.toml')
    command([str(binary),'sandbox-image','promote','--base-path',str(base),'--runtime','apple_container','base',args.image_reference], env)
    with socket.socket() as sock:
        sock.bind(('127.0.0.1',0));port=sock.getsockname()[1]
    url = 'http://127.0.0.1:' + str(port)
    command([str(binary),'login','--base-path',str(base),'--host','127.0.0.1','--port',str(port),
             '--agent','schedule-audit-admin','--role','admin','--client-env','MASC_SCHEDULE_AUDIT_TOKEN','--no-expiry','--json'],env)
    admin_token=(base/'.masc/auth/schedule-audit-admin.token').read_text().strip()
    with (output/'server.log').open('w') as log:
        try:
            first_health = start_server('before')
            successful_tool('masc_keeper_up', {'name':'audit-restart-a','create_only':True,
                'sandbox_profile':'microvm','sandbox_image':'base','microvm_backend':'apple_container','network_mode':'none',
                'activation_mode':'manual','runtime_id':'ollama_cloud.deepseek-v4.1-flash',
                'skills':{'names':[]},'instructions':'Isolated paused schedule restart evidence.'})
            status, result = request('/api/v1/keepers/audit-restart-a/directive',admin_token,{'action':'pause'})
            check('pause succeeds before any scheduled input',status == 200 and result.get('ok') is True,result)
            before_inventory=inventory()
            check('owner is authoritatively paused before create',len(before_inventory.get('keepers',[]))==1
                  and before_inventory['keepers'][0].get('paused') is True)
            accepted_expiry=time.time()+30
            accepted=successful_tool('masc_schedule_create', {'schedule_id':'audit-retained-expiring',
                'keeper_name':'audit-restart-a','message':'Retain this accepted input after definition expiry.',
                'due_in_sec':1,'expires_at_unix':accepted_expiry,'recurrence_kind':'interval','recurrence_interval_sec':3600})
            successful_tool('masc_schedule_note_add',{'schedule_id':'audit-retained-expiring','body':'durable note across server restart'})
            deadline=time.monotonic()+30
            while True:
                observed=successful_tool('masc_schedule_get',{'schedule_id':'audit-retained-expiring'})
                first=inventory(); original_pending=pending(first)
                wake=observed.get('last_wake') or {}
                if wake.get('status')=='succeeded' and len(original_pending)==1:
                    break
                if time.monotonic()>=deadline:
                    raise RuntimeError('precondition: original occurrence was not accepted')
                time.sleep(0.2)
            original=original_pending[0]
            check('one exact occurrence accepted before shutdown',bool(original.get('post_id')) and bool(original.get('source_ref')),original)
            never_expiry=time.time()+25
            never=successful_tool('masc_schedule_create',{'schedule_id':'audit-expire-before-acceptance',
                'keeper_name':'audit-restart-a','message':'Must expire while the scheduler is down.',
                'due_in_sec':20,'expires_at_unix':never_expiry})
            missed=successful_tool('masc_schedule_create',{'schedule_id':'audit-missed-interval',
                'keeper_name':'audit-restart-a','message':'Miss multiple interval due times while scheduler is down.',
                'due_in_sec':20,'recurrence_kind':'interval','recurrence_interval_sec':2})
            originals={'accepted':accepted,'never':never,'missed':missed,'pending':original}
            (output/'before.json').write_text(json.dumps(originals,indent=2))
            stop_server()
            stopped_at=processes[-1]['stopped_at_unix']
            check('server stopped before the other definitions became due',stopped_at < min(never['due_at'],missed['due_at']),{'stopped_at':stopped_at,'never_due':never['due_at'],'interval_due':missed['due_at']})
            check('accepted definition has not expired before shutdown',stopped_at < accepted_expiry)
            # Controlled scheduler downtime covers expiry and at least three due instants.
            resume_after=max(accepted_expiry,never_expiry,missed['due_at']+4)+0.3
            while time.time()<resume_after:
                time.sleep(min(0.2,resume_after-time.time()))
            second_health=start_server('after')
            restarted_at=processes[-1]['started_at_unix']
            check('both expiries occur during actual scheduler downtime',stopped_at < accepted_expiry < restarted_at
                  and stopped_at < never_expiry < restarted_at,{'stopped':stopped_at,'accepted_expiry':accepted_expiry,'never_expiry':never_expiry,'restart':restarted_at})
            check('runtime instance changes across restart',first_health['build']['runtime_instance_id']!=second_health['build']['runtime_instance_id'])
            deadline=time.monotonic()+30
            while True:
                after_accepted=successful_tool('masc_schedule_get',{'schedule_id':'audit-retained-expiring'})
                after_never=successful_tool('masc_schedule_get',{'schedule_id':'audit-expire-before-acceptance'})
                after_missed=successful_tool('masc_schedule_get',{'schedule_id':'audit-missed-interval'})
                if (after_accepted.get('status')=='expired' and after_never.get('status')=='expired'
                        and (after_missed.get('last_wake') or {}).get('status')=='succeeded'):
                    break
                if time.monotonic()>=deadline:
                    raise RuntimeError('post-restart expected ledger transitions not observed')
                time.sleep(0.2)
            check('all public requests retain their exact instance after restart',all(current['schedule_instance_id']==prior['schedule_instance_id']
                  for current,prior in [(after_accepted,accepted),(after_never,never),(after_missed,missed)]))
            check('future-intake expiry preserves the earlier accepted wake receipt',
                  after_accepted['last_wake']['status']=='succeeded' and after_accepted['last_wake']['detail']['stimulus_id']==original['post_id'],after_accepted)
            check('unaccepted expired definition emits no wake',after_never.get('last_wake') is None,after_never)
            after_inventory=inventory(); remaining=pending(after_inventory)
            retained=[item for item in remaining if all(item.get(k)==original.get(k) for k in ['post_id','source_ref','source_incarnation'])]
            check('accepted exact source survives expiry and server restart',len(retained)==1,remaining)
            missed_id=after_missed['last_wake']['detail']['stimulus_id']
            check('multiple missed due instants produce one queued occurrence',
                  len(remaining)==2 and len([r for r in remaining if r.get('post_id')==missed_id])==1
                  and restarted_at>missed['due_at']+4,{'queue':remaining,'restart':restarted_at,'original_due':missed['due_at']})
            check('interval advances its next due beyond the restart boundary',after_missed['due_at']>restarted_at and after_missed['due_at']>after_missed['last_wake']['started_at'],after_missed)
            histories={}
            for schedule_id, expected_count in [('audit-retained-expiring',1),('audit-expire-before-acceptance',0),('audit-missed-interval',1)]:
                status, history=request('/api/v1/dashboard/scheduled-automation?schedule_id='+schedule_id,admin_token)
                check('retained wake history count '+schedule_id,status==200 and history.get('status')=='found'
                      and history.get('wake_count')==expected_count and len(history.get('wakes',[]))==expected_count,history)
                histories[schedule_id]=history
            check('missed interval history fits below the reported retention ceiling',
                  1+(restarted_at-missed['due_at'])//2 < histories['audit-missed-interval']['wake_retention_per_schedule'])
            notes=successful_tool('masc_schedule_notes_list',{'schedule_id':'audit-retained-expiring'})
            check('note survives expiry and restart', [n.get('body') for n in notes.get('notes',[])]==['durable note across server restart'],notes)
            owner=successful_tool('masc_keeper_status',{'name':'audit-restart-a','fast':True})
            check('owner remains paused with zero model turns',owner.get('paused') is True and owner.get('meta',{}).get('total_turns')==0,{'paused':owner.get('paused'),'turns':owner.get('meta',{}).get('total_turns')})
            (output/'after.json').write_text(json.dumps({'accepted':after_accepted,'never':after_never,'missed':after_missed,'inventory':after_inventory,'notes':notes,'histories':histories,'owner':{'paused':owner.get('paused'),'meta':{k:owner.get('meta',{}).get(k) for k in ['total_turns','last_turn_ts','last_runtime_attempt']}}},indent=2))
        finally:
            stop_server()
            save()
