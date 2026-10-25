import json,datetime,hashlib
from pathlib import Path
from collections import Counter
BASE=Path('/tmp/masc-goal-canary-2be9d216-qwen')
WIRE=Path('/tmp/masc-goal-wire-2be9d216-qwen')
OUT=Path('/tmp/masc-goal-2be9-qwen-recovery')
OP='kmsg-87931f3ea479204a01030b4ca169bf1c'
GID='goal-canary-three-results'
REV='323f43fbb45eda9a26d334f519d40239'
def now():return datetime.datetime.now(datetime.timezone.utc).isoformat()
def digest(x):return hashlib.sha256(x).hexdigest()
start=now();files=[];state={};errors=[]
REJECTED='vrf-5dd15968c9ec601c495335d00cc7b471'
REASON=json.loads((BASE/'operator-observations/first-rejection-corrected-intent.json').read_text())['reason']
for rel in ['identity.json','.masc/tasks/backlog.json','.masc/goals.json','.masc/goal_measurements.json','.masc/keepers/goal-canary.json','.masc/keepers/goal-canary/event-queue-v19.json']:
 p=BASE/rel
 if not p.exists():files.append({'path':str(p),'exists':False});continue
 raw=p.read_bytes();files.append({'path':str(p),'exists':True,'bytes':len(raw),'sha256':digest(raw)})
 try:state[rel]=json.loads(raw)
 except (ValueError,UnicodeError)as e:errors.append({'path':str(p),'error':str(e),'sha256':digest(raw)})
links=[]
for rel in ['.masc/tasks/goal_task_links.json','.masc/tasks/goal_task_links.json.last-good']:
 p=BASE/rel;x={'path':str(p),'exists':p.exists()}
 if p.exists():
  raw=p.read_bytes();x.update(bytes=len(raw),sha256=digest(raw))
  try:x['value']=json.loads(raw)
  except(ValueError,UnicodeError)as e:x['read_error']=str(e)
 links.append(x)
rows=[];pending=[];non_model=[]
for q in sorted(WIRE.glob('*.request')):
 raw=q.read_bytes();r=q.with_suffix('.response')
 if not raw:non_model.append({'request':q.name,'request_bytes':0});continue
 try:req=json.loads(raw)
 except(ValueError,UnicodeError)as e:errors.append({'path':str(q),'error':str(e),'sha256':digest(raw)});continue
 respraw=r.read_bytes()if r.exists()else b'';events=[];bad=[]
 for idx,line in enumerate(respraw.splitlines()):
  if not line.strip():continue
  try:events.append(json.loads(line))
  except(ValueError,UnicodeError):bad.append({'line':idx+1,'bytes':len(line),'sha256':digest(line)})
 msg=req.get('messages',[]);system='\n'.join(m.get('content','')for m in msg if m.get('role')=='system'and isinstance(m.get('content'),str));calls=[t for e in events for t in(e.get('message')or{}).get('tool_calls',[])];public=''.join((e.get('message')or{}).get('content','')for e in events);done=bool(events and events[-1].get('done'));feedback=[m for m in msg if m.get('role')=='tool'];lastfeedback=feedback[-1]if feedback else None
 row={'request_id':q.stem,'request_sha256':digest(raw),'request_bytes':len(raw),'response_sha256':digest(respraw),'response_bytes':len(respraw),'response_complete':done,'partial_response_lines':bad,'model_alias':req.get('model'),'options':req.get('options'),'goal_in_system':GID in system,'revision_in_system':REV in system,'new_reporting_instruction_in_system':'measurement_status="reported_only"'in system and 'completion_effect="unchanged"'in system,'offered_tools':[t.get('function',{}).get('name')for t in req.get('tools',[])],'tool_calls':calls,'last_tool_feedback':lastfeedback,'public_response':public,'response_terminal':[{'created_at':e.get('created_at'),'done_reason':e.get('done_reason'),'eval_count':e.get('eval_count'),'prompt_eval_count':e.get('prompt_eval_count')}for e in events if e.get('done')],'provider_errors':[e['error']for e in events if 'error'in e],'raw_thinking_codepoints_count_only':sum(len((e.get('message')or{}).get('thinking',''))for e in events)}
 row['rejection_authority_in_system']={'task_id_present':'task-001' in system,'rejected_verification_id_present':REJECTED in system,'exact_reason_present':REASON in system,'system_sha256':digest(system.encode())}
 rows.append(row)
 if not done:pending.append(q.stem)
artifact_path=BASE/'.masc/playground/docker/goal-canary/workspace/acceptance.json';artifact=None
if artifact_path.exists():
 a=artifact_path.read_bytes();artifact={'path':str(artifact_path),'bytes':len(a),'sha256':digest(a),'content':a.decode('utf-8'),'value':json.loads(a)}
verifications=[]
for task in state.get('.masc/tasks/backlog.json',{}).get('tasks',[]):
 vid=task.get('verification_id')
 if not vid:continue
 p=BASE/'.masc/verifications'/f'{vid}.json'
 if not p.exists():verifications.append({'verification_id':vid,'exists':False});continue
 raw=p.read_bytes();v=json.loads(raw);evidence=[e for e in v.get('output',{}).get('submitted_evidence',[])if e.get('kind')=='artifact'];verifications.append({'path':str(p),'exists':True,'bytes':len(raw),'sha256':digest(raw),'value':v,'artifact_checks':[{'reference':e.get('reference'),'declared_bytes':e.get('bytes'),'content_bytes':len(e.get('content','').encode()),'content_sha256':digest(e.get('content','').encode()),'truncated':e.get('truncated'),'equal_current_artifact':artifact is not None and e.get('content','').encode()==artifact['content'].encode()}for e in evidence]})
eventpath=BASE/'.masc/keeper_chat_events/goal-canary'/f'{OP}.jsonl';counts=Counter();terminal=[];eventbad=[];eventhash=None
if eventpath.exists():
 eventraw=eventpath.read_bytes();eventhash=digest(eventraw)
 for idx,line in enumerate(eventraw.splitlines()):
  try:e=json.loads(line)
  except(ValueError,UnicodeError):eventbad.append({'line':idx+1,'bytes':len(line),'sha256':digest(line)});continue
  event=e.get('event',{});kind=event.get('type');counts[kind]+=1
  if kind in ['reply_details','text_message_end','run_finished','run_failed','error','run_error']:
   keep={k:v for k,v in event.items()if k in ['type','reply','turn_outcome','turn_ref','terminal_stream_scope','run_id','error','message','code']};terminal.append({'v':e.get('v'),'seq':e.get('seq'),'ts':e.get('ts'),'event':keep})
operation_done=any(e['event'].get('type')=='run_finished'and e['event'].get('run_id')=='keeper-operation-run-'+OP for e in terminal)
report={'scope':'Read-only filesystem observation; no API, model call, Keeper message, approval, link, measurement, source/runtime mutation. Writes only external private evidence. No raw thinking copied. Independent runtime observation is not source approval or Official path proof. Sequential file reads, no atomic snapshot claim.','observed_at':now(),'read_window_started_at':start,'goal_id':GID,'criterion_revision':REV,'state':state,'files':files,'goal_link_files':links,'wire':rows,'excluded_empty_request_bodies':non_model,'pending_wire':pending,'artifact':artifact,'verifications':verifications,'owner_operation':{'id':OP,'source':str(eventpath),'source_sha256':eventhash,'event_type_counts':dict(counts),'partial_event_lines':eventbad,'selected_public_terminal_events':terminal,'run_finished':operation_done},'read_errors':errors}
history=[]
for hp in sorted((BASE/'.masc/verifications').glob('vrf-*.json')):
 hraw=hp.read_bytes();history.append({'path':str(hp),'bytes':len(hraw),'sha256':digest(hraw),'value':json.loads(hraw)})
report['verification_history']=history
queue=state.get('.masc/keepers/goal-canary/event-queue-v19.json',{});transition=(queue.get('last_transition')or{}).get('transition',{});source=transition.get('source',{});expected='completion-authority-rejected:task-001:'+REJECTED
recovery_done=transition.get('kind')=='ack_source_terminal'and source.get('post_id')==expected
report['stage']='Controlled rejection recovery only; first owner failure remains frozen separately.'
report['initial_owner_operation']=report.pop('owner_operation')
report['recovery_source']={'expected_post_id':expected,'exact_reason':REASON,'source_terminal_ack':recovery_done,'receipt_kind':transition.get('source_receipt_kind'),'pending':queue.get('pending'),'last_transition':queue.get('last_transition')}
(OUT/'snapshots').mkdir(exist_ok=True);stamp=datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%S%fZ');dest=OUT/'snapshots'/(stamp+'.json');dest.write_text(json.dumps(report,ensure_ascii=False,indent=2)+'\n')
print(json.dumps({'snapshot':str(dest),'sha256':digest(dest.read_bytes()),'observed_at':report['observed_at'],'requests':len(rows),'last_request':rows[-1]['request_id']if rows else None,'last_tools':rows[-1]['tool_calls']if rows else [],'pending_wire':pending,'task_states':[{'id':x.get('id'),'status':x.get('status'),'verification_id':x.get('verification_id')}for x in state.get('.masc/tasks/backlog.json',{}).get('tasks',[])],'links':links,'artifact':{'bytes':artifact['bytes'],'sha256':artifact['sha256'],'value':artifact['value']}if artifact else None,'recovery_source_terminal_ack':recovery_done,'keeper_total_turns':state.get('.masc/keepers/goal-canary.json',{}).get('total_turns'),'verification_artifact_checks':[x['artifact_checks']for x in verifications if'artifact_checks'in x],'rejection_system_presence':[{'request':r['request_id'],**r['rejection_authority_in_system']}for r in rows if int(r['request_id'].split('-')[-1])>=10],'read_errors':errors},ensure_ascii=False,indent=2))
