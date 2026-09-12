"""Join the typed turn's outer execution IDs to durable tool and node receipts."""
from pathlib import Path
import argparse,hashlib,json
parser=argparse.ArgumentParser();parser.add_argument('evidence',type=Path);args=parser.parse_args();p=args.evidence
report=json.loads((p/'report.json').read_text())
turns=json.loads((p/'keeper-turn-records.json').read_text())['response']['entries']
assert len(turns)==1
turn=turns[0]['record'];ids=turn['execution_ids'];assert len(set(ids))==len(ids)
rows=json.loads((p/'keeper-tool-calls.json').read_text())['response']['entries']
by_id={r['execution_id']:r for r in rows if r['record_kind']=='tool_call'}
assert len(by_id)==sum(r['record_kind']=='tool_call' for r in rows)
outer=[by_id[x] for x in ids]
raw_path=Path(turn['raw_trace_run_ref']['path'])
raw_events=[json.loads(line) for line in raw_path.read_text().splitlines()]
raw_outputs={event['tool_use_id']:event for event in raw_events if event['record_type']=='tool_execution_finished'}
resolved_outer=[]
for row in outer:
 row=dict(row)
 if row.get('truncated_to') is not None:
  event=raw_outputs[row['tool_use_id']]
  assert event['tool_name']==row['tool'] and event['tool_error']==(not row['success'])
  row['logged_output']=row['output']
  row['output']=event['tool_result']
  row['full_output_source']={'path':str(raw_path),'seq':event['seq'],'tool_use_id':row['tool_use_id']}
  assert len(row['output'].encode())==row['result_bytes']
 resolved_outer.append(row)
outer=resolved_outer
composed=[]
for row in outer:
 if row['tool'] in ('keeper_compose_browser-navigate-regions','keeper_compose_browser-navigate-content'):
  payload=json.loads(row['output']);assert payload['composition_tool']==row['tool']
  actions=payload['actions'];kind='regions' if row['tool']=='keeper_compose_browser-navigate-regions' else 'content';assert [a['node_id'] for a in actions]==['navigate',kind]
  for a in actions:
   durable=by_id[a['execution_id']]
   assert durable['tool_use_id']==a['tool_use_id'] and durable['input']==a['input'] and durable['tool']==a['tool_name']
   assert a['result']['disposition']=='completed' and durable['success']
  nav,read=actions
  assert read['input']['expectedUrl']==nav['result']['data']['url']
  assert nav['input']['tabId']==read['input']['tabId']==read['result']['data']['tabId']
  scene=read['result']['data']
  route={'outer_execution_id':row['execution_id'],'node_execution_ids':[a['execution_id'] for a in actions], 'url':scene['url'],'document_id':scene['documentId'],'navigation_then_observation_ms':[a['result']['duration_ms'] for a in actions]}
  if kind=='regions':
   scoped=[r for r in outer if r['tool']=='BrowserRead' and r['input'].get('mode')=='scene' and r['input'].get('scope',{}).get('documentId')==scene['documentId']]
   assert len(scoped)==1
   body=scoped[0];target=body['input']['scope']['nodeId']
   assert any(n['nodeId']==target and n['tag']=='article' for n in scene['nodes'])
   observed=json.loads(body['output']);assert observed['url']==scene['url'] and observed['scope']==body['input']['scope']
   route.update(body_execution_id=body['execution_id'],scope=body['input']['scope'])
  else:
   assert read['input']['mode']=='scene' and not read['input'].get('scope')
   observed=scene
   assert any(n['tag']=='h1' for n in observed['nodes'])
   route.update(scope=observed['scope'],visible_nodes=len(observed['nodes']))
  assert not observed['truncated']
  composed.append(route)
history=json.loads((p/'keeper-history.json').read_text())
items=history.get('response',history)
if isinstance(items,dict):
 for key in ['messages','items','rows']:
  if key in items:items=items[key];break
assert isinstance(items,list),type(items)
answer=[r['content'] for r in items if r.get('role')=='assistant' and r.get('transcript_slot',{}).get('kind')=='terminal_assistant']
assert len(answer)==1
result={'source':'typed turn execution_ids joined to durable tool_call rows; composition actions joined by execution_id and tool_use_id', 'operation_id':report['operation_id'],'state':report['operation_state'],'trace_id':turn['trace_id'],'runtime_id':report['runtime_id'],'server':report['build'],'tui_sha256':report['clipboard']['tui_sha256'],'outer_call_count':len(outer),'outer_errors':sum(not r['success'] for r in outer),'composition_invocations':len(composed),'outer_result_bytes':sum(len(r['output'].encode()) for r in outer),'outer_calls':[{'tool':r['tool'],'input':r['input'],'execution_id':r['execution_id'],'tool_use_id':r['tool_use_id'],'success':r['success'],'output':r['output'],'full_output_source':r.get('full_output_source')} for r in outer],'composition_routes':composed,'answer':answer[0],'observed_elapsed_seconds':report['turn_observed_elapsed_seconds'],'measurement_limits':['Outer calls are typed execution-ID joins; truncated durable outputs are resolved from raw tool_execution_finished events by exact tool_use_id.','Timing includes status polling and request latency; no causal speed claim from a single run.','Answer accuracy is reviewed separately against the retained fixture; call counts alone do not establish it.']}
(p/'composition-audit.json').write_text(json.dumps(result,ensure_ascii=False,indent=2)+'\n')
print({k:result[k] for k in ['outer_call_count','outer_errors','composition_invocations','outer_result_bytes','observed_elapsed_seconds']})
