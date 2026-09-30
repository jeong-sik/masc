"""Exercise real TCP HTTP routes with an isolated exact-source CI probe binary.

No live instance is contacted. Login writes credentials inside the isolated
workspace; its auth directory is removed on exit and excluded from evidence.
Keeper metadata, empty ledger and catalog are synthetic inputs, not evidence
of lifecycle creation, a real payout or a Keeper purchase.
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

def require(condition, detail):
    if not condition:
        raise RuntimeError(detail)


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
require(identity['schema'] == 'masc.dashboard-build.v1', 'dashboard build identity schema differs')
require(identity['source_commit'] == args.source_sha, 'dashboard identity differs')
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
           MASC_HOST='127.0.0.1', MASC_KEEPER_AUTONOMOUS_ENABLED='0',
           MASC_ORCHESTRATOR_ENABLED='0', MASC_OTEL_ENABLED='0')
login = subprocess.run([str(binary), 'login', '--base-path', str(base),
    '--host', '127.0.0.1', '--port', str(port), '--agent', 'item-probe-admin',
    '--role', 'admin', '--client-env', 'MCP_TOKEN', '--no-expiry', '--json'],
    env=env, capture_output=True, text=True, check=True)
token = json.loads(login.stdout)['bearer_token']
origin = f'http://127.0.0.1:{port}'
# These requests target only the isolated child server and carry local auth.
# Proxy settings in the invoking shell must not route them elsewhere.
http = urllib.request.build_opener(urllib.request.ProxyHandler({}))
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
        return response.status, body

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
        require(status in (401, 403), ('account route bypassed auth', status))
        status, body = request(path)
        account = json.loads(body)
        (root / 'account.json').write_bytes(body)
        require(status == 200 and account['status'] == 'ready', account)
        require(account['balance_milli'] == '0' and account['owned_items'] == [], account)
        require(len(account['catalog']) == 18, account)
        glasses = next(item for item in account['catalog'] if item['id'] == 'glasses')
        require(glasses['price_status'] == 'priced' and glasses['price_milli'] == '0', glasses)
        status, png = request('/api/v1/keepers/item-runtime-probe/portrait.png?size=96')
        require(status == 200 and png.startswith(b'\x89PNG\r\n\x1a\n'), status)
        (root / 'portrait.png').write_bytes(png)
        status, index = request('/dashboard/', False)
        require(status == 200, status)
        require(hashlib.sha256(index).hexdigest() == hashlib.sha256(
            (dashboard / 'index.html').read_bytes()).hexdigest(), 'served index differs')
        result = dict(source_sha=source, binary_sha256=hashlib.sha256(binary.read_bytes()).hexdigest(),
            fixture_sha256=config_hashes, dashboard_index_sha256=hashlib.sha256(index).hexdigest(),
            scope='Isolated CI binary over real TCP HTTP; synthetic current-schema paused Keeper metadata, empty test ledger and configured catalog; no lifecycle creation, production rollout or Keeper tool execution',
            requests=records, passed=True)
        (root / 'http-evidence.json').write_text(json.dumps(result, indent=2) + '\n')
        print('Isolated Item HTTP acceptance: PASS')
    finally:
        server.terminate()
        try:
            server.wait(timeout=10)
        except subprocess.TimeoutExpired:
            server.kill()
            server.wait()
