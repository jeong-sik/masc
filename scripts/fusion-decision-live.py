"""CI-binary-bound, loopback-only operator for the isolated Fusion scenario.

The prepare script creates its fresh private base. This helper never changes
runtime journals or fabricates model tool calls. Raw responses stay private.
"""
import argparse
import fcntl
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import socket
import signal
import subprocess
import time
import tomllib
from urllib.request import Request, HTTPRedirectHandler, ProxyHandler, build_opener
from urllib.error import HTTPError


class NoRedirect(HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def observe_process_rows(command):
    result = subprocess.run(command, capture_output=True, text=True)
    rows = result.stdout.splitlines()
    if result.returncode == 0 and rows and not result.stderr.strip():
        return rows
    if result.returncode == 1 and not rows and not result.stderr.strip():
        return []  # Both lsof and ps report a successful no-match with exit 1.
    raise RuntimeError(f'{command[0]} process observation failed (exit {result.returncode}); no restart authorized')


def candidate_binary(args):
    if args.installed_prefix is not None:
        prefix = args.installed_prefix.resolve()
        spec = importlib.util.spec_from_file_location(
            'release_dashboard_bundle', Path(__file__).with_name('release-dashboard-bundle.py'))
        bundle = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(bundle)
        if (prefix / bundle.TRANSACTION).exists():
            raise ValueError('Uncommitted installed release transaction')
        binary = (prefix / 'masc').resolve(strict=True)
        root = binary.parent
        if binary.name != 'masc' or root.parent != prefix / '.masc-releases':
            raise ValueError('Binary is not in this prefix immutable release tree')
        receipt = bundle.verify_tree(root, 'masc-macos-arm64')
        if (receipt['source_commit'] != args.expected_commit
                or bundle.binary_commit(binary) != args.expected_commit):
            raise ValueError('Installed release source mismatch')
        return binary, receipt['binary_sha256']
    manifest = json.loads((args.artifact_dir / 'manifest.json').read_text())
    binary = (args.artifact_dir / 'main_eio.exe').resolve()
    digest = hashlib.sha256(binary.read_bytes()).hexdigest()
    if (manifest['commit'] != args.expected_commit or manifest['arch'] != 'macos-arm64'
            or manifest['sha256']['main_eio.exe'] != digest):
        raise ValueError('CI manifest mismatch')
    return binary, digest


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--base', type=Path, required=True)
    p.add_argument('--expected-commit', required=True)
    sub = p.add_subparsers(dest='command', required=True)
    start = sub.add_parser('start')
    restart = sub.add_parser('restart-owned')
    for command in (start, restart):
        source = command.add_mutually_exclusive_group(required=True)
        source.add_argument('--artifact-dir', type=Path)
        source.add_argument('--installed-prefix', type=Path)
    call = sub.add_parser('call')
    call.add_argument('tool')
    call.add_argument('--arguments-file', type=Path, required=True)
    get = sub.add_parser('get')
    get.add_argument('path')
    post = sub.add_parser('post')
    post.add_argument('path')
    post.add_argument('--arguments-file', type=Path, required=True)
    args = p.parse_args()
    is_effect = args.command in ['call', 'post']
    base = args.base.resolve()
    operator_lock = (base / 'operator.lock').open('a')
    fcntl.flock(operator_lock, fcntl.LOCK_EX)
    scenario = json.loads((base / 'scenario-input.json').read_text())
    token = (base / 'operator-token.private').read_text().strip()
    state_file = base / 'operator-state.private.json'
    state = json.loads(state_file.read_text()) if state_file.exists() else {'counter': 0}
    url = f"http://127.0.0.1:{scenario['port']}"
    http = build_opener(ProxyHandler({}), NoRedirect())

    def persist_state():
        temporary = state_file.with_suffix('.tmp')
        with temporary.open('w') as handle:
            temporary.chmod(0o600)
            handle.write(json.dumps(state))
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, state_file)

    def initialize():
        response = request('/mcp', {'jsonrpc': '2.0', 'id': 0, 'method': 'initialize', 'params': {'protocolVersion': '2025-03-26', 'capabilities': {}, 'clientInfo': {'name': 'fusion-decision-live', 'version': '1'}}})
        persist_state()
        return response

    def request(path, body=None, *, method=None):
        if not path.startswith('/') or path.startswith('//'):
            raise ValueError('Expected same-origin absolute path')
        headers = {'Authorization': 'Bearer ' + token, 'Accept': 'application/json, text/event-stream', 'Content-Type': 'application/json'}
        if state.get('session'):
            headers['Mcp-Session-Id'] = state['session']
        req = Request(url + path, headers=headers, method=method,
                      data=None if body is None and method != 'POST' else json.dumps(body).encode())
        try:
            with http.open(req, timeout=30) as response:
                raw = response.read().decode()
                if response.headers.get('Mcp-Session-Id'):
                    state['session'] = response.headers['Mcp-Session-Id']
        except HTTPError as error:
            body = error.read().decode()
            if token not in body:
                (base / f"operator-http-error-{state['counter']:03}.private.json").write_text(json.dumps({'status': error.code, 'body': body}))
            raise
        if token in raw:
            raise ValueError('Credential echo withheld')
        lines = [line[6:] for line in raw.splitlines() if line.startswith('data: ')]
        return json.loads(next((line for line in lines if '"id"' in line), raw))

    def check_health(*, expected_commit=None, expected_binary_sha256=None):
        health = request('/health?full=1')
        if health['build']['binary_commit'] != (expected_commit or args.expected_commit) or Path(health['paths']['effective_base_path']).resolve() != base:
            raise ValueError('Running binary/base identity mismatch')
        if expected_binary_sha256 is not None and health['build']['executable_sha256'] != expected_binary_sha256:
            raise ValueError('Running binary hash differs from the owned process receipt')
        return health

    if args.command in ['start', 'restart-owned']:
        if args.command == 'start' and state_file.exists():
            raise ValueError('Existing operator state; refusing a second server start')
        binary, digest = candidate_binary(args)
        binary.chmod(binary.stat().st_mode | 0o100)
        env = {key: value for key, value in os.environ.items() if not any(part in key for part in ['TOKEN', 'SECRET', 'API_KEY']) and not key.startswith('MASC_')}
        runtime_config = tomllib.loads((base / '.masc/config/runtime.toml').read_text())
        for provider in runtime_config['providers'].values():
            if provider.get('protocol') in ('codex-app-server', 'ollama-http') and 'credentials' not in provider:
                # Codex owns its subscription authentication. An explicitly
                # credential-free Ollama connection needs no secret injected.
                continue
            credential = provider.get('credentials', {})
            if credential.get('type') != 'env':
                raise ValueError('This scenario expects explicit environment credential references')
            key = credential['key']
            if not os.environ.get(key):
                raise ValueError('Selected provider credential environment is absent')
            env[key] = os.environ[key]
        env.update(MASC_ADMIN_TOKEN=token, MASC_BASE_PATH=str(base), MASC_GRPC_ENABLED='0', MASC_KEEPER_AUTONOMOUS_ENABLED='true', MASC_KEEPER_SANDBOX_PREFLIGHT_ENABLED='false')
        if args.command == 'restart-owned':
            if state.get('pending'):
                raise ValueError('Unconfirmed effect requires reconciliation before restart')
            listeners = observe_process_rows(['lsof', '-t', f"-iTCP:{scenario['port']}", '-sTCP:LISTEN'])
            if set(listeners) == {str(state['pid'])}:
                # Validate the process being replaced against its own receipt,
                # not against the new candidate's commit. A source change is
                # the reason for this restart, not an ownership mismatch.
                check_health(expected_commit=state['expected_commit'],
                             expected_binary_sha256=state['binary_sha256'])
                state.setdefault('restarts', []).append({'previous_pid': state['pid'], 'at': time.time()})
                persist_state()
                os.kill(state['pid'], signal.SIGTERM)
            elif (listeners or not state.get('restarts')
                  or state['restarts'][-1]['previous_pid'] != state['pid']
                  or observe_process_rows(['ps', '-p', str(state['pid']), '-o', 'comm='])):
                raise ValueError('Neither a verified owned listener nor a recorded stopped restart')
            for _ in range(100):
                listeners = observe_process_rows(['lsof', '-t', f"-iTCP:{scenario['port']}", '-sTCP:LISTEN'])
                process_alive = observe_process_rows(['ps', '-p', str(state['pid']), '-o', 'comm='])
                if not listeners and not process_alive:
                    break
                time.sleep(0.2)
            else:
                raise TimeoutError('Owned process has not finished stopping; no forced kill or new process')
            state.pop('session', None)
            state['counter'] += 1
        with socket.socket() as sock:
            sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            sock.bind(('127.0.0.1', scenario['port']))
        with (base / 'server.private.log').open('ab' if args.command == 'restart-owned' else 'xb') as log:
            process = subprocess.Popen([str(binary), '--base-path', str(base), '--port', str(scenario['port'])], cwd=base, env=env, stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
        state.update(pid=process.pid, binary=str(binary), binary_sha256=digest, expected_commit=args.expected_commit)
        persist_state()
        for _ in range(100):
            if process.poll() is not None:
                raise RuntimeError('Owned server exited before health; inspect private log')
            try:
                health = check_health()
                if health['startup']['state_ready']:
                    break
            except OSError:
                pass
            time.sleep(0.2)
        else:
            raise TimeoutError('Owned server readiness not observed; process retained for diagnosis')
        (base / 'health.json').write_text(json.dumps(health, indent=2))
        result = initialize()
    else:
        check_health()
        if is_effect and state.get('pending'):
            raise RuntimeError('Previous effect response is unconfirmed. Reconcile the actual operation/target before any further tool call; do not resubmit.')
        if args.command == 'call':
            # The server may have expired an idle session while models ran.
            # Establish transport authority before reserving an effect intent.
            state.pop('session', None)
            initialize()
        state['counter'] += 1
        if is_effect:
            arguments = json.loads(args.arguments_file.read_text())
            target = {'tool': args.tool} if args.command == 'call' else {'path': args.path}
            state['pending'] = {'counter': state['counter'], **target,
                                'arguments_sha256': hashlib.sha256(json.dumps(arguments, sort_keys=True, separators=(',', ':')).encode()).hexdigest(),
                                'submitted_at': time.time(), 'remote_effect': 'unconfirmed'}
            persist_state()
            result = (request('/mcp', {'jsonrpc': '2.0', 'id': state['counter'], 'method': 'tools/call', 'params': {'name': args.tool, 'arguments': arguments}})
                      if args.command == 'call' else request(args.path, arguments, method='POST'))
        else:
            result = request(args.path)
    destination = base / f"operator-response-{state['counter']:03}.private.json"
    with destination.open('x') as handle:
        destination.chmod(0o600)
        handle.write(json.dumps(result, ensure_ascii=False, indent=2) + '\n')
        handle.flush()
        os.fsync(handle.fileno())
    if is_effect:
        state.pop('pending', None)
    persist_state()
    print(json.dumps({'response_file': str(destination), 'server_pid': state['pid'], 'counter': state['counter']}))


if __name__ == '__main__':
    main()
