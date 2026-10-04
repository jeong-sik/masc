"""Use the actual TUI to draft Exact activity and save through preview + CAS.

HTTP is synthetic. Opening, toggling, closing, reopening and Required refusal
must not write. Preview failure retains the draft; conflict recovery reapplies
only activity over the latest file. Read/reopen follows external activity when
no unsaved change is pending. This suite needs a separately built binary
from the tested source and is not a backend/model execution proof.
"""
import hashlib
import json
import os
import re
import sys
import threading

import tui_keyboard_harness as h
import tui_keyboard_keepers as lanes
import tui_keyboard_runtime as runtime
from test_tui_runtime_account_form_pty import commit_receipt

RAW = runtime.RUNTIME_CONFIG_RAW_PATH
PREVIEW = RAW + '/preview'
PATH = '/workspace/config/runtime.toml'
SOURCE = '''# retain operator notes
[runtime.exact_output_lanes.librarian_exact]
slots = ["first", "second"]
cli_slots = ["client"]
enabled = true

[runtime.exact_output_lanes.board_attention_exact]
slots = ["first"]
'''
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
            off = 'enabled = false' in self.text
        status, value = lanes.lane_inventory_response()
        exact = next(row for row in value['exact_snapshot']['lanes'] if row['lane_id'] == 'librarian_exact')
        row = next(row for row in value['rows'] if row['id'] == 'exact/librarian_exact')
        exact.update(declared_slots=['first', 'second'], declared_cli_slots=['client'],
                     admitted_slots=[] if off else ['first', 'second'], cli_slots=[] if off else ['client'],
                     configuration_state='off' if off else 'ready', status='off' if off else 'idle')
        row['state']['configuration'] = ({'kind': 'off', 'declared_slots': ['first', 'second'],
                                         'declared_cli_slots': ['client']} if off else {
            'kind': 'configured', **{key: exact[key] for key in (
                'declared_slots', 'declared_cli_slots', 'admitted_slots', 'cli_slots', 'dropped_slots', 'admission_error')}})
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
        select(process, fd, output, 'exact/librarian_exact', b'Librarian')
        h.send_and_wait(process, fd, output, b' ', b'Current file: On')
        with server.lock:
            server.text = SOURCE.replace('enabled = true', 'enabled = false')
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
        h.send_and_wait(process, fd, output, b'?', b'MASC Cheat Sheet')
        h.send_and_wait(process, fd, output, b'\x1b', b'MASC Exact activity')
        for dismiss in (b'?', b'\x1b'):
            print(f'Compact help hidden key: {dismiss!r}', flush=True)
            h.send_and_wait(process, fd, output, b'?', b'MASC Cheat Sheet')
            h.resize_and_wait(process, fd, output, rows=12, columns=120,
                              needle=b'terminal too small')
            os.write(fd, dismiss)
            h.drain_until_quiet(process, fd, output)
            h.resize_and_wait(process, fd, output, rows=32, columns=120,
                              needle=b'MASC Cheat Sheet')
            # Too_small owns hidden-modal keys. Dismiss only after help is visible.
            h.send_and_wait(process, fd, output, b'\x1b', b'Current file: On')
            visible = h.screen_text(bytes(output))
            assert b'Activity draft: Off' in visible, 'help dismissal closed the activity draft'
            assert server.previews == 0 and not server.saves, 'compact help dispatched a write'
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
            assert server.text == CONCURRENT.replace('enabled = true', 'enabled = false')
            assert server.saves[-1]['expected_source_revision'] == revision(CONCURRENT)
        h.send_and_wait(process, fd, output, b'\x1b', b'All lanes')
        select(process, fd, output, 'exact/board_attention_exact', b'Board Attention')
        h.send_and_wait(process, fd, output, b' ', b'Current file: On')
        h.send_and_wait(process, fd, output, b' ', b'cannot be switched off')
        assert len(server.saves) == 2, 'Required lane refusal submitted a write'
        h.send_and_wait(process, fd, output, b'q', b'All lanes')
        os.write(fd, b'q')

    h.run_terminal_scenario(binary, description='Exact activity draft, retained candidate order and conflict recovery',
        interact=interact, http_fixtures=fixtures, terminal_cols=120, terminal_rows=32)
    print('Exact activity focused PTY: PASS (synthetic HTTP)')

def run_compact_quit(binary):
    server = Server()
    fixtures = h.keeper_runtime_http_fixtures()
    fixtures[RAW] = h.RequestHttpResponse(server.raw)
    fixtures[PREVIEW] = h.RequestHttpResponse(server.preview)
    fixtures[lanes.LANE_INVENTORY_PATH] = h.RequestHttpResponse(server.inventory)

    def interact(process, fd, _slave, output, _base):
        h.palette_go(process, fd, output, b'go keepers', b'MASC Keepers')
        h.select_keeper_row(process, fd, output, b'alpha')
        h.palette_go(process, fd, output, b'go lanes', b'All lanes')
        select(process, fd, output, 'exact/librarian_exact', b'Librarian')
        h.send_and_wait(process, fd, output, b' ', b'Current file: On')
        h.send_and_wait(process, fd, output, b' ', b'Activity draft: Off')
        h.resize_and_wait(process, fd, output, rows=12, columns=120,
                          needle=b'terminal too small')
        os.write(fd, b'q')
        h.drain_until_quiet(process, fd, output)
        h.resize_and_wait(process, fd, output, rows=32, columns=120,
                          needle=b'MASC Exact activity')
        assert b'Activity draft: Off' in h.screen_text(bytes(output)), 'compact quit closed the hidden Exact draft'
        assert server.previews == 0 and not server.saves, 'compact quit dispatched a write'
        h.resize_and_wait(process, fd, output, rows=12, columns=120,
                          needle=b'terminal too small')
        os.write(fd, b'q')
        assert process.wait(timeout=3) == 0, 'second compact q did not finish the visible quit flow'

    h.run_terminal_scenario(binary, description='Compact overlay owns Exact quit',
        interact=interact, http_fixtures=fixtures, terminal_cols=120, terminal_rows=32)
    print('Exact compact quit PTY: PASS (synthetic HTTP)')


if __name__ == '__main__':
    run(sys.argv[1])
    run_compact_quit(sys.argv[1])
