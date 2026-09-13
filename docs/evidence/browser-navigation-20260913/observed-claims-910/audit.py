from pathlib import Path
import sys,json,hashlib
p=Path(__file__).resolve().parent
sys.path.insert(0,str(p.parent))
from compare_runs import summarize,raw_value
summary=summarize(p)
assert summary['outer_calls']==6 and summary['outer_errors']==0 and summary['successful_compositions']==3
raw=json.loads((p/'raw-tool-results.json').read_text());raw_events=raw;delivered={}
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
import importlib.util
helper=p.parent.parent/'browser-continuity-20260913/audit.py'
spec=importlib.util.spec_from_file_location('continuity',helper);module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module)
load=lambda path:json.loads(path.read_text())
bundle=load(p/'bundle.json');report=load(p/'report.json');commit='fd441e234f58f34e2889d8fde0fc20d3ea2be4d1'
assert bundle['source_commit']==report['build']['binary_commit']==report['live_extension']['source_commit']==commit
assert bundle['binaries']==bundle['binary_source_proof']['sha256']
assert report['binary_sha256']==bundle['binaries']['masc-macos-arm64']
tui=load(p/'tui-follow-audit.json');life=load(p/'tui-lifetime.json');assert tui['frames']==53 and tui['all_three_channels_followed']
assert life['exit']==0 and life['binary_sha256']==bundle['binaries']['masc-tui-macos-arm64']
assert not any(e['monotonic']>report['turn_started_monotonic'] for e in life['input_events'])
raw=(p/'tui-follow.pty').read_bytes()
for name,seen in tui['seen'].items():assert (p/f'tui-{name}.pty').read_bytes()==raw[:seen['offset']]
assert (p/'answer.txt').read_text()==load(p/'composition-audit.json')['answer']
instruction=load(p/'instruction-source-proof.json')
assert instruction['modified_paths']==['SKILL.md']
assert instruction['baseline_export_source_commit']==bundle['source_commit']
assert bundle==load(p.parent/'full-native-fd441/bundle.json')
installed=p/'packaged-skill'
files={str(f.relative_to(installed)):hashlib.sha256(f.read_bytes()).hexdigest() for f in installed.rglob('*') if f.is_file()}
assert files==instruction['package_sha256']
assert files['SKILL.md']==instruction['new_sha256']
assert bundle['packages']['browser-lanes']['SKILL.md']==instruction['old_sha256']
assert [name for name,digest in files.items() if bundle['packages']['browser-lanes'][name]!=digest]==['SKILL.md']
second=raw_events[1]
assert second['tool_name']=='keeper_skill'
body=(installed/'SKILL.md').read_text().split('---',2)[2][1:]
assert second['tool_result']==body
for line in (p/'SHA256SUMS').read_text().splitlines():
 sha,name=line.split(None,1);assert hashlib.sha256((p/name).read_bytes()).hexdigest()==sha,name
print(json.dumps(summary,ensure_ascii=False))
