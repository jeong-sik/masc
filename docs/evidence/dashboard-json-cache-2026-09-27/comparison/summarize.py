from pathlib import Path
import argparse,gzip,json,math,statistics
p=argparse.ArgumentParser();p.add_argument('root',type=Path);a=p.parse_args();root=a.root
plan=json.loads((root/'plan.json').read_text());rows=[];sessions=[];tasks={};arguments={};identities={};fixture_sha=None

def stats(xs):
 xs=sorted(xs);return {'n':len(xs),'min':xs[0],'median':statistics.median(xs),'p95':xs[math.ceil(.95*len(xs))-1],'max':xs[-1]}

def normalized_tasks(body):
 return sorted([{k:v for k,v in task.items() if k not in ('created_at','updated_at')} for task in body['tasks']],key=lambda t:t['id'])

expected=plan['expected_identities']
assert expected['baseline']['source']!=expected['candidate']['source']
assert expected['baseline']['binary_sha256']!=expected['candidate']['binary_sha256']
assert len(plan['plan'])==24
assert len({e['name'] for e in plan['plan']})==24
for entry in plan['plan']:
 name=entry['name'];kind=entry['text_kind'];encoding=entry['encoding'];role=entry['role'];d=root/name
 identity=json.loads((d/'identity.json').read_text());observations=json.loads((d/'observations.json').read_text());responses=json.loads(gzip.decompress((d/'responses.json.gz').read_bytes()));cleanup=json.loads((d/'cleanup.json').read_text());setup=json.loads((d/'setup.json').read_text())
 assert json.loads((root/(name+'.returncode.json')).read_text())['returncode']==0
 assert cleanup['reaped'] and cleanup['returncode']==0 and all(x=={'method':'GET','path':'/v1/models'} for x in cleanup['model_requests'])
 assert identity['seed_tasks']==250 and identity['cycles']==20 and len(observations)==len(responses)==40
 assert identity['text_kind']==kind and identity['requested_encoding']==encoding and identity['runner_sha256']==plan['session_runner_sha256']
 if fixture_sha is None:fixture_sha=identity['runtime_fixture_sha256']
 assert identity['runtime_fixture_sha256']==fixture_sha
 if role not in identities:identities[role]=(identity['source'],identity['binary_sha256'],identity['artifact_id'],identity['artifact_run'])
 assert (identity['source'],identity['binary_sha256'],identity['artifact_id'],identity['artifact_run'])==identities[role]
 assert identities[role]==tuple(expected[role][k] for k in ('source','binary_sha256','artifact_id','artifact_run'))
 args=[(r['tool'],r['arguments_sha256']) for r in setup]
 if kind not in arguments:arguments[kind]=args
 assert args==arguments[kind],name
 common={'text_kind':kind,'requested_encoding':encoding,'role':role,'repetition':entry['repetition'],'session':name}
 for i,(obs,response) in enumerate(zip(observations,responses)):
  cycle=i//2+1;phase=('cold','warm')[i%2];body=response['body']
  assert (obs['cycle'],obs['phase'])==(response['cycle'],response['phase'])==(cycle,phase)
  assert obs['status']==200 and obs['task_count']==250+cycle==len(body['tasks']) and body['execution_invalidated'] is False
  assert body['query']['actor'] is None and body['query']['default_light_request'] is True
  assert obs['query']==body['query'] and obs['cache']==body['cache'] and obs['generation']==body['execution_publication_generation']
  assert obs['server_timing']==response['headers']['server-timing']
  timings={}
  for metric in obs['server_timing'].split(','):
   label,duration=metric.strip().split(';');assert duration.startswith('dur=');timings[label]=float(duration[4:])
  assert ('cache_compute' in timings)==(phase=='cold')
  if i%2:assert body==responses[i-1]['body'] and obs['body_sha256']==observations[i-1]['body_sha256']
  elif i:assert obs['generation']>observations[i-2]['generation']
  normalized=normalized_tasks(body);key=(kind,cycle)
  if key not in tasks:tasks[key]=normalized
  assert normalized==tasks[key],(name,cycle)
  assert (obs['encoding'] or 'identity')==encoding,(name,cycle,obs['encoding'])
  rows.append({**obs,**common,'server_compute_ms':timings.get('cache_compute')})
 mutations=[r for r in setup if r['tool']=='masc_add_task'];assert len(mutations)==20
 assert sum(r['tool']=='masc_batch_add_tasks' for r in setup)==13
 for cycle,mutation in enumerate(mutations,1):
  result=mutation['result'];http=mutation['http_observation']
  assert http['status']==200 and http['rpc_method']=='tools/call' and not result.get('isError',False)
  assert result['structuredContent']['ok'] is True and result['structuredContent']['task_id']==f'task-{250+cycle:03d}'
  rows.append({**http,**common,'phase':'mutation','cycle':cycle})
 session_rows=[r for r in rows if r['session']==name]
 sessions.append({'name':name,**common,'timings':{phase:stats([r['wire_ms'] for r in session_rows if r['phase']==phase]) for phase in ('mutation','cold','warm')}})

groups={}
for kind in ('ascii','multilingual'):
 for encoding in ('identity','gzip'):
  for role in ('baseline','candidate'):
   for phase in ('mutation','cold','warm'):
    selected=[r for r in rows if (r['text_kind'],r['requested_encoding'],r['role'],r['phase'])==(kind,encoding,role,phase)]
    assert len(selected)==plan['expected_samples_per_kind_encoding_role_phase']==60
    key=f'{kind}-{encoding}-{role}-{phase}'
    group={metric:stats([r[metric] for r in selected]) for metric in ('wire_ms','headers_ms','body_read_ms','wire_bytes','json_bytes')}
    group['observed_content_encoding']=sorted({r['encoding'] or 'identity' for r in selected})
    if phase=='cold':group['server_compute_ms']=stats([r['server_compute_ms'] for r in selected])
    groups[key]=group
assert len(rows)==1440
summary={'groups':groups,'sessions':sessions,'identities':identities,'checks':{'sessions':24,'GET_observations':960,'mutation_observations':480,'p95_definition':'nearest rank sorted[ceil(.95*n)-1]','same_inputs_within_text_kind':True,'same_task_fields_except_created_updated_at_within_text_kind':True,'first_warm_parsed_body_equal':True,'first_route_miss_warm_cache_hit':True,'all_owned_servers_reaped_exit_zero':True,'scope':'fresh TCP per request; measured before connection request through full response body read; JSON parsing/decompression excluded. No pooling across text kind, requested encoding or phase.'}}
(root/'summary.json').write_text(json.dumps(summary,indent=2)+'\n')
for key,value in groups.items():print(key,json.dumps(value['wire_ms']))
