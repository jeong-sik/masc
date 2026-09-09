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
import shlex
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


def snapshot_evidence(base, output):
    """Preserve raw records before validating them, including a failed run."""
    keeper = base / '.masc/keepers/imp'
    traces = []
    parse_errors = []
    for name in ('raw-traces', 'turn-records', 'execution-receipts'):
        source = keeper / name
        if not source.exists():
            continue
        shutil.copytree(source, output / name, dirs_exist_ok=True)
        rows = []
        for path in sorted(source.rglob('*.jsonl')):
            for line_number, line in enumerate(path.read_text().splitlines(), 1):
                if not line.strip():
                    continue
                try:
                    rows.append(json.loads(line))
                except json.JSONDecodeError as error:
                    parse_errors.append(dict(file=str(path.relative_to(base)),
                                             line=line_number, error=str(error)))
        target = 'tool-traces.json' if name == 'raw-traces' else name + '.json'
        (output / target).write_text(json.dumps(rows, indent=2, ensure_ascii=False))
        if name == 'raw-traces':
            traces = rows
    for source, target in (('.masc/board_posts.jsonl', 'board-posts.jsonl'),
                           ('.masc/tasks/backlog.json', 'backlog.json')):
        path = base / source
        if path.exists():
            shutil.copyfile(path, output / target)
    if parse_errors:
        (output / 'trace-parse-errors.json').write_text(json.dumps(parse_errors, indent=2))
    return traces


def directory_execution(traces):
    # Join the actual dispatched input to its completion, never infer a listing
    # from a successful exit or an assistant's description. The final form is
    # also present in the recorded macOS baseline.
    def directory_commands(script):
        if not isinstance(script, str):
            return []
        try:
            lexer = shlex.shlex(script, posix=True, punctuation_chars=';&|\n')
            lexer.whitespace = ' \t\r'
            lexer.whitespace_split = True
            commands = [[]]
            for token in lexer:
                if token in (';', '&&', '\n'):
                    commands.append([])
                elif token in ('&', '|', '||'):
                    return []
                else:
                    commands[-1].append(token)
        except ValueError:
            return []
        return commands

    def command_roles(commands):
        def listing(command):
            return (command and command[0] == 'ls'
                    and all(arg.startswith('-') or arg == '.' for arg in command[1:]))
        if not commands or any(command and command != ['pwd'] and not listing(command)
                               for command in commands):
            return False, False
        return any(command == ['pwd'] for command in commands), any(listing(c) for c in commands)

    def identity(event):
        return tuple(event.get(key) for key in ('worker_run_id', 'session_id', 'tool_use_id'))
    starts = {identity(event): event for event in traces
              if event.get('record_type') == 'tool_execution_started'
              and event.get('tool_name') == 'Execute'
              and event.get('tool_use_id')}
    observations = {}
    for event in traces:
        if (event.get('record_type') != 'tool_execution_finished'
                or event.get('tool_name') != 'Execute' or event.get('tool_error') is not False):
            continue
        started = starts.get(identity(event))
        if not started or not all(identity(event)):
            continue
        tool_input = started.get('tool_input')
        if not isinstance(tool_input, dict):
            continue
        script = tool_input.get('script')
        if script is None:
            # Execute can encode the same shell program as an exact argv
            # wrapper. Never search arbitrary argv for text resembling ls.
            argv = tool_input.get('argv')
            if (isinstance(argv, list) and len(argv) == 3
                    and argv[0] in ('sh', 'bash', '/bin/sh', '/bin/bash')
                    and argv[1] in ('-c', '-lc')):
                script = argv[2]
        commands = directory_commands(script) if script is not None else [tool_input.get('argv')]
        if any(not isinstance(c, list) or not all(isinstance(arg, str) for arg in c)
               for c in commands):
            continue
        has_pwd, has_listing = command_roles(commands)
        if not (has_pwd or has_listing):
            continue
        try:
            result = json.loads(event.get('tool_result', ''))
        except (json.JSONDecodeError, TypeError):
            continue
        if not isinstance(result, dict):
            continue
        if not (result.get('ok') is True and result.get('via') == 'docker'
                and result.get('sandbox_profile') == 'docker'
                and result.get('status') == {'kind': 'exit', 'code': 0}
                and result.get('cwd') == '/home/keeper/playground/imp'
                and result.get('output_completeness') == 'complete'):
            continue
        lines = result.get('output', '').splitlines()
        directories = {line.split()[-1] for line in lines
                       if line.startswith('d') and len(line.split()) >= 9}
        proof = dict(input=started, completion=event)
        scope = (event['worker_run_id'], event['session_id'], result['cwd'])
        observed = observations.setdefault(scope, {})
        if has_pwd and '/home/keeper/playground/imp' in lines:
            observed['pwd'] = proof
        if has_listing and {'.', '..'}.issubset(directories):
            observed['listing'] = proof
        if 'pwd' in observed and 'listing' in observed:
            return proof if observed['pwd'] == observed['listing'] else observed
    raise RuntimeError('no matched Execute input/output proves the current path and directory listing in the Docker sandbox')


def measure(args):
    binary = str(Path(args.binary).resolve())
    output = Path(args.output).resolve()
    if output.exists() and (not output.is_dir() or any(output.iterdir())):
        raise RuntimeError('evidence output must be a new or empty directory: ' + str(output))
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
                    'Show the current path and a detailed directory listing, including hidden entries, inside your default sandbox.',
                    'Use WebFetch to retrieve https://example.com now and report the HTTP status and title.',
                ]
                for index, prompt in enumerate(prompts):
                    path = output / f'chat-{index}.sse'
                    with path.open('wb') as stream:
                        result = subprocess.run(['curl', '-sS', '--fail-with-body', '-N', '--config', '-',
                            '--data-binary', json.dumps({'name': 'imp', 'message': prompt, 'request_id': f'kmsg-acceptance-{index}'}),
                            url + '/api/v1/keepers/chat/stream'], env=env,
                            input=('header = "Content-Type: application/json"\nheader = "Authorization: Bearer ' + token + '"\n').encode(),
                            stdout=stream, stderr=subprocess.PIPE, timeout=240)
                    snapshot_evidence(base, output)
                    result.check_returncode()
                    stream_events = events(path)
                    if index == 0:
                        assistant_messages = {(event.get('runId'), event.get('messageId'))
                                              for event in stream_events
                                              if event.get('type') == 'TEXT_MESSAGE_START'
                                              and event.get('role') == 'assistant'}
                        greeting = ''.join(event['delta'] for event in stream_events
                                           if event.get('type') == 'TEXT_MESSAGE_CONTENT'
                                           and (event.get('runId'), event.get('messageId')) in assistant_messages
                                           and isinstance(event.get('delta'), str)).strip()
                        if not greeting:
                            raise RuntimeError('greeting completed without assistant text; see chat-0.sse')
                        (output / 'greeting.txt').write_text(greeting)
                    if any(event.get('type') == 'RUN_ERROR' for event in stream_events):
                        raise RuntimeError(f'chat {index} returned RUN_ERROR; see {path}')
                    if not any(event.get('type') == 'RUN_FINISHED' for event in stream_events):
                        raise RuntimeError(f'chat {index} has no completed run')
                    print(f'chat {index} completed', flush=True)
                traces = snapshot_evidence(base, output)
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
                directory_proof = directory_execution(traces)
                (output / 'directory-execution.json').write_text(json.dumps(directory_proof, indent=2))
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
                (output / 'backlog.json').write_bytes((base / '.masc/tasks/backlog.json').read_bytes())
                (output / 'health.json').write_text(json.dumps(health, indent=2))
                if args.playwright_module:
                    run('node', str(ROOT / 'scripts/imp-onboarding-browser.cjs'), url,
                        str(base / '.masc/auth/local-admin.token'), str(output),
                        args.playwright_module, args.browser_executable)
                (output / 'receipt.json').write_text(json.dumps(dict(
                    source=run(binary, 'build-commit').strip(), model=args.model,
                    platform=run('uname', '-sm').strip(), fixture_model=False,
                    approval_overrides=False, keeper='imp', completed_chats=len(prompts),
                    successful_tools=sorted(required)), indent=2))
                print('Acceptance evidence:', output, flush=True)
            finally:
                # SSE streams already live in output. Copy raw records even if
                # curl times out, a verdict fails, or browser verification fails.
                try:
                    server.terminate()
                    try:
                        server.wait(timeout=20)
                    except subprocess.TimeoutExpired:
                        server.kill()
                        server.wait()
                finally:
                    snapshot_evidence(base, output)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary', required=True)
    parser.add_argument('--codex-auth', required=True)
    parser.add_argument('--model', required=True)
    parser.add_argument('--context', required=True, type=int)
    parser.add_argument('--work-parent', default=str(Path.home()))
    parser.add_argument('--output', required=True)
    parser.add_argument('--playwright-module')
    parser.add_argument('--browser-executable')
    args = parser.parse_args()
    if bool(args.playwright_module) != bool(args.browser_executable):
        parser.error("--playwright-module and --browser-executable must be supplied together")
    measure(args)
