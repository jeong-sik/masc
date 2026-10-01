"""Exercise real TCP HTTP routes with an isolated exact-source CI probe binary.

No live instance is contacted. Login writes credentials inside the isolated
workspace; its auth directory is removed on exit and excluded from evidence.
Keeper metadata, empty ledger and catalog are synthetic inputs, not evidence
of lifecycle creation, a real payout or a Keeper purchase.
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
input_paths = ['scripts/item-http-acceptance.py'] + [
    f'test/fixtures/item-http/{name}'
    for name in ('runtime.toml', 'candle.toml', 'keeper.toml', 'keeper.json')]
verified_inputs = {}
for relative in input_paths:
    expected = subprocess.check_output(['git', '-C', str(repo), 'show', f'{source}:{relative}'], env=env)
    actual = (repo / relative).read_bytes()
    require(actual == expected, f'acceptance input differs from source SHA: {relative}')
    verified_inputs[relative] = actual
harness_sha256 = hashlib.sha256(verified_inputs['scripts/item-http-acceptance.py']).hexdigest()
config_hashes = {}
for src, dst in [('runtime.toml', 'config/runtime.toml'),
                 ('candle.toml', 'config/candle.toml'),
                 ('keeper.toml', 'config/keepers/item-runtime-probe.toml'),
                 ('keeper.json', 'keepers/item-runtime-probe.json')]:
    target = base / '.masc' / dst
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_bytes(verified_inputs[f'test/fixtures/item-http/{src}'])
    config_hashes[src] = hashlib.sha256(target.read_bytes()).hexdigest()
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
           MASC_HOST='127.0.0.1', MASC_HTTP_AUTH_STRICT='1',
           MASC_KEEPER_AUTONOMOUS_ENABLED='0',
           MASC_ORCHESTRATOR_ENABLED='0', MASC_OTEL_ENABLED='0')
login = subprocess.run([str(binary), 'login', '--base-path', str(base),
    '--host', '127.0.0.1', '--port', str(port), '--agent', 'item-probe-worker',
    '--role', 'worker', '--client-env', 'MCP_TOKEN', '--no-expiry', '--json'],
    env=env, capture_output=True, text=True, check=True)
token = json.loads(login.stdout)['bearer_token']
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
        status, index, _ = request('/dashboard/', False)
        require(status == 200, status)
        require(hashlib.sha256(index).hexdigest() == hashlib.sha256(
            (dashboard / 'index.html').read_bytes()).hexdigest(), 'served index differs')
        result = dict(source_sha=source, binary_sha256=hashlib.sha256(binary.read_bytes()).hexdigest(),
            harness_sha256=harness_sha256, fixture_sha256=config_hashes, dashboard_index_sha256=hashlib.sha256(index).hexdigest(),
            scope='Isolated CI binary over real TCP HTTP; synthetic current-schema paused Keeper metadata, empty test ledger and configured catalog; no lifecycle creation, production rollout or Keeper tool execution',
            requests=records, passed=True)
        (root / 'http-evidence.json').write_text(json.dumps(result, indent=2) + '\n')
        print('Isolated Item HTTP acceptance: PASS')
    finally:
        stop_server()
