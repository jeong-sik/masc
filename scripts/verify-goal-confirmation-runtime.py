"""Real isolated server/Goal/operator HTTP with a synthetic verifier provider.

The verifier reads a fixture file through the production tool before reporting
APPROVE. No Goal, proof or confirmation ledger is manufactured by this script.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import secrets
import socket
import subprocess
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen


def save(path, value):
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2) + '\n')


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--binary', type=Path, required=True)
    p.add_argument('--expected-commit', required=True)
    p.add_argument('--output', type=Path, required=True)
    p.add_argument('--port', type=int, default=18943)
    p.add_argument('--observation-seconds', type=int, default=120)
    a = p.parse_args()
    a.output.mkdir(parents=True, exist_ok=False)
    out = a.output.resolve()
    base = out / 'base'
    config = base / '.masc/config'
    config.mkdir(parents=True)
    artifact = base / '.masc/playground/fixture/evidence.txt'
    artifact.parent.mkdir(parents=True)
    artifact.write_text('synthetic goal evidence: exactly one marker\n')
    requests = []
    token = secrets.token_hex(32)

    class Provider(BaseHTTPRequestHandler):
        def log_message(self, *_):
            pass

        def do_POST(self):
            body = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
            index = len(requests)
            requests.append(body)
            save(out / f'verifier-request-{index:03}.json', body)
            names = [tool['function']['name'] for tool in body['tools']]
            if index == 0:
                assert 'tool_read_file' in names
                name = 'tool_read_file'
                arguments = {'file_path': str(artifact)}
            else:
                assert 'report_review_verdict' in names
                results = [m for m in body['messages'] if m['role'] == 'tool']
                assert results and 'synthetic goal evidence: exactly one marker' in json.dumps(results)
                name = 'report_review_verdict'
                arguments = {'verdict': 'APPROVE', 'reason': 'Synthetic verifier read the real fixture file and observed exactly one marker.'}
            choice = {'index': 0, 'message': {'role': 'assistant', 'content': None, 'tool_calls': [
                {'id': f'fixture-{index}', 'type': 'function', 'function': {'name': name, 'arguments': json.dumps(arguments)}}]}, 'finish_reason': 'tool_calls'}
            if index >= 2:
                choice = {'index': 0, 'message': {'role': 'assistant', 'content': 'Synthetic verifier finished after its one verdict.'}, 'finish_reason': 'stop'}
            usage = {'prompt_tokens': 10, 'completion_tokens': 10, 'total_tokens': 20}
            if body.get('stream'):
                delta = choice['message']
                if 'tool_calls' in delta:
                    delta['tool_calls'][0]['index'] = 0
                chunks = [ {'id': 'goal-proof-fixture', 'object': 'chat.completion.chunk', 'model': 'goal-fixture', 'choices': [{'index': 0, 'delta': delta, 'finish_reason': None}]},
                    {'id': 'goal-proof-fixture', 'object': 'chat.completion.chunk', 'choices': [{'index': 0, 'delta': {}, 'finish_reason': choice['finish_reason']}], 'usage': usage} ]
                raw = (''.join('data: ' + json.dumps(chunk) + '\n\n' for chunk in chunks) + 'data: [DONE]\n\n').encode()
                content_type = 'text/event-stream'
            else:
                raw = json.dumps({'id': 'goal-proof-fixture', 'model': 'goal-fixture', 'choices': [choice], 'usage': usage}).encode()
                content_type = 'application/json'
            self.send_response(200)
            self.send_header('Content-Type', content_type)
            self.send_header('Content-Length', str(len(raw)))
            self.end_headers()
            self.wfile.write(raw)

    provider = ThreadingHTTPServer(('127.0.0.1', 0), Provider)
    threading.Thread(target=provider.serve_forever, daemon=True).start()
    fixtures = Path(__file__).parent / 'fixtures/release-evidence'
    runtime = (fixtures / 'runtime.toml').read_text()
    runtime += '\n[runtime.exact_output_lanes.verifier_exact]\nslots = ["goal_fixture.proof"]\n'
    runtime += f'\n[providers.goal_fixture]\nprotocol = "openai-compatible-http"\nendpoint = "http://127.0.0.1:{provider.server_port}/v1"\n[models.proof]\napi-name = "goal-fixture"\nmax-context = 131072\ntools-support = true\nstreaming = true\n[goal_fixture.proof]\nmax-request-body-bytes = 1048576\n'
    overlay = (fixtures / 'agent-core-models-overlay.toml').read_text()
    overlay += f'''
[[providers]]
id = "goal_fixture"
kind = "openai_compat"
base_url = "http://127.0.0.1:{provider.server_port}/v1"
request_path = "/chat/completions"
api_key_env = ""
capabilities_base = "openai_chat"
[[models]]
id_prefix = "goal-fixture"
provider_name = "goal_fixture"
base = "openai_chat"
max_context_tokens = 131072
max_output_tokens = 1024
supports_tools = true
supports_tool_choice = true
supports_response_format_json = true
supports_native_streaming = true
[[targets]]
id = "goal_fixture.proof"
provider_ref = "goal_fixture"
model_id = "goal-fixture"
'''
    (config / 'runtime.toml').write_text(runtime)
    (config / 'agent-core-models-overlay.toml').write_text(overlay)
    env = {k: v for k, v in os.environ.items() if k in ['PATH', 'HOME', 'TMPDIR', 'LANG', 'LC_ALL', 'USER', 'SHELL']}
    env.update(MASC_ADMIN_TOKEN=token, MASC_BASE_PATH=str(base), MASC_GRPC_ENABLED='0', MASC_WS_ENABLED='0', MASC_KEEPER_AUTONOMOUS_ENABLED='false')
    with socket.socket() as probe:
        probe.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        probe.bind(('127.0.0.1', a.port))
    log = (out / 'server.log').open('wb')
    server = subprocess.Popen([str(a.binary.resolve()), '--base-path', str(base), '--port', str(a.port)], cwd=base, env=env, stdout=log, stderr=subprocess.STDOUT)
    counter = 0
    session = None
    receipt = {'scope': 'real isolated server and operator HTTP; synthetic verifier, no semantic LLM acceptance', 'status': 'started',
        'expected_commit': a.expected_commit, 'base_path': str(base), 'port': a.port,
        'binary_sha256': hashlib.sha256(a.binary.read_bytes()).hexdigest()}
    save(out / 'receipt.json', receipt)

    def http(path, body=None, *, authenticated=True, expected_status=200):
        nonlocal counter, session
        counter += 1
        headers = {'Content-Type': 'application/json', 'Accept': 'application/json, text/event-stream', 'x-agent-name': 'spoofed-human'}
        if authenticated:
            headers['Authorization'] = 'Bearer ' + token
        if session:
            headers['Mcp-Session-Id'] = session
        request = Request(f'http://127.0.0.1:{a.port}' + path, data=None if body is None else json.dumps(body).encode(), headers=headers)
        try:
            response = urlopen(request, timeout=20)
        except HTTPError as error:
            response = error
        with response:
            raw = response.read().decode()
            status = response.status
            session = response.headers.get('Mcp-Session-Id', session)
        if token in raw:
            raise ValueError('Credential echo withheld')
        save(out / f'http-{counter:03}.json', {'path': path, 'request': body, 'authenticated': authenticated, 'status': status, 'raw': raw})
        assert status == expected_status, (path, status, raw)
        lines = [line[6:] for line in raw.splitlines() if line.startswith('data: ')]
        return json.loads(next(line for line in lines if '"id"' in line) if lines else raw)

    def mcp(name, arguments):
        result = http('/mcp', {'jsonrpc': '2.0', 'id': counter + 1, 'method': 'tools/call', 'params': {'name': name, 'arguments': arguments}})['result']
        assert not result.get('isError'), result
        return result.get('structuredContent') or json.loads(result['content'][0]['text'])

    try:
        deadline = time.monotonic() + a.observation_seconds
        while True:
            assert server.poll() is None, 'server exited'
            try:
                health = http('/health?full=1')
                if health['startup']['state_ready']:
                    break
            except URLError:
                pass
            assert time.monotonic() < deadline, 'readiness observation deadline'
            time.sleep(0.2)
        assert health['build']['binary_commit'] == a.expected_commit
        assert Path(health['paths']['effective_base_path']).resolve() == base
        save(out / 'health.json', health)
        http('/mcp', {'jsonrpc': '2.0', 'id': 0, 'method': 'initialize', 'params': {'protocolVersion': '2025-03-26', 'capabilities': {}, 'clientInfo': {'name': 'goal-confirmation-fixture', 'version': '1'}}})
        created = mcp('masc_goal_upsert', {'title': 'Synthetic marker inspection', 'metric': 'marker count in fixture/evidence.txt', 'target_value': '1'})
        goal_id = created['goal']['id']
        mcp('masc_goal_transition', {'goal_id': goal_id, 'action': 'request_complete'})
        path = '/api/v1/goals/confirmation?goal_id=' + goal_id
        while True:
            evidence = http(path)
            if evidence['goal']['phase'] == 'awaiting_confirmation':
                break
            assert time.monotonic() < deadline, 'proof observation deadline'
            time.sleep(0.5)
        save(out / 'awaiting-evidence.json', evidence)
        verdict = evidence['verification']['completion']['verdict']
        assert evidence['verification']['completion']['state'] == 'proof_proven'
        binding = {'goal_id': goal_id, 'criterion_revision': evidence['goal']['criterion_revision'], 'request_id': verdict['request_id'], 'verification_run_id': verdict['verification_run_id']}
        http(path, authenticated=False, expected_status=401)
        endpoint = '/api/v1/goals/confirmation'
        http(endpoint, {**binding, 'actor': 'pretend-human'}, expected_status=400)
        http(endpoint, {**binding, 'verification_run_id': 'wrong-run'}, expected_status=400)
        unchanged = http(path)
        assert unchanged['goal']['phase'] == 'awaiting_confirmation'
        applied = http(endpoint, binding)
        readback = http(path)
        assert applied == readback
        confirmation = readback['verification']['completion']
        assert readback['goal']['phase'] == 'completed' and confirmation['state'] == 'human_confirmed'
        assert confirmation['operator_id'] == 'admin' and confirmation['operator_id'] != 'spoofed-human'
        assert confirmation['verdict'] == verdict
        assert http(endpoint, binding) == applied
        save(out / 'confirmed-readback.json', readback)
        events = [json.loads(line) for line in (base / '.masc/goal_events.jsonl').read_text().splitlines()]
        completions = [event for event in events if event.get('payload', {}).get('phase') == 'completed']
        assert len(completions) == 1 and completions[0]['payload']['actor'] == confirmation['operator_id']
        assert completions[0]['payload']['request_id'] == binding['request_id']
        save(out / 'confirmation-event.json', completions[0])
        mcp('masc_goal_transition', {'goal_id': goal_id, 'action': 'reopen'})
        http(endpoint, binding, expected_status=400)
        receipt.update(status='verified', goal_id=goal_id, binding=binding, operator_id=confirmation['operator_id'], confirmed_at=confirmation['confirmed_at'], verifier_requests=len(requests), unauthenticated_status=401, spoof_body_status=400, stale_run_status=400, reopened_replay_status=400)
        save(out / 'receipt.json', receipt)
    except Exception as error:
        receipt.update(status='failed', error=str(error))
        save(out / 'receipt.json', receipt)
        raise
    finally:
        server.terminate()
        try:
            server.wait(timeout=10)
        except subprocess.TimeoutExpired:
            server.kill(); server.wait()
        provider.shutdown()
        log.close()


if __name__ == '__main__':
    main()
