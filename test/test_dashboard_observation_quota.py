"""Native H1 burst proof: observations do not spend the MCP operation bucket."""
import argparse
import json
import os
from pathlib import Path
import secrets
import shutil
import socket
import subprocess
import tempfile
import time
from urllib.error import HTTPError, URLError
from urllib.request import Request, ProxyHandler, build_opener


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--binary', type=Path, required=True)
    args = parser.parse_args()
    binary = args.binary.resolve()
    fixtures = Path(__file__).resolve().parent.parent / 'scripts/fixtures/release-evidence'
    with tempfile.TemporaryDirectory(prefix='masc-observation-quota-') as temporary:
        base = Path(temporary)
        config = base / '.masc/config'
        config.mkdir(parents=True)
        for name in ('runtime.toml', 'agent-core-models-overlay.toml'):
            shutil.copyfile(fixtures / name, config / name)
        assets = base / 'assets/dashboard/assets'
        assets.mkdir(parents=True)
        (assets / 'fixture.js').write_text('/* quota observation fixture */\n')
        token = secrets.token_hex(32)
        with socket.socket() as sock:
            sock.bind(('127.0.0.1', 0))
            port = sock.getsockname()[1]
        env = {key: value for key, value in os.environ.items() if key in ('PATH', 'TMPDIR', 'LANG', 'LC_ALL', 'USER', 'SHELL')}
        env.update(HOME=str(base), XDG_CONFIG_HOME=str(base / 'xdg'), MASC_BASE_PATH=str(base),
                   MASC_ADMIN_TOKEN=token, MASC_ASSETS_DIR=str(base / 'assets'),
                   MASC_HTTP_AUTH_STRICT='true', MASC_GRPC_ENABLED='0', MASC_WS_ENABLED='0',
                   MASC_KEEPER_AUTONOMOUS_ENABLED='false', MASC_AGENT_RATE_LIMIT='0', MASC_AGENT_RATE_BURST='4',
                   MASC_RATE_LIMIT='0', MASC_RATE_BURST='100')
        # Zero refill makes the burst assertions independent of machine speed.
        # These are isolated fixture settings, not changed product defaults.
        opener = build_opener(ProxyHandler({}))
        observations = []
        def http(path, body=None, *, credential=token, method=None, extra=None):
            headers = {'Authorization': 'Bearer ' + credential, 'Content-Type': 'application/json',
                       'Accept': 'application/json, text/event-stream'}
            headers.update(extra or {})
            request = Request(f'http://127.0.0.1:{port}' + path,
                data=None if body is None else json.dumps(body).encode(), headers=headers, method=method)
            try:
                response = opener.open(request, timeout=10)
            except HTTPError as error:
                response = error
            with response:
                status, raw = response.status, response.read().decode()
            assert token not in raw, 'credential echoed'
            observations.append({'method': request.get_method(), 'path': path, 'status': status})
            return status, raw
        with (base / 'server.log').open('wb') as log:
            process = subprocess.Popen([str(binary), 'start', '--base-path', str(base), '--host', '127.0.0.1', '--port', str(port)],
                                       cwd=base, env=env, stdout=log, stderr=subprocess.STDOUT)
            try:
                deadline = time.monotonic() + 60
                while True:
                    assert process.poll() is None, (base / 'server.log').read_text()[-8000:]
                    try:
                        # MCP admission uses state_ready, not the /health
                        # aggregate's status (which can be ok during startup).
                        status, raw = http('/health/ready')
                        if status == 200 and json.loads(raw).get('ready') is True:
                            break
                    except (URLError, OSError):
                        pass
                    assert time.monotonic() < deadline, 'native server did not become ready'
                    time.sleep(0.02)  # Startup only. No sleeps or retries in the quota burst.
                for _ in range(60):
                    status, raw = http('/dashboard/assets/fixture.js')
                    assert status == 200 and 'quota observation fixture' in raw, (status, raw)
                for _ in range(4):
                    status, raw = http('/api/v1/providers')
                    assert status == 200, (status, raw)
                # This GET uses CanReadState permission auth, not with_read_auth.
                # More reads than the operation burst must leave all four MCP slots.
                for _ in range(8):
                    status, raw = http('/api/v1/dashboard/browser-lane/clients')
                    assert status == 200 and 'clients' in json.loads(raw)['data'], (status, raw)
                meta = {'io.modelcontextprotocol/protocolVersion': '2026-07-28',
                        'io.modelcontextprotocol/clientInfo': {'name': 'quota-fixture', 'version': '1'},
                        'io.modelcontextprotocol/clientCapabilities': {}}
                def mcp(index):
                    return http('/mcp', {'jsonrpc': '2.0', 'id': index, 'method': 'tools/call',
                        'params': {'name': 'masc_status', 'arguments': {}, '_meta': meta}},
                        extra={'mcp-protocol-version': '2026-07-28', 'mcp-method': 'tools/call',
                               'mcp-name': 'masc_status'})
                for index in range(4):
                    status, raw = mcp(index)
                    assert status == 200, (index, status, raw)
                    wire = next((line[6:] for line in raw.splitlines() if line.startswith('data: ')), raw)
                    result = json.loads(wire)
                    assert 'result' in result and not result['result'].get('isError'), result
                status, raw = mcp(4)
                assert status == 429 and json.loads(raw)['message'] == 'Per-agent rate limit exceeded', (status, raw)
                # A mutation endpoint remains metered, before it can perform work.
                status, raw = http('/api/v1/dashboard/browser-lane/goto', {})
                assert status == 429 and json.loads(raw)['message'] == 'Per-agent rate limit exceeded', (status, raw)
                for path in ('/dashboard/assets/fixture.js', '/api/v1/providers',
                             '/api/v1/dashboard/browser-lane/clients'):
                    status, raw = http(path)
                    assert status == 200, (path, status, raw)
                status, _ = http('/api/v1/providers', credential='invalid-fixture-token')
                assert status in (401, 403), status
                status, _ = http('/api/v1/dashboard/browser-lane/clients', credential='invalid-fixture-token')
                assert status in (401, 403), status
                # CanReadState does not exempt POST operations from metering.
                status, raw = http('/api/v1/dashboard/browser-lane/read', {})
                assert status == 429 and json.loads(raw)['message'] == 'Per-agent rate limit exceeded', (status, raw)
                # Observations still exhaust the original per-IP resource bucket.
                for _ in range(100):
                    status, raw = http('/dashboard/assets/fixture.js')
                    if status == 429:
                        assert json.loads(raw)['message'] == 'Rate limit exceeded', raw
                        break
                    assert status == 200, (status, raw)
                else:
                    raise AssertionError('IP resource limit disappeared')
                print('DASHBOARD_OBSERVATION_QUOTA ' + json.dumps({'protocol': 'h1', 'asset_reads_before_operations': 60,
                    'authorized_reads_before_operations': 4, 'MCP_operations_accepted': 4,
                    'operation_quota_exhaustion_enforced': True, 'auth_still_required': True,
                    'IP_quota_exhaustion_enforced': True, 'requests': observations}))
            finally:
                process.terminate()
                try:
                    process.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait()


if __name__ == '__main__':
    main()
