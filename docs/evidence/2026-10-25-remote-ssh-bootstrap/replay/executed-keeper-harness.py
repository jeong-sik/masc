#!/usr/bin/env python3
"""Installed Keeper -> scripted model -> real pinned SSH -> durable file evidence.

Requires a provisioned workspace, empty unless initial file hashes are declared.
Does not build, bootstrap,
log in to GitHub, delete endpoints, or modify production configuration.
Keep output private: .workspace contains the isolated server's admin token.
"""
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path, PurePosixPath
import shlex
import socket
import subprocess
import urllib.error
import uuid

HELPER = Path(__file__).with_name('keeper-first-turn-smoke.py')
SPEC = importlib.util.spec_from_file_location('keeper_first_turn', HELPER)
smoke = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(smoke)

SHELL_IO_FILES = {
    'redirect input.txt': 'alpha\n',
    'redirect output.txt': 'alpha\nbeta\n',
    'redirect stdout.txt': 'separate-out\n',
    'redirect stderr.txt': 'separate-err\n',
}


def transport_refusal(content):
    """Require one Execute payload's typed unavailable receipt, never error prose."""
    try:
        payload = json.loads(content) if isinstance(content, str) else content
    except ValueError as error:
        raise smoke.SmokeError('pin refusal is not a structured Execute payload') from error
    expected = {'status': 'recorded', 'receipts': [
        {'status': 'unavailable', 'reason': 'transport_unavailable'}]}
    if (type(payload) is not dict or payload.get('ok') is not False
            or payload.get('typed') is not True
            or payload.get('shim_execution_evidence') != expected):
        raise smoke.SmokeError('pin replacement lacks typed transport_unavailable Execute evidence')
    return payload


def preserved_file_manifest(pairs):
    manifest = {}
    for name, digest in pairs:
        if (not name or name in ('.', '..') or '\0' in name
                or PurePosixPath(name).name != name):
            raise smoke.SmokeError('preserved files must name workspace-root regular files')
        if (len(digest) != 64 or any(c not in '0123456789abcdef' for c in digest)
                or name in manifest):
            raise smoke.SmokeError('preserved files require unique names and lowercase SHA256 digests')
        manifest[name] = digest
    return manifest


def initial_workspace_inspection():
    return ('import hashlib,json,os,socket,sys; from pathlib import Path; '
            'p=Path(sys.argv[1]); names=json.loads(sys.argv[2]); '
            'print(json.dumps({"cwd":str(p),"hostname":socket.gethostname(),'
            '"uid":p.stat().st_uid,"files":sorted(os.listdir(p)),'
            '"preserved_files":{n:hashlib.sha256((p/n).read_bytes()).hexdigest() '
            'if (p/n).is_file() and not (p/n).is_symlink() else None for n in names}}))')


def validate_initial_workspace(snapshot, manifest):
    files = snapshot.get('files')
    if (type(snapshot.get('uid')) is not int or snapshot['uid'] <= 0
            or type(files) is not list or any(type(name) is not str for name in files)
            or len(files) != len(set(files)) or set(files) != set(manifest)
            or snapshot.get('preserved_files') != manifest):
        raise smoke.SmokeError('expected a nonroot-owned workspace with exactly the declared initial file hashes')


class FilesFixture(smoke.ModelFixture):
    def __init__(self, marker, output, *, exercise_shell_io=False):
        super().__init__(marker, output)
        self.final = 'REMOTE_SSH_FILES_COMPLETED_' + marker
        self.results, self.sent, self.step = [], None, 0
        self.phase = 0
        self.expect_failure = False
        self.filename = 'ssh-proof.json'
        self.exercise_shell_io = exercise_shell_io
        initial = ('import json,os,socket; from pathlib import Path; '
                   'p={"marker":' + repr(marker) + ',"cwd":os.getcwd(),'
                   '"hostname":socket.gethostname(),"uid":os.getuid()}; '
                   'Path("ssh-proof.json").write_text(json.dumps(p)+"\\n"); print(json.dumps(p))')
        final = ('import hashlib,json,os; from pathlib import Path; '
                 'p=json.loads(Path("ssh-proof.json").read_text()); '
                 'b=Path("notes.txt").read_bytes(); assert b==b"after\\n"; '
                 'p.update(notes=b.decode(),sha256=hashlib.sha256(b).hexdigest(),'
                 'files=sorted(os.listdir("."))); ')
        if exercise_shell_io:
            # The public command form deliberately names a real remote shell.
            # Spaces in all filenames exercise the shell's quoting boundary.
            final += ('p["shell_io"]={n:Path(n).read_bytes().decode("utf-8") for n in '
                      + repr(list(SHELL_IO_FILES)) + '}; ')
        final += 'print(json.dumps(p))'
        if exercise_shell_io:
            shell_io = (
                "printf '%s\\n' alpha > 'redirect input.txt' && "
                "cat < 'redirect input.txt' > 'redirect output.txt' && "
                "printf '%s\\n' beta >> 'redirect output.txt' && "
                "{ printf '%s\\n' separate-out; printf '%s\\n' separate-err >&2; } "
                "> 'redirect stdout.txt' 2> 'redirect stderr.txt' && "
                + shlex.join(['python3', '-c', final]))
        self.steps = [
            ('Execute', {'argv': ['python3', '-c', initial]}),
            ('Write', {'file_path': 'notes.txt', 'content': 'before\n'}),
            ('Read', {'file_path': 'notes.txt'}),
            ('Edit', {'file_path': 'notes.txt', 'old_string': 'before\n', 'new_string': 'after\n'}),
            ('Grep', {'path': 'notes.txt', 'pattern': '^after$'}),
            ('Execute', {'argv': ['python3', '-c', final]}),
        ]
        if exercise_shell_io:
            self.steps[-1] = ('Execute', {'command': shell_io, 'shell': 'sh',
                                          'intent': 'request_effect'})
        self.final_step = self.steps[-1]

    def resume_after_restart(self):
        self.phase = 'restart'
        self.step = 0
        self.sent = None
        self.expect_failure = False
        self.final = 'REMOTE_SSH_RESTART_COMPLETED_' + self.marker
        self.steps = [('Read', {'file_path': 'notes.txt'}), self.final_step]

    def pin_phase(self, *, denied):
        self.phase = 'pin-denied' if denied else 'pin-restored'
        self.step, self.sent = 0, None
        self.expect_failure = denied
        self.final = 'REMOTE_SSH_' + self.phase.upper() + '_' + self.marker
        self.steps = [('Execute', {'argv': ['python3', '-c',
            'from pathlib import Path; Path("pin-rotation-must-not-exist").write_text("unexpected")']})
            ] if denied else [self.final_step]

    def validate(self, name, content):
        decoded = list(smoke.objects(content))
        if self.expect_failure:
            if name != 'Execute':
                raise smoke.SmokeError('pin refusal must be an Execute result')
            transport_refusal(content)
            return
        if any(obj.get('ok') is False or obj.get('is_error') is True for obj in decoded):
            raise smoke.SmokeError(f'{name} returned an explicit failure: {content}')
        if name == 'Execute':
            if not any(obj.get('ok') is True and obj.get('status') == {'kind': 'exit', 'code': 0}
                       and type(obj['status']['code']) is int
                       for obj in decoded):
                raise smoke.SmokeError('Execute did not return successful process status')
            proof = smoke.proof_from(content, self.marker)
            if proof is None or proof['uid'] == 0:
                raise smoke.SmokeError('Execute lacks a nonroot endpoint proof: ' + str(content))
            if self.step == len(self.steps) - 1:
                files = proof.get('files')
                if (proof.get('notes') != 'after\n' or type(files) is not list
                        or any(type(filename) is not str for filename in files)
                        or not {'notes.txt', self.filename}.issubset(files)):
                    raise smoke.SmokeError('final Execute did not verify edited bytes and enumeration')
                if self.exercise_shell_io and proof.get('shell_io') != SHELL_IO_FILES:
                    raise smoke.SmokeError('shell redirects did not return exact split file bytes')
            self.proof = proof
        elif name in ('Read', 'Write', 'Edit', 'Grep'):
            if self.proof is None:
                raise smoke.SmokeError(name + ' has no preceding endpoint cwd proof')
            expected = {'ok': True, 'via': 'remote_ssh',
                        'path': str(PurePosixPath(self.proof['cwd']) / 'notes.txt')}
            if name == 'Read':
                text = 'after\n' if self.phase else 'before\n'
                expected.update(content=text, bytes=len(text.encode('utf-8')), truncated=False,
                                offset=1, returned_lines=1)
            elif name == 'Write':
                expected.update(mode='overwrite', bytes_written=len('before\n'.encode('utf-8')))
            elif name == 'Edit':
                expected.update(mode='patch', bytes_written=len('after\n'.encode('utf-8')),
                                changed=True, occurrences=1, replace_all=False)
            else:
                expected.update(op='rg', pattern='^after$', matches=['1:after'],
                                status={'kind': 'exit', 'code': 0})

            def matches_contract(obj):
                if not all(key in obj and type(obj[key]) is type(value) and obj[key] == value
                           for key, value in expected.items()):
                    return False
                # bool is an int subclass: a false status is not process exit 0.
                return name != 'Grep' or type(obj['status']['code']) is int

            if not any(matches_contract(obj) for obj in decoded):
                raise smoke.SmokeError(name + ' did not return the exact remote file result: '
                                       + str(content))

    def reply(self, request):
        with self.lock:
            self.requests.append(request)
            (self.output / 'model-requests.json').write_text(json.dumps(self.requests, indent=2))
            if request.get('model') != 'deepseek-v4.1-flash':
                raise smoke.SmokeError('unexpected model request')
            messages = request.get('messages', [])
            if self.sent is not None:
                call_id, name = self.sent
                results = [m for m in messages if m.get('role') == 'tool'
                           and m.get('tool_call_id') == call_id]
                if len(results) != 1:
                    raise smoke.SmokeError(f'expected exactly one result for {call_id}')
                self.validate(name, results[0].get('content'))
                self.results.append({'call_id': call_id, 'tool': name, 'result': results[0],
                                     'expected_failure': self.expect_failure})
                (self.output / 'tool-results.json').write_text(json.dumps(self.results, indent=2))
                self.step += 1
                self.sent = None
            offered = {t.get('function', {}).get('name') for t in request.get('tools', [])}
            if self.step == len(self.steps):
                message, finish = {'role': 'assistant', 'content': self.final}, 'stop'
            else:
                name, arguments = self.steps[self.step]
                if name not in offered:
                    if self.search_requested or 'keeper_tool_search' not in offered:
                        raise smoke.SmokeError('Keeper did not expose requested filesystem tools')
                    self.search_requested = True
                    call_id, name, arguments = 'ssh-file-discovery', 'keeper_tool_search', {
                        'names': sorted({name for name, _ in self.steps})}
                else:
                    call_id = f'ssh-file-{self.phase}-{self.step}'
                    self.sent = (call_id, name)
                    if self.step == len(self.steps) - 1:
                        self.call_id, self.tool_name = call_id, name
                message = {'role': 'assistant', 'content': None, 'tool_calls': [{
                    'id': call_id, 'type': 'function', 'function': {
                        'name': name, 'arguments': json.dumps(arguments)}}]}
                finish = 'tool_calls'
            return {'id': 'ssh-fixture-' + str(len(self.requests)), 'object': 'chat.completion',
                    'model': 'deepseek-v4.1-flash', 'choices': [{'index': 0, 'message': message,
                    'finish_reason': finish}], 'usage': {'prompt_tokens': 1, 'completion_tokens': 1,
                                                        'total_tokens': 2}}


def ssh(args, argv):
    prefix = ['ssh', '-T', '-F', 'none', '-o', 'BatchMode=yes', '-o', 'IdentitiesOnly=yes',
              '-o', 'IdentityFile=none', '-o', 'IdentityAgent=none',
              '-o', 'ForwardAgent=no', '-o', 'ClearAllForwardings=yes',
              '-o', 'StrictHostKeyChecking=yes', '-o', 'UserKnownHostsFile=' + args.known_hosts,
              '-o', 'GlobalKnownHostsFile=none', '-o', 'ControlMaster=no', '-o', 'ControlPath=none',
              '-o', 'ConnectTimeout=10', '-i', args.identity, '-p', str(args.port),
              args.user + '@' + args.host]
    return smoke.command(prefix + [shlex.join(argv)], os.environ.copy())


def ledger_proof(base, keeper, fixture, output):
    rows = []
    for path in (base / '.masc/tool_calls').rglob('*.jsonl'):
        rows.extend(json.loads(line) for line in path.read_text().splitlines() if line.strip())
    selected = []
    for result in fixture.results:
        matches = [row for row in rows if row.get('keeper') == keeper
                   and row.get('tool_use_id') == result['call_id']]
        if len(matches) != 1:
            raise smoke.SmokeError('tool result does not have one canonical ledger row')
        row = matches[0]
        failure = result.get('expected_failure', False)
        if (row.get('tool') != result['tool'] or row.get('sandbox_profile') != 'remote_ssh'
                or row.get('wire_outcome') != 'ok' or row.get('disposition') != 'completed'):
            raise smoke.SmokeError('ledger differs from the expected SSH tool outcome')
        if result['tool'] == 'Execute':
            evidence = row.get('execution_evidence') or {}
            if evidence.get('via') != 'remote_ssh':
                raise smoke.SmokeError('Execute ledger lacks actual SSH transport evidence')
            if failure:
                # make_ok completes the tool envelope even when the process
                # payload reports failure. Match that payload and its receipt.
                payload = transport_refusal(result['result']['content'])
                logged = transport_refusal(row.get('output'))
                if (logged != payload or evidence.get('shim_execution_evidence')
                        != payload['shim_execution_evidence']):
                    raise smoke.SmokeError('ledger lacks the same typed transport refusal')
        selected.append(row)
    (output / 'tool-ledger.json').write_text(json.dumps(selected, indent=2))
    return selected


def pin_observation(url, token, args, output, phase, *, previous=None, denied=False):
    snapshot = json.loads(smoke.request(url + '/api/v1/keepers/' + args.keeper + '/config', token))
    catalog = snapshot.get('remote_ssh_endpoints') or {}
    endpoints = [endpoint for endpoint in catalog.get('endpoints', [])
                 if endpoint.get('name') == 'proof']
    if catalog.get('state') != 'available' or len(endpoints) != 1:
        raise smoke.SmokeError('pin proof lacks the configured endpoint catalog')
    endpoint = endpoints[0]
    if any(endpoint.get(key) != value for key, value in {
            'host': args.host, 'user': args.user, 'port': args.port,
            'remote_root': args.remote_root}.items()):
        raise smoke.SmokeError('pin observation belongs to another endpoint')
    observation = endpoint.get('observation') or {}
    dispatch = observation.get('last_dispatch') or {}
    if (observation.get('lane') != 'remote_ssh' or observation.get('endpoint') != 'proof'
            or type(dispatch.get('at_unix')) not in (int, float)
            or (previous is not None and dispatch['at_unix'] <= previous['at_unix'])
            or (denied and (dispatch.get('outcome') != 'lane_failed'
                            or dispatch.get('failure') != 'transport_failed'))
            or (not denied and (dispatch.get('outcome') != 'payload_finished'
                                or dispatch.get('status') != 'exit=0'))):
        raise smoke.SmokeError('pin phase lacks a fresh typed SSH dispatch observation')
    (output / ('endpoint-pin-' + phase + '.json')).write_text(json.dumps(endpoint, indent=2))
    return dispatch


def health_identity(snapshot, base, receipt):
    build = snapshot.get('build', {})
    if (snapshot.get('paths', {}).get('effective_base_path') != str(base)
            or build.get('binary_commit') != receipt['binary_commit']
            or build.get('executable_sha256') != receipt['binary_sha256']
            or not isinstance(build.get('runtime_instance_id'), str)
            or not build['runtime_instance_id']):
        raise smoke.SmokeError('server health does not identify the pinned executable and workspace')
    return build['runtime_instance_id']


def run(args):
    binary = str(Path(args.binary).resolve(strict=True))
    output = Path(args.output_dir).resolve()
    output.mkdir(mode=0o700, parents=True, exist_ok=False)
    base = output / '.workspace'
    base.mkdir(mode=0o700)
    home = base / 'home'
    home.mkdir(mode=0o700)
    marker = uuid.uuid4().hex
    fixture = FilesFixture(marker, output, exercise_shell_io=args.exercise_shell_io)
    model, server = None, None
    receipt = {'schema': 'masc.remote_ssh_keeper_files.v1', 'result': 'FAIL',
               'keeper': args.keeper, 'expected_binary_commit': args.expected_commit,
               'binary_sha256': hashlib.sha256(Path(binary).read_bytes()).hexdigest(),
               'model': 'scripted loopback fixture', 'claims': [],
               'identity_sha256': hashlib.sha256(Path(args.identity).read_bytes()).hexdigest(),
               'known_hosts_sha256': hashlib.sha256(Path(args.known_hosts).read_bytes()).hexdigest(),
               'not_measured': ['model quality', 'sustained continuity', 'GitHub authentication',
                                'bootstrap CLI', 'redirects and long jobs', 'candidate source unless commit matches',
                                'shim sandbox application receipt when peer omits it']}
    try:
        env = {k: v for k, v in os.environ.items() if k in ('PATH', 'LANG', 'LC_ALL', 'TMPDIR')}
        env.update(HOME=str(home), MASC_BASE_PATH=str(base), MASC_KEEPER_AUTONOMOUS_ENABLED='true')
        commit = smoke.command([binary, 'build-commit'], env).strip().splitlines()[-1]
        receipt['binary_commit'] = commit
        if commit != args.expected_commit:
            raise smoke.SmokeError('installed binary commit does not match --expected-commit')
        remote = str(PurePosixPath(args.remote_root) / args.keeper)
        preserved = preserved_file_manifest(getattr(args, 'preserved_file_sha256', []))
        before = json.loads(ssh(args, ['python3', '-c', initial_workspace_inspection(),
                                       remote, json.dumps(list(preserved))]))
        (output / 'endpoint-before.json').write_text(json.dumps(before, indent=2))
        validate_initial_workspace(before, preserved)
        smoke.command([binary, 'init', '--base-path', str(base)], env)
        # Mutate only the test workspace's private copy for rotation probes.
        # The operator's original trust file is read-only throughout this run.
        pins = base / '.masc/ssh/proof-known-hosts'
        pins.parent.mkdir(parents=True, exist_ok=True)
        original_pins = Path(args.known_hosts).read_bytes()
        pins.write_bytes(original_pins)
        pins.chmod(0o600)
        model = fixture.serve()
        config = base / '.masc/config'
        content = (HELPER.parent / 'fixtures/release-evidence/runtime.toml').read_text()
        content = content.replace('http://127.0.0.1:9/v1', f'http://127.0.0.1:{model.server_port}/v1')
        content = content.replace('streaming = true', 'streaming = false')
        content += '\n[exec.ssh.endpoints.proof]\n' + '\n'.join(
            key + ' = ' + json.dumps(value) for key, value in {
                'host': args.host, 'user': args.user, 'port': args.port,
                'remote_root': args.remote_root, 'identity_file': args.identity,
                'known_hosts_file': str(pins), 'env_allowlist': [],
                'private_home': False}.items()) + '\n'
        (config / 'runtime.toml').write_text(content)
        with socket.socket() as sock:
            sock.bind(('127.0.0.1', 0))
            port = sock.getsockname()[1]
        url = f'http://127.0.0.1:{port}'
        cli = ['--base-path', str(base), '--host', '127.0.0.1', '--port', str(port)]
        smoke.command([binary, 'login', *cli, '--agent', 'ssh-proof-admin', '--role', 'admin',
                       '--client-env', 'MASC_SSH_PROOF_TOKEN', '--no-expiry', '--json'], env)
        token = (base / '.masc/auth/ssh-proof-admin.token').read_text().strip()
        with (output / 'server.log').open('w') as log:
            server = subprocess.Popen([binary, 'start', *cli], env=env, stdout=log, stderr=log, cwd=base)
            def health():
                try:
                    snapshot = json.loads(smoke.request(url + '/health?full=1', timeout=2))
                    return snapshot if snapshot.get('startup', {}).get('state_ready') is True else None
                except (urllib.error.URLError, TimeoutError):
                    return None
            healthy = smoke.wait_until('isolated SSH server health', health, server)
            (output / 'health.json').write_text(json.dumps(healthy, indent=2))
            initial_instance = health_identity(healthy, base, receipt)
            create_argv = [binary, 'keeper-create', *cli, '--agent', 'ssh-proof-admin',
                '--name', args.keeper, '--sandbox-profile', 'remote_ssh', '--remote-endpoint', 'proof',
                '--network-mode', 'inherit', '--no-skills', '--activation-mode', 'manual',
                '--instructions', 'Perform the isolated remote SSH filesystem proof using the offered tools.']
            creation = smoke.command(create_argv, env)
            (output / 'keeper-create.txt').write_text(creation)
            mode = json.loads(smoke.request(url + '/api/v1/dashboard/gate/mode', token, {'mode': 'always_allow'}))
            if mode.get('ok') is not True or mode.get('mode') != 'always_allow':
                raise smoke.SmokeError('isolated gate mode was not applied')
            mode = json.loads(smoke.request(url + '/api/v1/keepers/tool-approval-mode', token,
                                            {'name': args.keeper, 'mode': 'yolo'}))
            if mode.get('keeper') != args.keeper or mode.get('mode') != 'yolo':
                raise smoke.SmokeError('isolated tool mode was not applied')
            smoke.chat_request(url + '/api/v1/keepers/chat/stream', token,
                {'name': args.keeper, 'message': 'Run the remote file workflow and verify the resulting bytes.',
                 'request_id': 'kmsg-' + marker}, output / 'chat-stream.txt')
            if fixture.error:
                raise smoke.SmokeError(fixture.error)
            if fixture.step != len(fixture.steps):
                raise smoke.SmokeError('Keeper did not finish the requested file workflow')
            checkpoint, data = smoke.wait_until('canonical final SSH checkpoint',
                lambda: smoke.checkpoint_proof(base, fixture), server)
            (output / 'checkpoint.json').write_text(json.dumps(data, indent=2))
            if args.exercise_pin_rotation:
                prior_dispatch = pin_observation(url, token, args, output, 'before')
                fixture.pin_phase(denied=True)
                try:
                    pins.write_bytes(b'')
                    smoke.chat_request(url + '/api/v1/keepers/chat/stream', token,
                        {'name': args.keeper, 'message': 'Attempt the isolated pin-rotation probe.',
                         'request_id': 'kmsg-pin-denied-' + marker}, output / 'chat-pin-denied.txt')
                    if fixture.error or fixture.step != len(fixture.steps):
                        raise smoke.SmokeError(fixture.error or 'pin denial turn did not finish')
                    denied_dispatch = pin_observation(url, token, args, output, 'denied',
                                                      previous=prior_dispatch, denied=True)
                finally:
                    pins.write_bytes(original_pins)
                fixture.pin_phase(denied=False)
                smoke.chat_request(url + '/api/v1/keepers/chat/stream', token,
                    {'name': args.keeper, 'message': 'Verify file bytes after explicit pin restoration.',
                     'request_id': 'kmsg-pin-restored-' + marker}, output / 'chat-pin-restored.txt')
                if fixture.error or fixture.step != len(fixture.steps):
                    raise smoke.SmokeError(fixture.error or 'pin restoration did not recover')
                pin_observation(url, token, args, output, 'restored', previous=denied_dispatch)
            shell_io_fields = (
                '"shell_io":{n:(p/n).read_bytes().decode("utf-8") for n in '
                + repr(list(SHELL_IO_FILES)) + '},') if args.exercise_shell_io else ''
            reread = ('import hashlib,json,os,socket,sys; from pathlib import Path; '
                      'p=Path(sys.argv[1]); b=(p/"notes.txt").read_bytes(); '
                      'print(json.dumps({"cwd":str(p),"hostname":socket.gethostname(),'
                      '"notes":b.decode(),"sha256":hashlib.sha256(b).hexdigest(),'
                      '"denied_effect_exists":(p/"pin-rotation-must-not-exist").exists(),'
                      '"preserved_files":{n:hashlib.sha256((p/n).read_bytes()).hexdigest() '
                      'if (p/n).is_file() and not (p/n).is_symlink() else None '
                      'for n in json.loads(sys.argv[2])},'
                      + shell_io_fields +
                      '"initial":json.loads((p/"ssh-proof.json").read_text())}))')
            reread_argv = ['python3', '-c', reread, remote, json.dumps(list(preserved))]
            actual = json.loads(ssh(args, reread_argv))
            (output / 'endpoint-after.json').write_text(json.dumps(actual, indent=2))
            if (actual['denied_effect_exists'] is not False or actual['notes'] != 'after\n'
                    or actual['hostname'] != before['hostname']
                    or actual['initial']['marker'] != marker or actual['sha256'] != fixture.proof['sha256']
                    or actual.get('preserved_files') != preserved):
                raise smoke.SmokeError('endpoint bytes or identity differ from Keeper ToolResult')
            if args.exercise_shell_io:
                if actual.get('shell_io') != SHELL_IO_FILES:
                    raise smoke.SmokeError('independent SSH read differs from shell redirect bytes')
                if any((Path(fixture.proof['cwd']) / name).exists() for name in SHELL_IO_FILES):
                    raise smoke.SmokeError('a remote redirect also exists in the projected host cwd')
            smoke.stop_server(server)
            after_stop = json.loads(ssh(args, reread_argv))
            if after_stop != actual:
                raise smoke.SmokeError('endpoint bytes changed after server shutdown')
            (output / 'endpoint-after-stop.json').write_text(json.dumps(after_stop, indent=2))
            fixture.resume_after_restart()
            server = subprocess.Popen([binary, 'start', *cli], env=env, stdout=log, stderr=log, cwd=base)
            resumed_health = smoke.wait_until('restarted SSH server health', health, server)
            (output / 'health-after-restart.json').write_text(json.dumps(resumed_health, indent=2))
            resumed_instance = health_identity(resumed_health, base, receipt)
            if resumed_instance == initial_instance:
                raise smoke.SmokeError('server restart did not produce a different runtime instance')
            # A manual Keeper is intentionally excluded from autoboot. Start
            # the same declaration through the operator CLI before chatting.
            resumed = smoke.command(create_argv, env)
            (output / 'keeper-resume.txt').write_text(resumed)
            smoke.chat_request(url + '/api/v1/keepers/chat/stream', token,
                {'name': args.keeper, 'message': 'Read the persisted notes and verify the original proof after restart.',
                 'request_id': 'kmsg-restart-' + marker}, output / 'chat-after-restart.txt')
            if fixture.error:
                raise smoke.SmokeError(fixture.error)
            if fixture.step != len(fixture.steps):
                raise smoke.SmokeError('Keeper did not complete resumed file reads')
            checkpoint, data = smoke.wait_until('canonical resumed SSH checkpoint',
                lambda: smoke.checkpoint_proof(base, fixture), server)
            (output / 'checkpoint-after-restart.json').write_text(json.dumps(data, indent=2))
            after_restart = json.loads(ssh(args, reread_argv))
            if after_restart != after_stop:
                raise smoke.SmokeError('endpoint bytes or declared initial hashes changed after restart/resume')
            (output / 'endpoint-after-restart.json').write_text(json.dumps(after_restart, indent=2))
            ledger_proof(base, args.keeper, fixture, output)
            receipt.update(result='PASS', model_requests=len(fixture.requests), tool_calls=len(fixture.results),
                runtime_instances=[initial_instance, resumed_instance],
                checkpoint_relative_path=str(checkpoint.relative_to(base)),
                actual_remote_cwd=actual['cwd'], model_projected_cwd=fixture.proof['cwd'],
                claims=['actual Keeper Execute/Write/Read/Edit/Grep over SSH',
                        'endpoint bytes match tool results', 'canonical final checkpoint',
                        'endpoint bytes survive server shutdown',
                        'same manual Keeper explicitly started and resumed after server restart',
                        'canonical ledger records completed SSH tools'])
            if args.exercise_pin_rotation:
                receipt['claims'].append('same-path pin replacement denied Execute; explicit restoration recovered')
            if preserved:
                receipt['preserved_file_sha256'] = preserved
                receipt['claims'].append('declared preexisting regular-file hashes survive workflow, shutdown and restart')
            if args.exercise_shell_io:
                receipt['claims'].append('public command form performed remote stdin, truncate, append and split output redirects')
                receipt['not_measured'].remove('redirects and long jobs')
                receipt['not_measured'].append('typed internal IR redirects and long jobs')
            receipt['successful_tools'] = sum(not r['expected_failure'] for r in fixture.results)
            receipt['expected_refusals'] = sum(r['expected_failure'] for r in fixture.results)
    except (smoke.SmokeError, OSError, ValueError, urllib.error.URLError) as error:
        receipt['error'] = str(error)
    finally:
        if server is not None:
            smoke.stop_server(server)
        if model is not None:
            model.shutdown()
            model.server_close()
        (output / 'receipt.json').write_text(json.dumps(receipt, indent=2) + '\n')
    print(json.dumps(receipt, indent=2))
    return 0 if receipt['result'] == 'PASS' else 1


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ('binary', 'expected-commit', 'output-dir', 'keeper', 'host', 'user',
                 'remote-root', 'identity', 'known-hosts'):
        parser.add_argument('--' + name, required=True)
    parser.add_argument('--port', type=int, default=22)
    parser.add_argument('--exercise-pin-rotation', action='store_true')
    parser.add_argument('--exercise-shell-io', action='store_true')
    parser.add_argument('--preserved-file-sha256', action='append', nargs=2, default=[],
                        metavar=('NAME', 'SHA256'),
                        help='Declare a preexisting workspace-root regular file and its exact hash; repeat per file.')
    args = parser.parse_args()
    if not args.keeper or any(c not in 'abcdefghijklmnopqrstuvwxyz0123456789-_' for c in args.keeper):
        parser.error('--keeper must be a lowercase safe Keeper name')
    path = PurePosixPath(args.remote_root)
    if not path.is_absolute() or any(p in ('.', '..', '') for p in args.remote_root.split('/')[1:]):
        parser.error('--remote-root must be an absolute normalized path')
    for name in ('identity', 'known_hosts'):
        setattr(args, name, str(Path(getattr(args, name)).resolve(strict=True)))
    return run(args)


if __name__ == '__main__':
    raise SystemExit(main())
