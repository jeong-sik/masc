"""Measure the checkpoint inventory route in an owned, provider-free server.

Synthetic valid v11 snapshots exercise directory scan/filter/sort and the real
inventory consumer. This does not measure vision or the full #25893 scope.
"""
import argparse
from contextlib import ExitStack
from concurrent.futures import ThreadPoolExecutor
import hashlib
import http.client
import json
import os
from pathlib import Path
import signal
import socket
import subprocess
import tempfile
import threading
import time

from linux_probe_artifact import digest, require
from server_artifact_session import write_json

NAME = 'checkpoint-measurement'
TRACE = 'trace-checkpoint-measurement'


def metadata():
    row = {key: 0 for key in (
        'total_turns total_input_tokens total_output_tokens total_tokens total_cost_usd '
        'last_turn_ts last_input_tokens last_output_tokens last_total_tokens last_latency_ms '
        'proactive_count_total last_proactive_ts proactive_visible_count_total '
        'last_visible_proactive_ts').split()}
    row.update({key: None for key in (
        'usage_cursor last_usage_resolution message_scope_ack_id last_runtime_attempt '
        'latched_reason current_task_id keeper_id').split()})
    row.update(schema='masc.keeper_meta.v2', name=NAME, trace_id=TRACE,
               instructions='Synthetic checkpoint inventory fixture; never start this Keeper.',
               created_at='2001-09-09T01:46:40Z', updated_at='2001-09-09T01:46:40Z',
               last_proactive_outcome='never_started', last_proactive_reason='',
               last_proactive_preview='', paused=True, agent_core_env={})
    return row


def checkpoint(n):
    value = {key: None for key in (
        'system_prompt tool_choice temperature top_p top_k min_p enable_thinking '
        'preserve_thinking reasoning_effort working_context').split()}
    usage = {key: 0 for key in (
        'total_input_tokens total_output_tokens total_cache_creation_input_tokens '
        'total_cache_read_input_tokens api_calls estimated_cost_usd').split()}
    usage['pricing_gap'] = None
    usage['estimated_cost_usd'] = 0.0
    value.update(version=11, session_id=TRACE, agent_name=NAME, model='test-model',
                 messages=[], usage=usage, turn_count=n, created_at=(1000000000000+n)/1000.,
                 tools=[], disable_parallel_tool_use=False, cache_system_prompt=False,
                 context={}, mcp_sessions=[], response_format={'type': 'off'})
    return json.dumps(value, sort_keys=True).encode()


def seed(base, history_count, noise_count):
    root = base / '.masc'
    (root / 'keepers').mkdir(exist_ok=True)
    write_json(root / 'keepers' / (NAME + '.json'), metadata())
    directory = root / 'traces' / TRACE
    directory.mkdir(parents=True)
    manifest = []
    # Reverse creation order relative to the required newest-first output.
    for n in range(history_count):
        name = f'agent-core-snapshot-{1000000000000+n:013d}.json'
        content = checkpoint(n)
        (directory / name).write_bytes(content)
        manifest.append([name, hashlib.sha256(content).hexdigest()])
    for n in range(noise_count):
        name = f'non-history-{n:08d}.txt'
        (directory / name).write_bytes(b'')
        manifest.append([name, hashlib.sha256(b'').hexdigest()])
    return directory, sorted(manifest)


def stop(process):
    if process.poll() is None:
        os.killpg(process.pid, signal.SIGTERM)
        try:
            process.wait(timeout=15)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGKILL)
            process.wait()
            raise RuntimeError('owned process required SIGKILL')


def run(args):
    out = args.output.resolve()
    out.mkdir(parents=True, exist_ok=False)
    identity = json.loads((args.artifact / 'identity.json').read_text())
    binary = (args.artifact / 'main_eio.exe').resolve()
    require(digest(binary) == identity['sha256']['main_eio.exe'], 'binary identity changed')
    repo = args.repo.resolve()
    # Explicit loopback-only provider fixture, with no credentials from the host.
    fixture = (repo / 'scripts/fixtures/release-evidence/runtime.toml').read_text()
    env = {'PATH': os.environ['PATH'], 'LANG': 'C.UTF-8',
           'MASC_KEEPER_AUTONOMOUS_ENABLED': 'false', 'MASC_ORCHESTRATOR_ENABLED': 'false',
           'MASC_GRPC_ENABLED': '0', 'MASC_WS_ENABLED': '0', 'MASC_CONFIG_BOOTSTRAP': 'skip',
           'MASC_RUNTIME_EVENTS': 'true'}
    processes = []
    with tempfile.TemporaryDirectory(prefix='masc-checkpoint-measurement-') as temporary:
        base = Path(temporary)
        config = base / '.masc/config'
        (config / 'keepers').mkdir(parents=True)
        (config / 'prompts').mkdir()
        (config / 'runtime.toml').write_text(fixture)
        directory, manifest = seed(base, args.histories, args.noise)
        write_json(out / 'fixture.json', {'files': manifest, 'metadata': metadata()})
        fixture_digest = digest(out / 'fixture.json')
        env.update(MASC_BASE_PATH=str(base), MASC_CONFIG_DIR=str(config),
                   OCAML_RUNTIME_EVENTS_DIR=str(base))
        with socket.socket() as sock:
            sock.bind(('127.0.0.1', 0))
            port = sock.getsockname()[1]
        require(port != 8935, 'refusing the production port')
        with ExitStack() as handles:
            try:
                command = [str(binary), '--base-path', str(base), '--host', '127.0.0.1', '--port', str(port)]
                log = handles.enter_context((out / 'server.log').open('wb'))
                process = subprocess.Popen(command, cwd=base, env=env, stdout=log, stderr=log, start_new_session=True)
                processes.append(process)
                write_json(out / 'identity.json', {**identity, 'command': command, 'pid': process.pid,
                    'environment': env, 'fixture_sha256': fixture_digest,
                    'config_sha256': digest(config / 'runtime.toml'), 'utc_start': time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime()),
                    'driver_sha256': digest(Path(__file__)), 'histories': args.histories, 'noise': args.noise,
                    'cycles': args.cycles, 'interval_s': args.interval, 'load_before': os.getloadavg()})
                receipts = handles.enter_context((out / 'requests.jsonl').open('w'))
                token = None
                receipt_lock = threading.Lock()

                def request(path, record=True):
                    headers = {'Accept': 'application/json', 'Accept-Encoding': 'identity'}
                    if token:
                        headers['Authorization'] = 'Bearer ' + token
                    connection = http.client.HTTPConnection('127.0.0.1', port, timeout=30)
                    start_unix = time.time()
                    start = time.monotonic_ns()
                    try:
                        connection.request('GET', path, headers=headers)
                        response = connection.getresponse()
                        body = response.read()
                        end = time.monotonic_ns()
                        if record:
                            with receipt_lock:
                                receipts.write(json.dumps({'path': path, 'status': response.status,
                                    'start_unix': start_unix, 'end_unix': time.time(),
                                    'start_ns': start, 'end_ns': end, 'elapsed_ms': (end-start)/1e6,
                                    'body': body.decode()}) + '\n')
                                receipts.flush()
                        require(response.status == 200, f'{path}: HTTP {response.status}')
                        return json.loads(body)
                    finally:
                        connection.close()

                deadline = time.monotonic() + 120
                while True:
                    require(process.poll() is None, 'server exited before readiness')
                    try:
                        health = request('/health?full=1', record=False)
                        if health.get('startup', {}).get('state_ready'):
                            break
                    except (OSError, TimeoutError, http.client.HTTPException, ValueError):
                        pass
                    require(time.monotonic() < deadline, 'server readiness deadline')
                    time.sleep(.2)
                write_json(out / 'health-before.json', health)
                require(health['paths']['effective_masc_root'] == str(base / '.masc')
                        and health['build']['binary_commit'] == identity['source']
                        and health['build']['executable_sha256'] == identity['sha256']['main_eio.exe']
                        and health['keeper_fibers'] == 0, 'runtime identity/isolation mismatch')
                token = request('/api/v1/dashboard/dev-token', record=False)['token']
                expected = sorted((name for name, _ in manifest if name.startswith('agent-core-')), reverse=True)
                duration = args.cycles * args.interval
                for name in ('rtev_fibers', 'rtev_watch'):
                    tracer = (args.tracers / (name + '.exe')).resolve()
                    command = [str(tracer), str(base), str(process.pid), str(duration)]
                    write_json(out / (name + '-command.json'), {'argv': command, 'sha256': digest(tracer)})
                    output = handles.enter_context((out / (name + '.txt')).open('wb'))
                    processes.append(subprocess.Popen(command, stdout=output, stderr=output, start_new_session=True))
                ready_deadline = time.monotonic() + 30
                for index, name in enumerate(('rtev_fibers', 'rtev_watch'), 1):
                    while not (out / (name + '.txt')).read_text().startswith(f'ready pid={process.pid} '):
                        require(processes[index].poll() is None, 'tracer exited before readiness')
                        require(time.monotonic() < ready_deadline, 'tracer readiness deadline')
                        time.sleep(.01)
                executor = handles.enter_context(ThreadPoolExecutor(max_workers=2))
                probe_command = ['bash', str(repo / 'scripts/harness/perf/scheduler_lag_probe.sh')]
                probe_env = {**env, 'MASC_URL': f'http://127.0.0.1:{port}',
                             'PROBES': '30', 'GAP_S': '1', 'RATE_WINDOW_S': '10',
                             'CURL_MAX_S': '30'}
                write_json(out / 'scheduler-probe-command.json', {'argv': probe_command,
                    'MASC_URL': probe_env['MASC_URL'], 'PROBES': 30, 'GAP_S': 1,
                    'RATE_WINDOW_S': 10, 'CURL_MAX_S': 30})
                probe_output = handles.enter_context((out / 'scheduler-probe.txt').open('wb'))
                probe = subprocess.Popen(probe_command, env=probe_env, cwd=repo,
                    stdout=probe_output, stderr=probe_output, start_new_session=True)
                processes.append(probe)
                # The scheduler owns its measurement window independently of
                # the checkpoint workload and its runtime-event readers.
                probes = int(probe_env['PROBES'])
                probe_deadline = (time.monotonic()
                    + probes * float(probe_env['GAP_S'])
                    + float(probe_env['RATE_WINDOW_S'])
                    + (probes + 2) * float(probe_env['CURL_MAX_S']))
                start = time.monotonic()
                for cycle in range(args.cycles):
                    time.sleep(max(0, start + cycle * args.interval - time.monotonic()))
                    barrier = threading.Barrier(2)
                    def concurrent_request(path):
                        barrier.wait(timeout=10)
                        return request(path)
                    inventory_request = executor.submit(concurrent_request, f'/api/v1/keepers/{NAME}/checkpoints')
                    health_request = executor.submit(concurrent_request, '/health')
                    inventory = inventory_request.result()
                    health_request.result()
                    require(inventory['trace_id'] == TRACE and inventory['history_errors'] == [], 'invalid fixture inventory')
                    require([row['snapshot_id'] for row in inventory['history']] == expected
                            and all(row['status'] == 'available' for row in inventory['history']),
                            'scan did not return every valid snapshot in order')
                require(time.monotonic() - start <= duration, 'workload exceeded the trace window')
                for tracer in processes[1:-1]:
                    require(tracer.wait(timeout=30) == 0, 'runtime-events consumer failed')
                require(probe.wait(timeout=max(0, probe_deadline - time.monotonic())) == 0,
                        'scheduler probe failed')
                after = request('/health?full=1')
                write_json(out / 'health-after.json', after)
                require(after['keeper_fibers'] == 0, 'unexpected Keeper started')
                actual = [[name, digest(directory / name)] for name, _ in manifest]
                require(actual == manifest, 'fixture changed during measurement')
                write_json(out / 'files-after.json', sorted(p.name for p in directory.iterdir()))
                write_json(out / 'completed.json', {'cycles': args.cycles, 'fixture_sha256': fixture_digest,
                    'elapsed_s': time.monotonic()-start, 'load_after': os.getloadavg(),
                    'scope': 'checkpoint inventory scan/filter/sort and valid snapshot decode; not vision or all of #25893'})
            finally:
                failures = []
                for child in reversed(processes):
                    try:
                        stop(child)
                    except (OSError, RuntimeError) as error:
                        failures.append(str(error))
                write_json(out / 'cleanup.json', {'all_exited': all(p.poll() is not None for p in processes),
                                                'errors': failures})
                require(not failures, 'owned-process cleanup failed')


def main():
    p = argparse.ArgumentParser(description=__doc__)
    for name in ('artifact', 'repo', 'tracers', 'output'):
        p.add_argument('--' + name, type=Path, required=True)
    p.add_argument('--histories', type=int, default=128)
    p.add_argument('--noise', type=int, default=8192)
    p.add_argument('--cycles', type=int, default=90)
    p.add_argument('--interval', type=float, default=1)
    args = p.parse_args()
    require(args.histories > 0 and args.noise >= 0 and args.cycles > 0 and args.interval > 0, 'invalid workload')
    def interrupted(_signal, _frame):
        raise KeyboardInterrupt
    signal.signal(signal.SIGTERM, interrupted)
    run(args)


if __name__ == '__main__':
    main()
