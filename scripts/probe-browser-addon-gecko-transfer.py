#!/usr/bin/env python3
"""Actual owned Gecko file transfers through the native browser Addon.

The fixture receives the File body only after the original host snapshot scope
has ended. Downloads come from a loopback attachment response. No WebDriver or
browser evaluation client is used outside the compiled production tool path.
"""
import argparse
import hashlib
import http.server
import json
import os
from pathlib import Path
import shutil
import subprocess
import threading
from urllib.parse import unquote

FIXTURE = b'''<!doctype html><meta charset="utf-8"><title>Gecko transfer fixture</title>
<h1>Owned Gecko transfer fixture</h1>
<input type="file" id="file"><button id="submit">Submit retained file</button>
<a id="download" href="/download" download="download.bin">Download binary</a>
<script>
const input=document.querySelector('#file');
input.onchange=()=>{document.title=input.files.length===1?'file selected':'invalid selection'};
document.querySelector('#submit').onclick=async e=>{
 if(!e.isTrusted){document.title='untrusted submit';return}
 const file=input.files[0];if(!file){document.title='file absent';return}
 try{const reply=await fetch('/uploaded',{method:'POST',headers:{'X-Fixture-Filename':encodeURIComponent(file.name)},body:file});
 document.title=await reply.text()}catch(error){document.title='upload failed'}
};
</script>'''


class Fixture(http.server.BaseHTTPRequestHandler):
    def log_message(self, *_args):
        pass

    def do_GET(self):
        if self.path == '/download':
            body = self.server.payload
            with self.server.gate:
                self.server.download_count += 1
                (self.server.output / 'download.json').write_text(json.dumps({'count': self.server.download_count}))
            self.send_response(200)
            self.send_header('Content-Type', 'application/octet-stream')
            self.send_header('Content-Disposition', 'attachment; filename="download.bin"')
        elif self.path == '/':
            body = FIXTURE
            self.send_response(200)
            self.send_header('Content-Type', 'text/html; charset=utf-8')
        else:
            self.send_error(404)
            return
        self.send_header('Content-Length', str(len(body)))
        self.send_header('Cache-Control', 'no-store')
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self):
        if self.path != '/uploaded':
            self.send_error(404)
            return
        length = int(self.headers.get('Content-Length', '0'))
        if length != len(self.server.payload):
            self.send_error(400, 'unexpected fixture length')
            return
        body = self.rfile.read(length)
        filename = unquote(self.headers.get('X-Fixture-Filename', ''))
        with self.server.gate:
            self.server.upload_count += 1
            (self.server.output / 'uploaded.bin').write_bytes(body)
            receipt = {'count': self.server.upload_count, 'filename': filename,
                       'bytes': len(body), 'sha256': hashlib.sha256(body).hexdigest()}
            (self.server.output / 'upload.json').write_text(json.dumps(receipt))
        accepted = body == self.server.payload and filename == 'payload.bin'
        answer = b'upload confirmed' if accepted else b'upload mismatch'
        self.send_response(200 if accepted else 400)
        self.send_header('Content-Type', 'text/plain')
        self.send_header('Content-Length', str(len(answer)))
        self.end_headers()
        self.wfile.write(answer)


class Server(http.server.ThreadingHTTPServer):
    daemon_threads = True

    def __init__(self, output, payload):
        self.output = output
        self.payload = payload
        self.gate = threading.Lock()
        self.upload_count = 0
        self.download_count = 0
        super().__init__(('127.0.0.1', 0), Fixture)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ('firefox', 'driver', 'probe', 'launcher', 'guardian', 'worker', 'out'):
        parser.add_argument('--' + name, required=True, type=Path)
    args = parser.parse_args()
    output = args.out.resolve()
    output.mkdir(parents=True, exist_ok=True)
    for name in ('uploaded.bin', 'upload.json', 'download.json', 'workspace.txt',
                 'gecko-transfer-proof.json', 'gecko-transfer.png', 'harness-result.json', 'probe.log'):
        (output / name).unlink(missing_ok=True)
    logs = output / 'worker-logs'
    if logs.is_symlink():
        raise ValueError('worker log directory must not be a symlink')
    if logs.exists():
        for path in logs.glob('*.log'):
            path.unlink()
    # Binary NULs and every byte value cross the actual File/download boundary.
    payload = bytes(index % 256 for index in range(65536 + 31))
    path = output / 'payload.bin'
    path.write_bytes(payload)
    (output / 'payload.json').write_text(json.dumps({'bytes': len(payload), 'sha256': hashlib.sha256(payload).hexdigest()}))
    repo = Path(__file__).resolve().parents[1]
    result = {'returncode': None, 'timed_out': False}
    with Server(output, payload) as server:
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            with (output / 'probe.log').open('w') as log:
                try:
                    run = subprocess.run([
                        str(args.probe.resolve()), '--firefox', str(args.firefox.resolve()),
                        '--driver', str(args.driver.resolve()), '--payload', str(path),
                        '--launcher', str(args.launcher.resolve()), '--guardian', str(args.guardian.resolve()),
                        '--worker', str(args.worker.resolve()), '--manifest', str(repo / 'addons/browser/lane.toml'),
                        '--fixture-url', f'http://127.0.0.1:{server.server_port}/', '--out', str(output),
                    ], env={**os.environ, 'MOZ_HEADLESS': '1'}, stdout=log,
                        stderr=subprocess.STDOUT, timeout=600)
                    result['returncode'] = run.returncode
                except subprocess.TimeoutExpired:
                    result['timed_out'] = True
        finally:
            server.shutdown()
            thread.join()
        result.update(upload_requests=server.upload_count, download_requests=server.download_count)
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
    return 0 if result['returncode'] == 0 and result['upload_requests'] == result['download_requests'] == 1 else 1


if __name__ == '__main__':
    raise SystemExit(main())
