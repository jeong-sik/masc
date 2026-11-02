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
import tomllib
import urllib.error
import urllib.request
import uuid
from typing import NamedTuple


class SmokeError(RuntimeError):
    pass


def ledger_execution_evidence(base, keeper, tool_use_id):
    """One Execute call's audit fields from the tool-call ledger.

    Shell receipts are recorded there for every call; the ToolResult the model
    reads carries them only when they are unusual (masc#39035). The row is
    committed before the result reaches the model.
    """
    found = []
    for path in sorted((base / '.masc/tool_calls').rglob('*.jsonl')):
        for line in path.read_text().splitlines():
            if not line.strip():
                continue
            row = json.loads(line)
            if (row.get('keeper') == keeper and row.get('tool_use_id') == tool_use_id
                    and isinstance(row.get('execution_evidence'), dict)):
                found.append(row['execution_evidence'])
    if len(found) != 1:
        raise SmokeError(f'expected one ledger execution_evidence for {tool_use_id}, found {len(found)}')
    return found[0]


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
            if request.get('model') != 'deepseek-v4.1-flash':
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
                            'model': 'deepseek-v4.1-flash', 'choices': [{'index': 0,
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
                    'model': 'deepseek-v4.1-flash', 'choices': [{'index': 0, 'message': message,
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


def require_chat_completion(output, expected_reply, keeper, request_id):
    """A closed HTTP stream can still carry an unsuccessful Keeper run."""
    state = 0
    thread_id = 'keeper:' + keeper
    run_id = 'keeper-operation-run-' + request_id
    for line in output.read_text(encoding='utf-8').splitlines():
        if not line.startswith('data:'):
            continue
        try:
            event = json.loads(line[5:])
        except ValueError as error:
            raise SmokeError('chat stream contains invalid event JSON') from error
        if not isinstance(event, dict):
            raise SmokeError('chat stream contains a non-object event')
        kind = event.get('type')
        if kind == 'RUN_ERROR':
            raise SmokeError('Keeper chat stream reported a failed run')
        if (state == 0 and kind == 'CUSTOM' and event.get('name') == 'KEEPER_CHAT_OPERATION_ACCEPTED'
                and isinstance(event.get('value'), dict)
                and event['value'].get('operation_id') == request_id):
            state = 1
        elif (state == 1 and kind == 'RUN_STARTED' and event.get('threadId') == thread_id
              and event.get('runId') == run_id):
            state = 2
        elif (state == 2 and kind == 'CUSTOM' and event.get('name') == 'KEEPER_REPLY_DETAILS'
              and event.get('threadId') == thread_id and event.get('runId') == run_id
              and isinstance(event.get('value'), dict)
              and event['value'].get('reply') == expected_reply
              and event['value'].get('turn_outcome') == 'visible_reply'):
            state = 3
        elif (state == 3 and kind == 'RUN_FINISHED' and event.get('threadId') == thread_id
              and event.get('runId') == run_id):
            state = 4
    if state != 4:
        raise SmokeError('Keeper chat stream has no completed run with the expected reply')


def chat_request(url, token, body, output, *, expected_reply):
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
    require_chat_completion(output, expected_reply, body['name'], body['request_id'])


def wait_until(description, action, server, timeout=60):
    deadline = time.monotonic() + timeout
    while (remaining := deadline - time.monotonic()) > 0:
        if server.poll() is not None:
            raise SmokeError('MASC exited while waiting for ' + description)
        value = action(remaining)
        if value and time.monotonic() < deadline:
            return value
        time.sleep(min(0.2, max(0, deadline - time.monotonic())))
    raise SmokeError('timed out waiting for ' + description)


def file_sha256(path):
    with Path(path).open('rb') as source:
        return hashlib.file_digest(source, 'sha256').hexdigest()


def require_checkpoint_inspector(fixture):
    """Refuse an incompatible pinned binary before running the Keeper workflow."""
    if file_sha256(fixture.checkpoint_binary) != fixture.checkpoint_binary_sha256:
        raise SmokeError('checkpoint inspector binary changed before capability check')
    command([fixture.checkpoint_binary, 'inspect-checkpoint', '--help'], fixture.checkpoint_env)
    if file_sha256(fixture.checkpoint_binary) != fixture.checkpoint_binary_sha256:
        raise SmokeError('checkpoint inspector binary changed during capability check')


def pinned_binary_commit(fixture):
    if file_sha256(fixture.checkpoint_binary) != fixture.checkpoint_binary_sha256:
        raise SmokeError('checkpoint inspector binary changed before commit lookup')
    commit = command([fixture.checkpoint_binary, 'build-commit'], fixture.checkpoint_env).strip()
    if file_sha256(fixture.checkpoint_binary) != fixture.checkpoint_binary_sha256:
        raise SmokeError('checkpoint inspector binary changed during commit lookup')
    return commit


def checkpoint_evidence_span(messages, fixture):
    """Return the ordered call-to-final span in one decoded checkpoint."""
    if not isinstance(messages, list):
        raise SmokeError('checkpoint inspection has no message list')
    stage, start = 0, None
    for index, message in enumerate(messages):
        if not isinstance(message, dict) or not isinstance(message.get('content'), list):
            raise SmokeError('checkpoint inspection has an invalid message')
        blocks = [block for block in message['content'] if isinstance(block, dict)]
        if stage == 0 and message.get('role') == 'assistant' and any(
                block.get('type') == 'tool_use' and block.get('id') == fixture.call_id
                and block.get('name') == fixture.tool_name for block in blocks):
            stage, start = 1, index
        elif stage == 1 and message.get('role') == 'tool' and any(
                block.get('type') == 'tool_result' and block.get('tool_use_id') == fixture.call_id
                and block.get('is_error') is False
                and proof_from(block.get('text_content', block.get('content')), fixture.marker) == fixture.proof
                for block in blocks):
            stage = 2
        elif stage == 2 and message.get('role') == 'assistant' and any(
                block.get('type') == 'text' and block.get('text') == fixture.final for block in blocks):
            return start, index
    return None


def require_checkpoint_resume(data, initial_trace, initial_evidence, resumed_evidence):
    messages = data['checkpoint']['messages']
    initial = checkpoint_evidence_span(messages, initial_evidence)
    resumed = checkpoint_evidence_span(messages, resumed_evidence)
    if (data['trace_id'] != initial_trace or initial is None or resumed is None
            or initial[1] >= resumed[0]):
        raise SmokeError('resumed checkpoint did not preserve the original turn on the same trace')


def checkpoint_proof(base, fixture, timeout):
    # The same pinned executable that ran the Keeper loads the canonical head
    # with the production checkpoint codec and session lock. Its JSON is a
    # decoded projection; the content digest is not a hash of the head file.
    if fixture.proof is None or not fixture.call_id or not fixture.tool_name:
        raise SmokeError('checkpoint inspection has no original tool proof')
    deadline = time.monotonic() + timeout
    if file_sha256(fixture.checkpoint_binary) != fixture.checkpoint_binary_sha256:
        raise SmokeError('checkpoint inspector binary changed before inspection')
    remaining = deadline - time.monotonic()
    if remaining <= 0:
        raise SmokeError('checkpoint inspection exceeded the remaining wait')
    try:
        result = subprocess.run(
            [fixture.checkpoint_binary, 'inspect-checkpoint', '--base-path', str(base),
             '--keeper', fixture.checkpoint_keeper],
            capture_output=True, text=True, timeout=remaining, cwd=base,
            env=fixture.checkpoint_env)
    except subprocess.TimeoutExpired as error:
        raise SmokeError('checkpoint inspection exceeded the remaining wait') from error
    if result.returncode:
        raise SmokeError('checkpoint inspection failed: ' + result.stderr.strip())
    if file_sha256(fixture.checkpoint_binary) != fixture.checkpoint_binary_sha256:
        raise SmokeError('checkpoint inspector binary changed during inspection')
    try:
        data = json.loads(result.stdout)
    except ValueError as error:
        raise SmokeError('checkpoint inspection did not return JSON') from error
    if (not isinstance(data, dict) or data.get('schema') != 'masc.checkpoint-inspection.v1'
            or data.get('keeper') != fixture.checkpoint_keeper):
        raise SmokeError('checkpoint inspection names another keeper or schema')
    if not isinstance(data.get('trace_id'), str) or not data['trace_id']:
        raise SmokeError('checkpoint inspection has no trace identity')
    if data.get('status') == 'not_found':
        return None
    checkpoint, reference, trace = data.get('checkpoint'), data.get('reference'), data.get('trace_id')
    if (data.get('status') != 'available' or not isinstance(checkpoint, dict)
            or not isinstance(reference, dict) or not isinstance(trace, str) or not trace
            or checkpoint.get('session_id') != trace or reference.get('trace_id') != trace
            or type(reference.get('turn_count')) is not int
            or checkpoint.get('turn_count') != reference['turn_count']
            or not isinstance(reference.get('content_sha256'), str)
            or len(reference['content_sha256']) != 64
            or any(c not in '0123456789abcdef' for c in reference['content_sha256'])):
        raise SmokeError('checkpoint inspection has an invalid reference')
    raw_path = data.get('canonical_path')
    if not isinstance(raw_path, str):
        raise SmokeError('checkpoint inspection has no canonical path')
    path = Path(raw_path)
    if (not path.is_absolute() or path.name != trace + '.json'
            or path.parent.name != trace or not path.resolve().is_relative_to(base.resolve())):
        raise SmokeError('checkpoint inspection has an invalid canonical path')
    messages, boundary = checkpoint.get('messages'), data.get('history_boundary')
    if (not isinstance(messages, list) or not isinstance(boundary, dict)
            or type(boundary.get('closed_messages')) is not int
            or type(boundary.get('open_messages')) is not int
            or boundary['closed_messages'] < 0 or boundary['open_messages'] < 0
            or boundary['closed_messages'] + boundary['open_messages'] != len(messages)):
        raise SmokeError('checkpoint inspection has an invalid history boundary')
    span = checkpoint_evidence_span(messages, fixture)
    if span is not None and span[1] < boundary['closed_messages']:
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


def strict_proof_path(value: str) -> PurePosixPath:
    if not isinstance(value, str) or not value or "\x00" in value:
        raise SmokeError('proof path must be a nonempty path string')
    path = PurePosixPath(value)
    if not path.is_absolute() or any(part in ('.', '..') for part in value.split('/')):
        raise SmokeError('proof path must be absolute without traversal segments')
    return path


class KataPathProjection(NamedTuple):
    host_root: PurePosixPath
    guest_root: PurePosixPath

    def guest_cwd(self, model_cwd: str) -> PurePosixPath:
        try:
            relative = strict_proof_path(model_cwd).relative_to(self.host_root)
        except ValueError as error:
            raise SmokeError('model proof cwd is outside this Keeper playground') from error
        return self.guest_root / relative

    def match_proof(self, raw: dict, model: dict) -> dict:
        if not isinstance(raw, dict) or not isinstance(model, dict):
            raise SmokeError('Kata proofs must be JSON objects')
        cwd = strict_proof_path(raw.get('cwd'))
        if cwd != self.guest_cwd(model.get('cwd')):
            raise SmokeError('guest proof cwd differs from the projected model cwd')
        projected = dict(raw, cwd=str(self.host_root / cwd.relative_to(self.guest_root)))
        if projected != model:
            raise SmokeError('guest volume file differs from actual ToolResult')
        return projected


def kata_path_projection(base: Path, keeper: str, mount_destination: str) -> KataPathProjection:
    # Keeper_remote_path.host_root / keeper_remote_root map only this Keeper's
    # playground namespace. Do not resolve guest paths through the host FS.
    if not keeper or '/' in keeper or keeper in ('.', '..'):
        raise SmokeError('invalid proof Keeper name')
    return KataPathProjection(
        strict_proof_path(str(base)) / '.masc' / 'playground' / keeper,
        strict_proof_path(mount_destination) / keeper)


def kata_proof(args, fixture, base, output, runtime_env, server):
    ids = command(['nerdctl', 'ps', '-aq', '--no-trunc', '--filter',
                   'label=masc.mcp.keeper=' + args.keeper], runtime_env).split()
    if len(ids) != 1:
        raise SmokeError('expected one actual Kata Keeper container')
    rows = json.loads(command(['nerdctl', 'inspect', '--mode', 'native', *ids], runtime_env))
    (output / 'kata-native-inspect.json').write_text(json.dumps(rows, indent=2))
    container = rows[0]
    spec = container['Spec']
# Canonical home of this runtime id: lib/keeper/keeper_microvm_kata_vmm.ml (Keeper_microvm_kata_vmm.default_shim_runtime_id). Keep literals in sync with it.
    if container['Runtime']['Name'] != 'io.containerd.kata.v2':
        raise SmokeError('Keeper container did not use the Kata runtime')
    # nerdctl v2.3.5 labels.Networks is JSON-encoded []string.
    if json.loads(container.get('Labels', {}).get('nerdctl/networks', 'null')) != ['none']:
        raise SmokeError('original Kata guest network is not none')
    if spec.get('hostname') != fixture.proof['hostname']:
        raise SmokeError('ToolResult hostname differs from the actual Kata guest')
    if spec.get('root', {}).get('readonly') is not True:
        raise SmokeError('Kata guest rootfs is not read-only')
    user = spec['process']['user']
    if user['uid'] != os.getuid() or user['uid'] != fixture.proof['uid'] or spec['process'].get('capabilities', {}).get('effective'):
        raise SmokeError('guest UID or capability boundary differs from the actual tool')
    mounts = spec['mounts']
    work_mount = next((mount for mount in mounts if mount['destination'] == '/masc-work'), None)
    shim_mount = next((mount for mount in mounts if mount['destination'] == '/opt/masc-exec-shim'), None)
    if not work_mount or not shim_mount:
        raise SmokeError('Kata work volume or release shim mount is absent')
    if 'ro' not in shim_mount.get('options', []) or 'rw' in shim_mount.get('options', []):
        raise SmokeError('guest release shim mount is not read-only')
    if Path(shim_mount['source']).resolve() != base / '.masc/microvm/shim':
        raise SmokeError('guest did not mount this workspace release shim')
    shim = ledger_execution_evidence(base, args.keeper, fixture.call_id).get(
        'shim_execution_evidence') or {}
    receipts = shim.get('receipts', []) if shim.get('status') == 'recorded' else []
    if not any(entry.get('status') == 'observed'
               and entry.get('receipt', {}).get('boundary') == 'sandbox_applied'
               and entry.get('outcome') == {'exit': 0, 'signal': None, 'timed_out': False, 'shim_error': False}
               for entry in receipts):
        raise SmokeError('actual Execute call has no successful shim execution receipt in the ledger')
    (output / 'shim-execution-receipts.json').write_text(json.dumps(receipts, indent=2))
    projection = kata_path_projection(base, args.keeper, work_mount['destination'])
    proof_path = str(projection.guest_cwd(fixture.proof['cwd']) / fixture.filename)
    identity = f"{user['uid']}:{user['gid']}"
    raw_proof = command(['nerdctl', 'exec', '--user', identity, ids[0],
                         'cat', proof_path], runtime_env)
    (output / 'tool-proof.json').write_text(raw_proof)
    (output / 'tool-proof-model-projected.json').write_text(json.dumps(fixture.proof) + '\n')
    proof = json.loads(raw_proof)
    projection.match_proof(proof, fixture.proof)
    expected_volume = 'masc-keeper-work-' + args.keeper
    volumes = json.loads(command(['nerdctl', 'volume', 'inspect', expected_volume], runtime_env))
    matching = [volume for volume in volumes
                if volume.get('Name') == expected_volume
                and Path(volume['Mountpoint']).resolve() == Path(work_mount['source']).resolve()]
    if len(matching) != 1:
        raise SmokeError('Kata work mount is not an identified managed named volume')
    volume = matching[0]['Name']
    (output / 'work-volume.json').write_text(json.dumps(matching[0], indent=2))
    checkpoint, data = wait_until('canonical final Kata checkpoint',
                                 lambda remaining: checkpoint_proof(base, fixture, remaining), server)
    # Stop the MASC owner before independently recreating a guest over its
    # persisted volume. This is a persistence probe, not a second model turn.
    stop_server(server)
    remaining = command(['nerdctl', 'ps', '-aq', '--no-trunc', '--filter',
                         'label=masc.mcp.keeper=' + args.keeper], runtime_env).split()
    if remaining:
        command(['nerdctl', 'rm', '-f', *remaining], runtime_env)
    reread = command(['nerdctl', 'run', '--rm', '--name', args.keeper + '-persistence',
        '--label', 'masc.mcp.keeper=' + args.keeper, '--runtime', 'io.containerd.kata.v2',
        '--pull', 'never', '--network', 'none', '--read-only', '--cap-drop', 'ALL', '--tmpfs', '/tmp',
        '--user', identity, '-v', volume + ':/masc-work', args.image, 'cat', proof_path], runtime_env)
    if reread != raw_proof:
        raise SmokeError('proof bytes did not survive Kata guest recreation')
    (output / 'volume-recreated-proof.json').write_text(reread)
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
    fixture.checkpoint_binary = binary
    fixture.checkpoint_binary_sha256 = file_sha256(binary)
    fixture.checkpoint_keeper = keeper
    model_server = fixture.serve()
    server = None
    docker_env = os.environ.copy()
    owned = []
    owned_volumes = ['masc-keeper-work-' + keeper] if args.backend == 'nerdctl_kata' else []
    try:
        docker_host = None
        if args.backend == 'docker':
            # Exits nonzero, and so raises, when Docker's store lacks the image.
            command(['docker', 'image', 'inspect', args.image], docker_env)
            docker_host = docker_env.get('DOCKER_HOST')
            if not docker_host:
                contexts = json.loads(command(['docker', 'context', 'inspect'], docker_env))
                docker_host = contexts[0]['Endpoints']['docker']['Host']
        else:
            if os.getuid() <= 0:
                raise SmokeError('installed Kata acceptance must run as a nonroot host user')
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
            env.update(HOME=str(home), MASC_BASE_PATH=str(base), MASC_KEEPER_AUTONOMOUS_ENABLED='true')
            fixture.checkpoint_env = env
            require_checkpoint_inspector(fixture)
            command([binary, 'init', '--base-path', str(base)], env)
            # A Keeper names a catalog image; this host's catalog makes the
            # image under test the build `base` starts from.
            store = 'docker' if args.backend == 'docker' else 'nerdctl_kata'
            (base / '.masc' / 'config' / 'sandbox-image-builds.toml').write_text(
                f'[images.base.{store}]\nreference = "{args.image}"\n')
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
            content = (fixtures / 'runtime.toml').read_text()
            if 'http://127.0.0.1:9/v1' not in content:
                raise SmokeError('release runtime fixture endpoint contract changed')
            content = content.replace('http://127.0.0.1:9/v1', endpoint)
            content = content.replace('streaming = true', 'streaming = false')
            (config / 'runtime.toml').write_text(content)
            keepers = config / 'keepers'
            keepers.mkdir(exist_ok=True)
            if sorted(path.name for path in keepers.iterdir()) != ['imp.toml']:
                raise SmokeError('fresh init must seed exactly the first Keeper manifest imp.toml')
            with (keepers / 'imp.toml').open('rb') as source:
                manifest = tomllib.load(source)
            if manifest.get('keeper', {}).get('activation_mode') != 'manual':
                raise SmokeError('first Keeper must wait for manual start (activation_mode = "manual")')
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
                    def health(remaining):
                        try:
                            snapshot = json.loads(request(url + '/health?full=1', timeout=min(2, remaining)))
                            return snapshot if snapshot.get('startup', {}).get('state_ready') is True else None
                        except (urllib.error.URLError, TimeoutError):
                            return None
                    healthy = wait_until('isolated server health', health, server)
                    actual_base = healthy.get('paths', {}).get('effective_base_path')
                    if actual_base != str(base):
                        raise SmokeError(f'health base path mismatch: {actual_base!r}')
                    if healthy.get('build', {}).get('executable_sha256') != fixture.checkpoint_binary_sha256:
                        raise SmokeError('server health names another executable')
                    (output / 'health.json').write_text(json.dumps(healthy, indent=2))
                    try:
                        creation = command([binary, 'keeper-create', '--base-path', str(base),
                            '--host', '127.0.0.1', '--port', str(port), '--agent', 'first-turn-admin',
                            '--name', keeper, '--sandbox-profile', profile, '--sandbox-image', 'base',
                            '--network-mode', 'none',
                            *(['--microvm-backend', 'nerdctl_kata'] if args.backend == 'nerdctl_kata' else []),
                            '--no-skills', '--activation-mode', 'manual', '--instructions',
                            'Execute the isolated first-turn proof and report its actual result.'], env)
                    except SmokeError as error:
                        # Diagnostic only: do not turn a broken installed CLI
                        # into a passing acceptance by silently bypassing it.
                        try:
                            direct = request(url + '/api/v1/keepers/' + keeper + '/up', token,
                                {'name': keeper, 'sandbox_profile': profile, 'sandbox_image': 'base',
                                 'network_mode': 'none',
                                 **({'microvm_backend': 'nerdctl_kata'} if args.backend == 'nerdctl_kata' else {}),
                                 'skills': {'names': []}, 'activation_mode': 'manual', 'instructions': 'Isolated first-turn proof.'}, timeout=15)
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
                         'request_id': 'kmsg-' + marker}, output / 'chat-stream.txt',
                        expected_reply=fixture.final)
                    if fixture.error:
                        raise SmokeError(fixture.error)
                    if fixture.proof is None or len(fixture.requests) != (3 if fixture.search_requested else 2):
                        raise SmokeError('expected exactly tool-request then actual ToolResult/final response')
                    if args.backend == 'nerdctl_kata':
                        container_id, checkpoint, data = kata_proof(
                            args, fixture, base, output, docker_env, server)
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
                            lambda remaining: checkpoint_proof(base, fixture, remaining), server)
                        container_id = container['Id']
                    (output / 'checkpoint.json').write_text(json.dumps(data['checkpoint'], indent=2))
                    (output / 'checkpoint-inspection.json').write_text(json.dumps(data, indent=2))
                    receipt = {'schema': 'masc.first_keeper_turn.v1', 'result': 'PASS',
                        'binary_sha256': fixture.checkpoint_binary_sha256,
                        'binary_commit': pinned_binary_commit(fixture),
                        'keeper': keeper, 'model': 'scripted loopback fixture', 'model_requests': len(fixture.requests),
                        'image': args.image, 'container_id': container_id, 'backend': args.backend,
                        'checkpoint_relative_path': str(checkpoint.relative_to(base)),
                        'checkpoint_reference': data['reference'],
                        'claims': ['actual ' + args.backend + ' Execute', 'ToolResult returned to model',
                                   ('host file matched' if args.backend == 'docker' else
                                    'shim receipt and volume bytes survive guest recreation'),
                                   'canonical checkpoint contains final answer'],
                        'not_measured': ['model quality', 'long-running Keeper continuity']}
                    if args.backend == 'nerdctl_kata':
                        receipt['proof_artifacts'] = {
                            'raw_guest': 'tool-proof.json',
                            'model_projected': 'tool-proof-model-projected.json',
                            'raw_guest_after_recreation': 'volume-recreated-proof.json'}
                    (output / 'receipt.json').write_text(json.dumps(receipt, indent=2) + '\n')
                    print(json.dumps(receipt))
                finally:
                    stop_server(server)
                    ids = command([runtime, 'ps', '-aq', '--filter', 'label=masc.mcp.keeper=' + keeper], docker_env).split()
                    owned = list(set(owned + ids))
                    if owned:
                        command([runtime, 'rm', '-fv' if runtime == 'docker' else '-f', *owned], docker_env)
                    if owned_volumes:
                        existing_volumes = command([runtime, 'volume', 'ls', '--format', '{{.Name}}'], docker_env).splitlines()
                        for volume in owned_volumes:
                            if volume in existing_volumes:
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
