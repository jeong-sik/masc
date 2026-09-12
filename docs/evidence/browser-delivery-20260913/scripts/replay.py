"""Render recorded PTY bytes in xterm; this is a replay, not a live server run."""
import argparse
import json
import os
from pathlib import Path
import signal
import socket
import subprocess
import sys
import time

from playwright.sync_api import sync_playwright

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('recording', type=Path)
parser.add_argument('--columns', type=int, required=True)
parser.add_argument('--rows', type=int, required=True)
parser.add_argument('--output', type=Path, required=True)
args = parser.parse_args()
with socket.socket() as sock:
    sock.bind(('127.0.0.1', 0))
    port = sock.getsockname()[1]
server = subprocess.Popen([
    'ttyd', '-p', str(port), '-i', '127.0.0.1',
    '-t', 'rendererType=dom', '-t', 'fontSize=14', '-t', 'fontFamily=Menlo',
    sys.executable, '-c', 'import signal; signal.pause()',
], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
try:
    deadline = time.monotonic() + 10
    while True:
        try:
            with socket.create_connection(('127.0.0.1', port), timeout=.2):
                break
        except OSError:
            if server.poll() is not None or time.monotonic() >= deadline:
                raise RuntimeError('fixture terminal did not start')
            time.sleep(.05)
    with sync_playwright() as p:
        browser = p.chromium.launch(headless=True)
        page = browser.new_page(viewport={'width': args.columns * 9 + 30, 'height': args.rows * 18 + 30})
        page.goto(f'http://127.0.0.1:{port}')
        page.wait_for_function('window.term && window.term.element')
        page.evaluate('''async ({columns, rows, bytes}) => {
            window.term.resize(columns, rows);
            window.term.reset();
            await new Promise(resolve => window.term.write(new Uint8Array(bytes), resolve));
            if (typeof window.term.onRender !== 'function' || typeof window.term.refresh !== 'function')
                throw new Error('xterm render completion API unavailable');
            await new Promise(resolve => {
                const subscription = window.term.onRender(({start, end}) => {
                    if (start === 0 && end >= rows - 1) {
                        subscription.dispose();
                        requestAnimationFrame(() => requestAnimationFrame(resolve));
                    }
                });
                window.term.refresh(0, rows - 1);
            });
        }''', {'columns': args.columns, 'rows': args.rows, 'bytes': list(args.recording.read_bytes())})
        # ttyd briefly overlays resize dimensions; wait for its actual removal.
        page.get_by_text(f'{args.columns}x{args.rows}', exact=True).wait_for(state='hidden')
        terminal = page.locator('.xterm-screen')
        terminal.screenshot(path=str(args.output))
        text = page.evaluate(r'''rows => Array.from({length: rows}, (_, row) =>
            window.term.buffer.active.getLine(row).translateToString(true)).join('\n')''', args.rows)
        args.output.with_suffix('.txt').write_text(text)
        print(json.dumps({'replay_screenshot': str(args.output), 'columns': args.columns,
                          'rows': args.rows, 'text': text}))
        browser.close()
finally:
    os.killpg(server.pid, signal.SIGTERM)
    server.wait(timeout=5)
