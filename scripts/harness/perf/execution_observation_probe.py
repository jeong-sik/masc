#!/usr/bin/env python3
"""Measure execution observations against one isolated native server.

Seeds paused Keeper metadata and synthetic Candle grants, never active agents.
Public HTTP reads exercise real metadata/ledger reads; an owned TOML edit checks
fresh Board addresses after the snapshot is cached. No operator workspace or
credentials are used, and any attempted model POST fails the experiment.
"""
import argparse
from collections import Counter
from contextlib import ExitStack
import gzip
import hashlib
import http.client
import http.server
import json
import math
import os
from pathlib import Path
import signal
import shutil
import socket
import subprocess
import tempfile
import threading
import time
import tomllib

from linux_probe_artifact import digest, require
from server_artifact_session import write_json
from checkpoint_history_artifact_session import stop


class CandleWorker:
    """Real package, with Docker resources owned by this private installation."""
    def __init__(self, repo, base, out):
        self.out = out
        self.endpoint = subprocess.check_output(
            ['docker', 'context', 'inspect', '--format', '{{.Endpoints.docker.Host}}'],
            text=True).strip()
        require(self.endpoint.startswith('unix://'), 'a local Docker socket is required')
        self.label = 'masc.lane.state.owner'
        self.owner = json.dumps([str(base/'.masc/lane-addons'),
            json.dumps(['configuration', 'observation-candle'], ensure_ascii=False,
                       separators=(',', ':')),
            'candle-appraiser'], ensure_ascii=False, separators=(',', ':'))
        self.volume = 'masc-lane-state-' + hashlib.sha256(self.owner.encode()).hexdigest()
        package = base/'candle-appraiser'
        shutil.copytree(repo/'addons/candle-appraiser', package)
        manifest = package/'lane.toml'
        original = manifest.read_text()
        requested = tomllib.loads(original)['image']
        image = json.loads(self.docker('image', 'inspect', requested))[0]['Id']
        require(original.count(f'image = "{requested}"') == 1, 'unexpected package image declaration')
        manifest.write_text(original.replace(f'image = "{requested}"', f'image = "{image}"'))
        self.manifest = manifest
        write_json(out/'candle-worker.json', {'docker_endpoint': self.endpoint,
            'image': image, 'requested_image': requested, 'state_owner': self.owner,
            'volume': self.volume, 'package_files': {str(path.relative_to(package)): digest(path)
                for path in sorted(package.rglob('*')) if path.is_file()}})

    def docker(self, *arguments):
        return subprocess.check_output(['docker', '--host', self.endpoint, *arguments], text=True)

    def containers(self):
        ids = self.docker('container', 'ls', '--all', '--quiet', '--no-trunc',
            '--filter', f'label={self.label}={self.owner}').split()
        rows = json.loads(self.docker('container', 'inspect', *ids)) if ids else []
        for row in rows:
            require(row['Config']['Labels'].get(self.label) == self.owner
                    and row['Name'] == '/' + self.volume + '-writer',
                    'Candle container ownership differs; refusing cleanup')
        return rows

    def cleanup(self):
        rows = self.containers()
        for row in rows:
            self.docker('container', 'rm', '--force', row['Id'])
        volumes = self.docker('volume', 'ls', '--quiet', '--filter',
            f'label={self.label}={self.owner}').split()
        for name in volumes:
            require(name == self.volume, 'unexpected owned volume name')
            row = json.loads(self.docker('volume', 'inspect', name))[0]
            require(row['Labels'].get(self.label) == self.owner, 'volume ownership differs')
            self.docker('volume', 'rm', name)
        require(not self.containers(), 'owned Candle container remains')
        require(not self.docker('volume', 'ls', '--quiet', '--filter',
            f'label={self.label}={self.owner}').strip(), 'owned Candle volume remains')
        write_json(self.out/'candle-cleanup.json', {'verified_absent': True,
            'removed_containers': [row['Id'] for row in rows], 'removed_volumes': volumes})


def keeper_rows(document):
    rows = document.get('keepers')
    return rows.get('items') if isinstance(rows, dict) else rows


def observe(document, names, addresses):
    rows = keeper_rows(document)
    require(isinstance(rows, list), 'execution response has no Keeper rows')
    require(len(rows) == len(names) and {row.get('name') for row in rows} == set(names),
            'execution response lost or duplicated seeded Keepers')
    candle = document.get('candle')
    if candle is None and isinstance(document.get('keepers'), dict):
        candle = document['keepers'].get('candle')
    require(isinstance(candle, dict) and candle.get('status') == 'ready',
            'Candle must be enabled, not Off or Disabled')
    projected = []
    for row in rows:
        name = row['name']
        require(row.get('candle_balance_milli') == '1000', 'synthetic wallet differs')
        require(row.get('board_address') == {'state': 'ready', 'target_ids': [addresses[name]]},
                'fresh Board address differs')
        require(isinstance(row.get('candle_account_revision'), str), 'account revision absent')
        require(isinstance(row.get('portrait'), dict), 'portrait observation absent')
        projected.append({key: row[key] for key in (
            'name', 'candle_balance_milli', 'board_address', 'candle_account_revision', 'portrait')})
    return {'candle': candle, 'keepers': sorted(projected, key=lambda row: row['name'])}


def paused_inventory_warming(health):
    # Full health populates this section asynchronously, independently of
    # startup readiness. Only its explicit cold placeholder is retryable;
    # errors, timeouts and completed but mismatching scans still fail below.
    paused = health.get('paused_keepers')
    return (isinstance(paused, dict) and paused.get('status') == 'warming'
            and paused.get('component_timed_out') is False)


def verify_paused_fixture(health, names, root, metadata_hashes):
    require(type(health.get('keeper_fibers')) is int and health['keeper_fibers'] == 0,
            'paused fixture has active or unobserved Keeper fibers')
    paused = health.get('paused_keepers')
    require(isinstance(paused, dict), 'health has no paused Keeper observation')
    paused_names = paused.get('durable_names')
    require(type(paused.get('durable_count')) is int
            and paused['durable_count'] == len(names)
            and isinstance(paused_names, list)
            and all(isinstance(name, str) for name in paused_names)
            and sorted(paused_names) == sorted(names),
            'durable paused Keeper inventory differs from the seeded fixture')
    require(type(paused.get('read_error_count')) is int
            and paused['read_error_count'] == 0 and paused.get('read_errors') == [],
            'paused Keeper metadata could not be observed completely')
    observed_hashes = {}
    for name in names:
        content = (root/'keepers'/f'{name}.json').read_bytes()
        metadata = json.loads(content)
        require(isinstance(metadata, dict) and metadata.get('paused') is True,
                f'seeded Keeper is no longer paused: {name}')
        observed_hashes[name] = hashlib.sha256(content).hexdigest()
        require(observed_hashes[name] == metadata_hashes[name],
                f'seeded Keeper metadata changed: {name}')
    return {'keeper_fibers': health['keeper_fibers'],
            'durable_paused_names': paused['durable_names'],
            'metadata_sha256': observed_hashes}


def run(args):
    out = args.output.resolve()
    repo, binary = args.repo.resolve(), args.binary.resolve()
    binary_hash = digest(binary)
    process = None
    stub = None
    connection = None
    env = {'PATH': os.environ['PATH'], 'LANG': 'C.UTF-8',
           'MASC_CONFIG_BOOTSTRAP': 'skip', 'MASC_KEEPER_AUTONOMOUS_ENABLED': '0',
           'MASC_ORCHESTRATOR_ENABLED': '0', 'MASC_GRPC_ENABLED': '0', 'MASC_WS_ENABLED': '0',
           'MASC_HTTP_AUTH_STRICT': '0', 'MASC_OTEL_ENABLED': '0'}
    model_requests = []
    records = []
    result = None

    class ModelStub(http.server.BaseHTTPRequestHandler):
        def reply(self):
            model_requests.append({'method': self.command, 'path': self.path})
            self.send_response(503)
            self.send_header('Content-Length', '0')
            self.end_headers()
        do_GET = reply
        do_POST = reply
        def log_message(self, *_args):
            pass

    try:
        with tempfile.TemporaryDirectory(prefix='masc-execution-observation-') as temporary, ExitStack() as owned:
            base = Path(temporary).resolve()
            root = base / '.masc'
            config = root / 'config'
            for path in [config/'keepers', config/'prompts', config/'lane-addons', root/'keepers']:
                path.mkdir(parents=True, exist_ok=True)
            env.update(MASC_BASE_PATH=str(base), MASC_CONFIG_DIR=str(config))
            source = subprocess.check_output([str(binary), 'build-commit'], env=env, text=True).strip()
            require(source == args.source_sha, 'binary source does not match requested SHA')
            worker = CandleWorker(repo, base, out)
            owned.callback(worker.cleanup)
            env['DOCKER_HOST'] = worker.endpoint
            (config/'lane-addons/candle.toml').write_text(
                'id = "observation-candle"\nrun_id = "observation-measurement"\n'
                f'manifest_path = {json.dumps(str(worker.manifest))}\n'
                'exact_outputs = []\n[binding]\nsources = []\n')
            stub = http.server.ThreadingHTTPServer(('127.0.0.1', 0), ModelStub)
            thread = threading.Thread(target=stub.serve_forever, daemon=True)
            thread.start()
            fixture = repo / 'test/fixtures/item-http'
            runtime = (fixture/'runtime.toml').read_text()
            require(runtime.count('http://127.0.0.1:9/v1') == 1, 'unexpected runtime fixture')
            (config/'runtime.toml').write_text(runtime.replace('http://127.0.0.1:9/v1',
                f'http://127.0.0.1:{stub.server_port}/v1'))
            (config/'candle.toml').write_bytes((fixture/'candle.toml').read_bytes())
            template = json.loads((fixture/'keeper.json').read_text())
            require(template.get('paused') is True, 'Keeper fixture metadata must be paused')
            declaration = (fixture/'keeper.toml').read_text()
            names = [f'observation-{i:04d}' for i in range(args.keepers)]
            addresses = {name: f'route-{name}' for name in names}
            metadata_hashes = {}
            at = '1970-01-01T00:00:01Z'
            ledger = [{'kind': 'half_life_set', 'at': at, 'half_life': 'off'}]
            for name in names:
                metadata = {**template, 'name': name, 'trace_id': f'trace-{name}'}
                metadata_path = root/'keepers'/f'{name}.json'
                write_json(metadata_path, metadata)
                metadata_hashes[name] = digest(metadata_path)
                (config/'keepers'/f'{name}.toml').write_text(
                    declaration + f'\nmention_targets = ["{addresses[name]}"]\n')
                ledger.append({'kind': 'granted', 'at': at, 'keeper': name,
                               'amount_milli': 1000, 'reason': 'synthetic performance fixture'})
            ledger_path = root/'candle-ledger.jsonl'
            ledger_path.write_text(''.join(json.dumps(event) + '\n' for event in ledger))
            ledger_path.chmod(0o600)
            ledger_hash = digest(ledger_path)
            write_json(out/'fixture.json', {'names': names, 'addresses': addresses,
                'metadata_template': template, 'declaration_template': declaration,
                'metadata_sha256': metadata_hashes,
                'ledger': ledger, 'input_hashes': {name: digest(fixture/name) for name in
                    ('runtime.toml', 'candle.toml', 'keeper.toml', 'keeper.json')}})
            with socket.socket() as reservation:
                reservation.bind(('127.0.0.1', 0))
                port = reservation.getsockname()[1]
            require(port != 8935 and port != stub.server_port, 'invalid private server port')
            with (out/'server.log').open('wb') as log, (out/'requests.jsonl').open('w') as receipts:
                process = subprocess.Popen([str(binary), '--host', '127.0.0.1', '--base-path',
                    str(base), '--port', str(port)], cwd=base, env=env, stdout=log, stderr=log,
                    start_new_session=True)
                # Reap before the temporary workspace is removed, including
                # validation failures. The outer finally also covers an
                # interruption between process creation and registration.
                owned.callback(stop, process)
                connection = http.client.HTTPConnection('127.0.0.1', port, timeout=30)

                def request(path, phase, ordinal=None, ready_check=False):
                    started = time.monotonic_ns()
                    unix_start = time.time()
                    connection.request('GET', path, headers={
                        'Accept': 'application/json', 'Accept-Encoding': args.encoding})
                    response = connection.getresponse()
                    headers_at = time.monotonic_ns()
                    wire = response.read()
                    finished = time.monotonic_ns()
                    headers = {k.lower(): v for k, v in response.getheaders()}
                    encoding = headers.get('content-encoding', 'identity')
                    require(encoding == 'identity' or encoding == args.encoding == 'gzip',
                            'server returned an unrequested encoding')
                    raw = gzip.decompress(wire) if encoding == 'gzip' else wire
                    row = {'phase': phase, 'ordinal': ordinal, 'path': path,
                        'status': response.status, 'unix_start': unix_start,
                        'elapsed_ms': (finished-started)/1e6, 'headers_ms': (headers_at-started)/1e6,
                        'wire_bytes': len(wire), 'json_bytes': len(raw), 'encoding': encoding,
                        'etag': headers.get('etag'), 'server_timing': headers.get('server-timing'),
                        'body_sha256': hashlib.sha256(raw).hexdigest(), 'body': raw.decode()}
                    receipts.write(json.dumps(row) + '\n'); receipts.flush()
                    records.append(row)
                    if ready_check and response.status == 503:
                        return None
                    require(response.status == 200, f'HTTP {response.status} at {path}')
                    return json.loads(raw)

                deadline = time.monotonic() + 120
                while True:
                    require(process.poll() is None, 'owned server exited before readiness')
                    try:
                        health = request('/health?full=1', 'readiness', ready_check=True)
                        if health is not None:
                            require(health['paths']['effective_base_path'] == str(base)
                                    and health['build']['binary_commit'] == args.source_sha,
                                    'private listener identity differs')
                            if (health.get('startup', {}).get('state_ready')
                                    and not paused_inventory_warming(health)):
                                break
                    except (OSError, http.client.HTTPException):
                        connection.close()
                    require(time.monotonic() < deadline, 'owned server readiness deadline')
                    time.sleep(.2)
                write_json(out/'health-before.json', health)
                write_json(out/'paused-fixture-before.json',
                    verify_paused_fixture(health, names, root, metadata_hashes))
                instance = health['build']['runtime_instance_id']
                write_json(out/'identity.json', {'source': source, 'binary_sha256': binary_hash,
                    'runtime_instance': instance, 'base': str(base), 'port': port,
                    'keepers': args.keepers, 'samples': args.samples, 'interval_s': args.interval,
                    'encoding': args.encoding, 'driver_sha256': digest(Path(__file__)),
                    'scope': __doc__, 'environment_keys': sorted(env), 'load_before': os.getloadavg()})
                while True:
                    warm = request('/api/v1/dashboard/execution?force=true', 'warmup')
                    candle = warm.get('candle', warm.get('keepers', {}).get('candle')
                        if isinstance(warm.get('keepers'), dict) else None)
                    if isinstance(candle, dict) and candle.get('status') == 'ready':
                        break
                    require(time.monotonic() < deadline, 'Candle worker readiness deadline')
                    time.sleep(.2)
                containers = worker.containers()
                require(len(containers) == 1 and containers[0]['State']['Running'],
                        'real Candle worker is not running')
                write_json(out/'candle-container.json', containers[0])
                initial_observation = observe(warm, names, addresses)
                canonical = json.dumps(initial_observation, sort_keys=True)
                write_json(out/'observation-before.json', initial_observation)
                for phase in ('unchanged', 'address_changed'):
                    if phase == 'address_changed':
                        first = names[0]
                        addresses[first] = 'updated-' + addresses[first]
                        target = config/'keepers'/f'{first}.toml'
                        replacement = target.with_suffix('.new')
                        replacement.write_text(declaration + f'\nmention_targets = ["{addresses[first]}"]\n')
                        replacement.replace(target)
                    for ordinal in range(args.samples):
                        time.sleep(args.interval)
                        document = request('/api/v1/dashboard/execution', phase, ordinal)
                        observed = observe(document, names, addresses)
                        if phase == 'unchanged':
                            require(json.dumps(observed, sort_keys=True) == canonical,
                                    'visible authority changed during unchanged samples')
                final_health = request('/health?full=1', 'closing')
                write_json(out/'health-after.json', final_health)
                write_json(out/'paused-fixture-after.json',
                    verify_paused_fixture(final_health, names, root, metadata_hashes))
                require(final_health['build']['runtime_instance_id'] == instance,
                        'runtime changed during measurements')
                require(digest(binary) == binary_hash, 'binary file changed during measurements')
                require(digest(ledger_path) == ledger_hash, 'reads modified the Candle ledger')
                result = {'semantic_checks_passed': True,
                    'paused_fixture_verified_before_and_after': True,
                    'target_ms': .1, 'phases': {}}
                for phase in ('unchanged', 'address_changed'):
                    rows = [row for row in records if row['phase'] == phase]
                    times = sorted(row['elapsed_ms'] for row in rows)
                    result['phases'][phase] = {'samples': len(rows),
                        'p50_ms': times[math.ceil(.5*len(times))-1],
                        'p95_ms': times[math.ceil(.95*len(times))-1], 'max_ms': times[-1],
                        'all_within_target': all(value <= .1 for value in times),
                        'encodings': dict(Counter(row['encoding'] for row in rows)),
                        'unique_body_hashes': len({row['body_sha256'] for row in rows})}
    finally:
        if connection is not None:
            connection.close()
        try:
            if process is not None:
                stop(process)
        finally:
            if stub is not None:
                stub.shutdown(); stub.server_close(); thread.join(timeout=5)
            write_json(out/'cleanup.json', {'server_reaped': process is None or process.poll() is not None,
                'server_returncode': None if process is None else process.returncode,
                'model_requests': model_requests})
    require(process is not None and process.returncode == 0, 'server did not stop cleanly')
    require(all(row['method'] == 'GET' for row in model_requests), 'unexpected model POST')
    write_json(out/'summary.json', result)
    print(json.dumps(result, indent=2))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary', type=Path, required=True)
    parser.add_argument('--source-sha', required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--repo', type=Path, default=Path(__file__).resolve().parents[3])
    parser.add_argument('--keepers', type=int, default=35)
    parser.add_argument('--samples', type=int, default=10)
    parser.add_argument('--interval', type=float, default=1.1)
    parser.add_argument('--encoding', choices=('identity', 'gzip'), default='gzip')
    args = parser.parse_args()
    require(args.keepers > 0 and args.samples > 0 and args.interval > 1,
            'positive Keeper/sample counts and interval > one Candle clock second required')
    def terminate(signum, _frame):
        raise SystemExit(128+signum)
    signal.signal(signal.SIGTERM, terminate)
    # Enter the failure-writing scope only after this invocation has created
    # its output directory. An existing evidence folder must remain untouched.
    args.output = args.output.resolve()
    args.output.mkdir(parents=True, exist_ok=False)
    try:
        run(args)
    except BaseException as error:
        write_json(args.output/'failure.json', {'type': type(error).__name__, 'message': str(error)})
        raise


if __name__ == '__main__':
    main()
