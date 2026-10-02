"""Exercise real TCP HTTP routes with an isolated exact-source CI probe binary.

No live instance is contacted. Login writes credentials inside the isolated
workspace; its auth directory is removed on exit and excluded from evidence.
Keeper metadata, empty ledger and catalog are synthetic inputs, not evidence
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

class RejectRedirects(urllib.request.HTTPRedirectHandler):
    """Keep authenticated probe requests on their original route and origin."""
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        raise urllib.error.HTTPError(req.full_url, code, msg, headers, fp)


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
repo = Path(__file__).resolve().parents[1]
fixture_paths = [('runtime.toml', 'config/runtime.toml'),
                 ('candle.toml', 'config/candle.toml'),
                 ('keeper.toml', 'config/keepers/item-runtime-probe.toml'),
                 ('keeper.json', 'keepers/item-runtime-probe.json')]
input_paths = ['scripts/item-http-acceptance.py'] + [
    f'test/fixtures/item-http/{name}' for name, _ in fixture_paths]
if args.capture_browser:
    input_paths.append('dashboard/e2e/item-server.mjs')
verified_inputs = {}
for relative in input_paths:
    expected = subprocess.check_output(['git', '-C', str(repo), 'show', f'{source}:{relative}'], env=env)
    actual = (repo / relative).read_bytes()
    require(actual == expected, f'acceptance input differs from source SHA: {relative}')
    verified_inputs[relative] = actual
harness_sha256 = hashlib.sha256(verified_inputs['scripts/item-http-acceptance.py']).hexdigest()
config_hashes = {}
for src, dst in fixture_paths:
    target = base / '.masc' / dst
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_bytes(verified_inputs[f'test/fixtures/item-http/{src}'])
    config_hashes[src] = hashlib.sha256(target.read_bytes()).hexdigest()
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
    '--host', '127.0.0.1', '--port', str(port), '--agent', 'item-probe-worker',
    '--role', 'worker', '--client-env', 'MCP_TOKEN', '--no-expiry', '--json'],
    env=env, capture_output=True, text=True, check=True)
token = json.loads(login.stdout)['bearer_token']
keeper_login = subprocess.run([str(binary), 'login', '--base-path', str(base),
    '--host', '127.0.0.1', '--port', str(port), '--agent', 'item-runtime-probe',
    '--role', 'worker', '--client-env', 'ITEM_PROBE_TOKEN', '--no-expiry', '--json'],
    env=env, capture_output=True, text=True, check=True)
keeper_token = json.loads(keeper_login.stdout)['bearer_token']
origin = f'http://127.0.0.1:{port}'
# These requests target only the isolated child server and carry local auth.
# Proxy settings in the invoking shell must not route them elsewhere.
http = urllib.request.build_opener(urllib.request.ProxyHandler({}), RejectRedirects())
records = []
def request(path, authenticated=True):
    headers = {'Authorization': 'Bearer ' + token} if authenticated else {}
    req = urllib.request.Request(origin + path, headers=headers)
    try:
        response = http.open(req, timeout=5)
    except urllib.error.HTTPError as error:
        response = error
    with response:
        body = response.read()
        records.append({'path': path, 'authenticated': authenticated,
                        'status': response.status, 'sha256': hashlib.sha256(body).hexdigest()})
        return response.status, body, response.headers

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
        require(len(events) == 1, 'expected one JSON-RPC SSE event')
        envelope = events[0]
    require(envelope.get('id') == rpc_sequence and 'error' not in envelope, envelope)
    return envelope['result']

def tool(name, arguments, error_code=None, validation_reason=None):
    result = rpc('tools/call', {'name': name, 'arguments': arguments})
    failed = result.get('isError', False)
    require(failed == (error_code is not None or validation_reason is not None), result)
    data = result['structuredContent']
    if error_code is not None:
        require(data['error_code'] == error_code, data)
    if validation_reason is not None:
        require(data['validation'] == 'agent_core_tool_middleware', data)
        require(data['reason'] == validation_reason, data)
    tool_records.append({'name': name, 'arguments': arguments, 'is_error': failed,
                         'data': data})
    return data

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
        attempt_record_start = len(records)
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
                    status, body, _ = request('/health?full=1', False)
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
                        status, _, _ = request('/health/ready', False)
                        if status == 200:
                            return
                except (OSError, urllib.error.URLError):
                    pass
                time.sleep(0.2)
        except PortCollision:
            del records[attempt_record_start:]
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
        status, _, _ = request(path, False)
        require(status in (401, 403), ('account route bypassed auth', status))
        status, body, _ = request(path)
        account = json.loads(body)
        (root / 'account.json').write_bytes(body)
        require(status == 200 and account['status'] == 'ready'
                and account['keeper'] == 'item-runtime-probe', account)
        require(account['balance_milli'] == '0' and account['owned_items'] == [], account)
        glasses = next(item for item in account['catalog'] if item['id'] == 'glasses')
        require(glasses['price_status'] == 'priced' and glasses['price_milli'] == '0', glasses)
        crown = next(item for item in account['catalog'] if item['id'] == 'crown')
        require(crown['price_status'] == 'priced' and crown['price_milli'] == '200', crown)
        portrait_path = '/api/v1/keepers/item-runtime-probe/portrait.png?size=96'
        status, _, _ = request(portrait_path, False)
        require(status in (401, 403), ('portrait route bypassed auth', status))
        status, png, headers = request(portrait_path)
        require(status == 200, status)
        require(headers.get('Content-Type') is not None
                and headers.get_content_type() == 'image/png',
                ('portrait response media type differs', headers.get('Content-Type')))
        validate_portrait(png, 96)
        (root / 'portrait.png').write_bytes(png)
        rpc('initialize', {'protocolVersion': '2025-11-25', 'capabilities': {},
                           'clientInfo': {'name': 'item-http-acceptance', 'version': '1'}})
        rpc('notifications/initialized', {}, notification=True)
        own = tool('keeper_candle_balance', {})
        require(own['keeper'] == 'item-runtime-probe' and own['balance_milli'] == '0', own)
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
        status, updated, _ = request(path)
        account_after = json.loads(updated)
        require(status == 200 and account_after['balance_milli'] == '0', account_after)
        require(account_after['owned_items'] == [item], account_after)
        (root / 'account-after.json').write_bytes(updated)
        status, equipped_png, _ = request('/api/v1/keepers/item-runtime-probe/portrait.png?size=96')
        require(status == 200, status)
        validate_portrait(equipped_png, 96)
        require(equipped_png != png, 'equipment did not change the served portrait')
        (root / 'portrait-equipped.png').write_bytes(equipped_png)
        if args.capture_browser:
            browser_script = repo / 'dashboard/e2e/item-server.mjs'
            subprocess.run(['node', str(browser_script)], input=json.dumps({
                'origin': origin, 'token': token, 'output': str(root),
                'sourceSha': source, 'keeper': 'item-runtime-probe', 'ownedItem': item,
            }), text=True, check=True, cwd=browser_script.parent, env=env)
        restored = tool('keeper_candle_equip', {'slot': 'face', 'item': 'default'})
        require(restored['equipment'] == starting, restored)
        status, restored_png, _ = request('/api/v1/keepers/item-runtime-probe/portrait.png?size=96')
        require(status == 200 and restored_png == png, 'default did not restore the served portrait')
        status, index, _ = request('/dashboard/', False)
        require(status == 200, status)
        require(hashlib.sha256(index).hexdigest() == hashlib.sha256(
            (dashboard / 'index.html').read_bytes()).hexdigest(), 'served index differs')
        result = dict(source_sha=source, binary_sha256=hashlib.sha256(binary.read_bytes()).hexdigest(),
            harness_sha256=harness_sha256, fixture_sha256=config_hashes, dashboard_index_sha256=hashlib.sha256(index).hexdigest(),
            scope='Isolated CI binary over real TCP HTTP; synthetic current-schema paused Keeper metadata, empty test ledger and configured catalog; authenticated Keeper MCP purchase/equipment calls and ledger-backed HTTP; no lifecycle creation, model-driven decision, paid purchase/payout or production rollout',
            requests=records, tool_calls=tool_records, browser_captured=args.capture_browser, passed=True)
        (root / 'http-evidence.json').write_text(json.dumps(result, indent=2) + '\n')
        print('Isolated Item HTTP acceptance: PASS')
    finally:
        stop_server()
