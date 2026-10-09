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


def run_machine_pre_refresh_swap(executable, operation):
    """A cached A grant cannot send a machine write to B before periodic health."""
    current, observed, prepare, health = workspace_fixture()
    rgb = base64.b64encode(b'\xff\x00\x00\x00\x00\xff').decode()
    first_tick = threading.Event()
    release_tick = threading.Event()
    tick_recorded = threading.Event()

    class RecordedRequests(list):
        def append(self, request):
            super().append(request)
            if request[0] == '/api/v1/msx/tick':
                tick_recorded.set()

    requests = RecordedRequests()

    def live(path):
        source = urllib.parse.parse_qs(urllib.parse.urlsplit(path).query)['source_kind'][0]
        answer = {'state': 'changed', 'source_kind': source, 'change_count': 1,
                  'incarnation': current['phase'], 'screen': {'format': 'rgb8', 'width': 2,
                  'height': 1, 'rgb_base64': rgb}}
        if source == 'msx_capture': answer['frame_number'] = 1
        else: answer['activity'] = []
        return 200, answer

    def tick(_body):
        first_tick.set()
        if operation == 'tick':
            # The first A write is already admitted; its completed frame arms
            # the next automatic tick, while the cached authority still says A.
            current['phase'] = 'b'
        else:
            assert release_tick.wait(8), 'fixture tick was not released'
        return 200, {'loaded': True, 'number': 9000, 'change_count': 9000,
            'incarnation': 'a', 'width': 2, 'height': 1, 'mode': 'SCREEN2',
            'cartridge': 'game.rom', 'disk': None, 'players': [], 'pixels': {
                'kind': 'inline', 'revision': 'a' * 64, 'width': 2, 'height': 1,
                'rgb_base64': rgb}}

    def interact(process, master, _slave, output, _base):
        def key(value, needle):
            return press(process, master, output, value, needle)

        try:
            key(b':go Collab\r', '› guest'.encode())
            if operation == 'load':
                key(b'g', b'pick a game')
                key(b'jjjj', b'game.rom')
            else:
                key(b'm', b'frame 1 ')
                if operation != 'f5':
                    key(b'\x1b[15~', b'Controlling')
                    assert h.wait_for_fixture_event(process, master, output, first_tick, timeout=8)
                    if operation == 'disk':
                        key(b'\x1b[19~', b'change disk')
                        key(b'j', b'game.dsk')
            if operation == 'tick':
                # The response callback runs before the harness records it.
                # Other operations intentionally keep their first tick blocked.
                assert h.wait_for_fixture_event(
                    process, master, output, tick_recorded, timeout=8)
            before = len(requests)
            start = len(output)
            if operation != 'tick':
                current['phase'] = 'b'
                command = {'f5': b'\x1b[15~', 'key': b'1', 'save': b'\x1b[17~',
                           'restore': b'\x1b[18~', 'load': b'\r', 'disk': b'\r'}[operation]
                os.write(master, command)
            assert h.wait_for_fixture_event(process, master, output, observed['b'], timeout=8)
            h.wait_for_output(process, master, output, b'MASC Dashboard', start=start, timeout=8)
            assert not any(path.startswith('/api/v1/msx/') for path, _ in requests[before:]), requests[before:]
            if operation == 'tick':
                assert sum(path == '/api/v1/msx/tick' for path, _ in requests) == 1, requests
            # The outstanding A tick may now finish. Its frame cannot reopen
            # the withdrawn view or restore its control grant.
            release_tick.set()
            key(b':go Collab\r', '› guest'.encode())
            assert b'Controlling' not in h.screen_text(bytes(output))
            key(b'\x1b', b'MASC Dashboard')
            os.write(master, b'q')
        finally:
            release_tick.set()

    h.run_terminal_scenario(executable,
        description='pre-refresh workspace replacement refuses MSX ' + operation,
        interact=interact, prepare_workspace=prepare, refresh=60.0, terminal_cols=200,
        http_requests=requests, http_fixtures={'/health': health, '/health?full=1': health,
            '/api/v1/play/invites': (200, {'invites': [row()]}),
            '/api/v1/lane-addons/live': h.PathHttpResponse(live),
            '/api/v1/msx/carts': (200, {'carts': ['game.dsk' if operation == 'disk' else 'game.rom']}),
            '/api/v1/msx/tick': h.RequestHttpResponse(tick)})


def run_tick_probe_view_withdrawal(executable):
    """A tick's delayed identity answer cannot authorize an abandoned control view."""
    current, _observed, prepare, health = workspace_fixture()
    requests = []
    gate = h.GatedHttpResponse((200, {}), hold_seconds=30)
    armed = threading.Event()
    rgb = base64.b64encode(b'\xff\x00\x00').decode()

    def checked_health():
        if armed.is_set():
            armed.clear()
            gate()
        return health()

    def live(_path):
        return 200, {'state': 'changed', 'source_kind': 'msx_capture', 'change_count': 1,
            'incarnation': 'a', 'frame_number': 1,
            'screen': {'format': 'rgb8', 'width': 1, 'height': 1, 'rgb_base64': rgb}}

    def tick(_body):
        armed.set()
        return 200, {'loaded': True, 'number': 2, 'change_count': 2,
            'incarnation': 'a', 'width': 1, 'height': 1, 'mode': 'SCREEN2',
            'cartridge': 'game.rom', 'disk': None, 'players': [], 'pixels': {
                'kind': 'inline', 'revision': 'b' * 64, 'width': 1, 'height': 1,
                'rgb_base64': rgb}}

    def interact(process, master, _slave, output, _base):
        try:
            press(process, master, output, b':go Collab\r', '› guest'.encode())
            press(process, master, output, b'm', b'frame 1 ')
            press(process, master, output, b'\x1b[15~', b'Controlling')
            assert h.wait_for_fixture_event(process, master, output, gate.requested, timeout=8)
            press(process, master, output, b'\x1b[15~', b'Watching only')
            boundary = len(requests)
            gate.release.set()
            press(process, master, output, b'\x1b', b'MASC Collab')
            assert not any(path == '/api/v1/msx/tick' for path, _ in requests[boundary:]), requests[boundary:]
            press(process, master, output, b'\x1b', b'MASC Dashboard')
            os.write(master, b'q')
        finally:
            gate.release.set()

    h.run_terminal_scenario(executable,
        description='MSX tick probe answer cannot restore a withdrawn control view',
        interact=interact, prepare_workspace=prepare, refresh=60.0, terminal_cols=200,
        http_requests=requests, http_fixtures={'/health': checked_health, '/health?full=1': checked_health,
            '/api/v1/play/invites': (200, {'invites': [row()]}),
            '/api/v1/lane-addons/live': h.PathHttpResponse(live),
            '/api/v1/msx/tick': h.RequestHttpResponse(tick)})


def run_machine_post_workspace_swap(executable, operation, *, alias_identity=False):
    """Health admits A; the actual POST reaches B and must carry A's binding."""
    current, observed, prepare, health = workspace_fixture()
    first_tick = threading.Event()
    release_tick = threading.Event()
    refused = threading.Event()
    effects = []
    foreign_reads = []
    rgb = base64.b64encode(b'\xff\x00\x00').decode()
    endpoint = '/api/v1/msx/' + operation
    post_recorded = threading.Event()

    class RecordedRequests(list):
        def append(self, request):
            super().append(request)
            if request[0] == endpoint:
                post_recorded.set()

    requests = RecordedRequests()

    def bound_health():
        if alias_identity and current['phase'] == 'a':
            observed['a'].set()
            _, payload = h.fleet_safety_fixture()
            payload['paths'] = {'effective_base_path': current['base'] + '/.',
                'effective_masc_root': current['base'] + '/.masc/.'}
            return h.RawHttpResponse(200, json.dumps(payload).encode(), content_type='application/json')
        return health()

    def live(path):
        if current['phase'] == 'b':
            foreign_reads.append(path)
        return 200, {'state': 'changed', 'source_kind': 'msx_capture', 'change_count': 1,
            'incarnation': current['phase'], 'frame_number': 1,
            'screen': {'format': 'rgb8', 'width': 1, 'height': 1, 'rgb_base64': rgb}}

    def reject(body):
        payload = json.loads(body)
        expected = {'base_path': current['base'], 'masc_root': str(Path(current['base'], '.masc'))}
        assert payload['expected_workspace'] == expected, payload
        current['phase'] = 'b'  # Replacement happens after the successful health answer.
        actual = {'base_path': str(Path(current['base'], 'other-workspace')),
                  'masc_root': str(Path(current['base'], 'other-workspace', '.masc'))}
        if payload['expected_workspace'] == actual:
            effects.append(operation)
        refused.set()
        return 409, {'ok': False, 'code': 'workspace_precondition_failed',
                     'message': 'workspace precondition failed'}

    def tick(body):
        if operation == 'tick':
            return reject(body)
        payload = json.loads(body)
        assert payload['expected_workspace'] == {'base_path': current['base'],
            'masc_root': str(Path(current['base'], '.masc'))}, payload
        first_tick.set()
        assert release_tick.wait(8), 'admitted original tick was not released'
        if operation in ('save', 'restore'):
            return 409, {'ok': False, 'code': 'activity_disabled'}
        return 200, {'loaded': True, 'number': 2, 'change_count': 2,
            'incarnation': 'a', 'width': 1, 'height': 1, 'mode': 'SCREEN2',
            'cartridge': 'game.rom', 'disk': None, 'players': [], 'pixels': {
                'kind': 'inline', 'revision': 'a' * 64, 'width': 1, 'height': 1,
                'rgb_base64': rgb}}

    def interact(process, master, _slave, output, _base):
        def key(value, needle):
            return press(process, master, output, value, needle)
        try:
            key(b':go Collab\r', '› guest'.encode())
            if operation == 'load':
                key(b'g', b'pick a game')
                key(b'jjjj', b'game.rom')
            else:
                key(b'm', b'frame 1 ')
                control_from = key(b'\x1b[15~', b'Controlling')
                if operation != 'tick':
                    assert h.wait_for_fixture_event(process, master, output, first_tick, timeout=8)
                    if operation in ('save', 'restore'):
                        settled_from = len(output)
                        release_tick.set()
                        h.wait_for_output(process, master, output, b'MSX is off;', start=settled_from, timeout=8)
                if operation == 'disk':
                    key(b'\x1b[19~', b'change disk')
                    key(b'j', b'game.dsk')
            if operation != 'tick':
                key({'press': b'1', 'save': b'\x1b[17~', 'restore': b'\x1b[18~',
                     'load': b'\r', 'disk': b'\r'}[operation], b'workspace precondition failed')
            assert h.wait_for_fixture_event(process, master, output, refused, timeout=8)
            assert h.wait_for_fixture_event(process, master, output, post_recorded, timeout=8)
            assert effects == [], effects
            assert sum(path == endpoint for path, _ in requests) == 1, requests
            # In particular, a refused F6/F7 must not read B's frame and replace
            # the retained A evidence while its original poll is still held.
            assert foreign_reads == [], foreign_reads
            if operation in ('save', 'restore'):
                retained = h.screen_text(bytes(output))
                assert b'frame 1 ' in retained, retained
            if operation == 'tick':
                assert h.wait_for_fixture_event(process, master, output, observed['b'], timeout=8)
                h.wait_for_output(process, master, output, b'MASC Dashboard', start=control_from, timeout=8)
                assert b'MASC Dashboard' in h.screen_text(bytes(output))
                assert sum(path == endpoint for path, _ in requests) == 1, requests
            else:
                if operation == 'disk':
                    key(b'\x1b', b'frame 1 ')
                key(b'\x1b', b'MASC Collab')
                key(b'\x1b', b'MASC Dashboard')
            os.write(master, b'q')
        finally:
            release_tick.set()

    fixtures = {'/health': bound_health, '/health?full=1': bound_health,
        '/api/v1/play/invites': (200, {'invites': [row()]}),
        '/api/v1/lane-addons/live': h.PathHttpResponse(live),
        '/api/v1/msx/carts': (200, {'carts': ['game.dsk' if operation == 'disk' else 'game.rom']}),
        '/api/v1/msx/tick': h.RequestHttpResponse(tick)}
    if operation != 'tick':
        fixtures[endpoint] = h.RequestHttpResponse(reject)
    h.run_terminal_scenario(executable,
        description='MSX actual POST workspace binding refuses replacement ' + operation + (' with canonical alias' if alias_identity else ''),
        interact=interact, prepare_workspace=prepare, refresh=60.0, terminal_cols=200,
        http_requests=requests, http_fixtures=fixtures)


def run_checkpoint_certainty(executable, outcome):
    """A tick barrier and correlated receipt protect both quick-slot operations."""
    current, _observed, prepare, health = workspace_fixture()
    requests = []
    first_tick, release_tick, activity_read = (threading.Event() for _ in range(3))
    checkpoint, inspected, completed = (threading.Event() for _ in range(3))
    stale_read_started, release_stale_read, stale_read_returned = (threading.Event() for _ in range(3))
    operation = {}
    inspections = []
    generic_reads_after = []
    restore = outcome != 'save_unknown'
    rgb = base64.b64encode(b'\xff\x00\x00').decode()

    def pixels(number):
        return {'state': 'changed', 'source_kind': 'msx_capture', 'change_count': number,
            'incarnation': 'history-' + str(number), 'frame_number': number,
            'screen': {'format': 'rgb8', 'width': 1, 'height': 1, 'rgb_base64': rgb}}

    def live(_path):
        if outcome == 'late_read' and activity_read.is_set() and not checkpoint.is_set() and not stale_read_started.is_set():
            stale_read_started.set()
            assert release_stale_read.wait(8), 'stale observation was not released during the scenario'
            stale_read_returned.set()
            return 200, pixels(1)
        if checkpoint.is_set():
            generic_reads_after.append(True)
        return 200, pixels(1)

    def tick(_body):
        first_tick.set()
        assert release_tick.wait(8), 'held tick was not released during the scenario'
        return 409, {'ok': False, 'code': 'activity_disabled'}

    def activity():
        activity_read.set()
        return 200, {'schema': 'masc.msx-activity/v1', 'activity': 'off'}

    def write(body):
        operation.update(json.loads(body))
        assert operation['expected_workspace']['base_path'] == current['base']
        assert operation['operation_id']
        checkpoint.set()
        if outcome in ('refused', 'wrong_operation', 'wrong_workspace'):
            base = current['base'] if outcome != 'wrong_workspace' else str(Path(current['base'], 'foreign'))
            return 503, {'ok': False, 'checkpoint': 'restore', 'slot': 'quick',
                'operation_id': operation['operation_id'] if outcome != 'wrong_operation' else 'another-operation',
                'workspace': {'base_path': base, 'masc_root': str(Path(base, '.masc'))},
                'epoch': 'fixture-server', 'status': 'refused',
                'effect_disposition': 'proven_pre_effect', 'message': 'worker unavailable'}
        return h.DroppedHttpResponse()

    def inspect(body):
        request = json.loads(body)
        inspections.append(request)
        assert request == {
            'operation_id': operation['operation_id'],
            'checkpoint': 'restore' if restore else 'save',
            'slot': operation['slot'],
            'expected_workspace': {'base_path': current['base'],
                                   'masc_root': str(Path(current['base'], '.masc'))},
        }, request
        inspected.set()
        if outcome == 'failed':
            return 503, {'error': 'inspection unavailable'}
        base = current['base'] if outcome != 'read_swap' else str(Path(current['base'], 'other-workspace'))
        done = outcome in ('lost', 'read_swap', 'late_read') or completed.is_set()
        result = {'ok': done, 'operation_id': request['operation_id'], 'checkpoint': request['checkpoint'],
            'slot': 'quick', 'epoch': 'fixture-server', 'status': 'committed' if done else 'pending',
            'workspace': {'base_path': base, 'masc_root': str(Path(base, '.masc'))}}
        if done:
            result['effect'] = {'change_count': 2, 'incarnation': 'history-2', 'checkpoint_sha256': 'a' * 64}
            if restore:
                result.update(live=pixels(2), live_relation='observed_after_completion')
        return 200, result

    def interact(process, master, _slave, output, _base):
        def key(value, needle):
            return press(process, master, output, value, needle)
        checkpoint_key = b'\x1b[18~' if restore else b'\x1b[17~'
        def reinspect(value):
            assert h.drain_until_quiet(process, master, output)
            before = len(inspections)
            start = len(output)
            os.write(master, value)
            assert h.wait_for_fixture_state(process, master, output,
                lambda: len(inspections) > before, timeout=8)
            marker = (b'Checkpoint inspection failed' if outcome in ('failed', 'read_swap')
                      else b'Checkpoint is still pending')
            h.wait_for_output(process, master, output, marker, start=start, timeout=8)
        try:
            key(b':go Collab\r', '› guest'.encode())
            key(b'm', b'frame 1 ')
            key(b'\x1b[15~', b'Controlling')
            assert h.wait_for_fixture_event(process, master, output, first_tick, timeout=8)
            key(checkpoint_key, b'Wait for the outstanding MSX tick')
            assert not checkpoint.is_set(), requests
            # Release the late tick while the test is still live. The activity
            # request proves its completion was consumed before checkpointing.
            release_tick.set()
            assert h.wait_for_fixture_event(process, master, output, activity_read, timeout=8)
            if outcome == 'late_read':
                assert h.wait_for_fixture_event(process, master, output, stale_read_started, timeout=8)
            start = len(output)
            os.write(master, checkpoint_key)
            needle = (b'Checkpoint refused:' if outcome == 'refused' else
                      b'Restore completed; showing' if outcome in ('lost', 'late_read') else
                      b'Checkpoint inspection failed' if outcome in ('failed', 'read_swap') else
                      b'Checkpoint is still pending')
            h.wait_for_output(process, master, output, needle, start=start, timeout=8)
            if outcome != 'refused':
                assert inspected.is_set()
                assert not generic_reads_after, generic_reads_after
                screen = h.screen_text(bytes(output))
                assert (b'frame 2 ' if outcome in ('lost', 'late_read') else b'frame 1 ') in screen, screen
                if outcome == 'late_read':
                    # The pre-checkpoint read returns only after receipt-bound
                    # frame 2 was installed. It must not repaint frame 1.
                    release_stale_read.set()
                    assert h.wait_for_fixture_event(process, master, output, stale_read_returned, timeout=8)
                    assert h.drain_until_quiet(process, master, output)
                    key(b'+', b'frame 2 ')
                    screen = h.screen_text(bytes(output))
                    assert b'frame 2 ' in screen and b'frame 1 ' not in screen, screen
                elif outcome in ('pending', 'save_unknown', 'wrong_operation', 'wrong_workspace'):
                    # Neither control admission nor another save/restore can
                    # release a pending operation or overwrite quick.
                    reinspect(b'\x1b[15~')
                    reinspect(checkpoint_key)
                    completed.set()
                    key(b'\x1b[15~', b'Restore completed; showing' if restore else b'Saved quick checkpoint; operation receipt verified.')
                elif outcome in ('failed', 'read_swap'):
                    reinspect(b'\x1b[15~')
                    assert b'frame 1 ' in h.screen_text(bytes(output))
            path = '/api/v1/msx/restore' if restore else '/api/v1/msx/save'
            assert sum(route == path for route, _ in requests) == 1, requests
            assert sum(route == '/api/v1/msx/tick' for route, _ in requests) == 1, requests
            os.write(master, b'\x1b\x1bq')
        finally:
            release_tick.set()
            release_stale_read.set()

    h.run_terminal_scenario(executable,
        description='checkpoint ' + outcome + ' retains uncertainty until a correlated operation settles',
        interact=interact, prepare_workspace=prepare, refresh=60.0, terminal_cols=200,
        http_requests=requests, http_fixtures={'/health': health, '/health?full=1': health,
            '/api/v1/play/invites': (200, {'invites': [row()]}),
            '/api/v1/lane-addons/live': h.PathHttpResponse(live),
            '/api/v1/msx/activity': activity,
            '/api/v1/msx/tick': h.RequestHttpResponse(tick),
            '/api/v1/msx/restore': h.RequestHttpResponse(write),
            '/api/v1/msx/save': h.RequestHttpResponse(write),
            '/api/v1/msx/checkpoint-operation': h.RequestHttpResponse(inspect)})


def run_workspace_control_rearm(executable):
    """Activity alone cannot rearm a refused tick; fresh explicit F5 can."""
    current, _observed, prepare, health = workspace_fixture()
    requests = []
    ticks = []
    resumed = threading.Event()
    rgb = base64.b64encode(b'\xff\x00\x00').decode()

    def live(_path):
        number = 3 if ticks else 1
        return 200, {'state': 'changed', 'source_kind': 'msx_capture', 'change_count': number,
            'incarnation': 'a', 'frame_number': number,
            'screen': {'format': 'rgb8', 'width': 1, 'height': 1, 'rgb_base64': rgb}}

    def tick(_body):
        ticks.append('tick')
        if len(ticks) == 1:
            # A transient replacement at POST refused the original binding;
            # health and later reads again describe the original workspace.
            return 409, {'ok': False, 'code': 'workspace_precondition_failed',
                         'message': 'workspace precondition failed'}
        resumed.set()
        return 200, {'loaded': False}

    def interact(process, master, _slave, output, _base):
        def key(value, needle):
            return press(process, master, output, value, needle)
        key(b':go Collab\r', '› guest'.encode())
        key(b'm', b'frame 1 ')
        key(b'\x1b[15~', b'Controlling')
        h.wait_for_output(process, master, output, b'MSX workspace changed;', start=0, timeout=8)
        # The typed workspace refusal must retain A's frame until an explicit
        # interaction obtains a new bound observation; background activity is
        # not permission to read a replacement server.
        assert b'frame 1 ' in h.screen_text(bytes(output))
        assert ticks == ['tick'], ticks
        rearm_from = key(b'\x1b[15~', b'Watching only')
        h.wait_for_output(process, master, output, b'frame 3 ', start=rearm_from, timeout=8)
        key(b'\x1b[15~', b'Controlling')
        assert h.wait_for_fixture_event(process, master, output, resumed, timeout=8)
        os.write(master, b'\x1b\x1bq')

    h.run_terminal_scenario(executable,
        description='fresh explicit control admission rearms a workspace-refused MSX tick',
        interact=interact, prepare_workspace=prepare, refresh=60.0, terminal_cols=200,
        http_requests=requests, http_fixtures={'/health': health, '/health?full=1': health,
            '/api/v1/play/invites': (200, {'invites': [row()]}),
            '/api/v1/lane-addons/live': h.PathHttpResponse(live),
            '/api/v1/msx/activity': (200, {'schema': 'masc.msx-activity/v1', 'activity': 'on'}),
            '/api/v1/msx/tick': h.RequestHttpResponse(tick)})


if __name__ == '__main__':
    run_unknown(sys.argv[1], 'issue')
    run_unknown(sys.argv[1], 'revoke')
    run_pre_dispatch_failure(sys.argv[1], 'issue')
    run_pre_dispatch_failure(sys.argv[1], 'revoke')
    run_control_boundary(sys.argv[1])
    for operation in ('tick', 'f5', 'key', 'save', 'restore', 'load', 'disk'):
        run_machine_pre_refresh_swap(sys.argv[1], operation)
    run_tick_probe_view_withdrawal(sys.argv[1])
    for operation in ('press', 'save', 'restore', 'load', 'disk', 'tick'):
        run_machine_post_workspace_swap(sys.argv[1], operation)
    run_machine_post_workspace_swap(sys.argv[1], 'save', alias_identity=True)
    for outcome in ('refused', 'failed', 'lost', 'pending', 'read_swap', 'save_unknown', 'wrong_operation', 'wrong_workspace', 'late_read'):
        run_checkpoint_certainty(sys.argv[1], outcome)
    run_workspace_control_rearm(sys.argv[1])
    print('tui Collab authority: PASS')
