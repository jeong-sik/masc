"""Audit retained bytes and joined observations; does not rerun Firefox."""
from pathlib import Path
import hashlib
import json

base = Path(__file__).resolve().parent
for name in ['source-error-early-terminal', 'first-complete-too-early',
             'commit-then-document-end', 'final-extension-dispatch',
             'cancel-immediate-read-failure', 'cancel-after-observed-commit']:
    directory = base / name
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

partial = json.loads((base / 'cancel-immediate-read-failure/proof.json').read_text())
assert partial['failure'] is not None
assert all(item['ok'] for item in partial['cleanup'])
negative = json.loads((base / 'cancel-after-observed-commit/proof.json').read_text())
assert negative['failure'] is None
assert negative['source_commit'] == proof['source_commit']
assert negative['background_sha256'] == proof['background_sha256']
assert len(negative['cleanup']) == 5 and all(item['ok'] for item in negative['cleanup'])
negative_events = negative['events_before_resource_release']
negative_cases = [event for event in negative_events if event['kind'] == 'case']
assert [case['name'] for case in negative_cases] == ['closed-tab', 'read-deadline']
assert [case['rejected']['error'] for case in negative_cases] == ['navigation_tab_closed', 'browser_command_cancelled']
for case in negative_cases:
    assert case['follow']['ok'] and not case['rejected']['ok']
    assert not any(event['type'] == 'onCommitted' for event in case['nativeEventsAtReadSettlement'])
late = next(event for event in negative_events if event['kind'] == 'late-commit')
fresh = next(event for event in negative_events if event['kind'] == 'fresh-read')
assert late['old_read_reply_count'] == 1
assert late['committed']['documentId'] != negative_cases[1]['sourceFrameBeforeFollow']['documentId']
assert fresh['finalFrame']['documentId'] == late['committed']['documentId']
assert fresh['old_read_reply_count'] == 1 and fresh['answer']['ok']
assert late['committed']['url'] == fresh['answer']['data']['url']
assert any(node['tag'] == 'h1' and node['text'] == 'Observed /pending' for node in fresh['answer']['data']['nodes'])
assert sum(event['kind'] == 'reply' and event['verb'] == 'page.interact' for event in negative_events) == 2
print('PASS: cancelled reads stay settled; fresh observation follows externally verified commit; prior failure retained')

ci = base / 'native-host-ci'
provenance = json.loads((ci / 'provenance.json').read_text())
assert (ci / 'SOURCE_COMMIT').read_text().strip() == provenance['source_commit'] == 'c082d495b1edc03588142b310177712718c36b49'
assert provenance['run_id'] == 34732183649
assert 'Ran 15 tests' in (ci / 'native-host-tests.txt').read_text()
assert (ci / 'native-host-tests.txt').read_text().strip().endswith('OK')
print('PASS: retained native host CI identity and 15-test result; binary hashes verified at artifact download')

from compare_runs import summarize, raw_value
controlled = base / 'controlled-native-bridge'
for name, digest in json.loads((controlled / 'files-sha256.json').read_text()).items():
    assert hashlib.sha256((controlled / name).read_bytes()).hexdigest() == digest
measured = summarize(controlled)
assert measured['state'] == 'Succeeded'
assert (measured['outer_calls'], measured['outer_errors'], measured['successful_compositions']) == (6, 0, 3)
assert measured['component_sources'] == {'server_and_tui': '5334be62fca7e70350cff7e36899ef24f27230dc', 'native_host_and_extension': 'c082d495b1edc03588142b310177712718c36b49'}
controlled_report = json.loads((controlled / 'report.json').read_text())
bridge = json.loads((controlled / 'bridge-source-proof.json').read_text())
assert measured['actual_binary_sha256']['masc-browser-host-macos-arm64'] == bridge['native_host_sha256']
assert bridge['source_commit'] == measured['component_sources']['native_host_and_extension']
assert bridge['files']['connectors/browser/extension/background.js'] == proof['background_sha256']
calls = json.loads((controlled / 'composition-audit.json').read_text())['outer_calls']
assert [call['tool'] for call in calls] == ['keeper_skill', 'keeper_skill', 'BrowserRead'] + ['keeper_compose_browser-live-click-content'] * 3
previous = json.loads(calls[2]['output'])
delivered = {calls[2]['execution_id']: raw_value(calls[2]['output'], []).encode()}
for call in calls[3:]:
    payload = json.loads(call['output'])
    follow, read = payload['actions']
    nav = follow['result']['data']
    assert follow['input']['action'] == 'follow_link'
    assert follow['input']['documentId'] == previous['documentId']
    assert follow['input']['expectedUrl'] == previous['url']
    assert any(node['nodeId'] == follow['input']['nodeId'] and node.get('href') == nav['destinationUrl'] for node in previous['nodes'])
    assert read['input']['navigationSource'] == nav['navigationSource']
    assert read['result']['data']['url'] == nav['destinationUrl']
    assert read['input']['tabId'] == follow['input']['tabId'] == previous['tabId']
    assert read['input']['clientId'] == follow['input']['clientId'] == previous['clientId']
    delivered[read['execution_id']] = raw_value(call['output'], ['actions', 1, 'result', 'data']).encode()
    previous = read['result']['data']
rows = {row['execution_id']: row for row in json.loads((controlled / 'keeper-tool-calls.json').read_text())['response']['entries'] if row['record_kind'] == 'tool_call'}
observations = json.loads((controlled / 'retained-observations-audit.json').read_text())['observations']
assert len(observations) == 4
for observed in observations:
    ref = observed['reference']
    raw = (controlled / 'retained-scenes' / (ref['sha256'] + '.json')).read_bytes()
    assert hashlib.sha256(raw).hexdigest() == ref['sha256'] and len(raw) == ref['bytes']
    assert raw == delivered[observed['execution_id']]
    actual_refs = [entry['_blob'] for entry in rows[observed['execution_id']]['artifact_refs'] if entry.get('_blob', {}).get('mime') == 'application/vnd.masc.browser-scene+json']
    assert actual_refs == [ref]
import base64
import re
clipboard = (controlled / 'clipboard-osc52.bin').read_bytes()
assert clipboard in (controlled / 'tui-initial.pty').read_bytes()
encoded, = re.findall(rb'\x1b\]52;[^;]*;([A-Za-z0-9+/=]+)(?:\x07|\x1b\\)', clipboard)
assert base64.b64decode(encoded, validate=True) == (controlled / 'tui-context.json').read_bytes()
tui = json.loads((controlled / 'tui-follow-audit.json').read_text())
assert tui['frames'] == 76 and tui['all_three_channels_followed'] and tui['input_log_available']
raw_pty = (controlled / 'tui-follow.pty').read_bytes()
for channel in ['alpha', 'beta', 'gamma']:
    assert raw_pty.startswith((controlled / ('tui-' + channel + '.pty')).read_bytes())
assert json.loads((controlled / 'tui-lifetime.json').read_text())['exit'] == 0
assert {entry['name']: entry['exit'] for entry in controlled_report['cleanup'] if isinstance(entry, dict) and 'name' in entry} == {'server': 0, 'driver': 0}
assert (controlled / 'answer.md').read_text() == json.loads((controlled / 'composition-audit.json').read_text())['answer'] + '\n'
print('PASS: controlled bridge run, 6 calls/0 errors/3 compositions, 4 exact scenes, shared TUI prefixes and clipboard')
