"""Audit archived failure observations; this does not execute a browser or model."""
import base64
import hashlib
import json
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parent
load = lambda path: json.loads(path.read_text())
sha = lambda value: hashlib.sha256(value).hexdigest()


def audit_read_failure():
    root = ROOT / 'before-read-failure'
    report = load(root / 'report.json')
    audit = load(root / 'composition-audit.json')
    assert report['operation_state'] == audit['state'] == 'Failed'
    assert audit['answer'] is None
    assert (audit['outer_call_count'], audit['outer_errors'], audit['successful_compositions']) == (4, 1, 0)
    tool_rows = [row for row in load(root / 'keeper-tool-calls.json')['response']['entries']
                 if row['record_kind'] == 'tool_call']
    rows = {row['execution_id']: row for row in tool_rows}
    assert len(rows) == len(tool_rows)
    raw_events = load(root / 'raw-tool-results.json')
    events = {event['tool_use_id']: event for event in raw_events}
    assert len(events) == len(raw_events)
    turn, = load(root / 'keeper-turn-records.json')['response']['entries']
    identities = turn['record']['execution_ids']
    assert len(identities) == len(set(identities))
    assert identities == [call['execution_id'] for call in audit['outer_calls']]
    for call in audit['outer_calls']:
        row = rows[call['execution_id']]
        event = events[row['tool_use_id']]
        assert event['tool_name'] == row['tool'] == call['tool']
        assert row['tool_use_id'] == call['tool_use_id']
        assert row['input'] == call['input']
        assert row['success'] == call['success'] == (not event['tool_error'])
        assert call['output'] == event['tool_result']
        assert call['raw_result_bytes'] == len(call['output'].encode())
    assert audit['outer_result_bytes'] == sum(len(call['output'].encode()) for call in audit['outer_calls'])
    failed, = audit['compositions']
    wire, _ = json.JSONDecoder().raw_decode(audit['outer_calls'][-1]['output'])
    assert failed['nodes'] == wire['settled']
    assert wire['effect_disposition'] == 'proven_post_effect'
    click, read = wire['settled']
    assert click['result']['disposition'] == 'completed'
    assert read['result']['disposition'] == 'failed'
    assert read['result']['message'] == 'Missing host permission for the tab'
    assert wire['cause']['node'] == read
    assert click['execution_id'] != read['execution_id']
    for node in (click, read):
        assert node['tool_name'] == rows[node['execution_id']]['tool']
        assert node['tool_use_id'] == rows[node['execution_id']]['tool_use_id']
        assert node['input'] == rows[node['execution_id']]['input']
        assert rows[node['execution_id']]['success'] == (node['result']['disposition'] == 'completed')
    assert load(root / '08-user-message.json')['message'].endswith((root / 'tui-context.json').read_text())
    assert load(root / 'tui-lifetime.json')['exit'] == 0
    return {'outer_calls': 4, 'failed_compositions': 1, 'result': 'failed turn preserved'}


def first_png(frame):
    encoded = None
    for header, payload in re.findall(rb'\x1b_G([^;]+);([^\x1b]*)\x1b\\', frame):
        fields = dict(part.split(b'=', 1) for part in header.split(b',') if b'=' in part)
        if fields.get(b'a') == b'T':
            assert fields[b'f'] == b'100'
            encoded = [payload]
        elif encoded is not None and b'm' in fields:
            encoded.append(payload)
        if encoded is not None and fields.get(b'm') == b'0':
            return base64.b64decode(b''.join(encoded), validate=True)
    raise AssertionError('no complete PNG placement')


def audit_stale_viewport():
    root = ROOT / 'before-stale-viewport'
    trace = load(root / 'tui-gestures.json')
    assert trace['result'] == 'failed' and trace['tui_exit'] is None
    assert trace['cleanup_errors']
    actions = [row for row in trace['receipts'] if row['path'].endswith('/interact')]
    assert [row['input']['action'] for row in actions] == ['click_at', 'drag', 'scroll_at']
    assert all(row['status'] == 200 and row['response']['ok'] for row in actions)
    for name, text in [('click-observed-1.json', 'Details opened by link click'),
                       ('drag-observed-2.json', 'Card moved; down trusted=true; up trusted=true'),
                       ('scroll-observed-3.json', 'Gesture Lab; Pane scroll=120')]:
        assert any(node['text'] == text for node in load(root / name)['data']['nodes'])
    raw = (root / 'tui-gestures.pty').read_bytes()
    start = 0
    for image in trace['images']:
        png = (root / ('tui-image-' + image['name'] + '.png')).read_bytes()
        assert sha(png) == image['png_sha256']
        assert first_png(raw[start:image['pty_prefix_bytes']]) == png
        start = image['pty_prefix_bytes']
    assert (root / 'tui-image-dragged.png').read_bytes() == (root / 'tui-image-scrolled.png').read_bytes()
    return {'verified_actions': 3, 'immediate_scroll_image': 'unchanged', 'cleanup': 'failed, exit unknown'}


if __name__ == '__main__':
    print(json.dumps({'read_failure': audit_read_failure(), 'stale_viewport': audit_stale_viewport()}, indent=2))
