"""Audit a natural live attempt without treating recovered tool failures as success."""
from pathlib import Path
import argparse,json,uuid
root=Path(__file__).resolve().parent
load=lambda name:json.loads((root/name).read_text())
report=load('report.json');turns=load('keeper-turn-records.json')['response']['entries'];assert len(turns)==1
turn=turns[0]['record'];ids=turn['execution_ids'];assert len(ids)==len(set(ids))
rows=load('keeper-tool-calls.json')['response']['entries'];by_id={r['execution_id']:r for r in rows if r['record_kind']=='tool_call'}
finished=load('raw-tool-results.json');assert all(e['record_type']=='tool_execution_finished' for e in finished)
by_use={e['tool_use_id']:e for e in finished};assert len(by_use)==len(finished)
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
answer=[r['content'] for r in history if r.get('role')=='assistant' and r.get('transcript_slot',{}).get('kind')=='terminal_assistant'];assert len(answer)==1
result={'operation_id':report['operation_id'],'state':report['operation_state'],'outer_call_count':len(outer),
 'outer_errors':sum(not r['success'] for r in outer),'outer_result_bytes':sum(r['raw_result_bytes'] for r in outer),
 'composition_invocations':len(compositions),'successful_compositions':sum(c['success'] for c in compositions),
 'compositions':compositions,'direct_follow_receipts':follows,'wrong_client_inputs':wrong_clients,
 'outer_calls':outer,'answer':answer[0],'observed_elapsed_seconds':report['turn_observed_elapsed_seconds'],
 'byte_count_mismatches':[r['execution_id'] for r in outer if r['declared_result_bytes']!=r['raw_result_bytes']],
 'scope':'Actual live extension/native-host experiment. Keeper operation success is separate from composition success; raw failure suffixes and byte discrepancies are preserved.'}
assert result==load('composition-audit.json')
assert [by_use[by_id[i]['tool_use_id']] for i in ids]==load('raw-tool-results.json')

import hashlib
checksums={}
for line in (root/'SHA256SUMS').read_text().splitlines():
 sha,name=line.split(maxsplit=1);assert name not in checksums;checksums[name]=sha
 assert hashlib.sha256((root/name).read_bytes()).hexdigest()==sha,name
assert set(checksums)=={str(f.relative_to(root)) for f in root.rglob('*') if f.is_file() and f.name!='SHA256SUMS'}
assert report['composition_file_sha256']==hashlib.sha256((root/'experimental-skill/SKILL.md').read_bytes()).hexdigest()
assert report['clipboard']['tui_sha256']==load('tui-lifetime.json')['binary_sha256']
for name,sha in report['live_extension']['files'].items():assert hashlib.sha256((root/'extension'/name).read_bytes()).hexdigest()==sha
observations=load('retained-observation-audit.json')['observations'];expected={}
for row in outer:
 if row['tool']=='BrowserRead' and row['success']:
  data=json.loads(row['output'])
  if data.get('schema')=='masc.browser.scene.v1':expected[row['execution_id']]=row['output'].strip().encode()
assert set(expected)=={o['execution_id'] for o in observations}
for obs in observations:
 receipt_refs=[entry['_blob'] for entry in by_id[obs['execution_id']].get('artifact_refs',[])
  if entry.get('_blob',{}).get('mime')=='application/vnd.masc.browser-scene+json']
 assert len(receipt_refs)==1, 'observation must join one retained scene in its original tool receipt'
 assert all(obs['reference'][key]==receipt_refs[0][key] for key in ('sha256','bytes','mime')), 'retained observation reference differs from original tool receipt'
 ref=obs['reference'];raw=(root/'observations'/ref['sha256']).read_bytes();scene=json.loads(raw)
 assert raw==expected[obs['execution_id']] and len(raw)==ref['bytes'] and hashlib.sha256(raw).hexdigest()==ref['sha256']
 assert scene['clientId']==client and scene['source']=='live' and not scene['truncated']
 assert scene['url']==obs['url'] and scene['documentId']==obs['document_id']
follow=load('tui-follow-audit.json');lifetime=load('tui-lifetime.json');raw=(root/'tui-follow.pty').read_bytes()
assert follow['frames']==67 and set(follow['seen'])=={'alpha','beta','gamma'}
for name,seen in follow['seen'].items():
 frame=(root/f'tui-{name}.pty').read_bytes();text=(root/f'tui-{name}.txt').read_text()
 assert raw.startswith(frame) and frame.endswith(b'\x1b[?7h') and len(frame)==seen['offset']
 assert text==seen['text'] and seen['url'] in text and seen['heading'] in text and seen['message'] in ' '.join(text.split())
assert lifetime['alive_at_copy'] and lifetime['alive_after_keeper_observation'] and lifetime['exit']==0 and not lifetime['capture_errors']
assert not [e for e in lifetime['input_events'] if e['monotonic']>report['turn_started_monotonic']]
assert len(outer)==13 and result['outer_errors']==4 and result['outer_result_bytes']==25153
assert len(compositions)==1 and not compositions[0]['success'] and len(compositions[0]['nodes'])==1
assert compositions[0]['nodes'][0]['result']['message']=='invalid_client_id' and compositions[0]['effect_disposition']=='proven_pre_effect'
assert len(wrong_clients)==3 and all(not w['supplied_is_uuid'] for w in wrong_clients)
assert len(follows)==3 and len(observations)==4
for item in report['cleanup']:
 if isinstance(item,dict) and item.get('name') in ('server','driver'):assert item['exit']==0
assert 'owned live Firefox profile closed' in report['cleanup'] and 'owned unique native host manifest removed' in report['cleanup']


identity=load('native-history-d441/identity.json')
assert identity['source_commit']==load('native-history-d441/verified-binaries.json')['source_commit']=='d4414681eb1335de48ccde6f20abb5e74d2e300d'
for name,sha in identity['files'].items(): assert hashlib.sha256((root/'native-history-d441'/name).read_bytes()).hexdigest()==sha
assert (root/'native-history-d441/result.txt').read_text().strip()=='Browser observation history: PASS'

extension_source=load('extension-source.json')
assert extension_source['source_commit']==report['composition_source_commit']==report['live_extension']['source_commit']
for name,sha in extension_source['original_sha256'].items():
 data=(root/'extension'/name).read_bytes()
 if name=='background.js':
  configured=('const HOST_NAME = "'+report['live_extension']['host_name']+'";').encode()
  assert data.count(configured)==1
  data=data.replace(configured,b'const HOST_NAME = "masc_browser_host";')
 assert hashlib.sha256(data).hexdigest()==sha
print('PASS: 13 calls, 4 visible errors, 0 successful compositions, 3 direct follows, 4 exact retained scenes and all 3 live TUI channels')
