from pathlib import Path
import json,copy,hashlib,urllib.request,concurrent.futures,datetime
root=Path('/tmp/masc-goal-carrier-pair-20261024');root.mkdir(mode=0o700,exist_ok=False)
original=Path('/tmp/masc-goal-wire-1eef45b6/request-000004.request').read_bytes();assert hashlib.sha256(original).hexdigest()=='feaece7293008a8c863dbb0a9e2b53a0b84ece128db9815bda42be6a11ecfedd'
request=json.loads(original);assert request['messages'][-1]['role']=='user' and '[system context]' in request['messages'][-1]['content']
with urllib.request.urlopen('http://127.0.0.1:11434/api/tags') as response:tags=json.load(response)
model,=[m for m in tags['models'] if m['name']==request['model']];assert model['digest']=='7fbdbf8f5e45a75bb122155ed546e765b4d9c53a1285f62fd9f506baa1c5a47e'
(root/'model.json').write_text(json.dumps({'name':model['name'],'digest':model['digest'],'size':model['size']},indent=2)+'\n')
def run(arm):
 data=copy.deepcopy(request);data.setdefault('options',{})['seed']=20261024
 if arm!='tail_user':
  carrier=data['messages'].pop()
  if arm=='system_suffix':
   assert data['messages'][0]['role']=='system';data['messages'][0]['content']+='\n\n'+carrier['content']
  elif arm=='leading_user':
   first=next(i for i,m in enumerate(data['messages']) if m['role']=='user');data['messages'].insert(first,carrier)
  else:raise ValueError(arm)
 raw=json.dumps(data,separators=(',',':')).encode();(root/(arm+'.request')).write_bytes(raw)
 req=urllib.request.Request('http://127.0.0.1:11434/api/chat',data=raw,headers={'Content-Type':'application/json'})
 tools=[];end=None
 with urllib.request.urlopen(req,timeout=1200) as response,(root/(arm+'.response')).open('wb') as capture:
  for line in response:
   capture.write(line);event=json.loads(line);tools += (event.get('message') or {}).get('tool_calls') or []
   if event.get('done'):end={k:event.get(k) for k in ['done','done_reason','prompt_eval_count','eval_count','total_duration']}
 scores=[]
 for t in tools:
  f=t['function'];a=f['arguments'];a=json.loads(a) if isinstance(a,str) else a
  scores.append({'tool':f['name'],'arguments':a,'required_description_present':isinstance(a.get('description'),str) and len(a['description'])>=10,'matching_goal':a.get('goal_id')=='goal-canary-three-results'})
 result={'arm':arm,'observed_at':datetime.datetime.now(datetime.timezone.utc).isoformat(),'request_sha256':hashlib.sha256(raw).hexdigest(),'response_sha256':hashlib.sha256((root/(arm+'.response')).read_bytes()).hexdigest(),'tools':scores,'termination':end,'returned_tools_executed':False}
 (root/(arm+'.result.json')).write_text(json.dumps(result,indent=2,ensure_ascii=False)+'\n');return result
with concurrent.futures.ThreadPoolExecutor(max_workers=3) as executor:
 for result in executor.map(run,['tail_user','system_suffix','leading_user']):print(json.dumps(result,ensure_ascii=False),flush=True)
