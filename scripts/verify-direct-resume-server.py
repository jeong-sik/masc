"""Synthetic provider fault injection through a real CI-built MASC server.

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
import sqlite3
import subprocess
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen


def save(path, value):
    path.write_text(json.dumps(value, indent=2, ensure_ascii=False) + '\n')


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--binary', type=Path, required=True)
    p.add_argument('--output', type=Path, required=True)
    p.add_argument('--expected-commit', required=True)
    p.add_argument('--port', type=int, default=18941)
    p.add_argument('--observation-seconds', type=int, default=120)
    args = p.parse_args()
    args.output.mkdir(parents=True, exist_ok=False)
    root = args.output.resolve()
    base = root / 'base'
    config = base / '.masc/config'
    config.mkdir(parents=True)
    keeper = 'direct-resume-http-proof'
    prompt = 'Synthetic continuation probe: record the supplied one-time file effect, then complete this exact original request.'
    effect = base / '.masc/playground/docker' / keeper / 'effect.txt'
    events = []
    primary_count = 0
    lock = threading.Lock()

    class Provider(BaseHTTPRequestHandler):
        def log_message(self, *_):
            pass

        def do_POST(self):
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
                if primary and primary_count == 1:
                    names = [t['function']['name'] for t in body.get('tools', [])]
                    if 'Write' not in names:
                        response = {'error': {'message': 'Fixture requires actual Write schema', 'type': 'invalid_request_error'}}
                        status = 400
                    else:
                        save(root / 'write-schema.json', next(t for t in body['tools'] if t['function']['name'] == 'Write'))
                        response = {'id': 'fixture-effect', 'model': 'resume-fixture', 'choices': [{'index': 0, 'message': {'role': 'assistant', 'content': None, 'tool_calls': [{'id': 'effect-once', 'type': 'function', 'function': {'name': 'Write', 'arguments': json.dumps({'file_path': 'effect.txt', 'content': 'one real filesystem effect\n'})}}]}, 'finish_reason': 'tool_calls'}]}
                        status = 200
                elif primary:
                    response = {'error': {'message': 'Synthetic provider rate limit after tool effect', 'type': 'rate_limit_error'}}
                    status = 429
                else:
                    database = base / '.masc/keepers' / keeper / 'chat-operations.sqlite3'
                    with sqlite3.connect('file:' + str(database) + '?mode=ro', uri=True) as db:
                        db.row_factory = sqlite3.Row
                        save(root / 'alternate-admission-operations.json', [dict(row) for row in db.execute('SELECT * FROM operations')])
                        save(root / 'alternate-admission-semantic.json', [json.loads(row[0]) for row in db.execute('SELECT record_json FROM semantic_executions')])
                    snapshots = []
                    for path in (base / '.masc/traces').rglob('agent-core-snapshot-*.json'):
                        snapshots.append({'path': str(path.relative_to(base)), 'sha256': hashlib.sha256(path.read_bytes()).hexdigest(), 'checkpoint': json.loads(path.read_text())})
                    save(root / 'alternate-admission-checkpoints.json', snapshots)
                    response = {'id': 'fixture-completed', 'model': 'resume-fixture', 'choices': [{'index': 0, 'message': {'role': 'assistant', 'content': 'Synthetic continuation completed from the saved tool receipt.'}, 'finish_reason': 'stop'}]}
                    status = 200
                response['usage'] = {'prompt_tokens': 10, 'completion_tokens': 10, 'total_tokens': 20}
                event['response_status'] = status
                save(root / f'provider-{index:03}.json', event)
            streaming = body.get('stream') is True and status == 200
            if streaming:
                choice = response['choices'][0]
                delta = choice['message']
                for tool in delta.get('tool_calls', []):
                    tool['index'] = 0
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
    env.update(MASC_ADMIN_TOKEN=token, MASC_BASE_PATH=str(base), MASC_GRPC_ENABLED='0', MASC_WS_ENABLED='0', MASC_KEEPER_AUTONOMOUS_ENABLED='false', MASC_KEEPER_SANDBOX_PREFLIGHT_ENABLED='false')
    receipt = {'scope': 'synthetic HTTP fault injection; no semantic LLM acceptance', 'expected_commit': args.expected_commit, 'base_path': str(base), 'port': args.port, 'binary_sha256': hashlib.sha256(args.binary.read_bytes()).hexdigest(), 'status': 'started'}
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
            response = urlopen(req, timeout=20)
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
        call('masc_keeper_up', {'name': keeper, 'instructions': 'Synthetic protocol probe. Use the supplied tool response and do not repeat completed effects.', 'sandbox_profile': 'docker', 'activation_mode': 'manual', 'runtime_id': 'primary.sample'})
        submitted = call('masc_keeper_msg', {'name': keeper, 'message': prompt})
        operation_id = submitted['operation_id']
        receipt['operation_id'] = operation_id
        save(root / 'receipt.json', receipt)
        while time.monotonic() < deadline:
            observed = call('masc_keeper_delegate_status', {'target': {'kind': 'keeper', 'name': keeper}, 'operation_id': operation_id})
            if observed.get('state') in ['Succeeded', 'Failed', 'Completed', 'succeeded', 'failed']:
                break
            time.sleep(0.5)
        save(root / 'terminal-observation.json', observed)
        if observed['state'] != 'Succeeded':
            raise AssertionError('Original operation did not succeed')
        if len(events) != 3 or [e['response_status'] for e in events] != [200, 429, 200]:
            raise AssertionError('Expected primary tool, primary rate limit, alternate completion')
        original = events[0]['body']['messages']
        alternate = events[2]['body']['messages']
        original_user = [m for m in original if m['role'] == 'user']
        for message in original_user:
            if alternate.count(message) != original.count(message):
                raise AssertionError('Original user input changed or duplicated')
        tool_receipts = [m for m in alternate if m['role'] == 'tool' and m.get('tool_call_id') == 'effect-once']
        if len(tool_receipts) != 1 or json.loads(tool_receipts[0]['content']).get('ok') is not True:
            raise AssertionError('Alternate did not receive successful original Write receipt')
        if effect.read_bytes() != b'one real filesystem effect\n':
            raise AssertionError('Actual filesystem bytes differ')
        rows = [json.loads(line) for path in (base / '.masc/tool_calls').rglob('*.jsonl') for line in path.read_text().splitlines()]
        writes = [row for row in rows if row.get('keeper') == keeper and row.get('tool') == 'Write']
        if len(writes) != 1 or writes[0]['success'] is not True:
            raise AssertionError('Expected one successful durable Write execution')
        save(root / 'effect-execution.json', writes[0])
        transcript = [json.loads(line) for line in (base / '.masc/keeper_chat' / (keeper + '.jsonl')).read_text().splitlines()]
        if any(row['delivery_key']['operation_id'] != operation_id for row in transcript):
            raise AssertionError('Transcript changed operation identity')
        if sum(row['role'] == 'user' for row in transcript) != 1 or sum(row['role'] == 'assistant' for row in transcript) != 1:
            raise AssertionError('Duplicate user or terminal assistant row')
        save(root / 'transcript.json', transcript)
        admissions = json.loads((root / 'alternate-admission-operations.json').read_text())
        if len(admissions) != 1 or admissions[0]['operation_id'] != operation_id or admissions[0]['state'] != 'running':
            raise AssertionError('Alternate not admitted under original running operation')
        semantic = json.loads((root / 'alternate-admission-semantic.json').read_text())
        if len(semantic) != 1 or semantic[0]['id']['id'] != operation_id or semantic[0]['input_sha256'] != admissions[0]['execution_digest']:
            raise AssertionError('Semantic continuation lost original operation/input digest')
        phase = semantic[0]['phase']
        if phase['kind'] != 'resuming_runtime_retry' or phase['origin']['next_runtime_id'] != 'alternate.sample':
            raise AssertionError('Alternate request not backed by durable runtime continuation')
        reference = phase['origin']['checkpoint']
        snapshots = json.loads((root / 'alternate-admission-checkpoints.json').read_text())
        matching = [s for s in snapshots if s['sha256'] == reference['sha256']]
        if not matching or matching[0]['checkpoint']['turn_count'] != reference['turn_count']:
            raise AssertionError('Continuation does not bind a saved checkpoint')
        receipt['checkpoint'] = reference
        receipt['input_sha256'] = admissions[0]['execution_digest']
        receipt['status'] = 'verified'
        receipt['execution_id'] = writes[0]['execution_id']
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


if __name__ == '__main__':
    main()
