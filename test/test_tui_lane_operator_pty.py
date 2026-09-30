"""Exercise target identity through the actual native Lane UI.

Controlled HTTP data; never presented as real worker execution. The first
installed worker deliberately differs from the selected observation producer.
"""
from __future__ import annotations

import argparse
import copy
import json
import os
import tomllib
from pathlib import Path

import test_tui_keyboard_input as terminal
from test_tui_lane_visual_pty import snapshot

# The sources this walk stands over. scripts/ci/run-edited-tests.sh reads the
# paths a suite names and runs it when a pull request changes one of them, so
# a change to the Lane workspace, the guided installer or the schema form is
# told what it did to the operator's path through them. Without the
# declaration the only job that ran this file was lane-addon-native.yml,
# which is not the pull-request gate: #36120 and #36155 each changed drawn
# text with no PTY scenario running, and main sat red until someone ran the
# suite by hand.
SOURCE_MODULES = (
    "lib/tui_terminal_text.ml",
    "lib/tui_terminal_text.mli",
    # Read off the walk's own needles rather than guessed: each of these owns
    # a literal this file waits for and no other bin source spells it --
    # "MASC Lane Add-ons" and "MASC Dashboard" (render), "Run action on" and
    # "no available worker" (lane_addons), "Install Add-on:", "Image
    # unverified:" and "Local draft only." (lane_installer), "Review input"
    # (schema_form).
    "bin/masc_tui_render.ml",
    "bin/masc_tui_lane_addons.ml",
    "bin/masc_tui_lane_installer.ml",
    "bin/masc_tui_schema_form.ml",
    # Not for a word on screen: the walk types ":go lane add-ons" and the
    # keys j / Enter / 4 / e, so the palette row and dispatcher own the path
    # it takes even though it waits for nothing they spell.
    "bin/masc_tui_types.ml",
    "bin/masc_tui.ml",
)


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
        expected = {'id': 'operator-layer', 'run_id': 'operator-run',
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
        key(b'i', b'Install Add-on:')
        key(b'/fixture/package/lane.toml\x13', b'Review input')
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


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('executable')
    parser.add_argument('--capture-dir', type=Path)
    args = parser.parse_args()
    main(os.path.abspath(args.executable), args.capture_dir)
    guided_install(os.path.abspath(args.executable), args.capture_dir)
