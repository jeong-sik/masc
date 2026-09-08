#!/usr/bin/env python3
"""Installed MASC -> fixture model -> real Docker tool -> durable checkpoint.

Requires an already-built, locally available Docker image. Never builds code or
images. The model is scripted: this proves wiring and persistence, not quality.
Evidence survives in --output-dir; temporary workspace and owned containers do not.
"""
import argparse
import hashlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path, PurePosixPath
import socket
import subprocess
import tempfile
import threading
import time
import urllib.error
import urllib.request
import uuid


class SmokeError(RuntimeError):
    pass


def objects(value):
    """Decode structured envelopes and stdout JSON without substring verdicts."""
    if isinstance(value, dict):
        yield value
        for child in value.values():
            yield from objects(child)
    elif isinstance(value, list):
        for child in value:
            yield from objects(child)
    elif isinstance(value, str):
        for line in value.splitlines():
            try:
                decoded = json.loads(line)
            except (ValueError, TypeError):
                continue
            if isinstance(decoded, (dict, list)):
                yield from objects(decoded)


def proof_from(value, marker):
    return next((obj for obj in objects(value)
                 if obj.get('marker') == marker and isinstance(obj.get('cwd'), str)
                 and isinstance(obj.get('hostname'), str) and type(obj.get('uid')) is int), None)


class ModelFixture:
    def __init__(self, marker, output):
        self.marker, self.output = marker, output
        self.requests = []
        self.tool_name = None
        self.search_requested = False
        self.proof = None
        self.error = None
        self.lock = threading.Lock()
        self.call_id = 'first-turn-proof-call'
        self.final = 'FIRST_KEEPER_TURN_COMPLETED_' + marker
        self.filename = 'first-turn-proof.json'

    def reply(self, request):
        with self.lock:
            self.requests.append(request)
            (self.output / 'model-requests.json').write_text(json.dumps(self.requests, indent=2))
            if request.get('model') != 'deepseek-v4-flash':
                raise SmokeError('unexpected auxiliary model request: ' + str(request.get('model')))
            messages = request.get('messages', [])
            results = [m for m in messages if m.get('role') == 'tool'
                       and m.get('tool_call_id') == self.call_id]
            if results:
                self.proof = proof_from(results[-1].get('content'), self.marker)
                if self.proof is None:
                    raise SmokeError('Execute returned no structured Docker proof: ' + str(results[-1]))
                message = {'role': 'assistant', 'content': self.final}
                finish = 'stop'
            else:
                if len(self.requests) != (2 if self.search_requested else 1):
                    raise SmokeError('model re-requested without the expected ToolResult')
                offered = {t.get('function', {}).get('name') for t in request.get('tools', [])}
                self.tool_name = next((name for name in ('Execute', 'tool_execute') if name in offered), None)
                if self.tool_name is None:
                    if self.search_requested or 'keeper_tool_search' not in offered:
                        raise SmokeError('installed Keeper offered no Execute tool')
                    self.search_requested = True
                    return {'id': 'fixture-discovery', 'object': 'chat.completion',
                            'model': 'deepseek-v4-flash', 'choices': [{'index': 0,
                            'message': {'role': 'assistant', 'content': None, 'tool_calls': [{
                                'id': 'first-turn-discovery', 'type': 'function', 'function': {
                                    'name': 'keeper_tool_search',
                                    'arguments': json.dumps({'names': ['Execute']})}}]},
                            'finish_reason': 'tool_calls'}],
                            'usage': {'prompt_tokens': 1, 'completion_tokens': 1, 'total_tokens': 2}}
                code = ('import json,os,socket; from pathlib import Path; '
                        'p={"marker":' + repr(self.marker) + ',"cwd":os.getcwd(),'
                        '"hostname":socket.gethostname(),"uid":os.getuid()}; '
                        's=json.dumps(p,sort_keys=True); Path(' + repr(self.filename)
                        + ').write_text(s+"\\n"); print(s)')
                args = {'argv': ['python3', '-c', code]}
                message = {'role': 'assistant', 'content': None, 'tool_calls': [{
                    'id': self.call_id, 'type': 'function', 'function': {
                        'name': self.tool_name, 'arguments': json.dumps(args)}}]}
                finish = 'tool_calls'
            return {'id': 'fixture-' + str(len(self.requests)), 'object': 'chat.completion',
                    'model': 'deepseek-v4-flash', 'choices': [{'index': 0, 'message': message,
                    'finish_reason': finish}], 'usage': {'prompt_tokens': 1, 'completion_tokens': 1,
                                                        'total_tokens': 2}}

    def serve(self):
        fixture = self
        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *_args):
                pass

            def do_POST(self):
                try:
                    request = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
                    response = fixture.reply(request)
                    status = 200
                except (SmokeError, ValueError, KeyError) as error:
                    fixture.error = str(error)
                    response, status = {'error': {'message': str(error)}}, 500
                data = json.dumps(response).encode()
                self.send_response(status)
                self.send_header('Content-Type', 'application/json')
                self.send_header('Content-Length', str(len(data)))
                self.end_headers()
                self.wfile.write(data)
        server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
        threading.Thread(target=server.serve_forever, daemon=True).start()
        return server


def command(argv, env, timeout=90):
    try:
        result = subprocess.run(argv, env=env, capture_output=True, text=True, timeout=timeout,
                                cwd=env.get("MASC_BASE_PATH"))
    except subprocess.TimeoutExpired as error:
        raise SmokeError(f'{argv[:2]} timed out after {timeout}s; stdout={error.stdout!r}; stderr={error.stderr!r}') from error
    if result.returncode:
        raise SmokeError(f'{argv[0]} {argv[1]} exited {result.returncode}: {result.stderr}\n{result.stdout}')
    return result.stdout


def request(url, token=None, body=None, timeout=30):
    headers = {'Content-Type': 'application/json'}
    if token:
        headers['Authorization'] = 'Bearer ' + token
    data = None if body is None else json.dumps(body).encode()
    with urllib.request.urlopen(urllib.request.Request(url, data=data, headers=headers), timeout=timeout) as response:
        return response.read()


def wait_until(description, action, server, timeout=60):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if server.poll() is not None:
            raise SmokeError('MASC exited while waiting for ' + description)
        value = action()
        if value:
            return value
        time.sleep(0.2)
    raise SmokeError('timed out waiting for ' + description)


def checkpoint_proof(base, fixture):
    for path in (base / '.masc').rglob('*.json'):
        try:
            data = json.loads(path.read_text())
        except (OSError, ValueError, UnicodeError):
            continue
        if not isinstance(data, dict) or not data.get('session_id'):
            continue
        messages = data.get('messages')
        if not isinstance(messages, list):
            continue
        call = any(m.get('role') == 'assistant' and any(
            obj.get('id') == fixture.call_id and obj.get('name') == fixture.tool_name
            for obj in objects(m.get('content'))) for m in messages)
        result = any(m.get('role') == 'tool' and proof_from(m.get('content'), fixture.marker)
                     for m in messages)
        final = any(m.get('role') == 'assistant' and any(
            obj.get('text') == fixture.final for obj in objects(m.get('content'))) for m in messages)
        if call and result and final:
            return path, data
    return None


def run(args):
    binary = str(Path(args.binary).resolve(strict=True))
    output = Path(args.output_dir).resolve()
    output.mkdir(parents=True, exist_ok=True)
    marker = uuid.uuid4().hex
    keeper = 'first-turn-' + marker[:12]
    fixture = ModelFixture(marker, output)
    model_server = fixture.serve()
    server = None
    docker_env = os.environ.copy()
    owned = []
    try:
        command(['docker', 'image', 'inspect', args.image], docker_env)
        # Docker Desktop/Colima choose their socket through the operator's
        # context. Carry only that endpoint across HOME isolation, not config
        # files or registry credentials.
        docker_host = docker_env.get('DOCKER_HOST')
        if not docker_host:
            contexts = json.loads(command(['docker', 'context', 'inspect'], docker_env))
            docker_host = contexts[0]['Endpoints']['docker']['Host']
        with tempfile.TemporaryDirectory(prefix='masc-first-turn-') as directory:
            base = Path(directory).resolve()
            home = base / 'home'
            home.mkdir()
            env = {k: v for k, v in os.environ.items()
                   if k in ('PATH', 'LANG', 'LC_ALL', 'TMPDIR', 'DOCKER_HOST', 'DOCKER_CONTEXT', 'DOCKER_CONFIG')}
            env.pop('DOCKER_CONTEXT', None)
            env.pop('DOCKER_CONFIG', None)
            env.update(DOCKER_HOST=docker_host, HOME=str(home), MASC_BASE_PATH=str(base), MASC_KEEPER_BOOTSTRAP_ENABLED='true',
                       MASC_KEEPER_SANDBOX_DOCKER_IMAGE=args.image)
            command([binary, 'init', '--base-path', str(base)], env)
            config = base / '.masc/config'
            # Reuse the checked release startup contracts, including mandatory
            # exact-output lanes; only endpoint and transport streaming differ.
            fixtures = Path(__file__).resolve().parent / 'fixtures/release-evidence'
            endpoint = f'http://127.0.0.1:{model_server.server_port}/v1'
            for name in ('runtime.toml', 'agent-core-models-overlay.toml'):
                content = (fixtures / name).read_text()
                if 'http://127.0.0.1:9/v1' not in content:
                    raise SmokeError('release runtime fixture endpoint contract changed')
                content = content.replace('http://127.0.0.1:9/v1', endpoint)
                content = content.replace('streaming = true', 'streaming = false')
                (config / name).write_text(content)
            keepers = config / 'keepers'
            keepers.mkdir(exist_ok=True)
            if list(keepers.glob('*.toml')):
                raise SmokeError('fresh init unexpectedly seeded a Keeper')
            with socket.socket() as sock:
                sock.bind(('127.0.0.1', 0))
                port = sock.getsockname()[1]
            url = f'http://127.0.0.1:{port}'
            command([binary, 'login', '--base-path', str(base), '--host', '127.0.0.1',
                     '--port', str(port), '--agent', 'first-turn-admin', '--role', 'admin',
                     '--client-env', 'MASC_FIRST_TURN_TOKEN', '--no-expiry', '--json'], env)
            token = (base / '.masc/auth/first-turn-admin.token').read_text().strip()
            with (output / 'server.log').open('w') as log:
                server = subprocess.Popen([binary, 'start', '--base-path', str(base), '--host',
                                           '127.0.0.1', '--port', str(port)], env=env, stdout=log, stderr=log, cwd=base)
                try:
                    def health():
                        try:
                            return json.loads(request(url + '/health?full=1', timeout=2))
                        except (urllib.error.URLError, TimeoutError):
                            return None
                    healthy = wait_until('isolated server health', health, server)
                    actual_base = healthy.get('paths', {}).get('effective_base_path')
                    if actual_base != str(base):
                        raise SmokeError(f'health base path mismatch: {actual_base!r}')
                    (output / 'health.json').write_text(json.dumps(healthy, indent=2))
                    try:
                        creation = command([binary, 'keeper-create', '--base-path', str(base),
                            '--host', '127.0.0.1', '--port', str(port), '--agent', 'first-turn-admin',
                            '--name', keeper, '--sandbox-profile', 'docker', '--network-mode', 'none',
                            '--no-skills', '--no-autoboot', '--no-proactive', '--instructions',
                            'Execute the isolated first-turn proof and report its actual result.'], env)
                    except SmokeError as error:
                        # Diagnostic only: do not turn a broken installed CLI
                        # into a passing acceptance by silently bypassing it.
                        try:
                            direct = request(url + '/api/v1/keepers/' + keeper + '/up', token,
                                {'name': keeper, 'sandbox_profile': 'docker', 'network_mode': 'none',
                                 'skills': {'names': []}, 'autoboot_enabled': False,
                                 'proactive_enabled': False, 'instructions': 'Isolated first-turn proof.'}, timeout=15)
                            (output / 'direct-up-diagnostic.json').write_bytes(direct)
                        except (urllib.error.URLError, TimeoutError) as diagnostic_error:
                            detail = (diagnostic_error.read().decode() if isinstance(diagnostic_error, urllib.error.HTTPError)
                                      else str(diagnostic_error))
                            (output / 'direct-up-diagnostic.txt').write_text(detail)
                        raise error
                    (output / 'keeper-create.txt').write_text(creation)
                    mode = json.loads(request(url + '/api/v1/keepers/tool-approval-mode', token,
                                              {'name': keeper, 'mode': 'yolo'}))
                    if mode.get('keeper') != keeper or mode.get('mode') != 'yolo':
                        raise SmokeError('approval mode was not applied')
                    body = request(url + '/api/v1/keepers/chat/stream', token,
                        {'name': keeper, 'message': 'Run the isolated Docker proof once, then report completion.',
                         'request_id': 'kmsg-' + marker}, timeout=180)
                    (output / 'chat-stream.txt').write_bytes(body)
                    if fixture.error:
                        raise SmokeError(fixture.error)
                    if fixture.proof is None or len(fixture.requests) != (3 if fixture.search_requested else 2):
                        raise SmokeError('expected exactly tool-request then actual ToolResult/final response')
                    ids = command(['docker', 'ps', '-aq', '--filter', 'label=masc.mcp.keeper=' + keeper], docker_env).split()
                    if not ids:
                        raise SmokeError('no actual Keeper Docker container found')
                    inspected = json.loads(command(['docker', 'inspect', *ids], docker_env))
                    owned = ids
                    (output / 'docker-inspect.json').write_text(json.dumps(inspected, indent=2))
                    container = next((item for item in inspected
                                      if item['Config']['Hostname'] == fixture.proof['hostname']), None)
                    if container is None or container['HostConfig']['NetworkMode'] != 'none':
                        raise SmokeError('tool proof did not originate in isolated Keeper Docker container')
                    guest_path = PurePosixPath(fixture.proof['cwd']) / fixture.filename
                    host_file = None
                    for mount in container['Mounts']:
                        try:
                            suffix = guest_path.relative_to(mount['Destination'])
                        except ValueError:
                            continue
                        candidate = (Path(mount['Source']) / str(suffix)).resolve()
                        if candidate.is_relative_to(base) and candidate.is_file():
                            host_file = candidate
                            break
                    if host_file is None or json.loads(host_file.read_text()) != fixture.proof:
                        raise SmokeError('host-mounted file does not match actual ToolResult')
                    (output / 'tool-proof.json').write_text(host_file.read_text())
                    checkpoint, data = wait_until('durable final checkpoint',
                        lambda: checkpoint_proof(base, fixture), server)
                    (output / 'checkpoint.json').write_text(json.dumps(data, indent=2))
                    receipt = {'schema': 'masc.first_keeper_turn.v1', 'result': 'PASS',
                        'binary_sha256': hashlib.sha256(Path(binary).read_bytes()).hexdigest(),
                        'binary_commit': command([binary, 'build-commit'], env).strip(),
                        'keeper': keeper, 'model': 'scripted loopback fixture', 'model_requests': len(fixture.requests),
                        'image': args.image, 'container_id': container['Id'],
                        'checkpoint_relative_path': str(checkpoint.relative_to(base)),
                        'claims': ['actual Docker Execute', 'ToolResult returned to model',
                                   'host file matched', 'canonical checkpoint contains final answer'],
                        'not_measured': ['model quality', 'long-running Keeper continuity']}
                    (output / 'receipt.json').write_text(json.dumps(receipt, indent=2) + '\n')
                    print(json.dumps(receipt))
                finally:
                    if server.poll() is None:
                        server.terminate()
                        try:
                            server.wait(timeout=15)
                        except subprocess.TimeoutExpired:
                            server.kill()
                            server.wait()
                    # Only this randomly named Keeper's containers are ours.
                    ids = command(['docker', 'ps', '-aq', '--filter', 'label=masc.mcp.keeper=' + keeper], docker_env).split()
                    owned = list(set(owned + ids))
                    if owned:
                        command(['docker', 'rm', '-fv', *owned], docker_env)
    finally:
        model_server.shutdown()
        model_server.server_close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary', required=True)
    parser.add_argument('--image', required=True)
    parser.add_argument('--output-dir', required=True)
    args = parser.parse_args()
    try:
        run(args)
    except (SmokeError, OSError, ValueError, subprocess.SubprocessError) as error:
        Path(args.output_dir).mkdir(parents=True, exist_ok=True)
        (Path(args.output_dir) / 'failure.txt').write_text(str(error) + '\n')
        raise SystemExit('first Keeper turn: FAIL: ' + str(error))


if __name__ == '__main__':
    main()
