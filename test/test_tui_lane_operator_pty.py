"""Exercise target identity through the actual native Lane UI.

Controlled HTTP data; never presented as real worker execution. The first
installed worker deliberately differs from the selected observation producer.
"""
from __future__ import annotations

import argparse
import copy
import json
import os
from pathlib import Path

import tomllib
from urllib.parse import parse_qs, urlsplit
import tui_keyboard_harness as terminal
from test_tui_lane_visual_pty import snapshot




def main(executable: str, captures: Path | None) -> None:
    data = snapshot()
    first = data['instances'][0]
    second = copy.deepcopy(first)
    second.update(instance_id='second-worker', incarnation='second-worker', title='Second producer')
    data['instances'] = [first, second]
    template = data['rows'][0]
    data['rows'] = [
        {**template, 'id': 'second-worker/1/selected', 'lane_id': 'second-worker/browser',
         'title': 'Selected second producer', 'related_ids': []},
        {**template, 'id': first['instance_id'] + '/1/other',
         'title': 'Other producer event', 'observed_at': template['observed_at'] + 1,
         'related_ids': []},
    ]
    for instance in data['instances']:
        instance['rows_count'] = 1
    data['configuration']['declarations'] = [{
        'id': 'unapplied-installation', 'source_path': '/fixture/lane-addons/pending.toml',
        'enabled': True,
        'desired_revision': 'pending', 'applied_revision': None, 'instance_id': None,
    }]
    fixtures = terminal.overview_event_http_fixtures()
    inventory = {'fail_after_evidence': False}

    def inspect() -> tuple[int, dict]:
        if inventory['fail_after_evidence']:
            return 503, {'error': 'follow-up inventory unavailable'}
        return 200, data

    fixtures['/api/v1/lane-addons'] = inspect
    requests: terminal.HttpRequests = []
    accepted: list[dict] = []

    def preserve(body: bytes) -> tuple[int, dict]:
        request = json.loads(body)
        if request != {'instance_id': 'second-worker', 'row_ids': ['second-worker/1/selected']}:
            raise AssertionError(f'Wrong evidence owner or row: {request!r}')
        accepted.append(request)
        inventory['fail_after_evidence'] = True
        return 200, {'retained': True, 'proof': 'operator-evidence-receipt'}

    fixtures['/api/v1/lane-addons/evidence'] = terminal.RequestHttpResponse(preserve)

    def interact(process, master, _slave, output, _base):
        def key(value: bytes, needle: bytes) -> bytes:
            return terminal.send_and_wait(process, master, output, value, needle)

        key(b':go lane add-ons\r', b'Lane Add-ons \xc2\xb7 1 declared \xc2\xb7 2 active \xc2\xb7 0 failed workers')
        key(b'j', b'Second producer')
        key(b'\r', b'Selected second producer')
        key(b'4', b'Selected second producer')
        key(b' ', b'[selected]')
        # `e` opens a choice (preserve only, or preserve and send the
        # reference to a named Keeper) rather than submitting; Enter takes the
        # default, which sends no keeper_name and is what `preserve` asserts.
        key(b'e', b'Preserve 1 marked row from Second producer')
        read_frame = key(b'\r', b'Read:')
        read_plain = b''.join(terminal.screen_text(read_frame).split())
        if b'Read:' not in read_plain or b'follow-upinventoryunavailable' not in read_plain:
            raise AssertionError('Failed follow-up inventory read was hidden behind the action receipt')
        if b'Request:' in read_plain or b'Action receipt:' in read_plain:
            raise AssertionError('Successful evidence preservation was reported as a request failure')
        # Raw detail puts the complete receipt after the records; scroll to
        # it rather than assuming it fits on the first terminal page.
        key(b'D', b'Raw details')
        start = len(output)
        os.write(master, b'J' * 80)
        if not terminal.drain_until_quiet(process, master, output):
            raise AssertionError('Raw detail did not settle after scrolling to the receipt')
        if b'operator-evidence-receipt' not in terminal.CSI_RE.sub(b'', bytes(output[start:])):
            raise AssertionError('Preserved evidence receipt is missing from raw detail')
        if len(accepted) != 1:
            raise AssertionError('Expected one explicit evidence preservation')
        key(b'D', b'Selected second producer')
        # The detail screen contains only this worker's rows. Opening another
        # worker clears the mark, so a later export cannot mix owners.
        key(b'q', b'Lane Add-ons \xc2\xb7 1 declared \xc2\xb7 2 active \xc2\xb7 0 failed workers')
        key(b'k', first['title'].encode())
        key(b'\r', b'Other producer event')
        key(b'4', b'Other producer event')
        first_frame = key(b' ', b'[selected]')
        if b'Selected second producer' in terminal.screen_text(first_frame):
            raise AssertionError('Another producer leaked into the selected detail')
        choice = key(b'e', b'Preserve 1 marked row from ' + first['title'].encode())
        if b'Second producer' in terminal.screen_text(choice):
            raise AssertionError('An old mark crossed the producer boundary')
        key(b'\x1b', b'Other producer event')
        if len(accepted) != 1:
            raise AssertionError('Switching producers unexpectedly submitted evidence')
        if captures is not None:
            captures.mkdir(parents=True, exist_ok=True)
            (captures / 'target-identity.pty').write_bytes(bytes(output))
            (captures / 'requests.json').write_text(json.dumps(accepted, indent=2))
        key(b'q', b'Lane Add-ons \xc2\xb7 1 declared \xc2\xb7 2 active \xc2\xb7 0 failed workers')
        key(b'q', b'MASC Dashboard')
        os.write(master, b'q')

    terminal.run_terminal_scenario(executable, description='Lane operator target identity',
        interact=interact, http_fixtures=fixtures, http_requests=requests)
    print('Owner-specific evidence / receipt with failed inventory read / isolated marks: PASS')


def guided_install(executable: str, captures: Path | None) -> None:
    data = snapshot()
    data.update(instances=[], rows=[], coverage=[])
    fixtures = terminal.overview_event_http_fixtures()
    fixtures['/api/v1/lane-addons'] = (200, data)
    def catalog(path: str) -> tuple[int, dict]:
        directory = parse_qs(urlsplit(path).query).get('directory', ['/fixture'])[0]
        if directory == '/fixture':
            return 200, {'directory': directory, 'parent': None, 'entries': [
                {'kind': 'folder', 'path': '/fixture/package'}]}
        if directory == '/fixture/package':
            return 200, {'directory': directory, 'parent': '/fixture', 'entries': [
                {'kind': 'package', 'manifest_path': '/fixture/package/lane.toml',
                 'title': 'Listed operator package', 'revision': 'old', 'description': 'Select to reread'}]}
        raise AssertionError(f'Unexpected package folder: {directory!r}')
    fixtures['/api/v1/lane-addons/package-catalog'] = terminal.PathHttpResponse(catalog)
    fixtures['/api/v1/lane-addons/package-preview'] = (200, {
        'manifest_path': '/fixture/package/lane.toml',
        'package': {'title': 'Operator package', 'revision': '1', 'image': 'fixture-image',
                    'binding_schema': {'type': 'object', 'properties': {
                        'source': {'type': 'string', 'minLength': 1}},
                        'required': ['source'], 'additionalProperties': False}},
        'image': {'state': 'unverified', 'detail': 'Controlled test does not inspect Docker'},
    })
    requests: terminal.HttpRequests = []
    saved: list[dict] = []

    def save(body: bytes) -> tuple[int, dict]:
        request = json.loads(body)
        parsed = tomllib.loads(request['source_text'])
        expected = {'enabled': True, 'id': 'operator-layer', 'run_id': 'operator-run',
                    'manifest_path': '/fixture/package/lane.toml',
                    'binding': {'source': 'explicit-source'}}
        if parsed != expected:
            raise AssertionError(f'Wizard changed reviewed binding: {parsed!r}')
        saved.append(request)
        doc = {'file_name': request['file_name'], 'source_path': '/fixture/lane-addons/operator-layer.toml',
               'source_text': request['source_text'], 'source_revision': 'saved-source',
               'desired_revision': 'desired', 'validation': {'valid': True, 'messages': []}}
        return 200, {'document': doc, 'write': {'state': 'created', 'durability': 'durable', 'detail': None},
                     'application': 'pending_reconciliation'}

    fixtures['/api/v1/lane-addons/declaration'] = terminal.RequestHttpResponse(save)

    def interact(process, master, _slave, output, _base):
        def key(value: bytes, needle: bytes) -> bytes:
            return terminal.send_and_wait(process, master, output, value, needle)
        key(b':go lane add-ons\r', b'MASC Lane Add-ons')
        key(b'i', b'Folder  package')
        key(b'p', b'Install Add-on:')
        key(b'\x1b', b'MASC Lane Add-ons')
        key(b'i', b'Folder  package')
        key(b'\r', b'Listed operator package')
        assert not [path for path, _ in requests if path.split('?', 1)[0] == '/api/v1/lane-addons/package-preview']
        key(b'\r', b'Image unverified:')
        key(b'operator-layer\t', b'run_id')
        key(b'operator-run\t', b'binding.source')
        key(b'explicit-source\x13', b'Review input')
        key(b'\r', b'Local draft only.')
        if saved:
            raise AssertionError('Preview or local review unexpectedly saved configuration')
        key(b's', b'Created')
        if len(saved) != 1:
            raise AssertionError('Explicit save did not create exactly one declaration')
        if any(path.endswith('/attach') for path, _ in requests):
            raise AssertionError('Wizard bypassed the declaration workflow')
        if captures is not None:
            captures.mkdir(parents=True, exist_ok=True)
            (captures / 'guided-install.pty').write_bytes(bytes(output))
            (captures / 'guided-install-request.json').write_text(json.dumps(saved, indent=2))
        key(b'q', b'MASC Dashboard')
        os.write(master, b'q')
    terminal.run_terminal_scenario(executable, description='Lane guided package installation',
        interact=interact, http_fixtures=fixtures, http_requests=requests)
    print('Package preview / schema fields / review / explicit declaration save: PASS')


def broadcast_export(executable: str, captures: Path | None) -> None:
    data = snapshot()
    data['instances'] = data['instances'][:1]
    data['rows'] = data['rows'][:1]
    data['instances'][0]['rows_count'] = 1
    owner = data['instances'][0]['instance_id']
    selected = data['rows'][0]['id']
    fixtures = terminal.overview_event_http_fixtures()
    fixtures['/api/v1/lane-addons'] = (200, data)
    fixtures['/api/v1/gate/keepers?detailed=true'] = (200, {
        'count': 0, 'total': 0, 'truncated': False, 'keepers': []})

    def prepare_workspace(base_path: str) -> None:
        # The export choices read the canonical local Keeper roster. Remove
        # only the harness's two seeded identities in this temporary workspace.
        for name in ('alpha', 'beta'):
            (Path(base_path) / '.masc' / 'keepers' / f'{name}.json').unlink()

    accepted: list[dict] = []
    principal_reads: list[bytes] = []
    requests: terminal.HttpRequests = []

    def principal(body: bytes) -> tuple[int, dict]:
        principal_reads.append(body)
        return 200, {'principal': 'principal:operator:fixture-operator'}

    def share(body: bytes) -> tuple[int, dict]:
        if len(principal_reads) != 1:
            raise AssertionError('Broadcast sent before proving the captured bearer principal')
        request = json.loads(body)
        expected = {'instance_id': owner, 'row_ids': [selected], 'broadcast': True}
        request_id = request.get('request_id')
        if not isinstance(request_id, str) or not request_id:
            raise AssertionError('Broadcast requires a retained request identity')
        expected['request_id'] = request_id
        if request != expected:
            raise AssertionError(f'Broadcast changed selected evidence: {request!r}')
        accepted.append(request)
        return 200, {'evidence': {'sha256': 'f' * 64}, 'row_count': 1,
                     'delivery': {'destination': 'broadcast', 'status': 'committed',
                                  'request_id': request_id,
                                  'receipt': {'request_id': 'fixture-broadcast', 'seq': 7}}}

    fixtures['/api/v1/lane-addons/broadcast-principal'] = terminal.RequestHttpResponse(principal)
    fixtures['/api/v1/lane-addons/evidence'] = terminal.RequestHttpResponse(share)

    def interact(process, master, _slave, output, _base):
        def key(value: bytes, needle: bytes) -> bytes:
            return terminal.send_and_wait(process, master, output, value, needle)
        key(b':go lane add-ons\r', b'World observer')
        key(b'\r', b'DOM captured')
        key(b'4', b'DOM captured')
        key(b' ', b'[selected]')
        key(b'e', b'> Preserve only')
        key(b'j', b'> Preserve and share the reference via Broadcast')
        if accepted:
            raise AssertionError('Selecting Broadcast published before Enter')
        key(b'\x1b', b'DOM captured')
        if accepted:
            raise AssertionError('Cancelling export published a Broadcast')
        key(b'e', b'> Preserve only')
        key(b'j', b'> Preserve and share the reference via Broadcast')
        frame = key(b'\r', b'Broadcast committed')
        if b'Keeper reads and actions are unverified' not in terminal.CSI_RE.sub(b'', frame):
            raise AssertionError('Broadcast receipt claimed or hid Keeper-use status')
        if len(accepted) != 1:
            raise AssertionError('Explicit export did not submit exactly once')
        if len(principal_reads) != 1:
            raise AssertionError('Broadcast did not prove exactly one authenticated principal')
        if captures is not None:
            captures.mkdir(parents=True, exist_ok=True)
            (captures / 'broadcast-export.pty').write_bytes(bytes(output))
            (captures / 'broadcast-export-request.json').write_text(json.dumps(accepted, indent=2))
        key(b'q', b'World observer')
        key(b'q', b'MASC Dashboard')
        os.write(master, b'q')

    terminal.run_terminal_scenario(executable, description='Explicit Lane evidence Broadcast',
        interact=interact, http_fixtures=fixtures, http_requests=requests,
        prepare_workspace=prepare_workspace)
    print('Selected evidence / explicit Broadcast / cancelled draft / committed receipt: PASS')


def stale_removal(executable: str) -> None:
    data = snapshot()
    worker = data['instances'][0]
    owner = {'id': 'owned-installation', 'source_path': '/fixture/lane-addons/owned.toml',
             'revision': 'installed'}
    worker['configuration'] = owner
    data['instances'] = [worker]
    declaration = {'id': owner['id'], 'source_path': owner['source_path'], 'enabled': True,
                   'desired_revision': 'changed', 'applied_revision': 'installed',
                   'instance_id': worker['instance_id']}
    data['configuration']['declarations'] = [declaration]
    fixtures = terminal.overview_event_http_fixtures()
    fixtures['/api/v1/lane-addons'] = lambda: (200, data)
    requests: terminal.HttpRequests = []
    fixtures['/api/v1/lane-addons/detach'] = (200, {'detached': True})

    def interact(process, fd, _slave, output, _base):
        terminal.palette_go(process, fd, output, b'go lane add-ons', b'Resolve changed TOML')
        terminal.send_and_wait(process, fd, output, b'd', b'nothing was removed')
        assert terminal.drain_until_quiet(process, fd, output)
        assert not [p for p, _ in requests if p.endswith('/detach')], requests
        declaration['desired_revision'] = 'installed'
        terminal.send_and_wait(process, fd, output, b'r', b'd:remove TOML + worker')
        os.write(fd, b'd')
        assert terminal.wait_for_fixture_state(process, fd, output,
            lambda: any(p.endswith('/detach') for p, _ in requests), timeout=5)
        removals = [json.loads(body) for p, body in requests if p.endswith('/detach')]
        assert removals == [{'instance_id': worker['instance_id']}], removals
        terminal.send_and_wait(process, fd, output, b'q', b'MASC Dashboard')
        os.write(fd, b'q')

    terminal.run_terminal_scenario(executable, description='Known stale TOML removal refuses before dispatch',
        interact=interact, http_fixtures=fixtures, http_requests=requests)
    print('Stale revision refuses removal; matching revision dispatches exact worker: PASS')


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('executable')
    parser.add_argument('--capture-dir', type=Path)
    args = parser.parse_args()
    stale_removal(os.path.abspath(args.executable))
    main(os.path.abspath(args.executable), args.capture_dir)
    guided_install(os.path.abspath(args.executable), args.capture_dir)
    broadcast_export(os.path.abspath(args.executable), args.capture_dir)
