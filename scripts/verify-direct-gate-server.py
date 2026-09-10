"""Real durable Gate approval and same-operation continuation through a CI-built MASC server.

No LLM semantic acceptance is asserted. Only public MCP submits work; journals
and checkpoints are read as evidence, never manufactured or edited.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import socket
import secrets
import shutil
import sqlite3
import subprocess
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.error import HTTPError, URLError
from urllib.request import Request, HTTPRedirectHandler, ProxyHandler, build_opener


class NoRedirect(HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


HTTP = build_opener(ProxyHandler({}), NoRedirect())


def save(path, value):
    path.write_text(json.dumps(value, indent=2, ensure_ascii=False) + '\n')


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--ci-run', type=int, required=True)
    p.add_argument('--arch', default='macos-arm64')
    p.add_argument('--artifact-cache', type=Path, help='Previously downloaded CI artifact directory with sibling ci-provenance.json')
    p.add_argument('--output', type=Path, required=True)
    p.add_argument('--base', type=Path, help='Fresh isolated runtime base on a filesystem shared with the sandbox daemon')
    p.add_argument('--expected-commit', required=True)
    p.add_argument('--port', type=int, default=18941)
    p.add_argument('--observation-seconds', type=int, default=120)
    args = p.parse_args()
    args.output.mkdir(parents=True, exist_ok=False)
    root = args.output.resolve()
    base = args.base.resolve() if args.base else root / 'base'
    base.mkdir(parents=True, exist_ok=False)
    config = base / '.masc/config'
    config.mkdir(parents=True)
    keeper = 'direct-gate-http-proof'
    prompt = 'Synthetic Gate probe: request the supplied one-time file effect, wait for its durable approval, then finish this exact original request.'
    effect = base / '.masc/playground/docker' / keeper / 'gate-effect.txt'
    events = []
    primary_count = 0
    approval_resolved = threading.Event()
    lock = threading.Lock()

    class Provider(BaseHTTPRequestHandler):
        def log_message(self, *_):
            pass

        def do_POST(self):
            try:
                self.respond_fixture()
            except Exception as error:
                detail = str(error).replace(token, '[WITHHELD]')
                save(root / 'provider-error.json', {'class': type(error).__name__, 'message': detail, 'event_count': len(events)})
                raw = json.dumps({'error': {'type': 'fixture_failure', 'message': detail}}).encode()
                try:
                    self.send_response(500)
                    self.send_header('Content-Type', 'application/json')
                    self.send_header('Content-Length', str(len(raw)))
                    self.end_headers()
                    self.wfile.write(raw)
                except (BrokenPipeError, ConnectionResetError):
                    pass

        def respond_fixture(self):
            nonlocal primary_count
            body = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
            with lock:
                index = len(events)
                event = {'path': self.path, 'body': body, 'time': time.time()}
                events.append(event)
                save(root / f'provider-{index:03}.json', event)
                primary = self.path.startswith('/primary')
                if primary:
                    primary_count += 1
                if index == 0:
                    names = [t['function']['name'] for t in body.get('tools', [])]
                    if not {'Write', 'Execute'}.issubset(names):
                        response = {'error': {'message': 'Fixture requires actual Write and Execute schemas', 'type': 'invalid_request_error'}}
                        status = 400
                    else:
                        save(root / 'execute-schema.json', next(t for t in body['tools'] if t['function']['name'] == 'Execute'))
                        save(root / 'write-schema.json', next(t for t in body['tools'] if t['function']['name'] == 'Write'))
                        command = "from pathlib import Path; p=Path('gate-effect.txt'); p.open('a').write('one real gate effect\\n'); print('gate-effect-written', str(p.resolve()))"
                        response = {'id': 'fixture-gate-request', 'model': 'resume-fixture', 'choices': [{'index': 0, 'message': {'role': 'assistant', 'content': None, 'tool_calls': [{'id': 'completed-before-gate', 'type': 'function', 'function': {'name': 'Write', 'arguments': json.dumps({'file_path': 'pre-gate-effect.txt', 'content': 'completed before Gate approval\n'})}}, {'id': 'gate-effect-once', 'type': 'function', 'function': {'name': 'Execute', 'arguments': json.dumps({'argv': ['python3', '-c', command], 'intent': 'request_effect'})}}]}, 'finish_reason': 'tool_calls'}]}
                        status = 200
                elif index == 1:
                    response = {'error': {'message': 'Synthetic rate limit after a completed effect and a new Gate obligation', 'type': 'rate_limit_error'}}
                    status = 429
                elif not approval_resolved.is_set():
                    response = {'error': {'message': 'Unexpected model invocation before authoritative Gate resolution', 'type': 'invalid_request_error'}}
                    status = 400
                else:
                    admission_prefix = 'resumed-admission' if index == 2 else 'after-artifact-read'
                    database = base / '.masc/keepers' / keeper / 'chat-operations.sqlite3'
                    with sqlite3.connect('file:' + str(database) + '?mode=ro', uri=True) as db:
                        db.row_factory = sqlite3.Row
                        save(root / f'{admission_prefix}-operations.json', [dict(row) for row in db.execute('SELECT * FROM operations')])
                        save(root / f'{admission_prefix}-semantic.json', [json.loads(row[0]) for row in db.execute('SELECT record_json FROM semantic_executions')])
                    snapshots = []
                    for path in (base / '.masc/traces').rglob('agent-core-snapshot-*.json'):
                        snapshots.append({'path': str(path.relative_to(base)), 'sha256': hashlib.sha256(path.read_bytes()).hexdigest(), 'checkpoint': json.loads(path.read_text())})
                    save(root / f'{admission_prefix}-checkpoints.json', snapshots)
                    if index == 2:
                        journal = json.loads((base / '.masc/gate/replay-results.json').read_text())
                        outcomes = [row['outcome'] for row in journal['outcomes'] if row['approval_id'] == receipt['approval_id']]
                        if len(outcomes) != 1 or outcomes[0]['kind'] != 'applied':
                            raise AssertionError('Approval has no actual applied replay outcome')
                        output_ref = outcomes[0]['output_ref']['_blob']
                        digest = output_ref['sha256']
                        if len(digest) != 64 or any(c not in '0123456789abcdef' for c in digest) or digest == receipt['approval_id']:
                            raise AssertionError('Replay output reference is not a full SHA-256')
                        if digest not in json.dumps(body['messages']):
                            raise AssertionError('Resumed model input omitted the exact full output_ref SHA-256')
                        blob = base / '.masc/tool_blobs' / digest[:2] / digest
                        raw_output = blob.read_bytes()
                        if hashlib.sha256(raw_output).hexdigest() != digest or len(raw_output) != output_ref['bytes']:
                            raise AssertionError('Replay output reference does not bind stored bytes')
                        names = [t['function']['name'] for t in body.get('tools', [])]
                        if 'keeper_artifact_read' not in names:
                            raise AssertionError('Resumed model cannot access artifact read')
                        save(root / 'approved-output-ref.json', output_ref)
                        save(root / 'artifact-read-schema.json', next(t for t in body['tools'] if t['function']['name'] == 'keeper_artifact_read'))
                        response = {'id': 'fixture-read-approved-output', 'model': 'resume-fixture', 'choices': [{'index': 0, 'message': {'role': 'assistant', 'content': None, 'tool_calls': [{'id': 'read-approved-result', 'type': 'function', 'function': {'name': 'keeper_artifact_read', 'arguments': json.dumps({'sha256': digest, 'offset': 0})}}]}, 'finish_reason': 'tool_calls'}]}
                    else:
                        response = {'id': 'fixture-completed', 'model': 'resume-fixture', 'choices': [{'index': 0, 'message': {'role': 'assistant', 'content': 'Synthetic Gate continuation completed from its approved effect receipt.'}, 'finish_reason': 'stop'}]}
                    status = 200
                response['usage'] = {'prompt_tokens': 10, 'completion_tokens': 10, 'total_tokens': 20}
                event['response_status'] = status
                save(root / f'provider-{index:03}.json', event)
            streaming = body.get('stream') is True and status == 200
            if streaming:
                choice = response['choices'][0]
                delta = choice['message']
                for tool_index, tool in enumerate(delta.get('tool_calls', [])):
                    tool['index'] = tool_index
                chunk = {'id': response['id'], 'object': 'chat.completion.chunk', 'model': 'resume-fixture', 'choices': [{'index': 0, 'delta': delta, 'finish_reason': None}]}
                stop = {'id': response['id'], 'object': 'chat.completion.chunk', 'choices': [{'index': 0, 'delta': {}, 'finish_reason': choice['finish_reason']}], 'usage': response['usage']}
                raw = ('data: ' + json.dumps(chunk) + '\n\n' + 'data: ' + json.dumps(stop) + '\n\ndata: [DONE]\n\n').encode()
            else:
                raw = json.dumps(response).encode()
            self.send_response(status)
            self.send_header('Content-Type', 'text/event-stream' if streaming else 'application/json')
            self.send_header('Content-Length', str(len(raw)))
            self.end_headers()
            self.wfile.write(raw)

    provider = ThreadingHTTPServer(('127.0.0.1', 0), Provider)
    provider_port = provider.server_address[1]
    threading.Thread(target=provider.serve_forever, daemon=True).start()
    fixture_dir = Path(__file__).resolve().parent / 'fixtures/release-evidence'
    runtime = (fixture_dir / 'runtime.toml').read_text()
    runtime = runtime.replace('default = "ollama_cloud.deepseek-v4-flash"', 'default = "primary.sample"')
    runtime = runtime.replace('is-default = true', 'is-default = false')
    runtime += '\n[runtime.lanes."primary.sample"]\ncandidates = ["primary.sample", "alternate.sample"]\n'
    overlay = (fixture_dir / 'agent-core-models-overlay.toml').read_text()
    for name in ['primary', 'alternate']:
        endpoint = f'http://127.0.0.1:{provider_port}/{name}'
        runtime += f'\n[providers.{name}]\nprotocol = "openai-compatible-http"\nendpoint = "{endpoint}"\n[{name}.sample]\nmax-request-body-bytes = 1048576\n'
        overlay += f'\n[[providers]]\nid = "{name}"\nkind = "openai_compat"\nbase_url = "{endpoint}"\nrequest_path = "/chat/completions"\napi_key_env = ""\ncapabilities_base = "openai_chat"\n\n[[models]]\nid_prefix = "resume-fixture"\nprovider_name = "{name}"\nbase = "openai_chat"\nmax_context_tokens = 131072\nmax_output_tokens = 1024\nsupports_tools = true\nsupports_native_streaming = false\n'
    runtime += '\n[models.sample]\napi-name = "resume-fixture"\nmax-context = 131072\ntools-support = true\nstreaming = false\n'
    (config / 'runtime.toml').write_text(runtime)
    (config / 'agent-core-models-overlay.toml').write_text(overlay)
    env = {k: v for k, v in os.environ.items() if not any(s in k for s in ['TOKEN', 'API_KEY', 'SECRET'])}
    token = secrets.token_hex(32)
    env.update(MASC_ADMIN_TOKEN=token, MASC_BASE_PATH=str(base), MASC_GRPC_ENABLED='0', MASC_WS_ENABLED='0', MASC_KEEPER_AUTONOMOUS_ENABLED='true', MASC_KEEPER_SANDBOX_PREFLIGHT_ENABLED='false')
    run = json.loads(subprocess.check_output(['gh', 'api', f'repos/jeong-sik/masc/actions/runs/{args.ci_run}']))
    if run['head_sha'] != args.expected_commit:
        raise ValueError('CI run does not match the requested commit')
    artifact_name = f"runtime-probe-{args.arch}-{args.expected_commit}-attempt-{run['run_attempt']}"
    artifact_list = json.loads(subprocess.check_output(['gh', 'api', f'repos/jeong-sik/masc/actions/runs/{args.ci_run}/artifacts?per_page=100']))
    artifact = next(a for a in artifact_list['artifacts'] if a['name'] == artifact_name and not a['expired'])
    binary_dir = root / 'ci-binary'
    if args.artifact_cache:
        cached_provenance = json.loads((args.artifact_cache.parent / 'ci-provenance.json').read_text())
        if cached_provenance['run_id'] != args.ci_run or cached_provenance['head_sha'] != args.expected_commit or cached_provenance['artifact']['id'] != artifact['id']:
            raise ValueError('Cached artifact provenance differs from the selected CI artifact')
        shutil.copytree(args.artifact_cache, binary_dir)
    else:
        subprocess.run(['gh', 'run', 'download', str(args.ci_run), '-R', 'jeong-sik/masc', '--name', artifact_name, '--dir', str(binary_dir)], check=True)
    manifest = json.loads((binary_dir / 'manifest.json').read_text())
    args.binary = binary_dir / 'main_eio.exe'
    binary_sha = hashlib.sha256(args.binary.read_bytes()).hexdigest()
    if manifest['commit'] != args.expected_commit or manifest['arch'] != args.arch or manifest['sha256']['main_eio.exe'] != binary_sha:
        raise ValueError('Downloaded runtime probe manifest does not bind this binary')
    args.binary.chmod(args.binary.stat().st_mode | 0o100)
    save(root / 'ci-provenance.json', {'run_id': args.ci_run, 'head_sha': run['head_sha'], 'artifact': artifact, 'manifest': manifest})
    receipt = {'scope': 'real durable Gate and same-operation continuation with synthetic provider; no semantic LLM acceptance', 'expected_commit': args.expected_commit, 'base_path': str(base), 'port': args.port, 'binary_sha256': hashlib.sha256(args.binary.read_bytes()).hexdigest(), 'status': 'started', 'limitations': ['synthetic provider, no semantic LLM acceptance', 'no attachment or channel-session input in this scenario', 'no server restart in this scenario', 'does not prove automatic recovery from unavailable Gate authority']}
    save(root / 'receipt.json', receipt)
    with socket.socket() as check:
        check.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        check.bind(('127.0.0.1', args.port))
    log = (root / 'server.log').open('wb')
    server = subprocess.Popen([str(args.binary.resolve()), '--base-path', str(base), '--port', str(args.port)], cwd=base, env=env, stdout=log, stderr=subprocess.STDOUT)
    url = f'http://127.0.0.1:{args.port}'
    counter = 0
    session = None

    def http(path, value=None):
        nonlocal session
        req = Request(url + path, data=None if value is None else json.dumps(value).encode(), headers={'Content-Type': 'application/json', 'Accept': 'application/json, text/event-stream', 'Authorization': 'Bearer ' + token})
        if session:
            req.add_header('Mcp-Session-Id', session)
        try:
            response = HTTP.open(req, timeout=20)
        except HTTPError as error:
            raw = error.read().decode()
            save(root / f'http-error-{counter}.json', {'status': error.code, 'body': raw.replace(token, '[WITHHELD]')})
            raise
        with response:
            if response.headers.get('Mcp-Session-Id'):
                session = response.headers['Mcp-Session-Id']
            raw = response.read().decode()
        if token in raw:
            raise ValueError('Credential echo withheld before response persistence')
        (root / f'http-{counter:03}-{path.split("?")[0].replace("/", "_")}.txt').write_text(raw)
        data_lines = [line[6:] for line in raw.splitlines() if line.startswith('data: ')]
        if data_lines:
            raw = next(line for line in data_lines if '"id"' in line)
        return json.loads(raw)

    def call(name, arguments):
        nonlocal counter
        counter += 1
        result = http('/mcp', {'jsonrpc': '2.0', 'id': counter, 'method': 'tools/call', 'params': {'name': name, 'arguments': arguments}})
        save(root / f'mcp-{counter:03}-{name}.json', result)
        if 'error' in result:
            raise ValueError(result['error'])
        result = result['result']
        if result.get('isError'):
            raise ValueError(result)
        return result.get('structuredContent') or json.loads(result['content'][0]['text'])

    try:
        deadline = time.monotonic() + args.observation_seconds
        while True:
            if server.poll() is not None:
                raise RuntimeError('Server exited before health')
            try:
                health = http('/health?full=1')
                if health['startup']['state_ready']:
                    break
                if time.monotonic() >= deadline:
                    raise TimeoutError('Server readiness observation deadline')
                time.sleep(0.2)
            except (URLError, ConnectionError):
                if time.monotonic() >= deadline:
                    raise TimeoutError('Server health observation deadline')
                time.sleep(0.2)
        save(root / 'health.json', health)
        truth = health['build']
        if truth['binary_commit'] != args.expected_commit or Path(health['paths']['effective_base_path']).resolve() != base.resolve():
            raise ValueError('Running binary or effective base differs from requested fixture')
        initialized = http('/mcp', {'jsonrpc': '2.0', 'id': 0, 'method': 'initialize', 'params': {'protocolVersion': '2025-03-26', 'capabilities': {}, 'clientInfo': {'name': 'direct-resume-fixture', 'version': '1'}}})
        save(root / 'initialize.json', initialized)
        http('/api/v1/dashboard/gate/mode', {'mode': 'manual'})
        call('masc_keeper_up', {'name': keeper, 'instructions': 'Synthetic protocol probe. Use the supplied tool response and do not repeat completed effects.', 'sandbox_profile': 'docker', 'activation_mode': 'manual', 'runtime_id': 'primary.sample'})
        submitted = call('masc_keeper_msg', {'name': keeper, 'message': prompt})
        operation_id = submitted['operation_id']
        receipt['operation_id'] = operation_id
        save(root / 'receipt.json', receipt)
        database = base / '.masc/keepers' / keeper / 'chat-operations.sqlite3'
        waiting = None
        while True:
            with sqlite3.connect('file:' + str(database) + '?mode=ro', uri=True) as db:
                db.row_factory = sqlite3.Row
                operations = [dict(row) for row in db.execute('SELECT * FROM operations')]
                semantic = [json.loads(row[0]) for row in db.execute('SELECT record_json FROM semantic_executions')]
            waits = [row for row in semantic if row['phase']['kind'] == 'recovering' and row['phase']['origin']['kind'] == 'gate_wait']
            if len(waits) == 1 and len(operations) == 1 and operations[0]['state'] == 'queued':
                waiting = waits[0]
                break
            if operations and operations[0]['state'] in ['failed', 'succeeded', 'cancelled']:
                raise AssertionError('Original Gate operation terminalized before its approval')
            time.sleep(0.2)
        if waiting is None:
            raise AssertionError('No durable same-operation Gate wait observed')
        save(root / 'waiting-operations.json', operations)
        save(root / 'waiting-semantic.json', semantic)
        if len(events) != 2 or any((base / '.masc/playground').rglob('gate-effect.txt')):
            raise AssertionError('Effect ran or model resumed before approval')
        obligations = waiting['phase']['origin']['waiting']['obligations']
        if len(obligations) != 1:
            raise AssertionError('Expected one actual producer Gate obligation')
        retry = waiting['phase']['origin']['waiting'].get('runtime_retry')
        if retry is None or retry['next_runtime_id'] != 'alternate.sample':
            raise AssertionError('Gate wait lost the simultaneous frozen runtime retry')
        completed = list((base / '.masc/playground').rglob('pre-gate-effect.txt'))
        if len(completed) != 1 or completed[0].read_bytes() != b'completed before Gate approval\n':
            raise AssertionError('The initial completed effect is absent before Gate approval')
        approval_id = obligations[0]['approval_id']
        gate = http('/api/v1/dashboard/gate?force=true')
        save(root / 'gate-before-resolution.json', gate)
        receipt['approval_id'] = approval_id
        receipt['waiting_input_sha256'] = waiting['input_sha256']
        save(root / 'receipt.json', receipt)
        # This event only controls the synthetic responder. The authoritative
        # resolution is the following authenticated public API call.
        approval_resolved.set()
        resolution = http('/api/v1/dashboard/gate/resolve', {'id': approval_id, 'decision': 'approve'})
        save(root / 'gate-resolution.json', resolution)
        while True:
            if server.poll() is not None:
                raise RuntimeError('Server exited while observing the original operation')
            try:
                observed = call('masc_keeper_delegate_status', {'target': {'kind': 'keeper', 'name': keeper}, 'operation_id': operation_id})
            except (URLError, ConnectionError) as error:
                save(root / 'operation-observation-error.json', {'operation_id': operation_id,
                    'error': str(error), 'action': 'continue observing the same operation'})
                time.sleep(0.5)
                continue
            if observed.get('state') in ['Succeeded', 'Failed', 'Completed', 'succeeded', 'failed']:
                break
            time.sleep(0.5)
        save(root / 'terminal-observation.json', observed)
        if observed['state'] != 'Succeeded':
            raise AssertionError('Original operation did not succeed')
        if len(events) != 4 or [e['response_status'] for e in events] != [200, 429, 200, 200]:
            raise AssertionError('Expected completed effect/new Gate request, rate limit, approved artifact read and frozen-runtime completion')
        if not events[2]['path'].startswith('/alternate'):
            raise AssertionError('Approved operation did not use its frozen alternate runtime')
        original = events[0]['body']['messages']
        resumed = events[2]['body']['messages']
        # Provider requests also contain refreshed system-context observations
        # projected as User messages. They are not the admitted human input.
        original_user = {'role': 'user', 'content': prompt}
        if original.count(original_user) != 1 or resumed.count(original_user) != 1:
            raise AssertionError('Original admitted user request changed or duplicated')
        if waiting['input']['payload']['message'] != prompt:
            raise AssertionError('Waiting operation lost its original request body')
        output_ref = json.loads((root / 'approved-output-ref.json').read_text())
        if output_ref['sha256'] not in json.dumps(resumed):
            raise AssertionError('Resumed model input lacks usable complete output_ref')
        read_messages = [m for m in events[3]['body']['messages'] if m['role'] == 'tool' and m.get('tool_call_id') == 'read-approved-result']
        if len(read_messages) != 1:
            raise AssertionError('Actual artifact read did not return to the same model continuation')
        page = json.loads(read_messages[0]['content'])
        if page['sha256'] != output_ref['sha256'] or not page['eof'] or hashlib.sha256(page['content'].encode()).hexdigest() != output_ref['sha256']:
            raise AssertionError('Artifact read did not deliver the complete approved output bytes')
        if 'gate-effect-written' not in page['content']:
            raise AssertionError('The approved Execute output is absent from the actual artifact read')
        save(root / 'artifact-read-result.json', page)
        effects = list((base / '.masc/playground').rglob('gate-effect.txt'))
        if len(effects) != 1 or effects[0].read_bytes() != b'one real gate effect\n':
            raise AssertionError('The real approved effect did not execute exactly once')
        effect = effects[0]
        save(root / 'effect.json', {'path': str(effect.relative_to(base)), 'sha256': hashlib.sha256(effect.read_bytes()).hexdigest(), 'bytes': effect.read_text()})
        rows = [json.loads(line) for path in (base / '.masc/tool_calls').rglob('*.jsonl') for line in path.read_text().splitlines()]
        writes = [row for row in rows if row.get('keeper') == keeper and row.get('tool') == 'Write']
        if len(writes) != 1 or writes[0]['success'] is not True:
            raise AssertionError('The completed pre-Gate effect was replayed or lost')
        save(root / 'completed-before-gate.json', writes[0])
        transcript = [json.loads(line) for line in (base / '.masc/keeper_chat' / (keeper + '.jsonl')).read_text().splitlines()]
        for row in transcript:
            key = row['delivery_key']
            if key['kind'] in ['operation', 'operation_checkpoint']:
                if key['operation_id'] != operation_id:
                    raise AssertionError('Transcript changed operation identity')
            elif key['kind'] == 'approval_lifecycle':
                if key['approval_id'] != approval_id or row['role'] != 'system':
                    raise AssertionError('Transcript contains an unrelated approval lifecycle')
            else:
                raise AssertionError('Unexpected transcript provenance in this isolated operation')
        if sum(row['role'] == 'user' for row in transcript) != 1 or sum(row['role'] == 'assistant' for row in transcript) != 1:
            raise AssertionError('Duplicate user or terminal assistant row')
        if not any(row.get('approval_lifecycle', {}).get('approval_id') == approval_id and row.get('approval_lifecycle', {}).get('phase') == 'continuation_recorded' for row in transcript):
            raise AssertionError('Successful direct continuation did not settle its pending Gate wake')
        save(root / 'transcript.json', transcript)
        admissions = json.loads((root / 'resumed-admission-operations.json').read_text())
        if len(admissions) != 1 or admissions[0]['operation_id'] != operation_id or admissions[0]['state'] != 'running':
            raise AssertionError('Alternate not admitted under original running operation')
        semantic = json.loads((root / 'resumed-admission-semantic.json').read_text())
        if len(semantic) != 1 or semantic[0]['id']['id'] != operation_id or semantic[0]['input_sha256'] != admissions[0]['execution_digest']:
            raise AssertionError('Semantic continuation lost original operation/input digest')
        phase = semantic[0]['phase']
        if phase['kind'] != 'resuming_gate' or phase['resolution']['obligation']['approval_id'] != approval_id:
            raise AssertionError('Resumed model is not owned by the same resolved Gate operation')
        if semantic[0].get('gate_obligations', []) != []:
            raise AssertionError('Approved evidence was not admitted before model continuation')
        if semantic[0]['input_sha256'] != receipt['waiting_input_sha256']:
            raise AssertionError('Gate resolution changed original input ownership')
        receipt['checkpoint'] = phase['waiting']['checkpoint']
        reference = receipt['checkpoint']
        retained = list((base / '.masc/traces').rglob('accepted-checkpoints/' + reference['sha256'] + '.json'))
        if len(retained) != 1 or hashlib.sha256(retained[0].read_bytes()).hexdigest() != reference['sha256']:
            raise AssertionError('Original Gate wait lost its exact retained checkpoint')
        save(root / 'retained-checkpoint.json', json.loads(retained[0].read_text()))
        receipt['input_sha256'] = admissions[0]['execution_digest']
        # Observe the wake consumer, not merely a quiet instant before shutdown.
        ack_text = 'acknowledged spent Gate grant replay without a turn keeper=' + keeper
        while True:
            if server.poll() is not None:
                raise RuntimeError('Server exited before spent Gate wake acknowledgement')
            if len(events) != 4:
                raise AssertionError('Gate wake invoked an additional provider turn')
            ack_lines = [line for line in (root / 'server.log').read_text().splitlines() if ack_text in line]
            if ack_lines:
                save(root / 'spent-wake-ack.json', {'operation_id': operation_id,
                    'approval_id': approval_id, 'provider_requests': len(events), 'log_lines': ack_lines})
                break
            time.sleep(0.5)
        receipt['status'] = 'verified'
        receipt['provider_requests'] = len(events)
        receipt['effect_exists'] = effect.exists()
        if effect.exists():
            receipt['effect_bytes'] = effect.read_text()
        save(root / 'receipt.json', receipt)
    except Exception as error:
        receipt.update(status='failed', error=str(error))
        save(root / 'receipt.json', receipt)
        raise
    finally:
        server.terminate()
        try:
            server.wait(timeout=10)
        except subprocess.TimeoutExpired:
            server.kill()
            server.wait()
        provider.shutdown()
        log.close()
        save(root / 'post-shutdown-observation.json', {'provider_requests': len(events),
            'operation_verification_provider_requests': receipt.get('provider_requests'),
            'operation_state': observed.get('state') if 'observed' in locals() else None})
        if receipt.get('status') == 'verified' and len(events) != receipt['provider_requests']:
            receipt.update(status='failed', error='Additional provider turn observed after direct operation verification',
                           provider_requests_after_shutdown=len(events))
            save(root / 'receipt.json', receipt)
            raise AssertionError(receipt['error'])


if __name__ == '__main__':
    main()
