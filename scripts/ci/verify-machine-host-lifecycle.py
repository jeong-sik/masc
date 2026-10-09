#!/usr/bin/env python3
"""Remote Linux CI proof of real host attachment; uses only synthetic media."""
import argparse
import base64
import hashlib
import http.server
import json
import os
import re
from pathlib import Path
import socket
import subprocess
import tempfile
import threading
import time
import tomllib
import urllib.error
import urllib.parse
import urllib.request



def digest(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def command(args, **kwargs):
    return subprocess.check_output(args, text=True, timeout=90, **kwargs).strip()


def wait_for(label, read, accept, server):
    # CI observation deadline, never a production machine/agent lifetime policy.
    deadline = time.monotonic() + 90
    while True:
        if server.poll() is not None:
            raise RuntimeError('host exited during ' + label)
        value = read()
        if accept(value):
            return value
        if time.monotonic() >= deadline:
            raise TimeoutError(label + ': last observation ' + repr(value))
        time.sleep(0.25)


class Sink(http.server.BaseHTTPRequestHandler):
    requests = []

    def do_POST(self):
        self.requests.append({'method': 'POST', 'path': self.path})
        self.send_response(503)
        self.end_headers()

    def do_GET(self):
        self.requests.append({'method': 'GET', 'path': self.path})
        self.send_response(503)
        self.end_headers()

    def log_message(self, *_args):
        pass


class Host:
    def __init__(self, port, token, artifact):
        self.url = 'http://127.0.0.1:' + str(port)
        self.token, self.artifact = token, artifact
        self.session = None
        self.version = None
        self.sequence = 0
        self.journal = (artifact / 'http.jsonl').open('w')

    def http(self, path, payload=None, *, rpc_id=None):
        headers = {'Authorization': 'Bearer ' + self.token,
                   'Accept': 'application/json, text/event-stream'}
        if self.session:
            headers['Mcp-Session-Id'] = self.session
        if self.version:
            headers['MCP-Protocol-Version'] = self.version
        data = None if payload is None else json.dumps(payload).encode()
        if data is not None:
            headers['Content-Type'] = 'application/json'
        request = urllib.request.Request(self.url + path, data=data, headers=headers)
        try:
            response = urllib.request.urlopen(request, timeout=30)
        except urllib.error.HTTPError as error:
            response = error
        with response:
            status = response.status
            session = response.headers.get('Mcp-Session-Id')
            if session:
                self.session = session
            if 'text/event-stream' in response.headers.get('Content-Type', ''):
                value = None
                event = []
                for raw in response:
                    line = raw.decode().rstrip('\r\n')
                    if line.startswith('data:'):
                        event.append(line[5:].lstrip())
                    elif not line and event:
                        item = json.loads('\n'.join(event))
                        event = []
                        if rpc_id is not None and item.get('id') == rpc_id:
                            value = item
                            break
                if value is None:
                    raise RuntimeError('SSE ended without matching response')
            else:
                body = response.read()
                value = json.loads(body) if body else None
        # Credentials/session headers are deliberately never serialized.
        self.journal.write(json.dumps({'path': path, 'request': payload,
                                      'status': status, 'response': value}) + '\n')
        self.journal.flush()
        return status, value

    def rpc(self, method, params):
        self.sequence += 1
        status, value = self.http('/mcp', {'jsonrpc': '2.0', 'id': self.sequence,
            'method': method, 'params': params}, rpc_id=self.sequence)
        assert status == 200 and value['id'] == self.sequence, (status, value)
        assert 'error' not in value, value
        return value['result']

    def tools(self):
        names, cursor, seen = set(), None, set()
        while True:
            page = self.rpc('tools/list', {} if cursor is None else {'cursor': cursor})
            for tool in page['tools']:
                assert tool['name'] not in names, 'duplicate tool name'
                names.add(tool['name'])
            cursor = page.get('nextCursor')
            if cursor is None:
                return names
            assert cursor not in seen, 'pagination cycle'
            seen.add(cursor)

    def call(self, machine, operation, arguments=None):
        value = self.rpc('tools/call', {'name': 'masc_' + machine + '_' + operation,
                                      'arguments': arguments or {}})
        assert value.get('isError') is not True, value
        return value

    def api(self, path, payload=None):
        status, value = self.http('/api/v1/lane-addons' + path, payload)
        assert status == 200, (status, value)
        return value

    def inspect(self, ident):
        result = self.api('?' + urllib.parse.urlencode({'instance_id': ident}))
        matches = [i for i in result['instances'] if i['instance_id'] == ident]
        assert len(matches) == 1, result
        if matches[0]['phase']['kind'] == 'failed':
            raise RuntimeError(str(matches[0]['phase']))
        return matches[0]

    def live(self, machine):
        return self.http('/api/v1/lane-addons/live?source_kind=' + machine + '_capture')


def png(host, machine, suffix):
    result = host.call(machine, 'screen')
    pictures = [i for i in result['content'] if i['type'] == 'image']
    assert len(pictures) == 1 and pictures[0]['mimeType'] == 'image/png'
    content = base64.b64decode(pictures[0]['data'], validate=True)
    assert content.startswith(b'\x89PNG\r\n\x1a\n')
    (host.artifact / (machine + '-' + suffix + '.png')).write_bytes(content)
    return result['structuredContent']


def absent(host, machine):
    status, value = host.live(machine)
    assert status == 503, (status, value)
    # A generic observation failure is insufficient: require the explicit absence.
    assert value == {'code': 'machine_observation_unavailable',
                     'error': 'No attached shared machine worker is available'}, value


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--source', type=Path, required=True)
    parser.add_argument('--expected-source', required=True)
    parser.add_argument('--artifact', type=Path, required=True)
    args = parser.parse_args()
    source, artifact = args.source.resolve(), args.artifact.resolve()
    artifact.mkdir(parents=True, exist_ok=False)
    assert re.fullmatch(r'[0-9a-f]{40}', args.expected_source), 'expected-source must be a full lowercase SHA'
    assert command(['git', '-C', str(source), 'rev-parse', 'HEAD']) == args.expected_source
    binary = source / '_build/default/bin/main_eio.exe'
    receipt = {'source_commit': args.expected_source, 'workflow_commit': os.environ.get('GITHUB_SHA'),
               'workflow_run_id': os.environ.get('GITHUB_RUN_ID'),
               'host_sha256': digest(binary), 'checks': [], 'instances': {},
               'scope': 'Native host public tool and active-context lifecycle; not Keeper prompt injection, installation reconciliation, deployment or game play'}
    manifests = {m: tomllib.loads((source / 'addons' / (m + '-machine') / 'lane.toml').read_text())
                 for m in ('msx', 'dos')}
    exports = {m: set(v['world']['tools']['export']) for m, v in manifests.items()}
    all_exports = exports['msx'] | exports['dos']
    assert exports['msx'].isdisjoint(exports['dos'])
    # All images are built from the same explicit source before this probe.
    for machine, manifest in manifests.items():
        meta, = json.loads(command(['docker', 'image', 'inspect', manifest['image']]))
        assert meta['Architecture'] == 'amd64'
        assert meta['Config']['Labels']['org.opencontainers.image.revision'] == args.expected_source
        receipt.setdefault('images', {})[machine] = meta['Id']
        receipt.setdefault('workers', {})[machine] = {
            'sha256': digest(source / 'addons' / ('masc-' + machine + '-addon-worker')),
            'manifest_sha256': digest(source / 'addons' / (machine + '-machine') / 'lane.toml')}
    with tempfile.TemporaryDirectory(prefix='masc-host-lifecycle-') as temporary:
        base = Path(temporary).resolve()
        raw_log = base / 'host.raw.log'
        bootstrap = source / 'scripts/harness/lib/server_bootstrap.sh'
        env = {key: os.environ[key] for key in ('PATH', 'HOME', 'LANG', 'TMPDIR') if key in os.environ}
        env.update({'MASC_BASE_PATH': str(base), 'MASC_CONFIG_DIR': str(base / '.masc/config'),
                    'MASC_KEEPER_AUTONOMOUS_ENABLED': '0', 'MASC_ORCHESTRATOR_ENABLED': '0',
                    'MASC_OTEL_ENABLED': '0'})
        command(['bash', '-c', 'source "$1"; harness_seed_server_config "$2" "$3"',
                 'seed', str(bootstrap), str(source), str(base)], env=env)
        sink = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Sink)
        thread = threading.Thread(target=sink.serve_forever, daemon=True)
        thread.start()
        runtime = base / '.masc/config/runtime.toml'
        contents = runtime.read_text()
        assert contents.count('http://127.0.0.1:9/v1') == 1
        runtime.write_text(contents.replace('http://127.0.0.1:9/v1',
                           'http://127.0.0.1:' + str(sink.server_port) + '/v1'))
        with socket.socket() as reservation:
            reservation.bind(('127.0.0.1', 0))
            port = reservation.getsockname()[1]
        host, token, server = None, '', None
        identities = {}
        log = raw_log.open('wb')
        try:
            server = subprocess.Popen([str(binary), '--host', '127.0.0.1', '--port', str(port),
                '--base-path', str(base)], env=env, cwd=base, stdout=log, stderr=subprocess.STDOUT)
            def ready():
                try:
                    with urllib.request.urlopen('http://127.0.0.1:' + str(port) + '/health/ready', timeout=2) as response:
                        return response.status == 200
                except (urllib.error.URLError, TimeoutError):
                    return False
            wait_for('host readiness', ready, bool, server)
            token = command(['bash', '-c', 'source "$1"; harness_mint_admin_token "$2" "$3" "$4" "$5"',
                'login', str(bootstrap), str(binary), str(port), str(base), 'host-proof-admin'], env=env)
            assert token and '\n' not in token
            host = Host(port, token, artifact)
            initialized = host.rpc('initialize', {'protocolVersion': '2025-11-25',
                'clientInfo': {'name': 'machine-host-proof', 'version': '1'}, 'capabilities': {}})
            host.version = initialized['protocolVersion']
            status, _ = host.http('/mcp', {'jsonrpc': '2.0', 'method': 'notifications/initialized'})
            assert status in (200, 202, 204)
            baseline = host.tools()
            assert not (baseline & all_exports)
            for machine in manifests:
                absent(host, machine)
            receipt['checks'].append('detached_tools_and_active_context_absent')
            active = set()
            for machine, manifest in manifests.items():
                attached = host.api('/attach', {'manifest_path': str(source / 'addons' / (machine + '-machine') / 'lane.toml'),
                    'run_id': 'host-proof-' + machine, 'binding': {'sources': []}})
                ident = attached['instance_id']
                owner = [str(base / '.masc/lane-addons'),
                         json.dumps(['manual', ident], separators=(',', ':')), manifest['id']]
                identities[machine] = {'instance_id': ident, 'owner': owner}
                entry = wait_for('attach ' + machine, lambda: host.inspect(ident),
                    lambda e: e['phase']['kind'] in ('attached', 'observing') and e['observation_seq'] > 0, server)
                container = entry['container_id']
                identities[machine]['container_id'] = container
                meta, = json.loads(command(['docker', 'container', 'inspect', container]))
                assert meta['Config']['Labels']['masc.lane.instance'] == ident
                assert meta['Image'] == receipt['images'][machine]
                assert meta['State']['Running'] is True
                mount, = [m for m in meta['Mounts'] if m['Destination'] == '/state']
                assert mount['Type'] == 'volume'
                volume = mount['Name']
                volume_meta, = json.loads(command(['docker', 'volume', 'inspect', volume]))
                assert json.loads(volume_meta['Labels']['masc.lane.state.owner']) == owner
                identities[machine].update({'volume': volume, 'owner': owner})
                receipt['instances'][machine] = dict(identities[machine])
                active |= exports[machine]
                assert host.tools() == baseline | active
                if machine == 'msx':
                    absent(host, 'dos')
                else:
                    # An idle worker has no loaded guest. Provision only this owned new volume.
                    fixture = bytes.fromhex('b409ba0d01cd21b400cd16ebfa') + b'HI$'
                    subprocess.run(['docker', 'exec', '-i', container, 'sh', '-c',
                        'mkdir -p /state/.masc/dos/programs && cat > /state/.masc/dos/programs/hello.com'],
                        input=fixture, check=True, timeout=30)
                host.call(machine, 'load', {'roms_dir': ''} if machine == 'msx' else {'program': 'hello.com'})
                before = png(host, machine, 'before')
                if machine == 'msx':
                    host.call(machine, 'step', {'frames': 1})
                else:
                    assert 'HI' in before['screen_text']
                    assert before['controller'] == 'host-proof-admin'
                    host.call(machine, 'press', {'keys': ['space']})
                after = png(host, machine, 'after')
                clock = 'frame' if machine == 'msx' else 'steps'
                assert after[clock] > before[clock]
                # Explicit public refresh; no direct access to worker control ports.
                host.api('/observe', {'instance_id': ident})
                def context():
                    snapshot = host.api('?' + urllib.parse.urlencode({'instance_id': ident}))
                    return snapshot, host.live(machine)
                def current_context(value):
                    snapshot, (status, live) = value
                    rows = snapshot['rows']
                    return (status == 200 and live.get('state') == 'changed'
                        and not live.get('refreshing') and len(rows) == 1
                        and rows[0]['clock']['value'] == str(after[clock])
                        and snapshot['instances'][0]['observation_seq'] == live['observation_seq'])
                snapshot, (status, live) = wait_for('live ' + machine, context, current_context, server)
                assert status == 200 and live['source_kind'] == machine + '_capture'
                row, = snapshot['rows']
                assert row['lane_id'] == ident + '/' + machine + '/screen'
                assert live['incarnation'] == row['subject_id']
                screen = live['screen']
                pixels = base64.b64decode(screen['rgb_base64'], validate=True)
                assert len(pixels) == screen['width'] * screen['height'] * 3
                receipt['instances'][machine]['live'] = {k: v for k, v in live.items() if k != 'screen'}
                rows = host.api('/slice?' + urllib.parse.urlencode({'run_id': 'host-proof-' + machine}))['rows']
                assert rows and any(r['lane_id'] == ident + '/' + machine + '/screen' for r in rows)
                receipt['checks'].append(machine + '_attached_declared_tools_native_execution_and_context')
            for machine in ('msx', 'dos'):
                identity = identities[machine]
                host.api('/detach', {'instance_id': identity['instance_id']})
                wait_for('detach ' + machine, lambda: host.inspect(identity['instance_id']),
                    lambda e: e['phase']['kind'] == 'detached', server)
                active -= exports[machine]
                assert host.tools() == baseline | active
                absent(host, machine)
                remaining = json.loads(command(['docker', 'container', 'ls', '-a', '--filter',
                    'label=masc.lane.instance=' + identity['instance_id'], '--format', '{{json .ID}}']) or 'null')
                assert remaining is None, 'host detach left its container'
                rows = host.api('/slice?' + urllib.parse.urlencode({'run_id': 'host-proof-' + machine}))['rows']
                assert rows, 'detach must preserve historical evidence'
                if machine == 'msx':
                    host.call('dos', 'press', {'keys': ['space']})
                    png(host, 'dos', 'after-msx-detach')
                receipt['checks'].append(machine + '_detached_tools_context_and_container_absent_history_retained')
            assert all(r == {'method': 'GET', 'path': '/v1/models'} for r in Sink.requests), Sink.requests
            receipt['checks'].append('no_model_generation_only_catalog_discovery')
            receipt['status'] = 'passed'
        finally:
            cleanup = []
            if server is not None and server.poll() is None:
                server.terminate()
                try:
                    server.wait(timeout=20)
                except subprocess.TimeoutExpired:
                    server.kill()
                    server.wait(timeout=10)
            log.close()
            if host is not None:
                host.journal.close()
            # Cleanup can remove only containers bearing an exact observed instance
            # label, and volumes whose complete ownership tuple was verified.
            for identity in identities.values():
                try:
                    ids = command(['docker', 'container', 'ls', '-aq', '--filter',
                                   'label=masc.lane.instance=' + identity['instance_id']]).split()
                    for ident in ids:
                        command(['docker', 'container', 'rm', '--force', ident])
                    volumes = command(['docker', 'volume', 'ls', '-q', '--filter',
                                       'label=masc.lane.state.owner']).split()
                    removed = []
                    for volume in volumes:
                        meta, = json.loads(command(['docker', 'volume', 'inspect', volume]))
                        if json.loads(meta['Labels']['masc.lane.state.owner']) == identity['owner']:
                            command(['docker', 'volume', 'rm', volume])
                            removed.append(volume)
                    cleanup.append({'instance_id': identity['instance_id'], 'cleaned': True,
                                    'removed_volumes': removed})
                except (subprocess.SubprocessError, AssertionError, KeyError, ValueError) as error:
                    cleanup.append({'instance_id': identity['instance_id'], 'cleaned': False,
                                    'error': str(error)})
            # A failed attach response may omit its ID after creating state.
            # Report any uncollected volume from this unique workspace rather
            # than claiming complete cleanup from only the received receipts.
            residual = []
            try:
                volumes = command(['docker', 'volume', 'ls', '-q', '--filter',
                                   'label=masc.lane.state.owner']).split()
                for volume in volumes:
                    meta, = json.loads(command(['docker', 'volume', 'inspect', volume]))
                    owner = json.loads(meta['Labels']['masc.lane.state.owner'])
                    if isinstance(owner, list) and owner and owner[0] == str(base / '.masc/lane-addons'):
                        residual.append(volume)
            except (subprocess.SubprocessError, KeyError, ValueError) as error:
                residual.append('cleanup inventory unavailable: ' + str(error))
            receipt['residual_workspace_volumes'] = residual
            sink.shutdown()
            sink.server_close()
            thread.join(timeout=5)
            receipt['provider_requests'] = Sink.requests
            receipt['cleanup'] = cleanup
            # Only this no-secret fixture runs in the process; redact the minted
            # credential even if an unexpected diagnostic prints it.
            content = raw_log.read_text(errors='replace') if raw_log.exists() else ''
            secrets = {token} if token else set()
            for token_file in (base / '.masc/auth').glob('*.token'):
                value = token_file.read_text().strip()
                if value:
                    secrets.add(value)
            for value in secrets:
                content = content.replace(value, '[REDACTED]')
            (artifact / 'host.log').write_text(content)
            if (any(r != {'method': 'GET', 'path': '/v1/models'} for r in Sink.requests)
                    or residual or any(not row['cleaned'] for row in cleanup)):
                receipt['status'] = 'failed'
            receipt.setdefault('status', 'failed')
            (artifact / 'receipt.json').write_text(json.dumps(receipt, indent=2) + '\n')
        assert receipt['status'] == 'passed', receipt
    print(json.dumps({'status': receipt['status'], 'checks': receipt['checks']}))


if __name__ == '__main__':
    main()
