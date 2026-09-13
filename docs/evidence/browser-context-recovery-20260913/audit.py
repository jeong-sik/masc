"""Offline receipt, clipboard, composition, retained-byte and TUI evidence audit."""
import base64
import hashlib
import json
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parent
sys.path.insert(0, str(ROOT / 'scripts'))
from raw_json import raw_value


def read(root, name):
    return json.loads((root / name).read_text())


def audit_trial(name):
    root = ROOT / name
    report = read(root, 'report.json')
    recorded = read(root, 'composition-audit.json')
    context = read(root, 'tui-context.json')
    clipboard = (root / 'tui-context.json').read_bytes()
    osc = (root / 'clipboard-osc52.bin').read_bytes()
    assert osc == b'\x1b]52;c;' + base64.b64encode(clipboard) + b'\x07'
    assert read(root, '08-user-message.json')['message'].endswith(clipboard.decode())
    assert hashlib.sha256(clipboard).hexdigest() == report['clipboard']['clipboard_sha256']
    turns = read(root, 'keeper-turn-records.json')['response']['entries']
    assert len(turns) == 1
    ids = turns[0]['record']['execution_ids']
    assert len(ids) == len(set(ids))
    rows = [r for r in read(root, 'keeper-tool-calls.json')['response']['entries']
            if r['record_kind'] == 'tool_call']
    by_id = {r['execution_id']: r for r in rows}
    assert len(by_id) == len(rows)
    raw = read(root, 'raw-tool-results.json')
    by_use = {r['tool_use_id']: r for r in raw}
    assert len(raw) == len(by_use) == len(ids)
    outer = [by_id[i] for i in ids]
    assert [r['execution_id'] for r in recorded['outer_calls']] == ids
    scenes, compositions = {}, []
    for row, archived in zip(outer, recorded['outer_calls']):
        event = by_use[row['tool_use_id']]
        output = event['tool_result']
        assert event['record_type'] == 'tool_execution_finished'
        assert event['tool_name'] == row['tool'] == archived['tool']
        assert row['input'] == archived['input']
        assert row['success'] == archived['success'] == (not event['tool_error'])
        assert output == archived['output']
        assert len(output.encode()) == archived['raw_result_bytes']
        if row['tool'] == 'keeper_compose_browser-live-click-content':
            payload, end = json.JSONDecoder().raw_decode(output)
            assert payload['composition_tool'] == row['tool']
            nodes = payload['actions'] if row['success'] else payload['settled']
            for node in nodes:
                child = by_id[node['execution_id']]
                assert child['input'] == node['input']
                assert child['tool_use_id'] == node['tool_use_id']
                assert child['tool'] == node['tool_name']
                assert child['success'] == (node['result']['disposition'] == 'completed')
            if row['success']:
                assert not output[end:].strip()
                assert [n['node_id'] for n in nodes] == ['click', 'content']
                click, content = nodes
                receipt = click['result']['data']
                scene = content['result']['data']
                assert content['input']['expectedUrl'] == receipt['destinationUrl'] == scene['url']
                assert content['input']['navigationSource'] == receipt['navigationSource']
                assert receipt['navigationSource']['documentId'] == click['input']['documentId']
                assert receipt['navigationSource']['url'] == click['input']['expectedUrl']
                assert click['input']['clientId'] == content['input']['clientId'] == scene['clientId'] == context['clientId']
                assert click['input']['tabId'] == content['input']['tabId'] == scene['tabId'] == context['tabId']
                scenes[content['execution_id']] = raw_value(output, ['actions', 1, 'result', 'data']).encode()
            else:
                assert payload['cause']['node'] == nodes[-1]
                assert payload['effect_disposition'] == 'proven_pre_effect'
            compositions.append((row, nodes))
        elif row['tool'] == 'BrowserRead' and row['success']:
            payload = json.loads(output)
            if payload.get('schema') == 'masc.browser.scene.v1':
                scenes[row['execution_id']] = raw_value(output, []).encode()
    assert recorded['outer_call_count'] == len(outer)
    assert recorded['outer_errors'] == sum(not r['success'] for r in outer)
    assert recorded['outer_result_bytes'] == sum(len(by_use[r['tool_use_id']]['tool_result'].encode()) for r in outer)
    assert recorded['successful_compositions'] == sum(r['success'] for r, _ in compositions)
    history = read(root, 'keeper-history.json')['response']
    if isinstance(history, dict):
        history = history['messages']
    answers = [r['content'] for r in history if r.get('role') == 'assistant'
               and r.get('transcript_slot', {}).get('kind') == 'terminal_assistant']
    assert answers == [recorded['answer']]
    lifetime = read(root, 'tui-lifetime.json')
    assert lifetime['alive_at_copy'] and lifetime['alive_after_keeper_observation']
    assert lifetime['exit'] == 0 and not lifetime['capture_errors']
    assert lifetime['binary_sha256'] == report['clipboard']['tui_sha256']
    assert not [e for e in lifetime['input_events'] if e['monotonic'] > report['turn_started_monotonic']]
    assert {'keeper_shutdown_finalized': True} in report['cleanup']
    assert 'owned live Firefox profile closed' in report['cleanup']
    assert 'owned unique native host manifest removed' in report['cleanup']
    assert all(r['exit'] == 0 for r in report['cleanup'] if isinstance(r, dict) and r.get('name') in ('server', 'driver'))
    if name == 'before':
        assert (len(outer), recorded['outer_errors'], len(scenes)) == (2, 2, 0)
        assert 'defaultAction' not in context
        assert all(len(nodes) == 1 and nodes[0]['input']['nodeId'] == context['nodeId']
                   and nodes[0]['result']['message'] == 'scene_link_not_observed'
                   for _, nodes in compositions)
        return
    assert (len(outer), recorded['outer_errors'], len(compositions), len(scenes)) == (6, 0, 3, 4)
    assert context['targetKind'] == 'region'
    action = context['defaultAction']
    assert action['kind'] == 'read_region' and action['tool'] == 'BrowserRead'
    assert action['input']['scope'] == {'documentId': context['documentId'], 'nodeId': context['nodeId']}
    first_read = next(r for r in outer if r['tool'] == 'BrowserRead')
    assert all(first_read['input'][key] == value for key, value in action['input'].items())
    refs = read(root, 'retained-observation-audit.json')['observations']
    assert set(scenes) == {r['execution_id'] for r in refs}
    for observation in refs:
        ref = observation['reference']
        receipt_refs = [r['_blob'] for r in by_id[observation['execution_id']]['artifact_refs']
                        if r.get('_blob', {}).get('mime') == 'application/vnd.masc.browser-scene+json']
        assert len(receipt_refs) == 1
        assert all(ref[k] == receipt_refs[0][k] for k in ('sha256', 'bytes', 'mime'))
        raw_scene = (root / 'observations' / ref['sha256']).read_bytes()
        assert raw_scene == scenes[observation['execution_id']]
        assert len(raw_scene) == ref['bytes'] and hashlib.sha256(raw_scene).hexdigest() == ref['sha256']
        scene = json.loads(raw_scene)
        assert not scene['truncated'] and scene['source'] == 'live'
        assert scene['clientId'] == context['clientId'] and scene['tabId'] == context['tabId']
    follow = read(root, 'tui-follow-audit.json')
    raw_tui = (root / 'tui-follow.pty').read_bytes()
    assert follow['frames'] == 57 and set(follow['seen']) == {'alpha', 'beta', 'gamma'}
    for channel, seen in follow['seen'].items():
        frame = (root / f'tui-{channel}.pty').read_bytes()
        text = (root / f'tui-{channel}.txt').read_text()
        assert raw_tui.startswith(frame) and len(frame) == seen['offset'] and frame.endswith(b'\x1b[?7h')
        assert text == seen['text'] and seen['url'] in text and seen['heading'] in text
        assert seen['message'] in ' '.join(text.split())
    bundle = read(root, 'bundle.json')
    proof = read(root, 'native/verified-binaries.json')
    source = 'ee73f5fd4b6d042500b0d8e9ff807d4900848448'
    assert bundle['source_commit'] == proof['source_commit'] == report['build']['binary_commit'] == source
    assert read(root, 'candidate-source-proof.json')['source_commit'] == source
    assert bundle['binaries'] == proof['sha256'] == bundle['binary_source_proof']['sha256']
    assert report['binary_sha256'] == proof['sha256']['masc-macos-arm64']
    assert lifetime['binary_sha256'] == proof['sha256']['masc-tui-macos-arm64']
    assert report['live_extension']['native_host_sha256'] == proof['sha256']['masc-browser-host-macos-arm64']
    assert report['composition_file_sha256'] == hashlib.sha256((root / 'packaged-skills/browser-live-click-content/SKILL.md').read_bytes()).hexdigest()
    for package, files in bundle['packages'].items():
        actual = {str(p.relative_to(root / 'packaged-skills' / package)): hashlib.sha256(p.read_bytes()).hexdigest()
                  for p in (root / 'packaged-skills' / package).rglob('*') if p.is_file()}
        assert actual == files
    original = read(root, 'candidate-source-proof.json')['files']
    for filename, sha in report['live_extension']['files'].items():
        data = (root / 'extension' / filename).read_bytes()
        assert hashlib.sha256(data).hexdigest() == sha
        if filename == 'background.js':
            configured = ('const HOST_NAME = "' + report['live_extension']['host_name'] + '";').encode()
            assert data.count(configured) == 1
            data = data.replace(configured, b'const HOST_NAME = "masc_browser_host";')
        assert hashlib.sha256(data).hexdigest() == original['connectors/browser/extension/' + filename]


manifest = {}
for line in (ROOT / 'SHA256SUMS').read_text().splitlines():
    sha, name = line.split(maxsplit=1)
    assert name not in manifest
    manifest[name] = sha
    assert hashlib.sha256((ROOT / name).read_bytes()).hexdigest() == sha, name
assert set(manifest) == {str(p.relative_to(ROOT)) for p in ROOT.rglob('*')
                         if p.is_file() and p != ROOT / 'SHA256SUMS' and '__pycache__' not in p.parts}
audit_trial('before')
audit_trial('after')
print('PASS: failed region-as-link attempt preserved; 6 calls, 0 errors, 3 compositions, 4 exact scenes, all 3 channels in native TUI')
