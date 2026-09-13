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


def audit_recovered_live():
    root = ROOT / 'after-read-recovery'
    audit = load(root / 'composition-audit.json')
    report = load(root / 'report.json')
    assert report['operation_state'] == audit['state'] == 'Succeeded'
    assert report['build']['binary_commit'] == '5334be62fca7e70350cff7e36899ef24f27230dc'
    assert (audit['outer_call_count'], audit['outer_errors'], audit['successful_compositions']) == (9, 3, 0)
    assert (root / 'answer.md').read_text() == audit['answer'] + '\n'
    rows_list = [row for row in load(root / 'keeper-tool-calls.json')['response']['entries'] if row['record_kind']=='tool_call']
    rows = {r['execution_id']:r for r in rows_list}
    events_list = load(root / 'raw-tool-results.json')
    events = {r['tool_use_id']:r for r in events_list}
    assert len(rows)==len(rows_list) and len(events)==len(events_list)
    calls=audit['outer_calls']
    turn, = load(root / 'keeper-turn-records.json')['response']['entries']
    assert turn['record']['execution_ids']==[c['execution_id'] for c in calls]
    assert len(set(turn['record']['execution_ids']))==len(calls)
    assert [c['tool'] for c in calls] == ['keeper_skill','keeper_skill','BrowserRead'] + ['keeper_compose_browser-live-click-content','BrowserRead']*3
    for c in calls:
        r=rows[c['execution_id']];e=events[c['tool_use_id']]
        assert c['tool']==r['tool']==e['tool_name']
        assert c['tool_use_id']==r['tool_use_id']
        assert c['input']==r['input'] and c['output']==e['tool_result']
        assert c['success']==r['success']==(not e['tool_error'])
    for i in (3,5,7):
        failed=calls[i];retry=calls[i+1]
        wire,_=json.JSONDecoder().raw_decode(failed['output'])
        assert not failed['success'] and retry['success']
        assert wire['effect_disposition']=='proven_post_effect'
        click,read=wire['settled']
        assert click['result']['disposition']=='completed' and click['input']['action']=='follow_link'
        assert read['result']['disposition']=='failed' and read['result']['message']=='Missing host permission for the tab'
        assert wire['cause']['node']==read
        for node in (click,read):
            row=rows[node['execution_id']]
            assert row['input']==node['input'] and row['tool']==node['tool_name'] and row['tool_use_id']==node['tool_use_id']
            assert row['success']==(node['result']['disposition']=='completed')
        nav=click['result']['data']
        assert retry['input']['navigationSource']==nav['navigationSource']
        assert retry['input']['expectedUrl']==nav['destinationUrl']
        assert retry['input']['clientId']==nav['clientId'] and retry['input']['tabId']==nav['tabId']
        scene=json.loads(retry['output'])
        assert scene['url']==nav['destinationUrl']
    observations=load(root / 'retained-observations-audit.json')['observations']
    assert len(observations)==4
    clipboard=(root/'clipboard-osc52.bin').read_bytes()
    assert clipboard in (root/'tui-initial.pty').read_bytes()
    encoded,=re.findall(rb'\x1b\]52;[^;]*;([A-Za-z0-9+/=]+)(?:\x07|\x1b\\)',clipboard)
    context=base64.b64decode(encoded,validate=True)
    assert context==(root/'tui-context.json').read_bytes()
    assert load(root/'08-user-message.json')['message'].endswith(context.decode())
    for observed in observations:
        ref=observed['reference'];data=(root/'retained-scenes'/(ref['sha256']+'.json')).read_bytes()
        row=rows[observed['execution_id']]
        scene_refs=[r['_blob'] for r in row['artifact_refs']
                    if r.get('_blob',{}).get('mime')=='application/vnd.masc.browser-scene+json']
        assert scene_refs==[ref] and row['tool_use_id']==observed['tool_use_id']
        assert sha(data)==ref['sha256'] and len(data)==ref['bytes']
        call,=[c for c in calls if c['execution_id']==observed['execution_id']]
        assert data==call['output'].encode()
    tui=load(root / 'tui-follow-audit.json')
    assert tui['all_three_channels_followed'] and list(tui['seen'])==['alpha','beta','gamma']
    raw=(root/'tui-follow.pty').read_bytes()
    for channel in ('alpha','beta','gamma'):
        assert raw.startswith((root/('tui-'+channel+'.pty')).read_bytes())
    assert load(root/'tui-lifetime.json')['exit']==0
    assert {entry['name']:entry['exit'] for entry in report['cleanup'] if isinstance(entry,dict) and 'name' in entry}=={'server':0,'driver':0}
    return {'channels':3,'read_failures_recovered':3,'navigation_replays':0,'outer_calls':9,'successful_compositions':0,'tui_frames':tui['frames']}


def audit_updated_viewport():
    root=ROOT/'after-viewport';trace=load(root/'tui-gestures.json');report=load(root/'report.json')
    assert trace['result']==report['result']=='passed' and trace['tui_exit']==0 and trace['cleanup_errors']==[]
    assert report['build']['binary_commit']=='5334be62fca7e70350cff7e36899ef24f27230dc'
    actions=[r for r in trace['receipts'] if r['path'].endswith('/interact')]
    assert [r['input']['action'] for r in actions]==['click_at','drag','scroll_at','scroll_at']
    assert all(r['status']==200 and r['response']['ok'] for r in actions)
    assert not trace['immediate_scroll_image_changed'] and trace['cadence_frames_observed_after_scroll']==1
    assert trace['external_navigation_followed_without_tui_input'] and trace['post_navigation_gesture_used_displayed_document']
    raw=(root/'tui-gestures.pty').read_bytes();start=0
    for image in trace['images']:
        png=(root/('tui-image-'+image['name']+'.png')).read_bytes()
        assert sha(png)==image['png_sha256'] and first_png(raw[start:image['pty_prefix_bytes']])==png
        start=image['pty_prefix_bytes']
    assert (root/'tui-image-scrolled.png').read_bytes()==(root/'tui-image-dragged.png').read_bytes()
    assert (root/'tui-image-scroll-cadence-4.png').read_bytes()!=(root/'tui-image-dragged.png').read_bytes()
    for name,text in [('click-observed-1.json','Details opened by link click'),('drag-observed-2.json','Card moved; down trusted=true; up trusted=true'),('scroll-observed-3.json','Gesture Lab; Pane scroll=120'),('new-document-scroll-observed-6.json','Gesture Lab; Pane scroll=120')]:
        assert any(n['text']==text for n in load(root/name)['data']['nodes'])
    stale=load(root/'stale-viewport-probe.json')
    assert stale['status']==400 and stale['response']=={'ok':False,'error':'javascript error: Error: page_url_changed'}
    assert stale['input']==actions[2]['input']
    fresh=load(root/'external-navigation-observed-5.json')['data']
    assert actions[-1]['input']['expectedUrl']==fresh['url']
    assert actions[-1]['input']['viewport']['documentId']==fresh['documentId']
    assert actions[-1]['input']['viewport']['documentId']!=actions[2]['input']['viewport']['documentId']
    assert {e['name']:e['exit'] for e in report['cleanup'] if isinstance(e,dict) and 'name' in e}=={'server':0,'driver':0}
    return {'tui_actions':4,'stale_probe':'guard refusal, separately recorded','cadence_image_changed':True,'external_navigation_followed':True,'cleanup':'passed'}


if __name__ == '__main__':
    print(json.dumps({'read_failure':audit_read_failure(), 'stale_viewport':audit_stale_viewport(),
                      'recovered_live':audit_recovered_live(), 'updated_viewport':audit_updated_viewport()},indent=2))
