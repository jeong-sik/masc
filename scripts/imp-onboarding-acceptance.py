#!/usr/bin/env python3
"""Measure a real default imp in an isolated home, using an authenticated Codex CLI.

Requires an installed release prefix and an already authenticated Codex auth.json.
Copies only that credential into a private disposable CLI home, never into evidence.
No fixture model, approval bypass, or existing workspace configuration is used.
"""
import argparse
import json
import os
from pathlib import Path
import shutil
import socket
import subprocess
import tempfile
import time
import urllib.request

ROOT = Path(__file__).resolve().parents[1]


def request(url, token=None, body=None):
    headers = {'Content-Type': 'application/json'}
    if token:
        headers['Authorization'] = 'Bearer ' + token
    data = None if body is None else json.dumps(body).encode()
    with urllib.request.urlopen(urllib.request.Request(url, data=data, headers=headers), timeout=30) as reply:
        return json.load(reply)


def events(path):
    return [json.loads(line[5:]) for line in path.read_text().splitlines() if line.startswith('data:')]


def measure(args):
    binary = str(Path(args.binary).resolve())
    output = Path(args.output).resolve()
    output.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='masc-imp-', dir=args.work_parent) as directory:
        base = Path(directory).resolve()
        home = base / 'home'
        auth = home / '.codex/auth.json'
        auth.parent.mkdir(parents=True, mode=0o700)
        shutil.copyfile(args.codex_auth, auth)
        auth.chmod(0o600)
        env = {k: v for k, v in os.environ.items() if k in ('PATH', 'LANG', 'DOCKER_HOST', 'DOCKER_CONTEXT', 'DOCKER_CONFIG')}
        env.update(HOME=str(home), CODEX_HOME=str(auth.parent))
        def run(*argv):
            result = subprocess.run(list(argv), env=env, capture_output=True, text=True, timeout=300, cwd=base)
            if result.returncode:
                raise RuntimeError(result.stderr + result.stdout)
            return result.stdout
        run(binary, 'init', '--base-path', str(base))
        config_spec = dict(choice='codex', model=args.model, max_context=args.context, tools=True, streaming=True)
        spec_path = base / 'runtime-spec.json'
        spec_path.write_text(json.dumps(config_spec))
        run('python3', str(ROOT / 'scripts/install-runtime-setup.py'), '--binary', binary,
            '--base-path', str(base), '--spec', str(spec_path))
        with socket.socket() as sock:
            sock.bind(('127.0.0.1', 0))
            port = sock.getsockname()[1]
        url = f'http://127.0.0.1:{port}'
        # Own a foreground server so acceptance always knows which process to stop.
        with (output / 'server.log').open('w') as log:
            server = subprocess.Popen([binary, 'start', '--base-path', str(base), '--port', str(port)],
                                      env=env, cwd=base, stdout=log, stderr=log)
            try:
                deadline = time.monotonic() + 60
                while True:
                    if server.poll() is not None:
                        raise RuntimeError('server exited; see server.log')
                    try:
                        health = request(url + '/health?full=1')
                        if health.get('startup', {}).get('state_ready') is True:
                            break
                    except OSError:
                        pass
                    if time.monotonic() >= deadline:
                        raise RuntimeError('server readiness deadline exceeded')
                    time.sleep(.2)
                (output / 'setup.txt').write_text(run(binary, 'setup', '--base-path', str(base), '--port', str(port), '--no-tui'))
                token = (base / '.masc/auth/local-admin.token').read_text().strip()
                before = request(url + '/api/v1/keepers/imp/boot', token, {'name': 'imp'})
                if before.get('already_live') is not True:
                    raise RuntimeError('repeated boot did not preserve the live imp')
                (output / 'repeated-boot.json').write_text(json.dumps(before, indent=2))
                prompts = [
                    'Hello imp. Please introduce yourself briefly.',
                    'Create a Board post titled Imp first conversation and a Task titled Imp onboarding check. Leave the task open.',
                    'List your sandbox working directory and show its current path.',
                    'Fetch https://example.com and tell me what it says.',
                ]
                for index, prompt in enumerate(prompts):
                    path = output / f'chat-{index}.sse'
                    with path.open('wb') as stream:
                        result = subprocess.run(['curl', '-sS', '--fail-with-body', '-N', '--config', '-',
                            '--data-binary', json.dumps({'name': 'imp', 'message': prompt, 'request_id': f'kmsg-acceptance-{index}'}),
                            url + '/api/v1/keepers/chat/stream'], env=env,
                            input=('header = "Content-Type: application/json"\nheader = "Authorization: Bearer ' + token + '"\n').encode(),
                            stdout=stream, stderr=subprocess.PIPE, timeout=240)
                    result.check_returncode()
                    stream_events = events(path)
                    if any(event.get('type') == 'RUN_ERROR' for event in stream_events):
                        raise RuntimeError(f'chat {index} returned RUN_ERROR; see {path}')
                    if not any(event.get('type') == 'RUN_FINISHED' for event in stream_events):
                        raise RuntimeError(f'chat {index} has no completed run')
                    print(f'chat {index} completed', flush=True)
                traces = [json.loads(line) for path in (base / '.masc/keepers/imp/raw-traces').glob('*.jsonl')
                          for line in path.read_text().splitlines()]
                completed = [event for event in traces if event.get('record_type') == 'tool_execution_finished'
                             and event.get('tool_error') is False]
                (output / 'tool-traces.json').write_text(json.dumps(traces, indent=2, ensure_ascii=False))
                results = {}
                for event in completed:
                    try:
                        value = json.loads(event.get('tool_result', ''))
                    except json.JSONDecodeError:
                        continue
                    results.setdefault(event['tool_name'], []).append(value)
                if not any(value.get('ok') is True and value.get('via') == 'docker'
                           and value.get('status') == {'kind': 'exit', 'code': 0}
                           and value.get('cwd') == '/home/keeper/playground/imp'
                           for value in results.get('Execute', [])):
                    raise RuntimeError('no successful directory execution in the actual Docker sandbox')
                if not any(value.get('status') == 'ok' and value.get('http_status') == 200
                           and value.get('final_url') == 'https://example.com/'
                           for value in results.get('WebFetch', [])):
                    raise RuntimeError('no successful real web fetch')
                board = [json.loads(line) for line in (base / '.masc/board_posts.jsonl').read_text().splitlines()]
                posted_ids = {value.get('id') for value in results.get('masc_board_post', [])}
                if not any(row.get('id') in posted_ids and row.get('author') == 'imp' for row in board):
                    raise RuntimeError('Board tool result has no persisted imp post')
                (output / 'board-posts.json').write_text(json.dumps(board, indent=2, ensure_ascii=False))
                backlog = json.loads((base / '.masc/tasks/backlog.json').read_text())
                if not any(task.get('title') == 'Imp onboarding check' and task.get('created_by') == 'imp'
                           and task.get('status') == 'todo' for task in backlog.get('tasks', [])):
                    raise RuntimeError('no persisted open imp task')
                required = {'masc_board_post', 'keeper_task_create', 'Execute', 'WebFetch'}
                if not required.issubset({event.get('tool_name') for event in completed}):
                    raise RuntimeError('missing successful MASC tool results: ' + str(required - {e.get('tool_name') for e in completed}))
                (output / 'tool-results.json').write_text(json.dumps(completed, indent=2, ensure_ascii=False))
                for name in ('turn-records', 'execution-receipts'):
                    rows = [json.loads(line) for path in (base / '.masc/keepers/imp' / name).rglob('*.jsonl')
                            for line in path.read_text().splitlines()]
                    (output / (name + '.json')).write_text(json.dumps(rows, indent=2, ensure_ascii=False))
                (output / 'backlog.json').write_bytes((base / '.masc/tasks/backlog.json').read_bytes())
                (output / 'health.json').write_text(json.dumps(health, indent=2))
                (output / 'receipt.json').write_text(json.dumps(dict(
                    source=run(binary, 'build-commit').strip(), model=args.model,
                    platform=run('uname', '-sm').strip(), fixture_model=False,
                    approval_overrides=False, keeper='imp', completed_chats=len(prompts),
                    successful_tools=sorted(required)), indent=2))
                print('Acceptance evidence:', output, flush=True)
            finally:
                server.terminate()
                try:
                    server.wait(timeout=20)
                except subprocess.TimeoutExpired:
                    server.kill()
                    server.wait()


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary', required=True)
    parser.add_argument('--codex-auth', required=True)
    parser.add_argument('--model', required=True)
    parser.add_argument('--context', required=True, type=int)
    parser.add_argument('--work-parent', default=str(Path.home()))
    parser.add_argument('--output', required=True)
    measure(parser.parse_args())
