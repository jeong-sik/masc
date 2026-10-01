"""Exercise real TCP HTTP routes with an isolated exact-source CI probe binary.

No live instance is contacted. Login writes credentials inside the isolated
workspace; its auth directory is removed on exit and excluded from evidence.
Keeper metadata, catalog and the paid scenario credit are synthetic inputs, not evidence
of lifecycle creation, a real payout or a model-driven purchase.
Authenticated MCP calls exercise the real purchase and equipment ledger.
"""
import argparse
import atexit
import errno
import hashlib
import json
import os
from pathlib import Path
import socket
import shutil
import signal
import struct
import zlib
import subprocess
import time
import urllib.error
import urllib.request

def require(condition, detail):
    if not condition:
        raise RuntimeError(detail)


def validate_portrait(png, edge):
    require(png.startswith(b'\x89PNG\r\n\x1a\n'), 'portrait has no PNG signature')
    offset, header, image, ended = 8, None, bytearray(), False
    while offset < len(png):
        require(offset + 12 <= len(png), 'truncated PNG chunk')
        size = struct.unpack_from('>I', png, offset)[0]
        kind = png[offset + 4:offset + 8]
        end = offset + 12 + size
        require(end <= len(png), 'truncated PNG chunk data')
        data = png[offset + 8:offset + 8 + size]
        crc = struct.unpack_from('>I', png, end - 4)[0]
        require(zlib.crc32(kind + data) & 0xffffffff == crc, 'invalid PNG chunk CRC')
        if header is None:
            require(kind == b'IHDR' and size == 13, 'PNG must begin with IHDR')
            header = struct.unpack('>IIBBBBB', data)
            width, height, depth, colour, compression, filtering, interlace = header
            require((width, height) == (edge, edge), 'portrait dimensions differ from request')
            # Rgb_png.encode emits noninterlaced RGB8 or RGBA8.
            require(depth == 8 and colour in (2, 6) and (compression, filtering, interlace) == (0, 0, 0),
                    'portrait differs from native RGB8/RGBA8 encoding')
        elif kind == b'IHDR':
            raise RuntimeError('duplicate PNG header')
        elif kind == b'IDAT':
            image.extend(data)
        elif kind == b'IEND':
            require(size == 0 and end == len(png), 'invalid PNG end')
            ended = True
            break
        elif kind[:1].isupper():
            raise RuntimeError('unsupported critical PNG chunk')
        offset = end
    require(ended and header is not None and image, 'PNG is missing image data or end')
    channels = 3 if header[3] == 2 else 4
    stride = edge * channels + 1
    expected = edge * stride
    decoder = zlib.decompressobj()
    pixels = decoder.decompress(image, expected + 1)
    require(decoder.eof and not decoder.unused_data and not decoder.unconsumed_tail
            and len(pixels) == expected, 'invalid PNG image data')
    require(all(pixels[row * stride] <= 4 for row in range(edge)), 'invalid PNG scanline filter')


parser = argparse.ArgumentParser()
parser.add_argument('--output', type=Path, required=True)
parser.add_argument('--binary', type=Path, required=True)
parser.add_argument('--dashboard', type=Path, required=True)
parser.add_argument('--source-sha', required=True)
parser.add_argument('--capture-browser', action='store_true')
args = parser.parse_args()
root = args.output.resolve()
# A fresh output root prevents accidental reuse of a real workspace or ledger.
root.mkdir(parents=True, exist_ok=False)
# Every child, including build-commit, receives the isolated environment.
env = {key: value for key, value in os.environ.items()
       if key in {'PATH', 'HOME', 'LANG', 'LC_ALL', 'TMPDIR', 'LD_LIBRARY_PATH'}}
binary = args.binary.resolve()
dashboard = args.dashboard.resolve()
identity = json.loads((dashboard / '.build-identity.json').read_text())
require(identity['schema'] == 'masc.dashboard-build.v1', 'dashboard build identity schema differs')
require(identity['source_commit'] == args.source_sha, 'dashboard identity differs')
source = subprocess.check_output([str(binary), 'build-commit'], text=True, env=env).strip()
if source != args.source_sha:
    raise SystemExit('native probe source differs from prepared dashboard')
base = root / 'workspace'
fixtures = Path(__file__).resolve().parents[1] / 'test/fixtures/item-http'
config_hashes = {}
for src, dst in [('runtime.toml', 'config/runtime.toml'),
                 ('candle.toml', 'config/candle.toml'),
                 ('keeper.toml', 'config/keepers/item-runtime-probe.toml'),
                 ('keeper.json', 'keepers/item-runtime-probe.json'),
                 ('restart-credit.jsonl', 'candle-ledger.jsonl')]:
    target = base / '.masc' / dst
    target.parent.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(fixtures / src, target)
    config_hashes[src] = hashlib.sha256(target.read_bytes()).hexdigest()
# Seed a second Keeper and canonical synthetic credit before either process starts.
# This is an Item spending fixture, not evidence of earning a Goal payout.
paid_meta = json.loads((fixtures / 'keeper.json').read_text())
paid_meta.update(name='item-paid-probe', trace_id='trace-item-paid-probe')
(base / '.masc/keepers/item-paid-probe.json').write_text(json.dumps(paid_meta) + '\n')
shutil.copyfile(fixtures / 'keeper.toml', base / '.masc/config/keepers/item-paid-probe.toml')
ledger_path = base / '.masc/candle-ledger.jsonl'
free_seed = ledger_path.read_bytes()
seed = (fixtures / 'paid-credit.jsonl').read_bytes()
seeded_ledger = free_seed + seed
seeded_payments = [json.loads(line) for line in seeded_ledger.splitlines()]
ledger_path.write_bytes(seeded_ledger)
ledger_path.chmod(0o600)
(root / 'ledger-seed.jsonl').write_bytes(seeded_ledger)
config_hashes['paid-credit.jsonl'] = hashlib.sha256(seed).hexdigest()
(base / '.masc/config/prompts').mkdir(exist_ok=True)
server = None
reservation = None

def stop_server():
    global server
    if server is not None:
        if server.poll() is None:
            server.terminate()
            try:
                server.wait(timeout=10)
            except subprocess.TimeoutExpired:
                server.kill()
                server.wait()
        server = None

def cleanup():
    try:
        stop_server()
    finally:
        if reservation is not None:
            reservation.close()
        shutil.rmtree(base / '.masc/auth', ignore_errors=True)

def terminated(signum, _frame):
    signal.signal(signal.SIGTERM, signal.SIG_IGN)
    raise SystemExit(128 + signum)

atexit.register(cleanup)
signal.signal(signal.SIGTERM, terminated)

def reserve_port():
    sock = socket.socket()
    try:
        sock.bind(('127.0.0.1', 0))
        return sock, sock.getsockname()[1]
    except BaseException:
        sock.close()
        raise

reservation, port = reserve_port()
env.update(MASC_BASE_PATH=str(base), MASC_ASSETS_DIR=str(dashboard.parent),
           MASC_HOST='127.0.0.1', MASC_HTTP_AUTH_STRICT='1', MASC_CONFIG_BOOTSTRAP='skip',
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
free_keeper_token = keeper_token
paid_login = subprocess.run([str(binary), 'login', '--base-path', str(base),
    '--host', '127.0.0.1', '--port', str(port), '--agent', 'item-paid-probe',
    '--role', 'worker', '--client-env', 'ITEM_PAID_PROBE_TOKEN', '--no-expiry', '--json'],
    env=env, capture_output=True, text=True, check=True)
paid_keeper_token = json.loads(paid_login.stdout)['bearer_token']

origin = f'http://127.0.0.1:{port}'
# These requests target only the isolated child server and carry local auth.
# Proxy settings in the invoking shell must not route them elsewhere.
http = urllib.request.build_opener(urllib.request.ProxyHandler({}))
records = []
server_generation = 1
def request(path, authenticated=True):
    headers = {'Authorization': 'Bearer ' + token} if authenticated else {}
    req = urllib.request.Request(origin + path, headers=headers)
    try:
        response = http.open(req, timeout=5)
    except urllib.error.HTTPError as error:
        response = error
    with response:
        body = response.read()
        records.append({'server_generation': server_generation, 'path': path, 'authenticated': authenticated,
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
    with http.open(req, timeout=10) as response:
        body = response.read()
        records.append({'server_generation': server_generation, 'path': '/mcp', 'authenticated': True, 'rpc_method': method,
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
        require(len(events) == 1, 'expected one JSON-RPC SSE event')
        envelope = events[0]
    require(envelope.get('id') == rpc_sequence and 'error' not in envelope, envelope)
    return envelope['result']

def tool(name, arguments, error_code=None, validation_reason=None):
    result = rpc('tools/call', {'name': name, 'arguments': arguments})
    failed = result.get('isError', False)
    # Retain the whole response before validating handler or middleware fields.
    entry = {'server_generation': server_generation, 'name': name,
             'arguments': arguments, 'is_error': failed,
             'result': result, 'data': result.get('structuredContent')}
    tool_records.append(entry)
    (root / 'tool-calls.json').write_text(json.dumps(tool_records, indent=2) + '\n')
    data = result['structuredContent']
    require(failed == (error_code is not None or validation_reason is not None), result)
    if error_code is not None:
        require(data['error_code'] == error_code, data)
    if validation_reason is not None:
        require(data['validation'] == 'agent_core_tool_middleware', data)
        require(data['reason'] == validation_reason, data)
    return data

def initialize_keeper_session(auth_token):
    global keeper_token
    keeper_token = auth_token
    rpc_session.clear()
    rpc('initialize', {'protocolVersion': '2025-11-25', 'capabilities': {},
                       'clientInfo': {'name': 'item-http-acceptance', 'version': '1'}})
    rpc('notifications/initialized', {}, notification=True)

class PortCollision(Exception):
    pass


def port_is_occupied():
    with socket.socket() as sock:
        try:
            sock.bind(('127.0.0.1', port))
        except OSError as error:
            if error.errno == errno.EADDRINUSE:
                return True
            raise
    return False


def start_ready(log):
    global server, reservation, port, origin
    deadline = time.monotonic() + 60
    while time.monotonic() < deadline:
        # Hold the ephemeral port through setup/login; native main has no
        # inherited-listener interface. Retry confirmed bind collisions.
        reservation.close()
        reservation = None
        server = subprocess.Popen([str(binary), '--port', str(port), '--base-path', str(base)],
                                  cwd=root, env=env, stdout=log, stderr=log)
        try:
            while time.monotonic() < deadline:
                if server.poll() is not None:
                    if port_is_occupied():
                        raise PortCollision()
                    raise RuntimeError('isolated server exited during startup; inspect server.log')
                try:
                    # Establish workspace identity anonymously before sending
                    # any bearer. A foreign listener is a port collision.
                    status, body = request('/health?full=1', False)
                    if status == 200:
                        try:
                            health = json.loads(body)
                        except (ValueError, UnicodeError):
                            raise PortCollision() from None
                        if not isinstance(health, dict) or not isinstance(health.get('paths'), dict):
                            raise PortCollision()
                        paths = health['paths']
                        if (paths.get('effective_base_path') != str(base.resolve())
                                or paths.get('effective_masc_root') != str((base / '.masc').resolve())):
                            raise PortCollision()
                        status, _ = request('/health/ready', False)
                        if status == 200:
                            return
                except (OSError, urllib.error.URLError):
                    pass
                time.sleep(0.2)
        except PortCollision:
            stop_server()
            reservation, port = reserve_port()
            origin = f'http://127.0.0.1:{port}'
            continue
        raise RuntimeError('isolated server readiness deadline exceeded')
    raise RuntimeError('isolated server startup collisions exhausted readiness deadline')


with (root / 'server.log').open('wb') as log:
    try:
        start_ready(log)
        path = '/api/v1/keepers/item-runtime-probe/items'
        status, _ = request(path, False)
        require(status in (401, 403), ('account route bypassed auth', status))
        status, body = request(path)
        account = json.loads(body)
        (root / 'account.json').write_bytes(body)
        require(status == 200 and account['status'] == 'ready'
                and account['keeper'] == 'item-runtime-probe', account)
        require(account['balance_milli'] == '100' and account['owned_items'] == [], account)
        require(len(account['catalog']) == 18, account)
        glasses = next(item for item in account['catalog'] if item['id'] == 'glasses')
        require(glasses['price_status'] == 'priced' and glasses['price_milli'] == '0', glasses)
        crown = next(item for item in account['catalog'] if item['id'] == 'crown')
        require(crown['price_status'] == 'priced' and crown['price_milli'] == '200', crown)
        portrait_path = '/api/v1/keepers/item-runtime-probe/portrait.png?size=96'
        status, _ = request(portrait_path, False)
        require(status in (401, 403), ('portrait route bypassed auth', status))
        status, png = request(portrait_path)
        require(status == 200, status)
        validate_portrait(png, 96)
        (root / 'portrait.png').write_bytes(png)
        rpc('initialize', {'protocolVersion': '2025-11-25', 'capabilities': {},
                           'clientInfo': {'name': 'item-http-acceptance', 'version': '1'}})
        rpc('notifications/initialized', {}, notification=True)
        own = tool('keeper_candle_balance', {})
        require(own['keeper'] == 'item-runtime-probe' and own['balance_milli'] == '100', own)
        tool('keeper_candle_balance', {'keeper': 'another-keeper'}, validation_reason='empty_schema_args')
        starting = tool('keeper_candle_equip', {'slot': 'face', 'item': 'default'})['equipment']
        item = 'shades' if starting['face'] == 'glasses' else 'glasses'
        tool('keeper_candle_equip', {'slot': 'face', 'item': item}, 'equipment_refused')
        purchase = tool('keeper_candle_purchase', {'item': item})
        require(purchase['amount_milli'] == '0', purchase)
        require(purchase['account']['owned_items'] == [item], purchase)
        ledger_path = base / '.masc/candle-ledger.jsonl'
        purchased_ledger = ledger_path.read_bytes()
        tool('keeper_candle_purchase', {'item': item}, 'already_owned')
        tool('keeper_candle_purchase', {'item': 'crown'}, 'insufficient_balance')
        tool('keeper_candle_equip', {'slot': 'head', 'item': item}, 'equipment_refused')
        require(ledger_path.read_bytes() == purchased_ledger, 'refused Item calls changed the ledger')
        equipped = tool('keeper_candle_equip', {'slot': 'face', 'item': item})
        require(equipped['changed'] is True and equipped['equipment']['face'] == item, equipped)
        for slot in ('head', 'neck', 'hand', 'base'):
            require(equipped['equipment'][slot] == starting[slot], equipped)
        status, updated = request(path)
        account_after = json.loads(updated)
        require(status == 200 and account_after['balance_milli'] == '100', account_after)
        require(account_after['owned_items'] == [item], account_after)
        (root / 'account-after.json').write_bytes(updated)
        status, equipped_png = request('/api/v1/keepers/item-runtime-probe/portrait.png?size=96')
        require(status == 200, status)
        validate_portrait(equipped_png, 96)
        require(equipped_png != png, 'equipment did not change the served portrait')
        (root / 'portrait-equipped.png').write_bytes(equipped_png)
        if args.capture_browser:
            browser_script = fixtures.parents[2] / 'dashboard/e2e/item-server.mjs'
            subprocess.run(['node', str(browser_script)], input=json.dumps({
                'origin': origin, 'token': token, 'output': str(root),
                'sourceSha': source, 'keeper': 'item-runtime-probe', 'ownedItem': item,
                'balanceLabel': '0.100 Candle',
            }), text=True, check=True, cwd=browser_script.parent, env=env)
        restored = tool('keeper_candle_equip', {'slot': 'face', 'item': 'default'})
        require(restored['equipment'] == starting, restored)
        status, restored_png = request('/api/v1/keepers/item-runtime-probe/portrait.png?size=96')
        require(status == 200 and restored_png == png, 'default did not restore the served portrait')
        status, index = request('/dashboard/', False)
        require(status == 200, status)
        require(hashlib.sha256(index).hexdigest() == hashlib.sha256(
            (dashboard / 'index.html').read_bytes()).hexdigest(), 'served index differs')
        # Leave the purchased accessory equipped for the restart proof.
        tool('keeper_candle_equip', {'slot': 'face', 'item': item})
        initialize_keeper_session(paid_keeper_token)
        paid_start = tool('keeper_candle_balance', {})
        require(paid_start['keeper'] == 'item-paid-probe' and paid_start['balance_milli'] == '700', paid_start)
        require(paid_start['owned_items'] == [], paid_start)
        paid_original = tool('keeper_candle_equip', {'slot': 'head', 'item': 'default'})['equipment']
        status, paid_before_png = request('/api/v1/keepers/item-paid-probe/portrait.png?size=96')
        require(status == 200 and paid_before_png.startswith(b'\x89PNG\r\n\x1a\n'), status)
        (root / 'paid-portrait-before.png').write_bytes(paid_before_png)
        purchase_paid = tool('keeper_candle_purchase', {'item': 'crown'})
        require(purchase_paid['amount_milli'] == '200', purchase_paid)
        require(purchase_paid['account']['balance_milli'] == '500', purchase_paid)
        require(purchase_paid['account']['owned_items'] == ['crown'], purchase_paid)
        before_refusals = ledger_path.read_bytes()
        tool('keeper_candle_purchase', {'item': 'crown'}, 'already_owned')
        tool('keeper_candle_purchase', {'item': 'medal'}, 'insufficient_balance')
        require(ledger_path.read_bytes() == before_refusals, 'refused purchases changed the ledger')
        paid_equipped = tool('keeper_candle_equip', {'slot': 'head', 'item': 'crown'})
        require(paid_equipped['equipment']['head'] == 'crown', paid_equipped)
        for slot in ('face', 'neck', 'hand', 'base'):
            require(paid_equipped['equipment'][slot] == paid_original[slot], paid_equipped)
        status, paid_body = request('/api/v1/keepers/item-paid-probe/items')
        paid_account = json.loads(paid_body)
        require(status == 200 and paid_account['balance_milli'] == '500', paid_account)
        require(paid_account['owned_items'] == ['crown'], paid_account)
        (root / 'paid-account.json').write_bytes(paid_body)
        status, paid_png = request('/api/v1/keepers/item-paid-probe/portrait.png?size=96')
        require(status == 200 and paid_png.startswith(b'\x89PNG\r\n\x1a\n'), status)
        require(paid_png != paid_before_png, 'paid crown did not change the served portrait')
        (root / 'paid-portrait.png').write_bytes(paid_png)
        ledger_before_restart = ledger_path.read_bytes()
        (root / 'ledger-before-restart.jsonl').write_bytes(ledger_before_restart)

    finally:
        stop_server()

# Reuse only this harness's isolated workspace and credential store. A new
# native process must recover the authoritative ledger rather than cached state.
server_generation = 2
reservation, port = reserve_port()
origin = f'http://127.0.0.1:{port}'
with (root / 'server.log').open('ab') as log:
    try:
        start_ready(log)
        status, persisted_body = request(path)
        persisted = json.loads(persisted_body)
        require(status == 200 and persisted == account_after, ('restart lost Item account', persisted))
        (root / 'account-restarted.json').write_bytes(persisted_body)
        status, persisted_png = request('/api/v1/keepers/item-runtime-probe/portrait.png?size=96')
        require(status == 200 and persisted_png == equipped_png, 'restart lost purchased equipment')
        (root / 'portrait-restarted.png').write_bytes(persisted_png)
        # Sessions belong to a process; authenticate and initialize a fresh MCP session.
        initialize_keeper_session(free_keeper_token)
        persisted_wallet = tool('keeper_candle_balance', {})
        require(persisted_wallet['balance_milli'] == '100' and persisted_wallet['owned_items'] == [item], persisted_wallet)
        tool('keeper_candle_purchase', {'item': item}, 'already_owned')
        unchanged = tool('keeper_candle_equip', {'slot': 'face', 'item': item})
        require(unchanged['changed'] is False and unchanged['equipment'] == equipped['equipment'], unchanged)
        restored_after_restart = tool('keeper_candle_equip', {'slot': 'face', 'item': 'default'})
        require(restored_after_restart['equipment'] == starting, restored_after_restart)
        status, default_after_restart = request('/api/v1/keepers/item-runtime-probe/portrait.png?size=96')
        require(status == 200 and default_after_restart == png, 'default restore after restart differs')
        initialize_keeper_session(paid_keeper_token)
        paid_persisted = tool('keeper_candle_balance', {})
        require(paid_persisted['balance_milli'] == '500' and paid_persisted['owned_items'] == ['crown'], paid_persisted)
        before_repeat_equipment = ledger_path.read_bytes()
        repeated = tool('keeper_candle_equip', {'slot': 'head', 'item': 'crown'})
        require(repeated['changed'] is False and repeated['equipment'] == paid_equipped['equipment'], repeated)
        require(ledger_path.read_bytes() == before_repeat_equipment, 'unchanged equipment appended a ledger event')
        status, paid_restarted_body = request('/api/v1/keepers/item-paid-probe/items')
        require(status == 200 and json.loads(paid_restarted_body) == paid_account, ('paid account response after restart', status, json.loads(paid_restarted_body)))
        (root / 'paid-account-restarted.json').write_bytes(paid_restarted_body)
        status, paid_restarted_png = request('/api/v1/keepers/item-paid-probe/portrait.png?size=96')
        require(status == 200 and paid_restarted_png == paid_png, 'restart lost paid equipment')
        before_refusals = ledger_path.read_bytes()
        tool('keeper_candle_purchase', {'item': 'crown'}, 'already_owned')
        tool('keeper_candle_purchase', {'item': 'medal'}, 'insufficient_balance')
        require(ledger_path.read_bytes() == before_refusals, 'restart refusals changed the ledger')
        final_ledger = ledger_path.read_bytes()
        rows = [json.loads(line) for line in final_ledger.splitlines()]
        require([row for row in rows if row['kind'] == 'paid'] == seeded_payments, 'synthetic credits changed')
        paid_purchases = [row for row in rows if row['kind'] == 'purchased' and row['keeper'] == 'item-paid-probe']
        require(len(paid_purchases) == 1 and paid_purchases[0]['item'] == 'crown' and paid_purchases[0]['amount_milli'] == 200, paid_purchases)
        (root / 'ledger-after-restart.jsonl').write_bytes(final_ledger)
        result = dict(source_sha=source, binary_sha256=hashlib.sha256(binary.read_bytes()).hexdigest(),
            fixture_sha256=config_hashes, dashboard_index_sha256=hashlib.sha256(index).hexdigest(),
            scope='Isolated CI binary over real TCP HTTP; synthetic current-schema paused Keeper metadata, synthetic 100-milli free Keeper and 700-milli paid Keeper credits and configured catalog; authenticated Keeper MCP purchase/equipment calls and ledger-backed HTTP; no lifecycle creation, model-driven decision, real earned payout or production rollout',
            requests=records, tool_calls=tool_records, browser_captured=args.capture_browser, restart_verified=True, paid_transaction_verified=True,
            synthetic_credit=True, ledger_before_restart_sha256=hashlib.sha256(ledger_before_restart).hexdigest(),
            ledger_after_restart_sha256=hashlib.sha256(final_ledger).hexdigest(), passed=True)
        (root / 'http-evidence.json').write_text(json.dumps(result, indent=2) + '\n')
        print('Isolated Item HTTP acceptance: PASS')
    finally:
        stop_server()
