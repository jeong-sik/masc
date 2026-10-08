"""Workspace changes retire game control and cannot settle a delayed invite write."""
import base64
import json
import os
from pathlib import Path
import sys
import threading
import urllib.parse

import tui_keyboard_harness as h


def row():
    return {'name': 'guest', 'expires_at': '2030-01-01T00:00:00Z',
            'expired': False, 'holds_controller': False}


def workspace_fixture():
    current = {'phase': 'a', 'base': None}
    observed = {phase: threading.Event() for phase in ('a', 'unknown', 'b')}

    def prepare(base):
        current['base'] = str(Path(base).resolve())

    def health():
        phase = current['phase']
        observed[phase].set()
        if phase == 'unknown':
            return h.RawHttpResponse(503, b'{"error":"identity unavailable"}', content_type='application/json')
        base = current['base'] if phase == 'a' else str(Path(current['base'], 'other-workspace'))
        _, payload = h.fleet_safety_fixture()
        payload['paths'] = {'effective_base_path': base, 'effective_masc_root': str(Path(base, '.masc'))}
        return h.RawHttpResponse(200, json.dumps(payload).encode(), content_type='application/json')

    return current, observed, prepare, health


def press(process, master, output, value, needle):
    start = len(output)
    os.write(master, value)
    h.wait_for_output(process, master, output, needle, start=start, timeout=8)
    return start


def run_unknown(executable, operation):
    current, observed, prepare, health = workspace_fixture()
    rows = [] if operation == 'issue' else [row()]
    gate = h.GatedHttpResponse((200, {}), hold_seconds=30)
    applied = threading.Event()
    mutations = []
    token_link = 'https://play.example.test/play#unknown-fixture-token'

    def inventory(body):
        if not body:
            return 200, {'invites': rows.copy()}
        mutations.append('issue')
        assert operation == 'issue' and mutations == ['issue'], mutations
        gate()
        rows[:] = [row()]
        applied.set()
        return 201, {**row(), 'link': token_link}

    def revoke(method):
        assert method == 'DELETE'
        mutations.append('revoke')
        assert operation == 'revoke' and mutations == ['revoke'], mutations
        gate()
        rows.clear()
        applied.set()
        return 200, {'name': 'guest', 'revoked': True, 'released_controller': False}

    def interact(process, master, _slave, output, _base):
        def key(value, needle):
            return press(process, master, output, value, needle)

        try:
            key(b':go Collab\r', b'No invites' if operation == 'issue' else '› guest'.encode())
            if operation == 'issue':
                key(b'nguest\r', b'Expires in hours:')
            else:
                key(b'x', b'Revoke guest?')
            key(b'\r', b'Waiting for the server')
            assert h.wait_for_fixture_event(process, master, output, gate.requested, timeout=8)
            start = len(output)
            current['phase'] = 'unknown'
            assert h.wait_for_fixture_event(process, master, output, observed['unknown'], timeout=8)
            h.wait_for_output(process, master, output, b'MASC Dashboard', start=start, timeout=8)
            start = len(output)
            current['phase'] = 'a'
            h.wait_for_output(process, master, output, ('Base: ' + current['base']).encode(), start=start, timeout=8)
            key(b':go Collab\r', b'unknown outcome')
            # Both blocked keys set the same notice, so the second key need
            # not redraw. The distinct confirmation is a processing barrier:
            # neither n nor x may have opened its write form before u.
            key(b'nxu', b'original request cannot still complete')
            key(b'\x1b', b'unknown outcome')
            key(b'r', b'No invites' if operation == 'issue' else '› guest'.encode())
            key(b'nxu', b'original request cannot still complete')
            key(b'\x1b', b'unknown outcome')
            assert mutations == [operation] and not applied.is_set(), mutations
            gate.release.set()
            assert h.wait_for_fixture_event(process, master, output, applied, timeout=8)
            key(b'r', '› guest'.encode() if operation == 'issue' else b'No invites')
            # The held handler is now known to have completed independently
            # of inventory. The operator can acknowledge that evidence.
            key(b'nxu', b'original request cannot still complete')
            key(b'\r', b'Operator confirmed')
            key(b'n', b'Player name:')
            assert mutations == [operation], mutations
            key(b'\x1b', b'm:MSX')  # The header is unchanged when closing a form.
            key(b'q', b'MASC Dashboard')
            os.write(master, b'q')
        finally:
            gate.release.set()

    h.run_terminal_scenario(executable,
        description='unknown invite ' + operation + ' survives identity withdrawal and unordered inventory',
        interact=interact, prepare_workspace=prepare, refresh=0.5, terminal_cols=300,
        http_fixtures={'/health': health, '/health?full=1': health,
          '/api/v1/play/invites': h.RequestHttpResponse(inventory),
          '/api/v1/play/invites/guest': h.MethodHttpResponse(revoke)})


def run_pre_dispatch_failure(executable, operation):
    current, observed, prepare, health = workspace_fixture()
    rows = [] if operation == 'issue' else [row()]
    armed = threading.Event()
    mutations = []

    def checked_health():
        # Wait for durable preparation, then fail the identity check before
        # the HTTP mutation can run. Ordinary background reads are harmless.
        if armed.is_set() and current['base']:
            journal = Path(current['base'], '.masc', 'tui-play-pending.jsonl')
            if journal.exists():
                content = journal.read_text()
                events = content.splitlines()
                if content.endswith('\n') and events and json.loads(events[-1])['event'] == 'pending':
                    current['phase'] = 'unknown'
        return health()

    def inventory(body):
        if not body:
            return 200, {'invites': rows.copy()}
        mutations.append('issue')
        rows[:] = [row()]
        return 201, {**row(), 'link': 'https://play.example.test/play#retry-fixture-token'}

    def revoke(method):
        assert method == 'DELETE'
        mutations.append('revoke')
        rows.clear()
        return 200, {'name': 'guest', 'revoked': True, 'released_controller': False}

    def interact(process, master, _slave, output, _base):
        def key(value, needle):
            return press(process, master, output, value, needle)

        def open_form():
            if operation == 'issue':
                key(b'nguest\r', b'Expires in hours:')
            else:
                key(b'x', b'Revoke guest?')

        key(b':go Collab\r', b'No invites' if operation == 'issue' else '› guest'.encode())
        open_form()
        armed.set()
        key(b'\r', b'MASC Dashboard')
        assert observed['unknown'].is_set() and mutations == [], mutations
        armed.clear()
        start = len(output)
        current['phase'] = 'a'
        h.wait_for_output(process, master, output, ('Base: ' + current['base']).encode(), start=start, timeout=8)
        key(b':go Collab\r', b'No invites' if operation == 'issue' else '› guest'.encode())
        # No explicit unknown resolution: the first request was never sent.
        open_form()
        key(b'\r', b'https://play.example.test/play#retry-fixture-token' if operation == 'issue' else b'Play invite guest: revoked')
        assert mutations == [operation], mutations
        if operation == 'issue':
            key(b'\x1b', b'MASC Collab')
        key(b'q', b'MASC Dashboard')
        os.write(master, b'q')

    h.run_terminal_scenario(executable,
        description='pre-dispatch identity failure releases the ' + operation + ' guard',
        interact=interact, prepare_workspace=prepare, refresh=0.5, terminal_cols=300,
        http_fixtures={'/health': checked_health, '/health?full=1': checked_health,
          '/api/v1/play/invites': h.RequestHttpResponse(inventory),
          '/api/v1/play/invites/guest': h.MethodHttpResponse(revoke)})


def run_control_boundary(executable):
    current, observed, prepare, health = workspace_fixture()
    requests = []
    rgb = base64.b64encode(b'\xff\x00\x00\x00\x00\xff').decode()
    ticks = threading.Event()
    reads = {'msx_capture': 0, 'dos_capture': 0}

    def live(path):
        source = urllib.parse.parse_qs(urllib.parse.urlsplit(path).query)['source_kind'][0]
        reads[source] += 1
        number = reads[source]
        answer = {'state': 'changed', 'source_kind': source, 'change_count': number,
                  'incarnation': current['phase'], 'screen': {'format': 'rgb8', 'width': 2,
                  'height': 1, 'rgb_base64': rgb}}
        if source == 'msx_capture': answer['frame_number'] = number
        else: answer['activity'] = []
        return 200, answer

    def tick(_body):
        ticks.set()
        return 200, {'loaded': True, 'number': 9000, 'change_count': 9000,
          'incarnation': 'a', 'width': 2, 'height': 1, 'mode': 'SCREEN2',
          'cartridge': 'game.rom', 'disk': None, 'players': [], 'rgb_base64': rgb}

    def interact(process, master, _slave, output, _base):
        def key(value, needle):
            return press(process, master, output, value, needle)

        key(b':go Collab\r', '› guest'.encode())
        key(b'm', b'frame 1 ')
        key(b'\x1b[15~', b'Controlling')
        assert h.wait_for_fixture_event(process, master, output, ticks, timeout=8)
        start = len(output)
        current['phase'] = 'b'
        assert h.wait_for_fixture_event(process, master, output, observed['b'], timeout=8)
        h.wait_for_output(process, master, output, b'MASC Dashboard', start=start, timeout=8)
        screen = h.screen_text(bytes(output))
        assert b'MASC Dashboard' in screen and b'Controlling' not in screen, screen
        boundary = len(requests)
        key(b':go Collab\r', '› guest'.encode())
        key(b'n', b'matching this TUI\'s local workspace')
        # x repeats the same notice; m supplies a distinct processing barrier
        # and must still open observation rather than type into a revoke form.
        key(b'xm', b'Watching only')
        key(b'\x1b[15~', b'MSX control requires')
        for value in (b'\x1b[17~', b'\x1b[18~', b'\x1b[19~', b'1'):
            key(value, b'Watching only')
        key(b'\x1b', b'MASC Collab')
        key(b'g', b'pick a game')
        key(b'jj', b'game.rom')  # The two watch entries precede the cartridge.
        key(b'\r', b'MSX control requires')
        assert not any(path.startswith(('/api/v1/msx/', '/api/v1/dos/', '/api/v1/play/invites'))
                       for path, _ in requests[boundary:]), requests[boundary:]
        key(b'\x1b', b'Watching only')
        key(b'\x1b', b'MASC Collab')
        key(b'\x1b', b'MASC Dashboard')
        os.write(master, b'q')

    h.run_terminal_scenario(executable,
        description='workspace boundary ends MSX control and mismatch blocks invite and game writes',
        interact=interact, prepare_workspace=prepare, refresh=0.5, terminal_cols=200,
        http_requests=requests, http_fixtures={'/health': health, '/health?full=1': health,
          '/api/v1/play/invites': (200, {'invites': [row()]}),
          '/api/v1/lane-addons/live': h.PathHttpResponse(live),
          '/api/v1/msx/carts': (200, {'carts': ['game.rom']}),
          '/api/v1/msx/tick': h.RequestHttpResponse(tick)})


if __name__ == '__main__':
    run_unknown(sys.argv[1], 'issue')
    run_unknown(sys.argv[1], 'revoke')
    run_pre_dispatch_failure(sys.argv[1], 'issue')
    run_pre_dispatch_failure(sys.argv[1], 'revoke')
    run_control_boundary(sys.argv[1])
    print('tui Collab authority: PASS')
