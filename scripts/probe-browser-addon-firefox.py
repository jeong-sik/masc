#!/usr/bin/env python3
"""Exercise the compiled native browser Addon on an isolated, real Firefox.

Only the loopback page is controlled. Browser startup, input and teardown stay
inside the installed Addon. MOZ_HEADLESS is scoped to this fixture process.
https://firefox-source-docs.mozilla.org/testing/geckodriver/Testing.html
"""
import argparse
import http.cookies
import http.server
import json
import os
from pathlib import Path
import shutil
import subprocess
import threading
import time
import uuid

FIXTURE = b'''<!doctype html><meta charset="utf-8"><title>Owned Firefox fixture</title>
<style>body{margin:0}#message{position:fixed;left:50px;top:40px;width:300px;height:100px;background:#ddd}
#react{opacity:0}#message:hover #react{opacity:1}
#double{position:fixed;left:450px;top:40px;width:180px;height:80px}
#source{position:fixed;left:80px;top:260px;width:100px;height:70px;background:orange;touch-action:none}
#destination{position:fixed;left:400px;top:260px;width:130px;height:100px;background:lightgreen}</style>
<h1>Owned Firefox fixture</h1><div id="message">Message<button id="react">Trusted reaction</button></div>
<button id="double">Double click</button><div id="source">Drag</div><div id="destination">Drop</div>
<script>
document.querySelector('#react').onclick=e=>{if(e.isTrusted)document.title='trusted reaction'};
document.querySelector('#double').ondblclick=e=>{if(e.isTrusted)document.title='trusted double click'};
const source=document.querySelector('#source');let active=null;
source.onpointerdown=e=>{if(e.isTrusted){active={id:e.pointerId,x:e.clientX,y:e.clientY,moved:false};source.setPointerCapture(e.pointerId)}};
source.onpointermove=e=>{if(active&&e.isTrusted&&e.pointerId===active.id&&(e.clientX!==active.x||e.clientY!==active.y))active.moved=true};
source.onpointerup=e=>{const start=active;active=null;const r=document.querySelector('#destination').getBoundingClientRect();
if(start&&start.moved&&e.isTrusted&&e.pointerId===start.id&&e.clientX>=r.left&&e.clientX<r.right&&e.clientY>=r.top&&e.clientY<r.bottom)document.title='trusted pointer drag'};
source.onpointercancel=()=>{active=null};
</script>'''


class Fixture(http.server.BaseHTTPRequestHandler):
    def log_message(self, *_args):
        pass

    def do_GET(self):
        if self.path == '/hold':
            with self.server.gate:
                self.server.hold_count += 1
                path = self.server.output / 'hold-requested.json'
                temporary = path.with_suffix('.tmp')
                temporary.write_text(json.dumps({'count': self.server.hold_count}))
                temporary.replace(path)
            # The probe's original detach owns cancellation. This page never
            # invents a successful navigation while its effect is being held.
            while not (self.server.output / 'release-hold').exists():
                time.sleep(.01)
        if self.path == '/must-not-open':
            (self.server.output / 'stale-input-reached').write_text('unexpected input')
        if self.path == '/login':
            self.send_response(303)
            self.send_header('Location', '/session')
            self.send_header('Set-Cookie', f'masc_fixture={self.server.cookie}; Max-Age=3600; Path=/; HttpOnly; SameSite=Lax')
            self.send_header('Content-Length', '0')
            self.end_headers()
            return
        if self.path == '/session':
            cookies = http.cookies.SimpleCookie()
            cookies.load(self.headers.get('Cookie', ''))
            cookie = cookies.get('masc_fixture')
            signed_in = cookie is not None and cookie.value == self.server.cookie
            body = f'<!doctype html><title>{"signed in" if signed_in else "signed out"}</title>'.encode()
        else:
            body = FIXTURE
        self.send_response(200)
        self.send_header('Content-Type', 'text/html; charset=utf-8')
        self.send_header('Content-Length', str(len(body)))
        self.send_header('Cache-Control', 'no-store')
        self.end_headers()
        try:
            self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError):
            pass


class Server(http.server.ThreadingHTTPServer):
    daemon_threads = True

    def __init__(self, output):
        self.output = output
        self.cookie = uuid.uuid4().hex
        self.hold_count = 0
        self.gate = threading.Lock()
        super().__init__(('127.0.0.1', 0), Fixture)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ('firefox', 'probe', 'launcher', 'guardian', 'worker', 'out'):
        parser.add_argument('--' + name, type=Path, required=True)
    args = parser.parse_args()
    output = args.out.resolve()
    output.mkdir(parents=True, exist_ok=True)
    for name in ('firefox-addon-proof.json', 'firefox-addon.png', 'hold-requested.json',
                 'release-hold', 'stale-input-reached', 'probe.log', 'workspace.txt', 'harness-result.json'):
        (output / name).unlink(missing_ok=True)
    logs = output / 'worker-logs'
    if logs.is_symlink():
        raise ValueError('proof log directory must not be a symlink')
    if logs.exists():
        for path in logs.glob('*.log'):
            path.unlink()
    repo = Path(__file__).resolve().parents[1]
    result = {'returncode': None, 'timed_out': False, 'stale_input_reached': False}
    with Server(output) as server:
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            with (output / 'probe.log').open('w') as log:
                try:
                    run = subprocess.run([
                        str(args.probe.resolve()), '--firefox', str(args.firefox.resolve()),
                        '--launcher', str(args.launcher.resolve()), '--guardian', str(args.guardian.resolve()),
                        '--worker', str(args.worker.resolve()), '--manifest', str(repo / 'addons/browser/lane.toml'),
                        '--fixture-url', f'http://127.0.0.1:{server.server_port}/', '--out', str(output),
                    ], env={**os.environ, 'MOZ_HEADLESS': '1'}, stdout=log,
                        stderr=subprocess.STDOUT, timeout=600)
                    result['returncode'] = run.returncode
                except subprocess.TimeoutExpired:
                    result['timed_out'] = True
        finally:
            (output / 'release-hold').write_text('release')
            server.shutdown()
            thread.join()
    result['stale_input_reached'] = (output / 'stale-input-reached').exists()
    workspace_file = output / 'workspace.txt'
    if workspace_file.exists():
        workspace = Path(workspace_file.read_text())
        logs.mkdir(exist_ok=True)
        for index, path in enumerate(workspace.rglob('*.log')):
            if path.is_file() and not path.is_symlink():
                shutil.copyfile(path, logs / f'{index}-{path.name}')
    (output / 'harness-result.json').write_text(json.dumps(result, indent=2) + '\n')
    print((output / 'probe.log').read_text())
    print(json.dumps(result))
    return 0 if result['returncode'] == 0 and not result['stale_input_reached'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
