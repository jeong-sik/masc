"""Observe installed tool search, then execute and read back the same run plan."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import secrets
import socket
import sqlite3
import subprocess
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.error import HTTPError, URLError
from urllib.request import Request, build_opener, HTTPRedirectHandler, ProxyHandler


def save(path, value):
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2) + '\n')


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
                assert 'keeper_tool_search' in names and 'masc_run_plan' in names
                save(out / 'initial-tool-names.json', names)
                name, arguments = 'keeper_tool_search', {'names': ['masc_run_plan']}
            elif index == 1:
                results = [m for m in body['messages'] if m['role'] == 'tool']
                assert results and 'already callable:' in str(results[-1]['content'])
                assert 'masc_run_plan' in str(results[-1]['content'])
                assert set(names) == set(json.loads((out / 'initial-tool-names.json').read_text()))
                save(out / 'search-result.json', results[-1])
                name, arguments = 'masc_run_plan', {'task_id': 'task-search-fixture', 'plan': 'Synthetic installed-tool execution proof'}
            else:
                results = [m for m in body['messages'] if m['role'] == 'tool']
                save(out / 'plan-tool-result.json', results[-1])
                name, arguments = '', {}
            choice = {'index': 0, 'message': {'role': 'assistant', 'content': None, 'tool_calls': [
                {'id': f'fixture-{index}', 'type': 'function', 'function': {'name': name, 'arguments': json.dumps(arguments)}}]}, 'finish_reason': 'tool_calls'}
            if index >= 2:
                choice = {'index': 0, 'message': {'role': 'assistant', 'content': 'Installed tool executed.'}, 'finish_reason': 'stop'}
            usage = {'prompt_tokens': 10, 'completion_tokens': 10, 'total_tokens': 20}
            if body.get('stream'):
                delta = choice['message']
                if 'tool_calls' in delta:
                    delta['tool_calls'][0]['index'] = 0
                chunks = [ {'id': 'goal-proof-fixture', 'object': 'chat.completion.chunk', 'model': 'search-fixture', 'choices': [{'index': 0, 'delta': delta, 'finish_reason': None}]},
                    {'id': 'goal-proof-fixture', 'object': 'chat.completion.chunk', 'choices': [{'index': 0, 'delta': {}, 'finish_reason': choice['finish_reason']}], 'usage': usage} ]
                raw = (''.join('data: ' + json.dumps(chunk) + '\n\n' for chunk in chunks) + 'data: [DONE]\n\n').encode()
                content_type = 'text/event-stream'
            else:
                raw = json.dumps({'id': 'goal-proof-fixture', 'model': 'search-fixture', 'choices': [choice], 'usage': usage}).encode()
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
    runtime += f'\n[providers.search_fixture]\nprotocol = "openai-compatible-http"\nendpoint = "http://127.0.0.1:{provider.server_port}/v1"\n[models.proof]\napi-name = "search-fixture"\nmax-context = 131072\ntools-support = true\nstreaming = true\n[search_fixture.proof]\nmax-request-body-bytes = 1048576\n'
    overlay = (fixtures / 'agent-core-models-overlay.toml').read_text()
    overlay += f'''
[[providers]]
id = "search_fixture"
kind = "openai_compat"
base_url = "http://127.0.0.1:{provider.server_port}/v1"
request_path = "/chat/completions"
api_key_env = ""
capabilities_base = "openai_chat"
[[models]]
id_prefix = "search-fixture"
provider_name = "search_fixture"
base = "openai_chat"
max_context_tokens = 131072
max_output_tokens = 1024
supports_tools = true
supports_tool_choice = true
supports_response_format_json = true
supports_native_streaming = true
[[targets]]
id = "search_fixture.proof"
provider_ref = "search_fixture"
model_id = "search-fixture"
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
    opener = build_opener(ProxyHandler({}), NoRedirect)
    counter = 0
    session = None
    receipt = {'scope': 'real installed-tool search and execution; synthetic provider, no semantic LLM acceptance', 'status': 'started',
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
            response = opener.open(request)
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
        while True:
            assert server.poll() is None, 'server exited'
            try:
                health = http('/health?full=1')
                if health['startup']['state_ready']:
                    break
            except (URLError, ConnectionError) as error:
                save(out / f'readiness-observation-error-{counter:03}.json',
                     {'error': str(error), 'server_pid': server.pid,
                      'action': 'continue_read_observation_on_same_server'})
            time.sleep(0.2)
        assert health['build']['binary_commit'] == a.expected_commit
        assert Path(health['paths']['effective_base_path']).resolve() == base
        save(out / 'health.json', health)
        http('/mcp', {'jsonrpc': '2.0', 'id': 0, 'method': 'initialize', 'params': {'protocolVersion': '2025-03-26', 'capabilities': {}, 'clientInfo': {'name': 'goal-confirmation-fixture', 'version': '1'}}})
        mcp('masc_run_init', {'task_id': 'task-search-fixture', 'agent_name': 'search-proof'})
        mcp('masc_keeper_up', {'name': 'search-proof', 'instructions': 'Synthetic installed tool protocol probe.', 'activation_mode': 'manual', 'runtime_id': 'search_fixture.proof'})
        save(out / 'admission-pending.json', {'keeper': 'search-proof', 'action': 'one admission; never resubmit'})
        admission = mcp('masc_keeper_msg', {'name': 'search-proof', 'message': 'Search for the installed plan tool then record the fixture plan.'})
        operation_id = admission['operation_id']
        save(out / 'admission.json', admission)
        while True:
            if server.poll() is not None:
                raise RuntimeError('Server exited while observing original operation')
            try:
                observed = mcp('masc_keeper_delegate_status', {'target': {'kind': 'keeper', 'name': 'search-proof'}, 'operation_id': operation_id})
            except (URLError, ConnectionError) as error:
                save(out / 'observation-error.json', {'operation_id': operation_id, 'error': str(error)})
                time.sleep(0.5)
                continue
            if observed['state'] in ['Succeeded', 'Failed', 'Cancelled']:
                break
            time.sleep(0.5)
        save(out / 'terminal.json', observed)
        assert observed['state'] == 'Succeeded' and len(requests) == 3
        plan = mcp('masc_run_get', {'task_id': 'task-search-fixture'})
        save(out / 'plan-readback.json', plan)
        assert plan['plan'] == 'Synthetic installed-tool execution proof'
        assert plan['run']['task_id'] == 'task-search-fixture'
        receipt.update(status='verified', operation_id=operation_id, provider_requests=len(requests))
        save(out / 'receipt.json', receipt)
    except Exception as error:
        receipt.update(status='observation_incomplete', error=str(error), server_pid=server.pid,
                       action='preserve server and provider; read-only observation; never resubmit')
        save(out / 'receipt.json', receipt)
        # Keep the responder thread alive too: unwinding main would kill it.
        while server.poll() is None:
            try:
                database = base / '.masc/keepers/search-proof/chat-operations.sqlite3'
                if database.exists():
                    with sqlite3.connect('file:' + str(database) + '?mode=ro', uri=True) as db:
                        db.row_factory = sqlite3.Row
                        operations = [dict(row) for row in db.execute('SELECT operation_id,state FROM operations')]
                    save(out / 'recovery-observation.json', {'operations': operations,
                         'action': 'read existing operation identities only; no admission'})
                    if len(operations) == 1:
                        recovered = mcp('masc_keeper_delegate_status', {'target': {'kind': 'keeper', 'name': 'search-proof'},
                            'operation_id': operations[0]['operation_id']})
                        save(out / 'recovered-operation.json', recovered)
            except (URLError, ConnectionError, sqlite3.Error, AssertionError, ValueError, KeyError) as observation_error:
                save(out / 'recovery-observation-error.json', {'error': str(observation_error)})
            time.sleep(0.5)
        receipt.update(server_exit_code=server.returncode)
        save(out / 'receipt.json', receipt)
    else:
        server.terminate()
        server.wait()
    provider.shutdown()
    log.close()


if __name__ == '__main__':
    main()
