"""Match durable scene bytes to the exact JSON slices delivered to a Keeper."""
from pathlib import Path
import argparse
import hashlib
import json

parser = argparse.ArgumentParser()
parser.add_argument('evidence', type=Path)
parser.add_argument('--output', type=Path, required=True)
a = parser.parse_args()
p = a.evidence.resolve()
decoder = json.JSONDecoder()

def raw_value(text, path):
    if not path:
        start = len(text) - len(text.lstrip())
        _, end = decoder.raw_decode(text, start)
        return text[start:end]
    value = json.loads(text)
    index = len(text) - len(text.lstrip()) + 1
    wanted, *remaining = path
    def skip(i):
        while i < len(text) and text[i] in ' \n\r\t':
            i += 1
        return i
    if isinstance(value, dict):
        while True:
            index = skip(index)
            if text[index] == '}':
                raise KeyError(wanted)
            key, index = decoder.raw_decode(text, index)
            index = skip(index)
            assert text[index] == ':'
            start = skip(index + 1)
            _, end = decoder.raw_decode(text, start)
            if key == wanted:
                return raw_value(text[start:end], remaining)
            index = skip(end)
            if text[index] == ',':
                index += 1
    elif isinstance(value, list):
        for item_index in range(len(value)):
            start = skip(index)
            _, end = decoder.raw_decode(text, start)
            if item_index == wanted:
                return raw_value(text[start:end], remaining)
            index = skip(end)
            if text[index] == ',':
                index += 1
        raise IndexError(wanted)
    else:
        raise TypeError('JSON path crosses a scalar')

report = json.loads((p / 'report.json').read_text())
audit = json.loads((p / 'composition-audit.json').read_text())
rows = json.loads((p / 'keeper-tool-calls.json').read_text())['response']['entries']
expected = {}
for outer in audit['outer_calls']:
    if outer['tool'] == 'keeper_skill' or not outer.get('success', True):
        continue
    text = outer['output']
    try:
        payload = json.loads(text)
    except json.JSONDecodeError:
        if outer['tool'] == 'BrowserRead':
            raise
        continue
    if not isinstance(payload, dict):
        continue
    if outer['tool'] == 'BrowserRead' and payload.get('schema') == 'masc.browser.scene.v1':
        expected[outer['execution_id']] = raw_value(text, []).encode()
    elif payload.get('tool_kind') == 'composition' and payload.get('composition_tool') == outer['tool']:
        for i, action in enumerate(payload['actions']):
            if action['tool_name'] == 'BrowserRead' and action['result']['disposition'] == 'completed':
                data = action['result']['data']
                if isinstance(data, dict) and data.get('schema') == 'masc.browser.scene.v1':
                    expected[action['execution_id']] = raw_value(text, ['actions', i, 'result', 'data']).encode()
assert expected, 'no completed scene observations in delivered results'
proof = []
for execution_id, delivered in expected.items():
    matching = [r for r in rows if r.get('record_kind') == 'tool_call' and r.get('execution_id') == execution_id]
    assert len(matching) == 1, 'ambiguous producer receipt'
    row = matching[0]
    refs = [r['_blob'] for r in row.get('artifact_refs', [])
            if r.get('_blob', {}).get('mime') == 'application/vnd.masc.browser-scene+json']
    assert len(refs) == 1
    ref = refs[0]
    sha = ref['sha256']
    raw = (p.parent / '.masc' / 'tool_blobs' / sha[:2] / sha).read_bytes()
    assert hashlib.sha256(raw).hexdigest() == sha and len(raw) == ref['bytes']
    assert raw == delivered, f'{execution_id}: durable bytes differ from delivered JSON slice'
    scene = json.loads(raw)
    proof.append({'execution_id': execution_id, 'tool_use_id': row['tool_use_id'], 'reference': ref,
                  'url': scene['url'], 'document_id': scene['documentId'], 'source': scene['source'],
                  'client_id': scene['clientId'], 'tab_id': scene['tabId'],
                  'scope': scene['scope'], 'truncated': scene['truncated']})
result = {'source_commit': report['build']['binary_commit'], 'binary_sha256': report['binary_sha256'],
          'operation_id': report['operation_id'], 'state': report['operation_state'],
          'outer_call_count': audit['outer_call_count'], 'outer_errors': audit['outer_errors'],
          'retained_observation_count': len(proof), 'artifact_reads_observed': sum(
              row['tool'] == 'keeper_artifact_read' for row in audit['outer_calls']),
          'observations': proof, 'proof_scope': 'Exact delivered JSON slices match durable blob bytes; no aligned screenshot claim.'}
a.output.write_text(json.dumps(result, ensure_ascii=False, indent=2) + '\n')
print(json.dumps({k: v for k, v in result.items() if k != 'observations'}, ensure_ascii=False))
