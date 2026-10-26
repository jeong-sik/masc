#!/usr/bin/env python3
"""Actual installed server, disposable workspace, no reachable model provider."""
import argparse
from concurrent.futures import ThreadPoolExecutor
import threading
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
args = parser.parse_args()
output = args.output.resolve()
output.mkdir(parents=True, exist_ok=True)
repo = Path.cwd()
binary = args.binary.resolve(strict=True)
records = []
checks = []
file_lock = threading.Lock()
id_lock = threading.Lock()


def save():
    with file_lock:
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
    records.append({'path': path, 'body': body, 'status': status, 'response': data})
    save()
    return status, data


sessions = {}
request_id = 0


def next_request_id():
    global request_id
    with id_lock:
        request_id += 1
        return request_id


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
        records.append({'path': '/mcp', 'body': payload, 'status': response.status, 'response': data})
        save()
        return response.status, data, response.headers.get('Mcp-Session-Id')


def tool(name, body, token=None):
    global request_id
    selected = admin_token if token is None else token
    if selected not in sessions:
        this_id = next_request_id()
        status, result, session = mcp_roundtrip(selected, {'jsonrpc': '2.0', 'id': this_id,
            'method': 'initialize', 'params': {'protocolVersion': '2025-11-25',
            'capabilities': {}, 'clientInfo': {'name': 'schedule-api-audit', 'version': '1'}}})
        if status != 200 or not session or 'error' in result:
            raise RuntimeError('MCP initialize failed: ' + json.dumps(result))
        sessions[selected] = session
    this_id = next_request_id()
    status, result, _ = mcp_roundtrip(selected, {'jsonrpc': '2.0', 'id': this_id,
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


metadata = {'requested_source': subprocess.check_output(['git', 'rev-parse', 'HEAD'], text=True).strip(),
            'executable_sha256': hashlib.sha256(binary.read_bytes()).hexdigest(),
            'binary': str(binary), 'model_provider': 'isolated dead loopback endpoint, autonomous disabled',
            'not_proven': ['real model execution', 'destination delivery', 'TUI execution', 'fault recovery']}
(output / 'provenance.json').write_text(json.dumps(metadata, indent=2) + '\n')
with tempfile.TemporaryDirectory(prefix='masc-schedule-api-') as directory:
    base = Path(directory).resolve()
    env = {key: value for key, value in os.environ.items()
           if key in ['PATH', 'HOME', 'LANG', 'LC_ALL', 'TMPDIR']}
    env.update(MASC_BASE_PATH=str(base), MASC_KEEPER_AUTONOMOUS_ENABLED='false')
    command([str(binary), 'init', '--base-path', str(base)], env)
    shutil.copyfile(repo / 'scripts/fixtures/release-evidence/runtime.toml', base / '.masc/config/runtime.toml')
    with socket.socket() as sock:
        sock.bind(('127.0.0.1', 0))
        port = sock.getsockname()[1]
    url = 'http://127.0.0.1:' + str(port)
    for actor, role in [('schedule-audit-admin', 'admin'), ('schedule-audit-worker', 'worker')]:
        command([str(binary), 'login', '--base-path', str(base), '--host', '127.0.0.1',
                 '--port', str(port), '--agent', actor, '--role', role,
                 '--client-env', 'MASC_SCHEDULE_AUDIT_TOKEN', '--no-expiry', '--json'], env)
    admin_token = (base / '.masc/auth/schedule-audit-admin.token').read_text().strip()
    worker_token = (base / '.masc/auth/schedule-audit-worker.token').read_text().strip()
    server = None
    with (output / 'server.log').open('w') as log:
        try:
            server = subprocess.Popen([str(binary), 'start', '--base-path', str(base),
                    '--host', '127.0.0.1', '--port', str(port)], env=env, stdout=log, stderr=log, cwd=base)
            print('Owned isolated server PID', server.pid, 'port', port, flush=True)
            (output / 'process.json').write_text(json.dumps({'pid': server.pid, 'port': port, 'base_path': str(base)}) + '\n')
            startup_deadline = time.monotonic() + 90
            while True:
                if server.poll() is not None:
                    raise RuntimeError('isolated server exited before readiness')
                try:
                    _, health = request('/health?full=1')
                    if health.get('startup', {}).get('state_ready'):
                        break
                except (urllib.error.URLError, TimeoutError):
                    pass
                if time.monotonic() >= startup_deadline:
                    raise RuntimeError('owned startup observation deadline; see server.log')
                time.sleep(0.2)
            metadata['observed_build'] = health['build']
            metadata['observed_base'] = health['paths']['effective_base_path']
            metadata['runtime_instance_id'] = health['build']['runtime_instance_id']
            (output / 'provenance.json').write_text(json.dumps(metadata, indent=2) + '\n')
            check('isolated effective base path', health['paths']['effective_base_path'] == str(base))
            check('installed executable identity', health['build']['executable_sha256'] == metadata['executable_sha256'])
            status, data = tool('masc_schedule_create', {'schedule_id': 'audit-seven-tools',
                'keeper_name': 'audit-future-owner', 'message': 'isolated future request',
                'due_in_sec': 3600, 'allow_unregistered_keeper': True})
            data = unwrap(data)
            check('create real future request', 200 <= status < 300 and isinstance(data, dict), list(data) if isinstance(data, dict) else data)
            (output / 'first-create.json').write_text(json.dumps(data, indent=2) + '\n')
            # The public response shape is inspected before proceeding with dependent assertions.
            if 'schedule_id' not in data and 'schedule' not in data:
                raise RuntimeError('inspect first-create.json before deriving schedule state')
            schedule = data.get('schedule', data)
            check('stable schedule identity', schedule.get('schedule_id') == 'audit-seven-tools', schedule)
            initial_instance = schedule.get('schedule_instance_id')
            status, data = tool('masc_schedule_update', {'schedule_id': 'audit-seven-tools',
                'keeper_name': 'audit-future-owner', 'message': 'edited isolated request',
                'allow_unregistered_keeper': True})
            data = unwrap(data)
            updated = data.get('schedule', data)
            check('update preserves public id and replaces instance', 200 <= status < 300
                  and updated.get('schedule_id') == 'audit-seven-tools'
                  and updated.get('schedule_instance_id') != initial_instance, updated)
            status, data = tool('masc_schedule_list', {'owner': 'all', 'limit': 50})
            data = unwrap(data)
            rows = data.get('schedules', [])
            check('list finds stable request', 200 <= status < 300 and any(row.get('schedule_id') == 'audit-seven-tools' for row in rows), data)
            status, data = tool('masc_schedule_get', {'schedule_id': 'audit-seven-tools'})
            data = unwrap(data)
            got = data.get('schedule', data)
            check('get reads edited instance', 200 <= status < 300 and got.get('schedule_instance_id') == updated.get('schedule_instance_id'), data)
            for body in ['first durable note', 'second durable note', 'third durable note']:
                status, data = tool('masc_schedule_note_add', {'schedule_id': 'audit-seven-tools', 'body': body})
                check('append note ' + body.split()[0], status == 200 and data.get('isError') is False, unwrap(data))
            status, data = tool('masc_schedule_notes_list', {'schedule_id': 'audit-seven-tools', 'limit': 2})
            data = unwrap(data)
            check('latest note window is oldest-first', 200 <= status < 300 and [note.get('body') for note in data.get('notes', [])]
                  == ['second durable note', 'third durable note'], data)
            status, data = tool('masc_schedule_cancel', {'schedule_id': 'audit-seven-tools', 'reason': 'isolated lifecycle done'}, worker_token)
            refused = data.get('isError') is True
            data = unwrap(data)
            check('worker cannot cancel another creator request', status == 200 and refused and data.get('error_kind') == 'not_schedule_owner', data)
            status, data = tool('masc_schedule_cancel', {'schedule_id': 'audit-seven-tools', 'reason': 'isolated lifecycle done'})
            data = unwrap(data)
            cancelled = data.get('schedule', data)
            check('creator cancels active declaration', 200 <= status < 300 and cancelled.get('status') == 'cancelled', data)
            status, data = tool('masc_schedule_notes_list', {'schedule_id': 'audit-seven-tools'})
            data = unwrap(data)
            check('notes survive cancellation', 200 <= status < 300 and len(data.get('notes', [])) == 3, data)
            status, data = tool('masc_schedule_update', {'schedule_id': 'audit-seven-tools',
                'keeper_name': 'audit-future-owner', 'message': 'forbidden terminal edit', 'allow_unregistered_keeper': True})
            refused = data.get('isError') is True
            data = unwrap(data)
            check('terminal definition cannot be updated', status == 200 and refused
                  and data.get('error_kind') == 'transition_refused' and data.get('current_status') == 'cancelled', data)
            # Concurrent notes from two authenticated identities must not lose either append.
            note_bodies = ['concurrent creator note', 'concurrent worker note']
            def append_concurrent(pair):
                token, body = pair
                return tool('masc_schedule_note_add', {'schedule_id': 'audit-seven-tools', 'body': body}, token)
            with ThreadPoolExecutor(max_workers=2) as pool:
                replies = list(pool.map(append_concurrent, zip([admin_token, worker_token], note_bodies)))
            check('both concurrent terminal note appends accepted',
                  all(status == 200 and data.get('isError') is False for status, data in replies),
                  [unwrap(data) for _, data in replies])
            status, data = tool('masc_schedule_notes_list', {'schedule_id': 'audit-seven-tools'})
            notes = unwrap(data).get('notes', [])
            check('concurrent notes retain both authors and unique ids', status == 200 and len(notes) == 5
                  and set(n.get('body') for n in notes[-2:]) == set(note_bodies)
                  and set(n.get('author_id') for n in notes[-2:]) == {'schedule-audit-admin', 'schedule-audit-worker'}
                  and len(set(n.get('note_id') for n in notes)) == 5, notes)
            # The recipient may change a definition while keeping its original creator and target.
            status, data = tool('masc_schedule_create', {'schedule_id': 'audit-recipient',
                'keeper_name': 'schedule-audit-worker', 'message': 'future recipient request',
                'due_in_sec': 3600, 'allow_unregistered_keeper': True})
            check('creator schedules another named recipient', status == 200 and data.get('isError') is False, unwrap(data))
            status, data = tool('masc_schedule_note_add', {'schedule_id': 'audit-recipient', 'body': 'note before replacement'})
            check('note before replacement accepted', status == 200 and data.get('isError') is False, unwrap(data))
            status, data = tool('masc_schedule_update', {'schedule_id': 'audit-recipient',
                'keeper_name': 'schedule-audit-worker', 'message': 'recipient edits its own wake',
                'allow_unregistered_keeper': True}, worker_token)
            edited = unwrap(data).get('schedule', unwrap(data))
            check('recipient edit keeps original creator', status == 200 and data.get('isError') is False
                  and edited.get('scheduled_by', {}).get('id') == 'schedule-audit-admin'
                  and edited.get('payload_target') == 'keeper:schedule-audit-worker', edited)
            status, data = tool('masc_schedule_notes_list', {'schedule_id': 'audit-recipient'})
            check('notes survive instance replacement', status == 200
                  and [n.get('body') for n in unwrap(data).get('notes', [])] == ['note before replacement'], unwrap(data))
            status, data = tool('masc_schedule_update', {'schedule_id': 'audit-recipient',
                'keeper_name': 'audit-other-recipient', 'message': 'forbidden recipient retarget',
                'allow_unregistered_keeper': True}, worker_token)
            check('recipient cannot replace with an unrelated target', status == 200
                  and data.get('isError') is True and unwrap(data).get('error_kind') == 'not_schedule_owner', unwrap(data))
            status, data = tool('masc_schedule_cancel', {'schedule_id': 'audit-recipient', 'reason': 'recipient cancels its wake'}, worker_token)
            check('recipient cancels a wake it did not create', status == 200 and data.get('isError') is False
                  and unwrap(data).get('schedule', {}).get('status') == 'cancelled'
                  and unwrap(data).get('cancelled_by', {}).get('id') == 'schedule-audit-worker', unwrap(data))
            # Pagination must neither duplicate nor omit a row and must bind its original filters.
            page_ids = ['audit-page-1', 'audit-page-2', 'audit-page-3']
            for schedule_id in page_ids:
                status, data = tool('masc_schedule_create', {'schedule_id': schedule_id,
                    'keeper_name': 'audit-page-owner', 'message': 'future page request',
                    'due_in_sec': 3600, 'allow_unregistered_keeper': True})
                check('page request created ' + schedule_id, status == 200 and data.get('isError') is False)
            page_args = {'owner': 'wake_target', 'owner_name': 'audit-page-owner', 'limit': 1}
            status, data = tool('masc_schedule_list', page_args)
            page = unwrap(data)
            check('first page returns one row and continuation', status == 200 and data.get('isError') is False
                  and len(page.get('schedules', [])) == 1 and isinstance(page.get('next_cursor'), str), page)
            first_cursor = page['next_cursor']
            status, data = tool('masc_schedule_list', {**page_args, 'status': 'active', 'cursor': first_cursor})
            check('cursor refuses changed filters', status == 200 and data.get('isError') is True
                  and unwrap(data).get('error_kind') == 'cursor_mismatch', unwrap(data))
            observed_ids = [row['schedule_id'] for row in page['schedules']]
            cursors = set()
            while page.get('next_cursor') is not None:
                cursor = page['next_cursor']
                if cursor in cursors:
                    raise RuntimeError('pagination repeated a cursor')
                cursors.add(cursor)
                status, data = tool('masc_schedule_list', {**page_args, 'cursor': cursor})
                check('continuation accepted', status == 200 and data.get('isError') is False)
                page = unwrap(data)
                observed_ids.extend(row['schedule_id'] for row in page.get('schedules', []))
            check('pagination visits each matching schedule exactly once', observed_ids == page_ids, observed_ids)
            status, data = tool('masc_schedule_create', {'schedule_id': 'audit-past', 'keeper_name': 'audit-page-owner',
                'message': 'past request must refuse', 'due_at_unix': 1, 'allow_unregistered_keeper': True})
            check('past due request is typed refusal', status == 200 and data.get('isError') is True
                  and unwrap(data).get('error_kind') == 'due_already_past', unwrap(data))
            status, data = tool('masc_keeper_list', {'detailed': True, 'limit': 100})
            data = unwrap(data)
            check('no autonomous model owner started', 200 <= status < 300 and isinstance(data.get('keepers'), list)
                  and data.get('truncated') is False and all(not k.get('keepalive_running', False) for k in data['keepers']), data)
        finally:
            if server is not None:
                server.terminate()
                try:
                    server.wait(timeout=15)
                except subprocess.TimeoutExpired:
                    server.kill()
                    server.wait()
                (output / 'process-ended.json').write_text(json.dumps({'pid': server.pid, 'returncode': server.returncode}) + '\n')
                print('Owned isolated server stopped', server.pid, server.returncode, flush=True)
            save()
