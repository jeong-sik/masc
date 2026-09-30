import argparse
import base64
import hashlib
import json
from pathlib import Path
import shutil
import socket
import subprocess
import time

from playwright.sync_api import sync_playwright

parser = argparse.ArgumentParser(description='Replay complete CI fixture PTY frames in Chromium/xterm.')
parser.add_argument('--log', required=True, type=Path)
parser.add_argument('--out', required=True, type=Path)
parser.add_argument('--source-sha', required=True)
parser.add_argument('--run-id', required=True, type=int)
args = parser.parse_args()
OUT, LOG, SOURCE_SHA, RUN_ID = args.out, args.log, args.source_sha, args.run_id
records = []
for line in LOG.read_text().splitlines():
    if 'HOME_JOURNEY_FRAME ' in line:
        records.append(json.loads(line.split('HOME_JOURNEY_FRAME ', 1)[1]))
assert len(records) == 12, len(records)
assert 'Home viewport PTY: PASS (4 scenarios, 12 frames)' in LOG.read_text()
OUT.mkdir(parents=True, exist_ok=True)
with socket.socket() as sock:
    sock.bind(('127.0.0.1', 0))
    port = sock.getsockname()[1]
ttyd = subprocess.Popen([
    shutil.which('ttyd'), '-p', str(port), '-i', '127.0.0.1', '-W',
    '-t', 'rendererType=dom', '-t', 'fontSize=14', '-t', 'fontFamily=Menlo',
    '/bin/cat',
], stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
try:
    deadline = time.monotonic() + 15
    while True:
        try:
            with socket.create_connection(('127.0.0.1', port), timeout=0.2):
                break
        except OSError:
            if ttyd.poll() is not None:
                raise RuntimeError(ttyd.stderr.read().decode())
            if time.monotonic() >= deadline:
                raise RuntimeError('replay ttyd did not listen')
    with sync_playwright() as playwright:
        browser = playwright.chromium.launch(headless=True)
        for index, record in enumerate(records, 1):
            cols, rows = record['columns'], record['rows']
            raw = base64.b64decode(record['pty'], validate=True)
            stem = f"{index:02d}-{record['name']}-{cols}x{rows}-" + ('no-color' if record['no_color'] else 'color')
            (OUT / (stem + '.pty')).write_bytes(raw)
            context = browser.new_context(viewport={'width': int(cols * 8.5) + 24, 'height': rows * 18 + 24}, device_scale_factor=2)
            try:
                page = context.new_page()
                page.goto(f'http://127.0.0.1:{port}', wait_until='domcontentloaded')
                page.wait_for_function('window.term && window.term.rows > 0')
                page.evaluate('''async ({cols, rows, raw}) => {
                    window.term.reset(); window.term.resize(cols, rows);
                    const bytes = Uint8Array.from(atob(raw), c => c.charCodeAt(0));
                    await new Promise(resolve => window.term.write(bytes, resolve));
                }''', {'cols': cols, 'rows': rows, 'raw': record['pty']})
                geometry = page.evaluate('() => ({columns: window.term.cols, rows: window.term.rows})')
                assert geometry == {'columns': cols, 'rows': rows}, geometry
                lines = page.evaluate('''() => { const b=window.term.buffer.active;
                    return Array.from({length: window.term.rows}, (_, i) =>
                        b.getLine(b.viewportY+i)?.translateToString(true) || ''); }''')
                text = '\n'.join(lines)
                for expected in ['Continue', 'Choose a Keeper', 'Enter:open']:
                    assert expected in text, (stem, text)
                (OUT / (stem + '.txt')).write_text(text)
                # ttyd briefly overlays the new geometry after resize. Wait
                # for its own dismissal instead of editing the screenshot.
                page.wait_for_function('''size => Array.from(document.querySelectorAll('div'))
                    .filter(el => el.textContent === size)
                    .every(el => { const s=getComputedStyle(el);
                        return s.display === 'none' || s.visibility === 'hidden'
                            || s.opacity === '0' || el.getBoundingClientRect().width === 0; })''',
                    arg=f'{cols}x{rows}', timeout=5000)
                page.locator('.xterm-screen').screenshot(path=str(OUT / (stem + '.png')))
                record.update({'stem': stem, 'observed_terminal': geometry,
                               'raw_sha256': hashlib.sha256(raw).hexdigest()})
                record.pop('pty')
            finally:
                context.close()
        browser.close()
    manifest = {
        'source_sha': SOURCE_SHA, 'test_run_id': RUN_ID,
        'test_run_url': f'https://github.com/jeong-sik/masc/actions/runs/{RUN_ID}',
        'test_suite': 'test_tui_home_viewports_pty',
        'test_pass_line': 'Home viewport PTY: PASS (4 scenarios, 12 frames)',
        'log_sha256': hashlib.sha256(LOG.read_bytes()).hexdigest(),
        'evidence_kind': 'Chromium/xterm replay of raw CI fixture PTY frames; no local TUI binary run',
        'frames': records,
    }
    (OUT / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
    print(json.dumps({'frames': len(records), 'output': str(OUT)}))
finally:
    ttyd.terminate()
    try:
        ttyd.wait(timeout=5)
    except subprocess.TimeoutExpired:
        ttyd.kill()
        ttyd.wait()
