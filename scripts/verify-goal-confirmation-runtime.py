"""Real isolated server/Goal/operator HTTP with a synthetic verifier provider.

The verifier reads a fixture file through the production tool before reporting
APPROVE. No Goal, proof or confirmation ledger is manufactured by this script.
The output's runtime workspace and server.log are private: the workspace may
contain the synthetic server's Admin token. Share only individually reviewed
evidence files, never the entire output directory.
"""
import argparse
import hashlib
import json
import os
import re
from pathlib import Path
import secrets
import socket
import subprocess
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.error import HTTPError, URLError
from urllib.request import Request, build_opener, HTTPRedirectHandler, ProxyHandler
from urllib.parse import urlencode


def save(path, value):
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2) + '\n')


def contains_credential(value, token):
    if isinstance(value, str):
        return contains_encoded_credential(value, token)
    if isinstance(value, dict):
        return any(contains_credential(key, token) or contains_credential(item, token) for key, item in value.items())
    if isinstance(value, list):
        return any(contains_credential(item, token) for item in value)
    return False


def unicode_escape_layers(text):
    # The fixture token is ASCII hex; JSON/SSE can encode its characters as
    # unicode escapes, including in a different SSE frame from the response.
    previous = None
    while text != previous:
        yield text
        previous = text
        text = re.sub(r'\\+u([0-9a-fA-F]{4})', lambda match: chr(int(match.group(1), 16)), text)


def contains_encoded_credential(text, token):
    return any(token in layer for layer in unicode_escape_layers(text))


class CredentialEchoWithheld(ValueError):
    pass


def decode_response_payload(raw, token):
    if contains_encoded_credential(raw, token):
        raise CredentialEchoWithheld('Credential echo withheld')
    lines = [line[6:] for line in raw.splitlines() if line.startswith('data: ')]
    if lines:
        frames = [(line, json.loads(line)) for line in lines if line.strip() != '[DONE]']
        if any(contains_credential(frame, token) for _, frame in frames):
            raise CredentialEchoWithheld('Credential echo withheld')
        payload = next(frame for line, frame in frames if '"id"' in line)
    else:
        payload = json.loads(raw)
    if contains_credential(payload, token):
        raise CredentialEchoWithheld('Credential echo withheld')
    return payload


def http_evidence(path, body, authenticated, status, raw, content_type):
    evidence = {'path': path, 'request': body, 'authenticated': authenticated, 'status': status}
    is_event_stream = (content_type.partition(';')[0].strip().lower() == 'text/event-stream'
                       or any(line.startswith('data:') for line in raw.splitlines()))
    if is_event_stream:
        evidence['response_body'] = {'state': 'not_retained', 'reason': 'event_stream_may_contain_split_credentials'}
    else:
        evidence['raw'] = raw
    return evidence


class ProviderFailure:
    """Transfer only a fixed failure category across the provider thread boundary."""

    def __init__(self):
        self._event = threading.Event()
        self._lock = threading.Lock()
        self._reason = None

    def record(self, error):
        reason = ('Credential echo withheld' if isinstance(error, CredentialEchoWithheld)
                  else 'Synthetic verifier provider handler failed; details withheld')
        with self._lock:
            if not self._event.is_set():
                self._reason = reason
                self._event.set()

    def raise_if_failed(self):
        if self._event.is_set():
            raise RuntimeError(self._reason) from None

    def wait(self, timeout):
        self._event.wait(timeout)
        self.raise_if_failed()


def run_provider_handler(failure, operation):
    try:
        operation()
        return True
    except Exception as error:
        failure.record(error)
        return False


def wait_for_confirmation(read, provider_failure, on_observation_error, interval=0.5):
    while True:
        provider_failure.raise_if_failed()
        try:
            evidence = read()
        except (URLError, ConnectionError) as error:
            provider_failure.raise_if_failed()
            on_observation_error(error)
        else:
            provider_failure.raise_if_failed()
            if evidence['goal']['phase'] == 'awaiting_confirmation':
                return evidence
        provider_failure.wait(interval)


class NoRedirect(HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--binary', type=Path, required=True)
    p.add_argument('--expected-commit', required=True)
    p.add_argument('--output', type=Path, required=True)
    p.add_argument('--port', type=int, default=18943)
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
    provider_failure = ProviderFailure()

    def safe_save(path, value):
        if contains_credential(value, token):
            raise CredentialEchoWithheld('Credential echo withheld')
        save(path, value)

    class Provider(BaseHTTPRequestHandler):
        def log_message(self, *_):
            pass

        def do_POST(self):
            if not run_provider_handler(provider_failure, self.handle_request_body):
                self.close_connection = True

        def handle_request_body(self):
            body = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
            index = len(requests)
            requests.append(body)
            safe_save(out / f'verifier-request-{index:03}.json', body)
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
    runtime += f'\n[providers.goal_fixture]\nprotocol = "openai-compatible-http"\nendpoint = "http://127.0.0.1:{provider.server_port}/v1"\nexact-body-timeout-s = 120.0\n[models.proof]\napi-name = "goal-fixture"\nmax-context = 131072\ntools-support = true\nstreaming = true\n[goal_fixture.proof]\n'
    (config / 'runtime.toml').write_text(runtime)
    env = {k: v for k, v in os.environ.items() if k in ['PATH', 'HOME', 'TMPDIR', 'LANG', 'LC_ALL', 'USER', 'SHELL']}
    env.update(MASC_ADMIN_TOKEN=token, MASC_BASE_PATH=str(base), MASC_GRPC_ENABLED='0', MASC_WS_ENABLED='0', MASC_KEEPER_AUTONOMOUS_ENABLED='false')
    with socket.socket() as probe:
        probe.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        probe.bind(('127.0.0.1', a.port))
    log = (out / 'server.log').open('wb')
    server = subprocess.Popen([str(a.binary.resolve()), '--base-path', str(base), '--port', str(a.port)], cwd=base, env=env, stdout=log, stderr=subprocess.STDOUT)
    opener = build_opener(ProxyHandler({}), NoRedirect)
    counter = 0
    session = None
    receipt = {'scope': 'confirmation GETs match the first ready health instance while the launched process is alive; PID-to-socket and MCP process ownership are not attested; synthetic verifier, no semantic LLM acceptance; runtime workspace and server.log are private', 'status': 'started',
        'expected_commit': a.expected_commit, 'base_path': str(base), 'port': a.port,
        'binary_sha256': hashlib.sha256(a.binary.read_bytes()).hexdigest()}
    safe_save(out / 'receipt.json', receipt)

    confirmation_instance = None
    initial_health_instance = None

    def http(path, body=None, *, authenticated=True, expected_status=200):
        nonlocal counter, session, confirmation_instance
        provider_failure.raise_if_failed()
        if server.poll() is not None:
            raise RuntimeError('Started server exited before the request')
        if body is not None and contains_credential(body, token):
            raise ValueError('Credential echo withheld')
        counter += 1
        headers = {'Content-Type': 'application/json', 'Accept': 'application/json, text/event-stream', 'x-agent-name': 'spoofed-human'}
        if authenticated:
            headers['Authorization'] = 'Bearer ' + token
        if session:
            headers['Mcp-Session-Id'] = session
        request = Request(f'http://127.0.0.1:{a.port}' + path, data=None if body is None else json.dumps(body).encode(), headers=headers)
        try:
            response = opener.open(request)
        except HTTPError as error:
            response = error
        with response:
            raw = response.read().decode()
            status = response.status
            content_type = response.headers.get('Content-Type', '')
            session = response.headers.get('Mcp-Session-Id', session)
            if path.startswith('/api/v1/goals/confirmation?') and authenticated and status == 200:
                assert response.headers.get_all('x-masc-workspace-read', []) == ['matched-v1']
                instances = response.headers.get_all('x-masc-runtime-instance-id', [])
                assert len(instances) == 1 and instances[0]
                if token in instances[0]:
                    raise ValueError('Credential echo withheld')
                if initial_health_instance is None or instances[0] != initial_health_instance or server.poll() is not None:
                    raise RuntimeError('Confirmation response did not match the first ready health instance')
                confirmation_instance = instances[0]
        payload = decode_response_payload(raw, token)
        safe_save(out / f'http-{counter:03}.json', http_evidence(path, body, authenticated, status, raw, content_type))
        if status != expected_status:
            raise RuntimeError(f'{path}: unexpected HTTP status {status} (expected {expected_status})')
        return payload

    def mcp(name, arguments):
        result = http('/mcp', {'jsonrpc': '2.0', 'id': counter + 1, 'method': 'tools/call', 'params': {'name': name, 'arguments': arguments}})['result']
        if result.get('isError'):
            raise RuntimeError(f'MCP tool {name} returned an error; response details withheld')
        return result.get('structuredContent') or json.loads(result['content'][0]['text'])

    try:
        while True:
            assert server.poll() is None, 'server exited'
            try:
                health = http('/health?full=1')
                # Until the server has published its workspace, /health answers
                # everyone the public probe, which has no `startup` section: not ready yet.
                if health.get('startup', {}).get('state_ready'):
                    break
            except (URLError, ConnectionError) as error:
                safe_save(out / f'readiness-observation-error-{counter:03}.json',
                     {'error': str(error), 'server_pid': server.pid,
                      'action': 'continue_read_observation_on_same_server'})
            time.sleep(0.2)
        assert health['build']['binary_commit'] == a.expected_commit
        initial_health_instance = health['build']['runtime_instance_id']
        if not isinstance(initial_health_instance, str) or not initial_health_instance or token in initial_health_instance:
            raise ValueError('Initial health instance unavailable or credential echo withheld')
        assert Path(health['paths']['effective_base_path']).resolve() == base
        expected_workspace = {'base_path': health['paths']['effective_base_path'],
                              'masc_root': health['paths']['effective_masc_root']}
        safe_save(out / 'health.json', health)
        http('/mcp', {'jsonrpc': '2.0', 'id': 0, 'method': 'initialize', 'params': {'protocolVersion': '2025-03-26', 'capabilities': {}, 'clientInfo': {'name': 'goal-confirmation-fixture', 'version': '1'}}})
        created = mcp('masc_goal_upsert', {'title': 'Synthetic marker inspection', 'metric': 'marker count in fixture/evidence.txt', 'target_value': '1'})
        goal_id = created['goal']['id']
        mcp('masc_goal_transition', {'goal_id': goal_id, 'action': 'request_complete'})
        path = '/api/v1/goals/confirmation?' + urlencode({'goal_id': goal_id,
            'expected_base_path': expected_workspace['base_path'], 'expected_masc_root': expected_workspace['masc_root']})
        def on_proof_observation_error(error):
            safe_save(out / f'proof-observation-error-{counter:03}.json',
                 {'path': path, 'error': str(error), 'server_pid': server.pid,
                  'action': 'continue_read_observation_on_same_server'})
            if server.poll() is not None:
                raise RuntimeError('Server exited during proof observation') from error

        evidence = wait_for_confirmation(lambda: http(path), provider_failure, on_proof_observation_error)
        safe_save(out / 'awaiting-evidence.json', evidence)
        verdict = evidence['verification']['completion']['verdict']
        assert evidence['verification']['completion']['state'] == 'proof_proven'
        binding = {'goal_id': goal_id, 'criterion_revision': evidence['goal']['criterion_revision'], 'request_id': verdict['request_id'],
            'verification_run_id': verdict['verification_run_id'], 'expected_workspace': expected_workspace,
            'expected_operator_id': evidence['inspection_operator_id'],
            'expected_runtime_instance_id': confirmation_instance}
        http(path, authenticated=False, expected_status=401)
        endpoint = '/api/v1/goals/confirmation'
        http(endpoint, {**binding, 'actor': 'pretend-human'}, expected_status=400)
        http(endpoint, {**binding, 'verification_run_id': 'wrong-run'}, expected_status=400)
        unchanged = http(path)
        assert unchanged['goal']['phase'] == 'awaiting_confirmation'
        applied = http(endpoint, binding)
        readback = http(path)
        assert confirmation_instance == binding['expected_runtime_instance_id']
        assert applied == readback
        confirmation = readback['verification']['completion']
        assert readback['goal']['phase'] == 'completed' and confirmation['state'] == 'human_confirmed'
        assert confirmation['operator_id'] == 'admin' and confirmation['operator_id'] != 'spoofed-human'
        assert confirmation['verdict'] == verdict
        assert http(endpoint, binding) == applied
        safe_save(out / 'confirmed-readback.json', readback)
        events = [json.loads(line) for line in (base / '.masc/goal_events.jsonl').read_text().splitlines()]
        completions = [event for event in events if event.get('payload', {}).get('phase') == 'completed']
        assert len(completions) == 1 and completions[0]['payload']['actor'] == confirmation['operator_id']
        assert completions[0]['payload']['request_id'] == binding['request_id']
        safe_save(out / 'confirmation-event.json', completions[0])
        mcp('masc_goal_transition', {'goal_id': goal_id, 'action': 'reopen'})
        http(endpoint, binding, expected_status=400)
        provider_failure.raise_if_failed()
        receipt.update(status='verified', goal_id=goal_id, binding=binding, operator_id=confirmation['operator_id'], confirmed_at=confirmation['confirmed_at'], verifier_requests=len(requests), unauthenticated_status=401, spoof_body_status=400, stale_run_status=400, reopened_replay_status=400)
        safe_save(out / 'receipt.json', receipt)
    except Exception as error:
        receipt.update(status='failed', error=str(error))
        safe_save(out / 'receipt.json', receipt)
        raise
    finally:
        server.terminate()
        server.wait()
        provider.shutdown()
        log.close()


if __name__ == '__main__':
    main()
