"""Audit retained bytes and joined observations; does not rerun Firefox."""
from pathlib import Path
import hashlib
import json

base = Path(__file__).resolve().parent
for directory in base.iterdir():
    if not directory.is_dir():
        continue
    proof = json.loads((directory / 'proof.json').read_text())
    assert hashlib.sha256((directory / 'probe.py').read_bytes()).hexdigest() == proof['probe_sha256']

final = base / 'final-extension-dispatch'
proof = json.loads((final / 'proof.json').read_text())
assert proof['source_commit'] == 'b40259fc4baf9187936a0686301b937d76b7104e'
assert hashlib.sha256((final / 'background.js').read_bytes()).hexdigest() == proof['background_sha256']
assert proof['failure'] is None
assert len(proof['cleanup']) == 5 and all(item['ok'] for item in proof['cleanup'])
events = proof['events_before_resource_release']
assert events[-1]['kind'] == 'done'
cases = [event for event in events if event['kind'] == 'case']
assert [case['name'] for case in cases] == ['document-change', 'same-url-link', 'redirect', 'hash', 'destination-error']
replies = [event for event in events if event['kind'] == 'reply']
assert len(replies) == 11
assert [event['verb'] for event in replies] == ['page.scene'] + ['page.interact', 'page.scene'] * 5
previous = replies[0]['answer']['data']
for index, case in enumerate(cases):
    followed = case['followed']
    read = case['read']
    assert followed == replies[1 + index * 2]['answer']
    assert read == replies[2 + index * 2]['answer']
    assert followed['ok'] and followed['data']['action'] == 'follow_link'
    assert followed['data']['navigationSource'] == {'url': previous['url'], 'documentId': previous['documentId']}
    request = replies[1 + index * 2]['args']
    assert request['expectedUrl'] == previous['url'] and request['documentId'] == previous['documentId']
    assert any(node['nodeId'] == request['nodeId'] and node.get('href') == followed['data']['destinationUrl'] for node in previous['nodes'])
    if case['name'] == 'destination-error':
        assert not read['ok'] and read['error']
        assert any(event['type'] == 'onCommitted' and event['details']['url'] == followed['data']['destinationUrl'] for event in case['events'])
        continue
    assert read['ok'] and case['observedState']['ready'] == 'interactive'
    observed = read['data']
    expected_path = '/final' if case['name'] in ['redirect', 'hash'] else '/first'
    assert case['observedState']['heading'] == 'Observed ' + expected_path
    if case['name'] == 'hash':
        assert observed['documentId'] == previous['documentId']
        assert observed['url'] == followed['data']['destinationUrl']
        assert any(event['type'] == 'onReferenceFragmentUpdated' and event['details']['url'] == observed['url'] for event in case['events'])
    else:
        assert observed['documentId'] != previous['documentId']
        committed = [event['details'] for event in case['events'] if event['type'] == 'onCommitted' and event['details']['url'] == observed['url']]
        assert committed
        assert any(event['type'] == 'onDOMContentLoaded' and event['details']['documentId'] == committed[-1]['documentId'] for event in case['events'])
    previous = observed
print('PASS: pinned bytes, 5 follow/read joins, 4 interactive documents, retained read failure, 5 cleanup stages')
