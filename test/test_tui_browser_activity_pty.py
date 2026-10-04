"""Actual TUI Browser draft/save keys against synthetic Runtime HTTP.

Opening/toggling/navigation cannot write. Explicit save previews and uses CAS;
conflict recovery retains current unrelated settings and moves accepted flat
Automation paths into the canonical table. The live backend stays independently
Off. Requires a separately built matching TUI; not a real Browser/server test.
"""
import hashlib
import json
import os
import re
import sys
import threading
import tomllib

import tui_keyboard_harness as h
import tui_keyboard_keepers as lanes
import tui_keyboard_runtime as runtime
from test_tui_runtime_account_form_pty import commit_receipt

RAW = runtime.RUNTIME_CONFIG_RAW_PATH
PREVIEW = RAW + '/preview'
PATH = '/workspace/config/runtime.toml'
SOURCE = '# retain operator notes\n[browser]\ngeckodriver = "/fixture/driver"\nbinary = "/fixture/browser"\n\n[browser.live]\nenabled = false\n'
CANONICAL_OFF = '# retain operator notes\n[browser.automation]\nenabled = false\ngeckodriver = "/fixture/driver"\nbinary = "/fixture/browser"\n\n[browser.live]\nenabled = false\n'
CONCURRENT = SOURCE + '\n[providers.extra]\nvalue = "concurrent"\n'


def revision(text):
    return hashlib.sha256(b'runtime_config_source\x00' + text.encode()).hexdigest()


class Server:
    def __init__(self):
        self.text = SOURCE
        self.lock = threading.Lock()
        self.previews = 0
        self.saves = []

    def raw(self, body):
        with self.lock:
            if not body:
                return 200, {**runtime.runtime_config_read_metadata(), 'path': PATH,
                             'source_text': self.text, 'source_revision': revision(self.text)}
            request = json.loads(body)
            self.saves.append(request)
            if request['expected_source_revision'] != revision(self.text):
                return 409, {'code': 'revision_conflict', 'error': 'file changed', 'current': {
                    'source_path': PATH, 'source_text': self.text, 'source_revision': revision(self.text)}}
            self.text = request['source_text']
            return 200, commit_receipt(self.text)

    def preview(self, _body):
        with self.lock:
            self.previews += 1
            if self.previews == 1:
                return 400, {'error': 'fixture preview refused'}
        return 200, {'ok': True, 'can_save': True, 'validation': {'valid': True, 'issues': []}}

    def inventory(self, _body):
        with self.lock:
            browser = tomllib.loads(self.text).get('browser', {})
        status, value = lanes.lane_inventory_response()
        for row in value['rows']:
            if row['selection']['kind'] == 'browser':
                lane = row['selection']['lane']
                enabled = browser.get(lane, {}).get('enabled', True)
                row['state']['activity'] = 'on' if enabled else 'off'
        return status, value


def select(process, fd, output, identity, label):
    h.send_and_wait(process, fd, output, b'/' + identity.encode(),
                    re.compile(rb'\x1b\[7m[^\x1b\n]*' + re.escape(label)))
    h.send_and_wait(process, fd, output, b'\x1b', b'j/k:move')


def run(binary):
    server = Server()
    fixtures = h.keeper_runtime_http_fixtures()
    fixtures[RAW] = h.RequestHttpResponse(server.raw)
    fixtures[PREVIEW] = h.RequestHttpResponse(server.preview)
    fixtures[lanes.LANE_INVENTORY_PATH] = h.RequestHttpResponse(server.inventory)

    def interact(process, fd, _slave, output, _base):
        h.palette_go(process, fd, output, b'go keepers', b'MASC Keepers')
        h.select_keeper_row(process, fd, output, b'alpha')
        h.palette_go(process, fd, output, b'go lanes', b'All lanes')
        select(process, fd, output, 'browser/automation', b'Browser automation')
        h.send_and_wait(process, fd, output, b' ', b'Current file: On')
        with server.lock:
            server.text = CANONICAL_OFF
        h.send_and_wait(process, fd, output, b'r', b'Current file: Off')
        h.drain_until_quiet(process, fd, output)
        screen = h.screen_text(bytes(output))
        assert b'Activity draft: Off' in screen, 'clean activity retained an old flag'
        assert b'File changed.' not in screen, 'clean activity fabricated a conflict'
        with server.lock:
            server.text = SOURCE
        h.send_and_wait(process, fd, output, b'\x1b', b'All lanes')
        h.send_and_wait(process, fd, output, b' ', b'Current file: On')
        h.drain_until_quiet(process, fd, output)
        assert b'Activity draft: On' in h.screen_text(bytes(output)), 'reopen retained a clean stale draft'
        assert server.previews == 0 and not server.saves, 'following the current file submitted a write'
        h.send_and_wait(process, fd, output, b' ', b'Activity draft: Off')
        h.send_and_wait(process, fd, output, b'?', b'reapply activity')
        h.send_and_wait(process, fd, output, b'\x1b', b'MASC Browser activity')
        h.send_and_wait(process, fd, output, b'\x1b', b'All lanes')
        h.send_and_wait(process, fd, output, b' ', b'Current file: On')
        h.drain_until_quiet(process, fd, output)
        assert b'Activity draft: Off' in h.screen_text(bytes(output))
        assert server.previews == 0 and not server.saves, 'draft navigation wrote configuration'
        h.send_and_wait(process, fd, output, b's', b'fixture preview refused')
        assert not server.saves, 'preview failure reached the write endpoint'
        with server.lock:
            server.text = CONCURRENT
        h.send_and_wait(process, fd, output, b's', b'File changed; draft retained')
        with server.lock:
            assert server.text == CONCURRENT, 'conflict overwrote current settings'
            assert server.saves[-1]['expected_source_revision'] == revision(SOURCE)
        h.send_and_wait(process, fd, output, b'u', b'Activity reapplied to current settings')
        h.send_and_wait(process, fd, output, b's', b'Current file: Off')
        with server.lock:
            configured = tomllib.loads(server.text)
            assert configured['browser']['automation'] == {
                'enabled': False, 'geckodriver': '/fixture/driver', 'binary': '/fixture/browser'}
            assert 'geckodriver' not in configured['browser'] and 'binary' not in configured['browser']
            assert configured['browser']['live']['enabled'] is False
            assert configured['providers']['extra']['value'] == 'concurrent'
            assert '# retain operator notes' in server.text
            assert server.saves[-1]['expected_source_revision'] == revision(CONCURRENT)
        h.send_and_wait(process, fd, output, b'\x1b', b'All lanes')
        select(process, fd, output, 'browser/live', b'Live browser')
        h.send_and_wait(process, fd, output, b' ', b'Current file: Off')
        h.send_and_wait(process, fd, output, b' ', b'Activity draft: On')
        assert len(server.saves) == 2, 'changing another backend draft wrote configuration'
        h.send_and_wait(process, fd, output, b'q', b'All lanes')
        os.write(fd, b'q')

    h.run_terminal_scenario(binary, description='Browser activity draft, flat path migration and conflict recovery',
        interact=interact, http_fixtures=fixtures, terminal_cols=120, terminal_rows=32)
    print('Browser activity focused PTY: PASS (synthetic HTTP)')


if __name__ == '__main__':
    run(sys.argv[1])
