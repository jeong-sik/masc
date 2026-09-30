"""Exercise real TCP HTTP routes with an isolated exact-source CI probe binary.

No live instance is contacted. Login writes credentials inside the isolated
workspace; its auth directory is removed on exit and excluded from evidence.
Keeper metadata, empty ledger and catalog are synthetic inputs, not evidence
of lifecycle creation, a real payout or a model-driven purchase.
Authenticated MCP calls exercise the real purchase and equipment ledger.
"""
import argparse
import atexit
import hashlib
import json
import os
from pathlib import Path
import socket
import shutil
import subprocess
import time
import urllib.error
import urllib.request

parser = argparse.ArgumentParser()
parser.add_argument('--output', type=Path, required=True)
parser.add_argument('--binary', type=Path, required=True)
parser.add_argument('--dashboard', type=Path, required=True)
parser.add_argument('--source-sha', required=True)
args = parser.parse_args()
root = args.output.resolve()
# A fresh output root prevents accidental reuse of a real workspace or ledger.
root.mkdir(parents=True, exist_ok=False)
binary = args.binary.resolve()
dashboard = args.dashboard.resolve()
identity = json.loads((dashboard / '.build-identity.json').read_text())
assert identity['schema'] == 'masc.dashboard-build.v1'
assert identity['source_commit'] == args.source_sha, 'dashboard identity differs'
source = subprocess.check_output([str(binary), 'build-commit'], text=True).strip()
if source != args.source_sha:
    raise SystemExit('native probe source differs from prepared dashboard')
base = root / 'workspace'
fixtures = Path(__file__).resolve().parents[1] / 'test/fixtures/item-http'
config_hashes = {}
for src, dst in [('runtime.toml', 'config/runtime.toml'),
                 ('candle.toml', 'config/candle.toml'),
                 ('keeper.toml', 'config/keepers/item-runtime-probe.toml'),
                 ('keeper.json', 'keepers/item-runtime-probe.json')]:
    target = base / '.masc' / dst
    target.parent.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(fixtures / src, target)
    config_hashes[src] = hashlib.sha256(target.read_bytes()).hexdigest()
atexit.register(shutil.rmtree, base / '.masc/auth', ignore_errors=True)
with socket.socket() as sock:
    sock.bind(('127.0.0.1', 0))
    port = sock.getsockname()[1]
# Do not inherit provider credentials or an operator's runtime configuration.
env = {key: value for key, value in os.environ.items()
       if key in {'PATH', 'HOME', 'LANG', 'LC_ALL', 'TMPDIR', 'LD_LIBRARY_PATH'}}
env.update(MASC_BASE_PATH=str(base), MASC_ASSETS_DIR=str(dashboard.parent),
           MASC_HOST='127.0.0.1', MASC_CONFIG_BOOTSTRAP='skip',
           MASC_GRPC_ENABLED='0', MASC_WS_ENABLED='0', MASC_KEEPER_AUTONOMOUS_ENABLED='0',
           MASC_ORCHESTRATOR_ENABLED='0', MASC_OTEL_ENABLED='0')
login = subprocess.run([str(binary), 'login', '--base-path', str(base),
    '--host', '127.0.0.1', '--port', str(port), '--agent', 'item-probe-admin',
    '--role', 'admin', '--client-env', 'MCP_TOKEN', '--no-expiry', '--json'],
    env=env, capture_output=True, text=True, check=True)
token = json.loads(login.stdout)['bearer_token']
keeper_login = subprocess.run([str(binary), 'login', '--base-path', str(base),
    '--host', '127.0.0.1', '--port', str(port), '--agent', 'item-runtime-probe',
    '--role', 'worker', '--client-env', 'ITEM_PROBE_TOKEN', '--no-expiry', '--json'],
    env=env, capture_output=True, text=True, check=True)
keeper_token = json.loads(keeper_login.stdout)['bearer_token']
origin = f'http://127.0.0.1:{port}'
records = []
def request(path, authenticated=True):
    headers = {'Authorization': 'Bearer ' + token} if authenticated else {}
    req = urllib.request.Request(origin + path, headers=headers)
    try:
        response = urllib.request.urlopen(req, timeout=5)
    except urllib.error.HTTPError as error:
        response = error
    with response:
        body = response.read()
        records.append({'path': path, 'authenticated': authenticated,
                        'status': response.status, 'sha256': hashlib.sha256(body).hexdigest()})
        return response.status, body

rpc_sequence = 0
rpc_session = {}
tool_records = []
def rpc(method, params, notification=False):
    global rpc_sequence
    rpc_sequence += 1
    payload = {'jsonrpc': '2.0', 'method': method, 'params': params}
    if not notification:
        payload['id'] = rpc_sequence
    headers = {'Authorization': 'Bearer ' + keeper_token,
               'Content-Type': 'application/json',
               'Accept': 'application/json, text/event-stream', **rpc_session}
    req = urllib.request.Request(origin + '/mcp', data=json.dumps(payload).encode(), headers=headers)
    with urllib.request.urlopen(req, timeout=10) as response:
        body = response.read()
        records.append({'path': '/mcp', 'authenticated': True, 'rpc_method': method,
                        'status': response.status, 'sha256': hashlib.sha256(body).hexdigest()})
        if method == 'initialize':
            rpc_session['Mcp-Session-Id'] = response.headers['Mcp-Session-Id']
            rpc_session['Mcp-Protocol-Version'] = '2025-11-25'
    if notification:
        return None
    try:
        envelope = json.loads(body)
    except json.JSONDecodeError:
        events = [json.loads(line[5:].strip()) for line in body.decode().splitlines()
                  if line.startswith('data:')]
        assert len(events) == 1, 'expected one JSON-RPC SSE event'
        envelope = events[0]
    assert envelope.get('id') == rpc_sequence and 'error' not in envelope, envelope
    return envelope['result']

def tool(name, arguments, error_code=None):
    result = rpc('tools/call', {'name': name, 'arguments': arguments})
    failed = result.get('isError', False)
    assert failed == (error_code is not None), result
    data = result['structuredContent']
    if error_code is not None:
        assert data['error_code'] == error_code, data
    tool_records.append({'name': name, 'arguments': arguments, 'is_error': failed,
                         'data': data})
    return data

with (root / 'server.log').open('wb') as log:
    server = subprocess.Popen([str(binary), '--port', str(port), '--base-path', str(base)],
                              cwd=root, env=env, stdout=log, stderr=log)
    try:
        deadline = time.monotonic() + 60
        while True:
            if server.poll() is not None:
                raise RuntimeError('isolated server exited during startup; inspect server.log')
            try:
                status, _ = request('/health/ready', False)
                if status == 200:
                    break
            except (OSError, urllib.error.URLError):
                pass
            if time.monotonic() >= deadline:
                raise RuntimeError('isolated server readiness deadline exceeded')
            time.sleep(0.2)
        path = '/api/v1/keepers/item-runtime-probe/items'
        status, _ = request(path, False)
        assert status in (401, 403), ('account route bypassed auth', status)
        status, body = request(path)
        account = json.loads(body)
        (root / 'account.json').write_bytes(body)
        assert status == 200 and account['status'] == 'ready', account
        assert account['balance_milli'] == '0' and account['owned_items'] == [], account
        assert len(account['catalog']) == 18, account
        glasses = next(item for item in account['catalog'] if item['id'] == 'glasses')
        assert glasses['price_status'] == 'priced' and glasses['price_milli'] == '0', glasses
        status, png = request('/api/v1/keepers/item-runtime-probe/portrait.png?size=96')
        assert status == 200 and png.startswith(b'\x89PNG\r\n\x1a\n'), status
        (root / 'portrait.png').write_bytes(png)
        rpc('initialize', {'protocolVersion': '2025-11-25', 'capabilities': {},
                           'clientInfo': {'name': 'item-http-acceptance', 'version': '1'}})
        rpc('notifications/initialized', {}, notification=True)
        own = tool('keeper_candle_balance', {})
        assert own['keeper'] == 'item-runtime-probe' and own['balance_milli'] == '0', own
        tool('keeper_candle_balance', {'keeper': 'another-keeper'}, 'invalid_arguments')
        starting = tool('keeper_candle_equip', {'slot': 'face', 'item': 'default'})['equipment']
        item = 'shades' if starting['face'] == 'glasses' else 'glasses'
        tool('keeper_candle_equip', {'slot': 'face', 'item': item}, 'equipment_refused')
        purchase = tool('keeper_candle_purchase', {'item': item})
        assert purchase['amount_milli'] == '0', purchase
        assert purchase['account']['owned_items'] == [item], purchase
        tool('keeper_candle_purchase', {'item': item}, 'already_owned')
        tool('keeper_candle_purchase', {'item': 'crown'}, 'insufficient_balance')
        equipped = tool('keeper_candle_equip', {'slot': 'face', 'item': item})
        assert equipped['changed'] is True and equipped['equipment']['face'] == item, equipped
        for slot in ('head', 'neck', 'hand', 'base'):
            assert equipped['equipment'][slot] == starting[slot], equipped
        status, updated = request(path)
        account_after = json.loads(updated)
        assert status == 200 and account_after['balance_milli'] == '0', account_after
        assert account_after['owned_items'] == [item], account_after
        (root / 'account-after.json').write_bytes(updated)
        status, equipped_png = request('/api/v1/keepers/item-runtime-probe/portrait.png?size=96')
        assert status == 200 and equipped_png.startswith(b'\x89PNG\r\n\x1a\n'), status
        assert equipped_png != png, 'equipment did not change the served portrait'
        (root / 'portrait-equipped.png').write_bytes(equipped_png)
        restored = tool('keeper_candle_equip', {'slot': 'face', 'item': 'default'})
        assert restored['equipment'] == starting, restored
        status, restored_png = request('/api/v1/keepers/item-runtime-probe/portrait.png?size=96')
        assert status == 200 and restored_png == png, 'default did not restore the served portrait'
        status, index = request('/dashboard/', False)
        assert status == 200, status
        assert hashlib.sha256(index).hexdigest() == hashlib.sha256(
            (dashboard / 'index.html').read_bytes()).hexdigest(), 'served index differs'
        result = dict(source_sha=source, binary_sha256=hashlib.sha256(binary.read_bytes()).hexdigest(),
            fixture_sha256=config_hashes, dashboard_index_sha256=hashlib.sha256(index).hexdigest(),
            scope='Isolated CI binary over real TCP HTTP; synthetic current-schema paused Keeper metadata, empty test ledger and configured catalog; authenticated Keeper MCP purchase/equipment calls and ledger-backed HTTP; no lifecycle creation, model-driven decision, paid purchase/payout or production rollout',
            requests=records, tool_calls=tool_records, passed=True)
        (root / 'http-evidence.json').write_text(json.dumps(result, indent=2) + '\n')
        print('Isolated Item HTTP acceptance: PASS')
    finally:
        server.terminate()
        try:
            server.wait(timeout=10)
        except subprocess.TimeoutExpired:
            server.kill()
            server.wait()
