"""Offline recheck of retained IDs, raw UTF-8 results and native PTY provenance."""
from pathlib import Path
import hashlib,json
p=Path(__file__).resolve().parent
load=lambda name:json.loads((p/name).read_text())
a=load('composition-audit.json');turn=load('turn-execution-ids.json')
rows={r['execution_id']:r for r in load('execution-receipts.json')}
raw={r['tool_use_id']:r for r in load('raw-tool-results.json')}
assert len(turn['execution_ids'])==len(set(turn['execution_ids']))==6
outputs=[]
for recorded in a['outer_calls']:
 r=rows[recorded['execution_id']];assert r['execution_id'] in turn['execution_ids']
 event=raw[r['tool_use_id']]
 assert event['tool_name']==r['tool'] and event['tool_error']==(not r['success'])
 assert event['tool_result']==recorded['output']
 outputs.append(event['tool_result'])
 if r.get('result_bytes') is not None: assert r['result_bytes']==len(event['tool_result'].encode())
 if r['tool'].startswith('keeper_compose_'):
  actions=json.loads(event['tool_result'])['actions'];assert len(actions)==2
  for node in actions:
   receipt=rows[node['execution_id']]
   assert receipt['tool_use_id']==node['tool_use_id'] and receipt['input']==node['input']
   assert receipt['success'] and node['result']['disposition']=='completed'
  assert actions[1]['input']['expectedUrl']==actions[0]['result']['data']['url']
skill=(p/'browser-lanes.SKILL.md').read_bytes()
assert len(skill)==13391 and hashlib.sha256(skill).hexdigest()=='6e3ea26f00a79eee164488476ecd4bcdb3e348fcd903a3bfe191e747e66576df'
# The native parser excludes the frontmatter closing-line newline, preserves body whitespace.
delivered=skill.split(b'---',2)[2][1:]
assert len(delivered)==13159 and hashlib.sha256(delivered).hexdigest()=='1a085c9cdf6752cf4193541ad2bbff3a9dd7ca06ef8c0a1c7a968238ef076b1c'
assert outputs[0].encode()==delivered
assert sum(len(s.encode()) for s in outputs)==a['outer_result_bytes']==36199
assert a['outer_errors']==0 and a['composition_invocations']==3
lifetime=load('tui-lifetime.json');report=load('report.json');tui=load('tui-follow-audit.json')
assert lifetime['binary_sha256']==a['tui_sha256']
assert not [e for e in lifetime['input_events'] if e['monotonic']>report['turn_started_monotonic']]
assert lifetime['alive_at_copy'] and lifetime['alive_after_keeper_observation']
assert tui['all_three_channels_followed'] and tui['frames']==49
for line in (p/'SHA256SUMS').read_text().splitlines():
 digest,name=line.split(None,1);assert hashlib.sha256((p/name).read_bytes()).hexdigest()==digest,name
print('PASS: 6 outer calls, 0 errors, 3 compositions, 36199 raw bytes; 49 retained replay frames. Re-render with replay-tui.py separately.')
