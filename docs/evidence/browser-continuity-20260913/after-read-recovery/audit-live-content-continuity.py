"""Audit a natural live attempt without treating recovered tool failures as success."""
from pathlib import Path
import argparse,json,uuid
p=argparse.ArgumentParser();p.add_argument('evidence',type=Path);a=p.parse_args();root=a.evidence
load=lambda name:json.loads((root/name).read_text())
report=load('report.json');turns=load('keeper-turn-records.json')['response']['entries'];assert len(turns)==1
turn=turns[0]['record'];ids=turn['execution_ids'];assert len(ids)==len(set(ids))
rows=load('keeper-tool-calls.json')['response']['entries'];by_id={r['execution_id']:r for r in rows if r['record_kind']=='tool_call'}
events=[json.loads(line) for line in Path(turn['raw_trace_run_ref']['path']).read_text().splitlines()]
finished=[e for e in events if e['record_type']=='tool_execution_finished'];by_use={e['tool_use_id']:e for e in finished};assert len(by_use)==len(finished)
context=load('tui-context.json');client=context['clientId'];uuid.UUID(client)
assert load('08-user-message.json')['message'].endswith((root/'tui-context.json').read_text())
assert load('01-live-clients.json')['data']['clients'][0]['clientId']==client
outer=[];compositions=[];follows=[];wrong_clients=[]
for identity in ids:
 row=by_id[identity];e=by_use[row['tool_use_id']]
 assert row['tool']==e['tool_name'] and row['success']==(not e['tool_error'])
 output=e['tool_result'];actual_bytes=len(output.encode())
 outer.append({'execution_id':identity,'tool_use_id':row['tool_use_id'],'tool':row['tool'],'input':row['input'],
  'success':row['success'],'output':output,'raw_result_bytes':actual_bytes,'declared_result_bytes':row.get('result_bytes')})
 supplied=row['input'].get('clientId')
 if supplied is not None and supplied!=client:
  try:uuid.UUID(supplied);valid=True
  except ValueError:valid=False
  wrong_clients.append({'execution_id':identity,'supplied':supplied,'observed':client,'supplied_is_uuid':valid})
 if row['tool']=='keeper_compose_browser-live-click-content':
  payload,end=json.JSONDecoder().raw_decode(output)
  assert payload['composition_tool']==row['tool']
  nodes=payload['actions'] if row['success'] else payload['settled']
  for node in nodes:
   durable=by_id[node['execution_id']]
   assert durable['input']==node['input'] and durable['tool_use_id']==node['tool_use_id']
   assert durable['tool']==node['tool_name']
   assert durable['success']==(node['result']['disposition']=='completed')
  if row['success']:
   assert [n['node_id'] for n in nodes]==['click','content'] and not output[end:].strip()
  else:
   assert payload['cause']['kind']=='tool_did_not_complete'
   assert payload['cause']['node']==nodes[-1]
  compositions.append({'execution_id':identity,'success':row['success'],'nodes':nodes,
   'effect_disposition':payload.get('effect_disposition'),'raw_suffix':output[end:]})
 if row['tool']=='BrowserInteract' and row['success']:
  data=json.loads(output);assert data['clientId']==client and data['action']=='follow_link'
  assert data['tabId']==context['tabId'] and data['navigationSource']['url']==row['input']['expectedUrl']
  assert data['navigationSource']['documentId']==row['input']['documentId']
  follows.append({'execution_id':identity,'receipt':data})
history=load('keeper-history.json')['response']
if isinstance(history,dict):history=history['messages']
answer=[r['content'] for r in history if r.get('role')=='assistant' and r.get('transcript_slot',{}).get('kind')=='terminal_assistant']
assert len(answer)==1 if report['operation_state']=='Succeeded' else len(answer)<=1
result={'operation_id':report['operation_id'],'state':report['operation_state'],'outer_call_count':len(outer),
 'outer_errors':sum(not r['success'] for r in outer),'outer_result_bytes':sum(r['raw_result_bytes'] for r in outer),
 'composition_invocations':len(compositions),'successful_compositions':sum(c['success'] for c in compositions),
 'compositions':compositions,'direct_follow_receipts':follows,'wrong_client_inputs':wrong_clients,
 'outer_calls':outer,'terminal_text':answer[0] if answer else None,
 'answer':answer[0] if answer and report['operation_state']=='Succeeded' else None,'observed_elapsed_seconds':report['turn_observed_elapsed_seconds'],
 'byte_count_mismatches':[r['execution_id'] for r in outer if r['declared_result_bytes']!=r['raw_result_bytes']],
 'scope':'Actual live extension/native-host experiment. Keeper operation success is separate from composition success; raw failure suffixes and byte discrepancies are preserved.'}
(root/'composition-audit.json').write_text(json.dumps(result,ensure_ascii=False,indent=2)+'\n')
(root/'raw-tool-results.json').write_text(json.dumps([by_use[by_id[i]['tool_use_id']] for i in ids],ensure_ascii=False,indent=2)+'\n')
print(json.dumps({k:result[k] for k in ['state','outer_call_count','outer_errors','outer_result_bytes','composition_invocations','successful_compositions','observed_elapsed_seconds']},ensure_ascii=False))
