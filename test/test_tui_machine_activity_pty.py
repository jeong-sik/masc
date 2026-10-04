"""Native TUI machine settings keys against synthetic Runtime/inventory HTTP.

Select MSX/DOS independently; draft navigation performs no writes. A preview
failure, CAS conflict and ambiguous commit preserve intent. File settings and
the server reading stay separate. Requires a separately built matching TUI;
this fixture does not execute a real server or machine.
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
PATH = '/workspace/config/runtime.toml'
SOURCE = '# operator note\n[machines.msx]\nenabled = true\n[machines.dos]\nenabled = false\n'


def revision(text):
    return hashlib.sha256(b'runtime_config_source\x00' + text.encode()).hexdigest()


class Server:
    def __init__(self):
        self.text = SOURCE
        self.lock = threading.Lock()
        self.previews = 0
        self.saves = []
        self.ambiguous = False
        self.msx_observed = False

    def raw(self, body):
        with self.lock:
            if not body:
                return 200, {**runtime.runtime_config_read_metadata(), 'path': PATH,
                             'source_text': self.text, 'source_revision': revision(self.text)}
            request = json.loads(body)
            self.saves.append(request)
            assert request['expected_source_path'] == PATH, 'save lost its observed configuration path'
            if request['expected_source_revision'] != revision(self.text):
                return 409, {'code': 'revision_conflict', 'error': 'file changed', 'current': {
                    'source_path': PATH, 'source_text': self.text, 'source_revision': revision(self.text)}}
            self.text = request['source_text']
            self.msx_observed = tomllib.loads(self.text)['machines']['msx']['enabled']
            if self.ambiguous:
                self.ambiguous = False
                return 503, {'error': 'fixture lost commit acknowledgement'}
            return 200, commit_receipt(self.text)

    def preview(self, _body):
        with self.lock:
            self.previews += 1
            if self.previews == 1:
                return 400, {'error': 'fixture preview refused'}
        return 200, {'ok': True, 'can_save': True, 'validation': {'valid': True, 'issues': []}}

    def inventory(self, _body):
        with self.lock:
            configured = tomllib.loads(self.text)['machines']
            observed = self.msx_observed
        status, value = lanes.lane_inventory_response()
        assert isinstance(value, dict) and isinstance(value.get('rows'), list)
        for row in value['rows']:
            if row['selection']['kind'] == 'machine':
                machine = row['selection']['machine']
                enabled = observed if machine == 'msx' else configured[machine]['enabled']
                row['state']['activity'] = 'on' if enabled else 'off'
        return status, value


def select(process, fd, output, machine):
    h.send_and_wait(process, fd, output, b'/machine/' + machine.encode(),
                    re.compile(rb'\x1b\[7m[^\x1b\n]*' + machine.upper().encode()))
    h.send_and_wait(process, fd, output, b'\x1b', b'j/k:move')


def run(binary):
    server = Server()
    fixtures = h.keeper_runtime_http_fixtures()
    fixtures[RAW] = h.RequestHttpResponse(server.raw)
    fixtures[RAW + '/preview'] = h.RequestHttpResponse(server.preview)
    fixtures[lanes.LANE_INVENTORY_PATH] = h.RequestHttpResponse(server.inventory)

    def interact(process, fd, _slave, output, _base):
        h.palette_go(process, fd, output, b'go keepers', b'MASC Keepers')
        h.select_keeper_row(process, fd, output, b'alpha')
        h.palette_go(process, fd, output, b'go lanes', b'All lanes')
        select(process, fd, output, 'msx')
        h.send_and_wait(process, fd, output, b' ', b'Current file: On')
        h.drain_until_quiet(process, fd, output)
        assert b'Server activity: Off' in h.screen_text(bytes(output))
        h.send_and_wait(process, fd, output, b' ', b'Activity draft: Off')
        h.send_and_wait(process, fd, output, b'?', b'MASC Cheat Sheet')
        h.send_and_wait(process, fd, output, b'\x1b', b'MASC Machine activity')
        for dismiss in (b'?', b'\x1b'):
            print(f'Compact Machine help hidden key: {dismiss!r}', flush=True)
            h.send_and_wait(process, fd, output, b'?', b'MASC Cheat Sheet')
            h.resize_and_wait(process, fd, output, rows=12, columns=120,
                              needle=b'terminal too small')
            os.write(fd, dismiss)
            h.drain_until_quiet(process, fd, output)
            h.resize_and_wait(process, fd, output, rows=40, columns=120,
                              needle=b'MASC Cheat Sheet')
            h.send_and_wait(process, fd, output, b'\x1b', b'Current file: On')
            assert b'Activity draft: Off' in h.screen_text(bytes(output)), 'help dismissal closed the Machine activity draft'
            with server.lock:
                assert server.previews == 0 and not server.saves, 'compact help dispatched a write'
        h.send_and_wait(process, fd, output, b'\x1b', b'All lanes')
        h.send_and_wait(process, fd, output, b' ', b'Current file: On')
        h.drain_until_quiet(process, fd, output)
        assert b'Activity draft: Off' in h.screen_text(bytes(output))
        assert not server.saves and server.previews == 0
        h.send_and_wait(process, fd, output, b's', b'fixture preview refused')
        h.drain_until_quiet(process, fd, output)
        assert b'Server activity: Off' in h.screen_text(bytes(output)), 'known preview refusal erased the last server reading'
        assert not server.saves
        with server.lock:
            server.text += '\n[providers.extra]\nvalue = "keep"\n'
        h.send_and_wait(process, fd, output, b's', b'File changed; draft retained')
        h.send_and_wait(process, fd, output, b'u', b'Activity reapplied to current settings')
        with server.lock:
            server.ambiguous = True
        h.send_and_wait(process, fd, output, b's', b'Current file: Off')
        h.drain_until_quiet(process, fd, output)
        with server.lock:
            save_count = len(server.saves)
            data = tomllib.loads(server.text)
            assert data['machines'] == {'msx': {'enabled': False}, 'dos': {'enabled': False}}
            assert data['providers']['extra']['value'] == 'keep'
            assert '# operator note' in server.text
        assert b'Activity draft: Off' in h.screen_text(bytes(output))
        h.send_and_wait(process, fd, output, b's', b'File changed.')
        assert len(server.saves) == save_count, 'uncertain write was retried automatically'
        h.send_and_wait(process, fd, output, b'u', b'Activity reapplied to current settings')
        h.send_and_wait(process, fd, output, b'\x1b', b'All lanes')
        select(process, fd, output, 'dos')
        h.send_and_wait(process, fd, output, b' ', b'Current file: Off')
        h.send_and_wait(process, fd, output, b' ', b'Activity draft: On')
        h.send_and_wait(process, fd, output, b's', b'Current file: On')
        h.drain_until_quiet(process, fd, output)
        assert b'Server activity: On' in h.screen_text(bytes(output))
        with server.lock:
            data = tomllib.loads(server.text)
            assert data['machines'] == {'msx': {'enabled': False}, 'dos': {'enabled': True}}
        h.send_and_wait(process, fd, output, b'q', b'All lanes')
        os.write(fd, b'q')

    h.run_terminal_scenario(binary, description='machine activity draft, conflict and ambiguous save',
                            interact=interact, http_fixtures=fixtures,
                            terminal_cols=120, terminal_rows=40)

def run_unavailable_file(binary):
    server = Server()
    fixtures = h.keeper_runtime_http_fixtures()
    fixtures[RAW] = (503, {'error': 'fixture raw file unavailable'})
    inventory_reads = []
    def inventory(body):
        inventory_reads.append(True)
        return server.inventory(body)
    fixtures[lanes.LANE_INVENTORY_PATH] = h.RequestHttpResponse(inventory)
    requests = []

    def interact(process, fd, _slave, output, _base):
        h.palette_go(process, fd, output, b'go lanes', b'All lanes')
        select(process, fd, output, 'msx')
        before = len(inventory_reads)
        h.send_and_wait(process, fd, output, b' ', b'fixture raw file unavailable')
        h.drain_until_quiet(process, fd, output)
        assert len(inventory_reads) > before, 'file failure prevented the independent inventory request'
        assert b'Server activity: Off' in h.screen_text(bytes(output))
        assert b'Current file: unverified' in h.screen_text(bytes(output))
        h.send_and_wait(process, fd, output, b's', b'Read the current configuration')
        assert not [path for path, _ in requests if path.startswith(RAW)], 'unverified file dispatched a write or preview'
        assert not server.saves
        h.send_and_wait(process, fd, output, b'q', b'All lanes')
        os.write(fd, b'q')

    h.run_terminal_scenario(binary, description='Machine observation survives unavailable file',
        interact=interact, http_fixtures=fixtures, http_requests=requests,
        terminal_cols=120, terminal_rows=40)
    print('Machine unavailable file / independent server activity / no save: PASS')


def run_compact_quit(binary):
    server = Server()
    fixtures = h.keeper_runtime_http_fixtures()
    fixtures[RAW] = h.RequestHttpResponse(server.raw)
    fixtures[RAW + '/preview'] = h.RequestHttpResponse(server.preview)
    fixtures[lanes.LANE_INVENTORY_PATH] = h.RequestHttpResponse(server.inventory)

    def interact(process, fd, _slave, output, _base):
        h.palette_go(process, fd, output, b'go keepers', b'MASC Keepers')
        h.select_keeper_row(process, fd, output, b'alpha')
        h.palette_go(process, fd, output, b'go lanes', b'All lanes')
        select(process, fd, output, 'msx')
        h.send_and_wait(process, fd, output, b' ', b'Current file: On')
        h.send_and_wait(process, fd, output, b' ', b'Activity draft: Off')
        h.resize_and_wait(process, fd, output, rows=12, columns=120,
                          needle=b'terminal too small')
        os.write(fd, b'q')
        h.drain_until_quiet(process, fd, output)
        h.resize_and_wait(process, fd, output, rows=32, columns=120,
                          needle=b'MASC Machine activity')
        assert b'Activity draft: Off' in h.screen_text(bytes(output)), 'compact quit closed the hidden Machine draft'
        assert server.previews == 0 and not server.saves, 'compact quit dispatched a write'
        h.resize_and_wait(process, fd, output, rows=12, columns=120,
                          needle=b'terminal too small')
        exit_start = len(output)
        os.write(fd, b'q')
        h.wait_for_output(process, fd, output, b'Goodbye!', start=exit_start, timeout=3.0)

    h.run_terminal_scenario(binary, description='Compact overlay owns Machine quit',
        interact=interact, http_fixtures=fixtures, terminal_cols=120, terminal_rows=32)
    print('Machine compact quit PTY: PASS (synthetic HTTP)')



def run_workspace_boundary(binary, switch_after):
    server = Server()
    fixtures = h.keeper_runtime_http_fixtures()
    armed = threading.Event()
    switched = threading.Event()
    inventory_after_switch = []

    def foreign_identity(_body):
        return h.RawHttpResponse(200, json.dumps({'paths': {
            'effective_base_path': '/fixture/foreign-workspace',
            'effective_masc_root': '/fixture/foreign-workspace/.masc',
        }}).encode(), content_type='application/json')

    def switch_workspace():
        fixtures['/health'] = h.RequestHttpResponse(foreign_identity)
        fixtures['/health?full=1'] = h.RequestHttpResponse(foreign_identity)
        switched.set()

    def raw(body):
        result = server.raw(body)
        if armed.is_set() and not body and switch_after == 'document':
            switch_workspace()
        return result

    def inventory(body):
        if switched.is_set():
            inventory_after_switch.append(True)
        result = server.inventory(body)
        if armed.is_set() and switch_after == 'inventory':
            switch_workspace()
        return result

    fixtures[RAW] = h.RequestHttpResponse(raw)
    fixtures[lanes.LANE_INVENTORY_PATH] = h.RequestHttpResponse(inventory)

    def interact(process, fd, _slave, output, _base):
        h.palette_go(process, fd, output, b'go lanes', b'All lanes')
        select(process, fd, output, 'msx')
        h.drain_until_quiet(process, fd, output)
        armed.set()
        start = len(output)
        h.send_and_wait(process, fd, output, b' ', b'MASC Machine activity')
        h.drain_until_quiet(process, fd, output)
        assert switched.is_set(), 'fixture never switched workspace'
        if switch_after == 'document':
            assert not inventory_after_switch, 'inventory dispatched after document changed workspace'
        assert b'Current file: On' not in bytes(output[start:]), 'mixed-workspace document accepted'
        assert not server.saves, 'workspace change dispatched a write'
        os.write(fd, b'q')

    h.run_terminal_scenario(binary, description='Machine workspace switch after ' + switch_after,
        interact=interact, http_fixtures=fixtures, terminal_cols=120, terminal_rows=40)
    print('Machine workspace boundary after ' + switch_after + ': PASS')

if __name__ == '__main__':
    run(os.path.abspath(sys.argv[1]))
    run_compact_quit(os.path.abspath(sys.argv[1]))
    run_unavailable_file(os.path.abspath(sys.argv[1]))
    run_workspace_boundary(os.path.abspath(sys.argv[1]), 'document')
    run_workspace_boundary(os.path.abspath(sys.argv[1]), 'inventory')
    print('tui machine activity: PASS')
