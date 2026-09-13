from pathlib import Path
import sys,json,hashlib
p=Path(__file__).resolve().parent
sys.path.insert(0,str(p))
from compare_runs import summarize,raw_value
summary=summarize(p)
assert summary['outer_calls']==6 and summary['outer_errors']==0 and summary['successful_compositions']==3
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
proof=json.loads((p/'retained-observations-audit.json').read_text());assert len(proof['observations'])==4
for o in proof['observations']:
 ref=o['reference'];data=(p/'observations'/ref['sha256']).read_bytes()
 assert hashlib.sha256(data).hexdigest()==ref['sha256'] and len(data)==ref['bytes']
 assert data==delivered[o['execution_id']]
 assert any(a.get('_blob')==ref for a in by_id[o['execution_id']]['artifact_refs'])
load=lambda path:json.loads(path.read_text())
bundle=load(p/'bundle.json');report=load(p/'report.json');commit='3446d8a35ee132eebadcadc63fc77d36e4eafead'
assert bundle['source_commit']==report['build']['binary_commit']==report['live_extension']['source_commit']==commit
assert bundle['binaries']==bundle['binary_source_proof']['sha256']
assert report['binary_sha256']==bundle['binaries']['masc-macos-arm64']
sourceproof=load(p/'candidate-source-proof.json')
assert sourceproof['source_commit']==commit and sourceproof['tracked_clean'] is True
assert report['live_extension']['native_host_sha256']==bundle['binaries']['masc-browser-host-macos-arm64']
assert bundle['runtime_provenance']['source_commit']==commit
cleanup=report['cleanup']
assert any(isinstance(e,dict) and e.get('keeper_shutdown_finalized') is True for e in cleanup)
assert any(isinstance(e,dict) and e.get('keeper_shutdown_admission',{}).get('accepted') is True for e in cleanup)
assert {e['name']:e['exit'] for e in cleanup if isinstance(e,dict) and 'name' in e}=={'server':0,'driver':0}
assert [e for e in cleanup if isinstance(e,str)]==['owned live Firefox profile closed','owned unique native host manifest removed']
tui=load(p/'tui-follow-audit.json');life=load(p/'tui-lifetime.json');assert tui['frames']==116 and tui['all_three_channels_followed']
assert life['alive_at_copy'] and life['alive_after_keeper_observation'] and life['capture_errors']==[]
assert life['exit']==0 and life['binary_sha256']==bundle['binaries']['masc-tui-macos-arm64']
assert not any(e['monotonic']>report['turn_started_monotonic'] for e in life['input_events'])
raw=(p/'tui-follow.pty').read_bytes()
for name,seen in tui['seen'].items():assert (p/f'tui-{name}.pty').read_bytes()==raw[:seen['offset']]
assert (p/'answer.txt').read_text()==load(p/'composition-audit.json')['answer']
for line in (p/'SHA256SUMS').read_text().splitlines():
 sha,name=line.split(None,1);assert hashlib.sha256((p/name).read_bytes()).hexdigest()==sha,name
print(json.dumps(summary,ensure_ascii=False))
