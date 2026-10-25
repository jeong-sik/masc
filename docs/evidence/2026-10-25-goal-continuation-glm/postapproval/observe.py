import json,hashlib,datetime,sqlite3
from pathlib import Path
BASE=Path('/tmp/masc-goal-canary-32805eb7-glm53')
WIRE=Path('/tmp/masc-goal-wire-32805eb7-glm53')
OUT=Path('/tmp/masc-goal-3280-glm-postapproval')
def sha(data):return hashlib.sha256(data).hexdigest()
def read(relative):
 p=BASE/relative;raw=p.read_bytes();return json.loads(raw),{'path':str(p),'bytes':len(raw),'sha256':sha(raw)}
def sse(path):
 raw=path.read_bytes();calls={};public=[];models=set();finish=[];invalid=0
 for line in raw.splitlines():
  if not line.startswith(b'data:'):continue
  body=line[5:].strip()
  if body==b'[DONE]':continue
  try:event=json.loads(body)
  except (ValueError,UnicodeError):invalid+=1;continue
  if event.get('model'):models.add(event['model'])
  for choice in event.get('choices',[]):
   delta=choice.get('delta') or {}
   if delta.get('content'):public.append(delta['content'])
   for part in delta.get('tool_calls') or []:
    index=(choice.get('index',0),part.get('index',0))
    target=calls.setdefault(index,{'choice_index':index[0],'tool_index':index[1],'id':'','name':'','arguments_text':''})
    target['id']+=part.get('id') or ''
    function=part.get('function') or {};target['name']+=function.get('name') or '';target['arguments_text']+=function.get('arguments') or ''
   if choice.get('finish_reason') is not None:finish.append(choice['finish_reason'])
 for item in calls.values():
  raw_args=item.pop('arguments_text')
  try:item['arguments']=json.loads(raw_args)
  except ValueError:item['unparsed_arguments_text']=raw_args
 return {'path':str(path),'sha256':sha(raw),'bytes':len(raw),'reported_models':sorted(models),'tool_calls':list(calls.values()),'public_text':''.join(public),'finish_reasons':finish,'malformed_sse_data_lines':invalid}
def observe():
 start=datetime.datetime.now(datetime.timezone.utc).isoformat();files=[]
 state={}
 for name in ['identity.json','.masc/tasks/backlog.json','.masc/tasks/goal_task_links.json','.masc/goals.json','.masc/goal_measurements.json']:
  try:value,meta=read(name);state[name]=value;files.append(meta)
  except FileNotFoundError:state[name]=None
 keeper,meta=read('.masc/keepers/goal-canary.json');files.append(meta)
 safe_keeper={key:keeper.get(key) for key in ['name','trace_id','total_turns','last_turn_ts','current_task_id','paused','latched_reason']}
 db=sqlite3.connect('file:'+str(BASE/'.masc/keepers/goal-canary/chat-operations.sqlite3')+'?mode=ro',uri=True)
 db.row_factory=sqlite3.Row
 operations=[dict(row) for row in db.execute('select operation_id,state,created_at,started_at,completed_at,outcome_ref,failure_kind from operations order by sequence')]
 semantic=[]
 for row in db.execute('select scope_key,revision,phase,record_json from semantic_executions'):
  value=json.loads(row['record_json']);phase=value.get('phase') or {};origin=phase.get('origin') or {}
  semantic.append({'scope_key':json.loads(row['scope_key']),'revision':row['revision'],'phase':row['phase'],'phase_detail':phase.get('detail'),'origin_kind':origin.get('kind'),'updated_at':value.get('updated_at'),'gate_obligations':[{key:item.get(key) for key in ['approval_id','input_hash','tool_name']} for item in value.get('gate_obligations',[])]})
 db.close()
 artifact_path=BASE/'.masc/playground/docker/goal-canary/workspace/acceptance.json'
 raw=artifact_path.read_bytes();artifact={'path':str(artifact_path),'bytes':len(raw),'sha256':sha(raw),'value':json.loads(raw)}
 verifications=[]
 for task in (state.get('.masc/tasks/backlog.json') or {}).get('tasks',[]):
  if not task.get('verification_id'):continue
  path=BASE/'.masc/verifications'/(task['verification_id']+'.json')
  if path.exists():
   raw=path.read_bytes();record=json.loads(raw);verifications.append({'path':str(path),'bytes':len(raw),'sha256':sha(raw),'record':record})
 records=[]
 for receipt_path in sorted(WIRE.glob('*.receipt.json')):
  receipt=json.loads(receipt_path.read_bytes());request_path=receipt_path.with_name(receipt_path.name.replace('.receipt.json','.request'));response_path=request_path.with_suffix('.response')
  raw=request_path.read_bytes()
  if not raw:continue
  request=json.loads(raw);messages=request.get('messages',[])
  if not messages:continue
  response=sse(response_path)
  assert sha(raw)==receipt['request_sha256'] and response['sha256']==receipt['response_sha256']
  system=messages[0].get('content','') if messages[0].get('role')=='system' else ''
  goals=state.get('.masc/goals.json') or {};goal=(goals.get('goals') or [{}])[0]
  records.append({'request_path':str(request_path),'request_sha256':sha(raw),'request_bytes':len(raw),'receipt_path':str(receipt_path),'receipt_sha256':sha(receipt_path.read_bytes()),'status':receipt['status'],'system_sha256':sha(system.encode()),'goal_id_present_in_system':goal.get('id','missing') in system,'criterion_revision_present_in_system':goal.get('criterion_revision','missing') in system,'offered_tools':[t.get('function',{}).get('name') for t in request.get('tools',[])],'actual_tool_feedback':[{'index':i,'role':m['role'],'tool_call_id':m.get('tool_call_id'),'name':m.get('name') or m.get('tool_name'),'content':m.get('content')} for i,m in enumerate(messages) if m.get('role')=='tool'][-3:],'response':response})
 sealed={Path(r['request_path']).name for r in records};pending=[p.name for p in WIRE.glob('*.request') if p.stat().st_size and p.name not in sealed]
 now=datetime.datetime.now(datetime.timezone.utc)
 result={'scope':'Read-only local authoritative state, operation SQL opened mode=ro, sealed actual HTTP/SSE public Tool calls/content only; no thought fields selected or published. No verdict/link/message/measurement/file edit in canary.','read_started_utc':start,'observed_at_utc':now.isoformat(),'state':state,'files':files,'keeper':safe_keeper,'operations':operations,'semantic_execution':semantic,'artifact':artifact,'verifications':verifications,'wire':records,'pending_request_bodies':sorted(pending)}
 path=OUT/(now.strftime('%Y%m%dT%H%M%S%fZ')+'.json');path.write_text(json.dumps(result,indent=2,ensure_ascii=False)+'\n')
 print(json.dumps({'snapshot':str(path),'keeper':safe_keeper,'operations':operations,'semantic_execution':semantic,'tasks':(state.get('.masc/tasks/backlog.json') or {}).get('tasks',[]),'goal_links':state.get('.masc/tasks/goal_task_links.json'),'goal_measurements':state.get('.masc/goal_measurements.json'),'artifact':artifact,'sealed_model_requests':len(records),'last_request':records[-1] if records else None,'pending_requests':pending},ensure_ascii=False))
if __name__=='__main__':observe()
