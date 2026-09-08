#!/usr/bin/env python3
"""Installed MASC -> fixture model -> actual Docker/Kata tool -> canonical checkpoint.

Requires an already-built image in the selected runtime store. Never builds code or
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
import shutil
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
                content_type = 'application/json'
                if status == 200 and request.get('stream'):
                    choice = response['choices'][0]
                    delta = choice['message'].copy()
                    if 'tool_calls' in delta:
                        delta['tool_calls'] = [dict(call, index=index)
                                               for index, call in enumerate(delta['tool_calls'])]
                    chunks = [dict(id=response['id'], object='chat.completion.chunk',
                                   model=response['model'], choices=[dict(index=0, delta=delta,
                                                                         finish_reason=None)]),
                              dict(id=response['id'], object='chat.completion.chunk',
                                   model=response['model'], choices=[dict(index=0, delta={},
                                       finish_reason=choice['finish_reason'])], usage=response['usage'])]
                    data = (''.join('data: ' + json.dumps(chunk) + '\n\n' for chunk in chunks)
                            + 'data: [DONE]\n\n').encode()
                    content_type = 'text/event-stream'
                else:
                    data = json.dumps(response).encode()
                self.send_response(status)
                self.send_header('Content-Type', content_type)
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


def chat_request(url, token, body, output):
    # SSE heartbeats reset a socket read timeout indefinitely. Bound the
    # acceptance process itself and preserve partial events on failure.
    with output.open('wb') as stream:
        try:
            result = subprocess.run(
                ['curl', '--silent', '--show-error', '--fail-with-body', '--no-buffer',
                 '--config', '-', '--data-binary', json.dumps(body), url],
                input=('header = "Content-Type: application/json"\n'
                       'header = "Authorization: Bearer ' + token + '"\n').encode(),
                stdout=stream, stderr=subprocess.PIPE, timeout=180)
        except subprocess.TimeoutExpired as error:
            raise SmokeError('first-turn stream exceeded 180s; partial events saved') from error
    if result.returncode:
        raise SmokeError('first-turn stream failed: ' + result.stderr.decode())


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
        if not isinstance(data, dict) or not isinstance(data.get('session_id'), str) or not data['session_id']:
            continue
        if path.name != data['session_id'] + '.json':
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


def stop_server(server):
    if server.poll() is None:
        server.terminate()
        try:
            server.wait(timeout=15)
        except subprocess.TimeoutExpired:
            server.kill()
            server.wait()


def kata_proof(args, fixture, base, output, runtime_env, server, owned_volumes):
    ids = command(['nerdctl', 'ps', '-aq', '--no-trunc', '--filter',
                   'label=masc.mcp.keeper=' + args.keeper], runtime_env).split()
    if len(ids) != 1:
        raise SmokeError('expected one actual Kata Keeper container')
    rows = json.loads(command(['nerdctl', 'inspect', '--mode', 'native', *ids], runtime_env))
    (output / 'kata-native-inspect.json').write_text(json.dumps(rows, indent=2))
    container = rows[0]
    spec = container['Spec']
    if container['Runtime']['Name'] != 'io.containerd.kata.v2':
        raise SmokeError('Keeper container did not use the Kata runtime')
    if spec.get('hostname') != fixture.proof['hostname']:
        raise SmokeError('ToolResult hostname differs from the actual Kata guest')
    if spec.get('root', {}).get('readonly') is not True:
        raise SmokeError('Kata guest rootfs is not read-only')
    user = spec['process']['user']
    if user['uid'] != fixture.proof['uid'] or spec['process'].get('capabilities', {}).get('effective'):
        raise SmokeError('guest UID or capability boundary differs from the actual tool')
    mounts = spec['mounts']
    work_mount = next((mount for mount in mounts if mount['destination'] == '/masc-work'), None)
    shim_mount = next((mount for mount in mounts if mount['destination'] == '/opt/masc-exec-shim'), None)
    if not work_mount or not shim_mount:
        raise SmokeError('Kata work volume or release shim mount is absent')
    if Path(shim_mount['source']).resolve() != base / '.masc/microvm/shim':
        raise SmokeError('guest did not mount this workspace release shim')
    tool_results = [m for req in fixture.requests for m in req.get('messages', [])
                    if m.get('role') == 'tool' and m.get('tool_call_id') == fixture.call_id]
    evidence = [obj['shim_execution_evidence'] for obj in objects(tool_results)
                if isinstance(obj.get('shim_execution_evidence'), dict)]
    receipts = [entry for group in evidence if group.get('status') == 'recorded'
                for entry in group.get('receipts', [])]
    if not any(entry.get('status') == 'observed'
               and entry.get('receipt', {}).get('boundary') == 'sandbox_applied'
               and entry.get('outcome') == {'exit': 0, 'signal': None, 'timed_out': False, 'shim_error': False}
               for entry in receipts):
        raise SmokeError('actual Execute ToolResult has no successful shim execution receipt')
    (output / 'shim-execution-receipts.json').write_text(json.dumps(receipts, indent=2))
    proof_path = str(PurePosixPath(fixture.proof['cwd']) / fixture.filename)
    if not PurePosixPath(proof_path).is_relative_to('/masc-work'):
        raise SmokeError('Kata Execute wrote outside the managed work volume')
    identity = f"{user['uid']}:{user['gid']}"
    proof = json.loads(command(['nerdctl', 'exec', '--user', identity, ids[0],
                               'cat', proof_path], runtime_env))
    if proof != fixture.proof:
        raise SmokeError('guest volume file differs from actual ToolResult')
    (output / 'tool-proof.json').write_text(json.dumps(proof) + '\n')
    expected_volume = 'masc-keeper-work-' + args.keeper
    volumes = json.loads(command(['nerdctl', 'volume', 'inspect', expected_volume], runtime_env))
    matching = [volume for volume in volumes
                if volume.get('Name') == expected_volume
                and Path(volume['Mountpoint']).resolve() == Path(work_mount['source']).resolve()]
    if len(matching) != 1:
        raise SmokeError('Kata work mount is not an identified managed named volume')
    volume = matching[0]['Name']
    owned_volumes.append(volume)
    (output / 'work-volume.json').write_text(json.dumps(matching[0], indent=2))
    checkpoint, data = wait_until('canonical final Kata checkpoint',
                                 lambda: checkpoint_proof(base, fixture), server)
    # Stop the MASC owner before independently recreating a guest over its
    # persisted volume. This is a persistence probe, not a second model turn.
    stop_server(server)
    remaining = command(['nerdctl', 'ps', '-aq', '--no-trunc', '--filter',
                         'label=masc.mcp.keeper=' + args.keeper], runtime_env).split()
    if remaining:
        command(['nerdctl', 'rm', '-f', *remaining], runtime_env)
    reread = json.loads(command(['nerdctl', 'run', '--rm', '--runtime', 'io.containerd.kata.v2',
        '--pull', 'never', '--network', 'none', '--read-only', '--cap-drop', 'ALL', '--tmpfs', '/tmp',
        '--user', identity, '-v', volume + ':/masc-work', args.image, 'cat', proof_path], runtime_env))
    if reread != fixture.proof:
        raise SmokeError('proof bytes did not survive Kata guest recreation')
    (output / 'volume-recreated-proof.json').write_text(json.dumps(reread) + '\n')
    return ids[0], checkpoint, data


def run(args):
    binary = str(Path(args.binary).resolve(strict=True))
    output = Path(args.output_dir).resolve()
    output.mkdir(parents=True, exist_ok=True)
    marker = uuid.uuid4().hex
    keeper = 'first-turn-' + marker[:12]
    args.keeper = keeper
    runtime = 'docker' if args.backend == 'docker' else 'nerdctl'
    profile = 'docker' if args.backend == 'docker' else 'microvm'
    fixture = ModelFixture(marker, output)
    model_server = fixture.serve()
    server = None
    docker_env = os.environ.copy()
    owned = []
    owned_volumes = []
    try:
        docker_host = None
        if args.backend == 'docker':
            command(['docker', 'image', 'inspect', args.image], docker_env)
            docker_host = docker_env.get('DOCKER_HOST')
            if not docker_host:
                contexts = json.loads(command(['docker', 'context', 'inspect'], docker_env))
                docker_host = contexts[0]['Endpoints']['docker']['Host']
        else:
            if not args.guest_shim:
                raise SmokeError('--backend nerdctl_kata requires --guest-shim from the installed release')
            images = json.loads(command(['nerdctl', 'image', 'inspect', '--mode', 'native', args.image], docker_env))
            if not images:
                raise SmokeError('general image was not loaded into the configured nerdctl store')
            (output / 'kata-image-native.json').write_text(json.dumps(images, indent=2))
        # Desktop/Colima share the user's home by default, while macOS's
        # /private/var temporary tree need not be visible to the Docker VM.
        with tempfile.TemporaryDirectory(prefix='masc-first-turn-', dir=Path.home()) as directory:
            base = Path(directory).resolve()
            home = base / 'home'
            home.mkdir()
            env = {k: v for k, v in os.environ.items()
                   if k in ('PATH', 'LANG', 'LC_ALL', 'TMPDIR', 'DOCKER_HOST', 'DOCKER_CONTEXT', 'DOCKER_CONFIG')}
            env.pop('DOCKER_CONTEXT', None)
            env.pop('DOCKER_CONFIG', None)
            if docker_host:
                env['DOCKER_HOST'] = docker_host
            env.update(HOME=str(home), MASC_BASE_PATH=str(base), MASC_KEEPER_BOOTSTRAP_ENABLED='true',
                       MASC_KEEPER_SANDBOX_DOCKER_IMAGE=args.image)
            command([binary, 'init', '--base-path', str(base)], env)
            if args.backend == 'nerdctl_kata':
                source = Path(args.guest_shim).resolve(strict=True)
                actual = hashlib.sha256(source.read_bytes()).hexdigest()
                sidecar = source.with_name(source.name + '.sha256')
                expected = sidecar.read_text().split() if sidecar.is_file() else []
                if not expected or expected[0] != actual:
                    raise SmokeError('installed release shim checksum sidecar missing or mismatched')
                target = base / '.masc/microvm/shim'
                target.mkdir(parents=True)
                shutil.copy2(source, target / 'masc-exec-shim')
                (target / 'masc-exec-shim').chmod(0o755)
                (target / 'masc-exec-shim.sha256').write_text(actual + '  masc-exec-shim\n')
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
                if name == 'agent-core-models-overlay.toml':
                    # The boot-only fixture supplies exact-output lanes but
                    # leaves the fleet provider's embedded credentials intact.
                    # Bind that provider to this fixture too before any turn.
                    content += ('\n[[providers]]\nid = "ollama_cloud"\n'
                                'kind = "openai_compat"\nbase_url = ' + json.dumps(endpoint)
                                + '\nrequest_path = "/chat/completions"\napi_key_env = ""\n'
                                'capabilities_base = "openai_chat"\n')
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
                            snapshot = json.loads(request(url + '/health?full=1', timeout=2))
                            return snapshot if snapshot.get('startup', {}).get('state_ready') is True else None
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
                            '--name', keeper, '--sandbox-profile', profile, '--network-mode', 'none',
                            *(['--microvm-backend', 'nerdctl_kata'] if args.backend == 'nerdctl_kata' else []),
                            '--no-skills', '--no-autoboot', '--no-proactive', '--instructions',
                            'Execute the isolated first-turn proof and report its actual result.'], env)
                    except SmokeError as error:
                        # Diagnostic only: do not turn a broken installed CLI
                        # into a passing acceptance by silently bypassing it.
                        try:
                            direct = request(url + '/api/v1/keepers/' + keeper + '/up', token,
                                {'name': keeper, 'sandbox_profile': profile, 'network_mode': 'none',
                                 **({'microvm_backend': 'nerdctl_kata'} if args.backend == 'nerdctl_kata' else {}),
                                 'skills': {'names': []}, 'autoboot_enabled': False,
                                 'proactive_enabled': False, 'instructions': 'Isolated first-turn proof.'}, timeout=15)
                            (output / 'direct-up-diagnostic.json').write_bytes(direct)
                        except (urllib.error.URLError, TimeoutError) as diagnostic_error:
                            detail = (diagnostic_error.read().decode() if isinstance(diagnostic_error, urllib.error.HTTPError)
                                      else str(diagnostic_error))
                            (output / 'direct-up-diagnostic.txt').write_text(detail)
                        raise error
                    (output / 'keeper-create.txt').write_text(creation)
                    # Only this disposable workspace is affected. The proof
                    # tests execution wiring, not the approval judge model.
                    mode = json.loads(request(url + '/api/v1/dashboard/gate/mode', token,
                                              {'mode': 'always_allow'}))
                    (output / 'approval-mode.json').write_text(json.dumps(mode, indent=2))
                    if mode.get('ok') is not True or mode.get('mode') != 'always_allow':
                        raise SmokeError('approval mode was not applied')
                    tool_mode = json.loads(request(url + '/api/v1/keepers/tool-approval-mode', token,
                                                   {'name': keeper, 'mode': 'yolo'}))
                    if tool_mode.get('keeper') != keeper or tool_mode.get('mode') != 'yolo':
                        raise SmokeError('tool approval mode was not applied')
                    chat_request(url + '/api/v1/keepers/chat/stream', token,
                        {'name': keeper, 'message': 'Run the isolated ' + args.backend + ' proof once, then report completion.',
                         'request_id': 'kmsg-' + marker}, output / 'chat-stream.txt')
                    if fixture.error:
                        raise SmokeError(fixture.error)
                    if fixture.proof is None or len(fixture.requests) != (3 if fixture.search_requested else 2):
                        raise SmokeError('expected exactly tool-request then actual ToolResult/final response')
                    if args.backend == 'nerdctl_kata':
                        container_id, checkpoint, data = kata_proof(
                            args, fixture, base, output, docker_env, server, owned_volumes)
                    else:
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
                        container_id = container['Id']
                    (output / 'checkpoint.json').write_text(json.dumps(data, indent=2))
                    receipt = {'schema': 'masc.first_keeper_turn.v1', 'result': 'PASS',
                        'binary_sha256': hashlib.sha256(Path(binary).read_bytes()).hexdigest(),
                        'binary_commit': command([binary, 'build-commit'], env).strip(),
                        'keeper': keeper, 'model': 'scripted loopback fixture', 'model_requests': len(fixture.requests),
                        'image': args.image, 'container_id': container_id, 'backend': args.backend,
                        'checkpoint_relative_path': str(checkpoint.relative_to(base)),
                        'claims': ['actual ' + args.backend + ' Execute', 'ToolResult returned to model',
                                   ('host file matched' if args.backend == 'docker' else
                                    'shim receipt and volume bytes survive guest recreation'),
                                   'canonical checkpoint contains final answer'],
                        'not_measured': ['model quality', 'long-running Keeper continuity']}
                    (output / 'receipt.json').write_text(json.dumps(receipt, indent=2) + '\n')
                    print(json.dumps(receipt))
                finally:
                    stop_server(server)
                    ids = command([runtime, 'ps', '-aq', '--filter', 'label=masc.mcp.keeper=' + keeper], docker_env).split()
                    owned = list(set(owned + ids))
                    if owned:
                        command([runtime, 'rm', '-fv' if runtime == 'docker' else '-f', *owned], docker_env)
                    for volume in owned_volumes:
                        command([runtime, 'volume', 'rm', volume], docker_env)
    finally:
        model_server.shutdown()
        model_server.server_close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--backend', choices=('docker', 'nerdctl_kata'), default='docker')
    parser.add_argument('--guest-shim', help='Installed release shim with adjacent .sha256 sidecar (Kata)')
    parser.add_argument('--binary', required=True)
    parser.add_argument('--image', required=True)
    parser.add_argument('--output-dir', required=True)
    args = parser.parse_args()
    try:
        run(args)
    except (SmokeError, OSError, ValueError, KeyError, TypeError, subprocess.SubprocessError) as error:
        Path(args.output_dir).mkdir(parents=True, exist_ok=True)
        (Path(args.output_dir) / 'failure.txt').write_text(str(error) + '\n')
        raise SystemExit('first Keeper turn: FAIL: ' + str(error))


if __name__ == '__main__':
    main()
