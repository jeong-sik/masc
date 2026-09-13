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
for line in (p/'SHA256SUMS').read_text().splitlines():
 sha,name=line.split(None,1);assert hashlib.sha256((p/name).read_bytes()).hexdigest()==sha,name
print(json.dumps(summary,ensure_ascii=False))
