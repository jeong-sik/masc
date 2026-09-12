"""Replay complete native PTY frames; verify current page identity and body together."""
import argparse
import json
import os
from pathlib import Path
import signal
import socket
import subprocess
import sys
import time
from urllib.parse import urljoin
from playwright.sync_api import sync_playwright

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('evidence', type=Path)
args = parser.parse_args()
directory = args.evidence
report = json.loads((directory / 'report.json').read_text())
initial = next(step['request']['url'] for step in report['steps'] if step['label'] == '02-goto')
messages = {'alpha': 'accessibility checklist Monday', 'beta': 'client payload before migration starts', 'gamma': 'end-to-end QA Wednesday'}
targets = [{'message': messages[name], 'channel': name, 'url': urljoin(initial, name + '.html'), 'heading': name.title() + ' channel'}
           for name in ('alpha', 'beta', 'gamma')]
raw = (directory / 'tui-follow.pty').read_bytes()
lifetime = json.loads((directory / 'tui-lifetime.json').read_text())
timeline = json.loads((directory / 'tui-timeline.json').read_text())
assert lifetime['alive_at_copy'] and lifetime['alive_after_keeper_observation']
assert lifetime['exit'] is not None
assert not lifetime.get('capture_errors')
assert lifetime['copied_monotonic'] < report['turn_started_monotonic'] < lifetime['keeper_observation_finished_monotonic']
inputs = lifetime.get('input_events')
if inputs is not None:
    assert not [event for event in inputs if event['monotonic'] > report['turn_started_monotonic']]

with socket.socket() as sock:
    sock.bind(('127.0.0.1', 0))
    port = sock.getsockname()[1]
server = subprocess.Popen(['ttyd', '-p', str(port), '-i', '127.0.0.1', '-t', 'rendererType=dom',
    '-t', 'fontSize=14', '-t', 'fontFamily=Menlo', sys.executable, '-c', 'import signal; signal.pause()'],
    stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
try:
    deadline = time.monotonic() + 10
    while True:
        try:
            with socket.create_connection(('127.0.0.1', port), timeout=.2):
                break
        except OSError:
            if server.poll() is not None or time.monotonic() >= deadline:
                raise RuntimeError('owned replay terminal unavailable')
            time.sleep(.05)
    with sync_playwright() as p:
        browser = p.chromium.launch(headless=True)
        page = browser.new_page(viewport={'width': 1200, 'height': 660})
        page.goto(f'http://127.0.0.1:{port}')
        page.wait_for_function('window.term && window.term.element')
        result = page.evaluate(r'''async ({bytes, targets, rows, columns}) => {
            const term = window.term;
            term.resize(columns, rows); term.reset();
            const data = new Uint8Array(bytes), end = [27,91,63,55,104];
            const text = () => Array.from({length: rows}, (_, row) =>
                term.buffer.active.getLine(row).translateToString(true)).join('\n');
            const seen = {}; let start = 0, frames = 0;
            for (let i = 0; i <= data.length - end.length; i++) {
                if (!end.every((value, j) => data[i+j] === value)) continue;
                const offset = i + end.length;
                await new Promise(resolve => term.write(data.slice(start, offset), resolve));
                start = offset; frames++;
                const rendered = text();
                for (const target of targets) {
                    if (!seen[target.channel] && rendered.includes(target.url) && rendered.includes(target.heading) && rendered.replace(/\s+/g, ' ').includes(target.message))
                        seen[target.channel] = {offset, frame: frames, text: rendered, ...target};
                }
            }
            return {frames, seen, final_text: text(), last_complete_offset: start};
        }''', {'bytes': list(raw), 'targets': targets, 'rows': lifetime['rows'], 'columns': lifetime['columns']})
        for channel, observed in result['seen'].items():
            arrival = next((item for item in timeline if item['offset_end'] >= observed['offset']), None)
            observed['frame_bytes_received_monotonic'] = None if arrival is None else arrival['monotonic']
            (directory / ('tui-' + channel + '.pty')).write_bytes(raw[:observed['offset']])
            (directory / ('tui-' + channel + '.txt')).write_text(observed['text'])
            page.evaluate('''async bytes => {
                window.term.reset();
                await new Promise(resolve => window.term.write(new Uint8Array(bytes), resolve));
                await new Promise(requestAnimationFrame); await new Promise(requestAnimationFrame);
            }''', list(raw[:observed['offset']]))
            page.locator('.xterm-screen').screenshot(path=str(directory / ('tui-' + channel + '.png')))
        page.evaluate('''async bytes => {
            window.term.reset();
            await new Promise(resolve => window.term.write(new Uint8Array(bytes), resolve));
            await new Promise(requestAnimationFrame); await new Promise(requestAnimationFrame);
        }''', list(raw[:result['last_complete_offset']]))
        page.locator('.xterm-screen').screenshot(path=str(directory / 'tui-final.png'))
        browser.close()
    result['lifetime'] = lifetime
    result['input_log_available'] = inputs is not None
    result['proof_scope'] = 'native PTY replay; current URL, channel heading and message evidence together; no input after Keeper starts; timestamps are byte arrival'
    result['all_three_channels_followed'] = len(result['seen']) == 3
    (directory / 'tui-follow-audit.json').write_text(json.dumps(result, indent=2))
    print(json.dumps({'evidence': str(directory), 'frames': result['frames'], 'observed_channels': list(result['seen']),
                      'all_three_channels_followed': result['all_three_channels_followed'],
                      'input_log_available': inputs is not None}))
finally:
    os.killpg(server.pid, signal.SIGTERM)
    server.wait(timeout=5)
