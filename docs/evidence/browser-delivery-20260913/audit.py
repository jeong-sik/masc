from pathlib import Path
import base64
import hashlib
import json
import re

P = Path(__file__).resolve().parent
def read(name):
    return json.loads((P / name).read_text())
def digest(data):
    return hashlib.sha256(data).hexdigest()

def json_slice(text, path):
    decoder = json.JSONDecoder()
    start = len(text) - len(text.lstrip())
    value, end = decoder.raw_decode(text, start)
    if not path:
        return text[start:end]
    wanted, *rest = path
    i = start + 1
    def space(j):
        while text[j] in ' \t\r\n': j += 1
        return j
    if isinstance(value, dict):
        while True:
            i = space(i)
            if text[i] == '}': raise KeyError(wanted)
            key, i = decoder.raw_decode(text, i)
            i = space(i); assert text[i] == ':'
            i = space(i + 1); _, stop = decoder.raw_decode(text, i)
            if key == wanted: return json_slice(text[i:stop], rest)
            i = space(stop)
            if text[i] == ',': i += 1
    elif isinstance(value, list):
        for key in range(len(value)):
            i = space(i); _, stop = decoder.raw_decode(text, i)
            if key == wanted: return json_slice(text[i:stop], rest)
            i = space(stop)
            if text[i] == ',': i += 1
        raise IndexError(wanted)
    else: raise TypeError('path crosses a scalar')

# Hash the complete committed bundle, including the captured outputs used below.
checksums = {}
for line in (P / 'SHA256SUMS').read_text().splitlines():
    sha, name = line.split(maxsplit=1)
    assert name not in checksums
    checksums[name] = sha
    assert digest((P / name).read_bytes()) == sha, name
files = {str(p.relative_to(P)) for p in P.rglob('*') if p.is_file() and p.name != 'SHA256SUMS'}
assert set(checksums) == files, 'unhashed or missing evidence file'

report = read('report.json'); candidate = read('candidate.json'); bundle = read('bundle/bundle.json')
assert report['build']['binary_commit'] == candidate['source_commit'] == bundle['source_commit']
assert report['binary_sha256'] == candidate['binary_sha256']['server'] == bundle['server_sha256']
assert report['clipboard']['tui_sha256'] == candidate['binary_sha256']['tui']
assert all(item['exit_code'] == 0 for item in bundle['exports'])
for name, expected in bundle['packages'].items():
    package = P / 'bundle' / name
    actual = {str(p.relative_to(package)): digest(p.read_bytes()) for p in package.rglob('*') if p.is_file()}
    assert actual == expected
assert report['composition_file_sha256'] == bundle['packages']['browser-navigate-content']['SKILL.md']
assert report['instruction_sha256'] == bundle['packages']['browser-lanes']['SKILL.md']

turn = read('turn.json'); receipts = read('receipts.json'); raw = read('raw-tool-results.json')
by_id = {r['execution_id']: r for r in receipts if r['record_kind'] == 'tool_call'}
assert len(by_id) == sum(r['record_kind'] == 'tool_call' for r in receipts)
by_use = {r['tool_use_id']: r for r in raw}; assert len(by_use) == len(raw)
outer = [by_id[key] for key in turn['execution_ids']]
assert len(outer) == len(set(turn['execution_ids'])) == len(raw) == 6
assert all(r['success'] for r in outer)
audit = read('composition-audit.json'); retained = read('retained-observation-audit.json')
assert audit['operation_id'] == report['operation_id'] == retained['operation_id']
assert audit['answer'] == (P / 'answer.txt').read_text()
expected = {}; composition_count = 0; total_bytes = 0
for row in outer:
    event = by_use[row['tool_use_id']]
    assert event['tool_name'] == row['tool'] and not event['tool_error']
    text = event['tool_result']; total_bytes += len(text.encode())
    assert len(text.encode()) == row['result_bytes']
    if row['tool'] == 'BrowserRead':
        expected[row['execution_id']] = json_slice(text, []).encode()
    elif row['tool'] == 'keeper_compose_browser-navigate-content':
        payload = json.loads(text); assert payload['composition_tool'] == row['tool']
        actions = payload['actions']; assert [a['node_id'] for a in actions] == ['navigate', 'content']
        nav, body = actions
        assert body['input']['expectedUrl'] == nav['result']['data']['url']
        assert body['input']['tabId'] == nav['input']['tabId']
        for a in actions:
            durable = by_id[a['execution_id']]
            assert durable['tool_use_id'] == a['tool_use_id'] and durable['input'] == a['input']
            assert durable['tool'] == a['tool_name'] and durable['success']
            assert a['result']['disposition'] == 'completed'
        expected[body['execution_id']] = json_slice(text, ['actions', 1, 'result', 'data']).encode()
        composition_count += 1
assert composition_count == audit['composition_invocations'] == 3
assert total_bytes == audit['outer_result_bytes'] == 36199
assert not any(r['tool'] == 'keeper_artifact_read' for r in outer)
assert len(expected) == retained['retained_observation_count'] == 4
observations = {}
for execution_id, delivered in expected.items():
    refs = [r['_blob'] for r in by_id[execution_id].get('artifact_refs', [])
            if r.get('_blob', {}).get('mime') == 'application/vnd.masc.browser-scene+json']
    assert len(refs) == 1
    ref = refs[0]; data = (P / 'observations' / ref['sha256']).read_bytes()
    assert data == delivered and len(data) == ref['bytes'] and digest(data) == ref['sha256']
    observations[(execution_id, ref['sha256'])] = json.loads(data)

history = read('history/report.json'); contexts = read('history/contexts.json')
assert history['source_commit'] == candidate['source_commit'] and history['keeper'] == report['keeper']
assert history['server_sha256'] == report['binary_sha256'] and history['tui_sha256'] == candidate['binary_sha256']['tui']
assert history['clients']['data']['clients'] == [] and history['capture_exit'] == history['server_exit'] == 0
full_history = (P / 'history/history.pty').read_bytes()
osc = re.compile(rb'\x1b\]52;c;([A-Za-z0-9+/=]+)\x07')
copied = [json.loads(base64.b64decode(m.group(1))) for m in osc.finditer(full_history)]
assert copied == contexts
assert {(c['execution_id'], c['artifact']['_blob']['sha256']) for c in contexts} == set(observations)
for context in contexts:
    key = (context['execution_id'], context['artifact']['_blob']['sha256'])
    scene = observations[key]
    assert context['current'] is False and context['keeper'] == report['keeper']
    assert context['observed_at'] == by_id[key[0]]['ts']
    assert context['documentId'] == scene['documentId'] and context['url'] == scene['url']
    assert context['truncated'] == scene['truncated']
end = b'\x1b[?7h'
for row in read('history/capture-boundaries.json'):
    i = row['observation']
    partial = (P / f'history/observation-{i}.pty').read_bytes()
    complete = (P / f'history/observation-{i}-complete.pty').read_bytes()
    assert full_history.startswith(partial) and full_history.startswith(complete)
    assert len(partial) == row['partial_bytes'] and len(complete) == row['completed_frame_bytes']
    assert full_history.find(end, len(partial)) + len(end) == len(complete)
    assert complete.endswith(end)
for name, i, evidence_text in [('gamma', 0, 'end-to-end QA Wednesday'), ('overview', 3, 'Text 1/4')]:
    text = (P / f'history/{name}-complete.txt').read_text()
    assert contexts[i]['url'] in text and contexts[i]['execution_id'] in text
    assert evidence_text in ' '.join(text.split())
    if name == 'overview':
        assert not any(word in text for word in ['Sora', 'Mina', 'Cedar', 'Wednesday', 'Text 1/14'])

follow = read('tui-follow-audit.json'); lifetime = read('tui-lifetime.json')
assert lifetime['alive_at_copy'] and lifetime['alive_after_keeper_observation'] and lifetime['exit'] == 0
assert not lifetime['capture_errors'] and not [e for e in lifetime['input_events'] if e['monotonic'] > report['turn_started_monotonic']]
assert follow['frames'] == 53 and set(follow['seen']) == {'alpha', 'beta', 'gamma'}
raw_follow = (P / 'tui-follow.pty').read_bytes()
for channel, seen in follow['seen'].items():
    frame = (P / f'tui-{channel}.pty').read_bytes(); text = (P / f'tui-{channel}.txt').read_text()
    assert raw_follow.startswith(frame) and frame.endswith(end) and len(frame) == seen['offset']
    assert text == seen['text'] and seen['url'] in text and seen['heading'] in text
    assert seen['message'] in ' '.join(text.split())
for row in report['cleanup']:
    if isinstance(row, dict) and row.get('name') in ('server', 'driver'): assert row['exit'] == 0
for name, sha in candidate['fixture_sha256'].items(): assert digest((P / name).read_bytes()) == sha
assert (P / 'native-history-fixture.txt').read_text().strip() == 'Browser observation history: PASS'
print('PASS: binary-exported packages, 6 calls/3 compositions, 4 exact scene blobs, 3 live-follow frames, 4 historical contexts and completed frame boundaries')
