from pathlib import Path
import sys,json,hashlib
p=Path(__file__).resolve().parent
sys.path.insert(0,str(p.parent))
from compare_runs import summarize,raw_value
summary=summarize(p)
assert summary['outer_calls']==7 and summary['outer_errors']==0 and summary['successful_compositions']==4
raw=json.loads((p/'raw-tool-results.json').read_text());delivered={}
rows=json.loads((p/'keeper-tool-calls.json').read_text())['response']['entries'];by_id={r['execution_id']:r for r in rows if r['record_kind']=='tool_call'}
for event in raw:
 if event['tool_name']=='keeper_skill':continue
 text=event['tool_result'];value=json.loads(text)
 if event['tool_name']=='BrowserRead':
  row=next(r for r in by_id.values() if r['tool_use_id']==event['tool_use_id']);delivered[row['execution_id']]=raw_value(text,[]).encode()
 elif 'actions' in value:
  for i,a in enumerate(value['actions']):
   if a['tool_name']=='BrowserRead':delivered[a['execution_id']]=raw_value(text,['actions',i,'result','data']).encode()
proof=json.loads((p/'retained-observations-audit.json').read_text());assert len(proof['observations'])==5
for o in proof['observations']:
 ref=o['reference'];data=(p/'observations'/ref['sha256']).read_bytes()
 assert hashlib.sha256(data).hexdigest()==ref['sha256'] and len(data)==ref['bytes']
 assert data==delivered[o['execution_id']]
 assert any(a.get('_blob')==ref for a in by_id[o['execution_id']]['artifact_refs'])
import importlib.util
helper=p.parent.parent/'browser-continuity-20260913/audit.py'
spec=importlib.util.spec_from_file_location('continuity',helper);module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module)
load=lambda path:json.loads(path.read_text())
bundle=load(p/'bundle.json');report=load(p/'report.json');commit='fd441e234f58f34e2889d8fde0fc20d3ea2be4d1'
assert bundle['source_commit']==report['build']['binary_commit']==report['live_extension']['source_commit']==commit
assert bundle['binaries']==bundle['binary_source_proof']['sha256']
assert report['binary_sha256']==bundle['binaries']['masc-macos-arm64']
tui=load(p/'tui-follow-audit.json');life=load(p/'tui-lifetime.json');assert tui['frames']==55 and tui['all_three_channels_followed']
assert life['exit']==0 and life['binary_sha256']==bundle['binaries']['masc-tui-macos-arm64']
assert not any(e['monotonic']>report['turn_started_monotonic'] for e in life['input_events'])
raw=(p/'tui-follow.pty').read_bytes()
for name,seen in tui['seen'].items():assert (p/f'tui-{name}.pty').read_bytes()==raw[:seen['offset']]
assert (p/'answer.txt').read_text()==load(p/'composition-audit.json')['answer']
g=p/'gestures';trace=load(g/'tui-gestures.json');gr=load(g/'report.json')
assert trace['result']==gr['result']=='passed' and trace['tui_exit']==0 and trace['cleanup_errors']==[]
actions=[r for r in trace['receipts'] if r['path'].endswith('/interact')]
assert [r['input']['action'] for r in actions]==['click_at','drag','scroll_at','scroll_at']
assert all(r['status']==200 and r['response']['ok'] for r in actions)
raw=(g/'tui-gestures.pty').read_bytes();start=0
for image in trace['images']:
 png=(g/('tui-image-'+image['name']+'.png')).read_bytes()
 assert hashlib.sha256(png).hexdigest()==image['png_sha256'] and module.first_png(raw[start:image['pty_prefix_bytes']])==png
 start=image['pty_prefix_bytes']
for name,text in [('click-observed-1.json','Details opened by link click'),('drag-observed-2.json','Card moved; down trusted=true; up trusted=true'),('scroll-observed-3.json','Gesture Lab; Pane scroll=120'),('new-document-scroll-observed-6.json','Gesture Lab; Pane scroll=120')]:
 assert any(n['text']==text for n in load(g/name)['data']['nodes'])
stale=load(g/'stale-viewport-probe.json');assert stale['status']==400 and stale['input']==actions[2]['input']
fresh=load(g/'external-navigation-observed-5.json')['data'];assert actions[-1]['input']['expectedUrl']==fresh['url']
assert actions[-1]['input']['viewport']['documentId']==fresh['documentId']!=actions[2]['input']['viewport']['documentId']
assert trace['external_navigation_followed_without_tui_input'] and trace['post_navigation_gesture_used_displayed_document']
for line in (p/'SHA256SUMS').read_text().splitlines():
 sha,name=line.split(None,1);assert hashlib.sha256((p/name).read_bytes()).hexdigest()==sha,name
print(json.dumps(summary,ensure_ascii=False))
