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
    # Read off the walk's own needles rather than guessed: each of these owns
    # a literal this file waits for and no other bin source spells it --
    # "MASC Lane Add-ons" and "MASC Overview" (render), "Run action on" and
    # "no available worker" (lane_addons), "Install Add-on:", "Image
    # unverified:" and "Local draft only." (lane_installer), "Review input"
    # (schema_form).
    "bin/masc_tui_render.ml",
    "bin/masc_tui_lane_addons.ml",
    "bin/masc_tui_lane_installer.ml",
    "bin/masc_tui_schema_form.ml",
    # Not for a word on screen: the walk types ":go lane add-ons" and the
    # keys 3 / a / 1 / e, so the palette row and the dispatcher own the path
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
    fixtures['/api/v1/lane-addons'] = (200, data)
    requests: terminal.HttpRequests = []
    accepted: list[dict] = []

    def preserve(body: bytes) -> tuple[int, dict]:
        request = json.loads(body)
        if request != {'instance_id': 'second-worker', 'row_ids': ['second-worker/1/selected']}:
            raise AssertionError(f'Wrong evidence owner or row: {request!r}')
        accepted.append(request)
        return 200, {'retained': True, 'proof': 'operator-evidence-receipt'}

    fixtures['/api/v1/lane-addons/evidence'] = terminal.RequestHttpResponse(preserve)

    def interact(process, master, _slave, output, _base):
        def key(value: bytes, needle: bytes) -> bytes:
            return terminal.send_and_wait(process, master, output, value, needle)

        key(b':go lane add-ons\r', b'Selected second producer')
        key(b'3', b'unapplied-installation')
        frame = key(b'a', b'no available worker')
        if b'Run action on' in terminal.CSI_RE.sub(b'', frame):
            raise AssertionError('Unapplied installation opened unrelated worker actions')
        key(b'1', b'Selected second producer')
        key(b' ', b'[x]')
        key(b'e', b'operator-evidence-receipt')
        if len(accepted) != 1:
            raise AssertionError('Expected one explicit evidence preservation')
        # Keeping the first mark then adding another owner must not submit a
        # mixed batch or silently change the first marked row's identity.
        key(b'j', b'Other producer event')
        key(b' ', b'[x]')
        key(b'e', b'Error:')
        if len(accepted) != 1:
            raise AssertionError('Mixed-owner evidence unexpectedly submitted')
        if captures is not None:
            captures.mkdir(parents=True, exist_ok=True)
            (captures / 'target-identity.pty').write_bytes(bytes(output))
            (captures / 'requests.json').write_text(json.dumps(accepted, indent=2))
        key(b'q', b'MASC Overview')
        os.write(master, b'q')

    terminal.run_terminal_scenario(executable, description='Lane operator target identity',
        interact=interact, http_fixtures=fixtures, http_requests=requests)
    print('Unapplied action / exact evidence owner / mixed-owner refusal: PASS')


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
        key(b'q', b'MASC Overview')
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
