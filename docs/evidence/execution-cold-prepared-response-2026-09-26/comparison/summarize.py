from pathlib import Path
import argparse, gzip, hashlib, json, math, statistics
p=argparse.ArgumentParser();p.add_argument('root',type=Path);a=p.parse_args();root=a.root
plan=json.loads((root/'plan.json').read_text());rows=[];sessions=[];tasks_by_cycle={};args_hashes=None;encodings={};checks=[]
def stats(xs):
 xs=sorted(xs);return {'n':len(xs),'min':xs[0],'median':statistics.median(xs),'p95':xs[math.ceil(.95*len(xs))-1],'max':xs[-1]}
for entry in plan['plan']:
 d=root/entry['name'];identity=json.loads((d/'identity.json').read_text());obs=json.loads((d/'observations.json').read_text());responses=json.loads(gzip.decompress((d/'responses.json.gz').read_bytes()));cleanup=json.loads((d/'cleanup.json').read_text());setup=json.loads((d/'setup.json').read_text())
 assert json.loads((root/(entry['name']+'.returncode.json')).read_text())['returncode']==0
 assert cleanup['reaped'] and cleanup['returncode']==0 and all(x=={'method':'GET','path':'/v1/models'} for x in cleanup['model_requests'])
 assert len(obs)==len(responses)==identity['cycles']*2
 assert identity['runner_sha256']==plan['session_runner_sha256'] and identity['requested_encoding']==entry['encoding']
 hs=[(x['tool'],x['arguments_sha256']) for x in setup]
 if args_hashes is None:args_hashes=hs
 assert hs==args_hashes
 for i,(o,r) in enumerate(zip(obs,responses)):
  assert (o['phase'],o['cycle'])==(r['phase'],r['cycle'])==(('cold','warm')[i%2],i//2+1)
  body=r['body'];assert o['status']==200 and len(body['tasks'])==identity['seed_tasks']+o['cycle'] and body['execution_invalidated'] is False
  assert body['query']['actor'] is None and body['query']['default_light_request'] is True
  assert o['generation']==body['execution_publication_generation']
  assert r['headers']['server-timing']==o['server_timing']
  timings={}
  for t in o['server_timing'].split(','):
   label,metric=t.strip().split(';');assert metric.startswith('dur=');timings[label]=float(metric[4:])
  assert ('cache_compute' in timings)==(o['phase']=='cold')
  if i%2:assert o['body_sha256']==obs[i-1]['body_sha256'] and body==responses[i-1]['body']
  elif i:assert o['generation']>obs[i-2]['generation']
  # All task fields must agree across arms, except these explicit creation timestamps.
  normalized=sorted([{k:v for k,v in task.items() if k not in ('created_at','updated_at')} for task in body['tasks']],key=lambda t:t['id'])
  if o['cycle'] not in tasks_by_cycle:tasks_by_cycle[o['cycle']]=normalized
  assert normalized==tasks_by_cycle[o['cycle']],(entry['name'],o['cycle'])
  row={**o,'role':entry['role'],'requested_encoding':entry['encoding'],'repetition':entry['repetition'],'session':entry['name'],'server_compute_ms':timings.get('cache_compute')};rows.append(row)
  key=entry['encoding']+'-'+entry['role']+'-'+o['phase'];encodings.setdefault(key,set()).add(o['encoding'] or 'identity')
 sessions.append({'name':entry['name'],'source':identity['source'],'binary_sha256':identity['binary_sha256'],'cold_wire_ms':stats([o['wire_ms'] for o in obs if o['phase']=='cold']),'warm_wire_ms':stats([o['wire_ms'] for o in obs if o['phase']=='warm'])})
summary={}
for encoding in ('identity','gzip'):
 for role in ('baseline','candidate'):
  for phase in ('cold','warm'):
   selected=[r for r in rows if r['requested_encoding']==encoding and r['role']==role and r['phase']==phase]
   key=f'{encoding}-{role}-{phase}'
   summary[key]={**{metric:stats([r[metric] for r in selected]) for metric in ('wire_ms','headers_ms','body_read_ms','wire_bytes','json_bytes')},'observed_content_encoding':sorted(encodings[key])}
   if phase=='cold':summary[key]['server_compute_ms']=stats([r['server_compute_ms'] for r in selected])
   assert len(selected)==plan['expected_samples_per_encoding_role']
(root/'summary.json').write_text(json.dumps({'groups':summary,'sessions':sessions,'checks':{'complete_planned_sessions':len(sessions),'all_raw_observations':len(rows),'same_tool_argument_hashes':True,'same_task_projection_except_created_updated_at':True,'cold_warm_body_identical':True,'cold_cache_compute_present_warm_absent':True,'all_children_reaped_exit_zero':True,'p95_definition':'nearest rank: sorted[ceil(0.95*n)-1]','tcp_connection':'fresh per GET; timing includes TCP connect, request, headers and full body read; JSON parse and gzip decompression excluded'}},indent=2)+'\n')
for key,g in summary.items():print(key, json.dumps({'wire_ms':g['wire_ms'],'bytes':g['wire_bytes'],'encoding':g['observed_content_encoding'],'compute_ms':g.get('server_compute_ms')}))
print('session cold medians:',[(s['name'],s['cold_wire_ms']['median']) for s in sessions])
