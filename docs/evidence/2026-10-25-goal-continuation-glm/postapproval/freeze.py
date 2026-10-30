from pathlib import Path
import json,hashlib,datetime
BASE=Path('/tmp/masc-goal-canary-32805eb7-glm53');WIRE=Path('/tmp/masc-goal-wire-32805eb7-glm53');OUT=Path('/tmp/masc-goal-3280-glm-postapproval')
S=json.loads((OUT/'20261024T182033823891Z.json').read_bytes());rows={int(Path(r['request_path']).stem.split('-')[-1]):r for r in S['wire']}
def sha(raw):return hashlib.sha256(raw).hexdigest()
def utc(ts):return datetime.datetime.fromtimestamp(ts,datetime.timezone.utc).isoformat()
def req(i):return json.loads((WIRE/f'request-{i:06}.request').read_bytes())
def call(i,name):return next(c for c in rows[i]['response']['tool_calls'] if c['name']==name)
def result(next_i,tool_id):
 m=next(m for m in req(next_i)['messages'] if m.get('role')=='tool' and m.get('tool_call_id')==tool_id)
 value=m['content']
 try:return json.loads(value)
 except ValueError:return {'public_content':value}
steps=[]
for i,name in [(29,'Read'),(30,'masc_goal_measure'),(31,'Edit'),(32,'Read'),(33,'masc_goal_measure'),(33,'keeper_task_done'),(35,'masc_goal_transition')]:
 c=call(i,name);steps.append({'response_sequence':i,'request_sha256':rows[i]['request_sha256'],'response_sha256':rows[i]['response']['sha256'],'call':c,'actual_receipt_in_next_request':result(i+1,c['id'])})
one=steps[1]['actual_receipt_in_next_request'];three=steps[4]['actual_receipt_in_next_request']
assert one['measurement']['id']=='c43ffbe4723f28980bb1e9972babd7e6' and three['measurement']['id']=='ff7a4f86482a94260ba642d65c5ae6b2'
assert one['measurement_status']==three['measurement_status']=='reported_only'
assert one['completion_effect']==three['completion_effect']=='unchanged'
assert one['goal_at_recording']['phase']==three['goal_at_recording']['phase']=='executing'
assert steps[2]['call']['arguments']['old_string']=='  "beta": false,\n  "gamma": false'
assert steps[5]['actual_receipt_in_next_request']['evidence_capture']['diagnostics']==[]
assert steps[6]['actual_receipt_in_next_request']['goal']['phase']=='verifying'
q_path=BASE/'.masc/keepers/goal-canary/event-queue-v19.json';q_raw=q_path.read_bytes();q=json.loads(q_raw);last=q['last_transition'];t=last['transition'];source=t['source'];payload=source['payload']
assert t['kind']=='ack_source_terminal' and source['post_id']=='task-outcome:task-001' and payload['verification_id']=='vrf-9990ff88de3eb7953ce427f8e3a0ad07' and t['source_receipt_kind']=='turn_completed'
queue={'path':str(q_path),'sha256':sha(q_raw),'revision':q['revision'],'pending_count':len(q['pending']),'ack_applied_at_unix':last['applied_at_unix'],'ack_applied_at_utc':utc(last['applied_at_unix']),'source_post_id':source['post_id'],'verification_id':payload['verification_id'],'source_incarnation':t['source_incarnation'],'receipt_kind':t['source_receipt_kind']}
task1=next(t for t in S['state']['.masc/tasks/backlog.json']['tasks'] if t['id']=='task-001');task2=next(t for t in S['state']['.masc/tasks/backlog.json']['tasks'] if t['id']=='task-002')
assert task1['status']=='done' and task2['status']=='awaiting_verification'
current=(BASE/'.masc/playground/docker/goal-canary/workspace/acceptance.json').read_bytes();v=S['verifications'][0]['record']
assert v['id']==task2['verification_id'];a=next(x for x in v['output']['submitted_evidence'] if x['kind']=='artifact');immutable=a['content'].encode()
assert current==immutable and len(current)==53 and json.loads(current)=={'alpha':True,'beta':True,'gamma':True}
(OUT/'artifact-current-final.json').write_bytes(current);(OUT/'artifact-task2-immutable.json').write_bytes(immutable)
(OUT/'actual-tool-sequence-and-receipts.json').write_text(json.dumps(steps,indent=2,ensure_ascii=False)+'\n')
operation=S['operations'][0];completed=datetime.datetime.fromtimestamp(operation['completed_at'],datetime.timezone.utc);approved=datetime.datetime.fromisoformat(task1['completed_at'].replace('Z','+00:00'))
assert operation['state']=='succeeded' and S['semantic_execution'][0]['phase']=='settled' and completed<approved
amend_path=BASE/'operator-observations/task-approval-timing-amendment.json';amend_raw=amend_path.read_bytes();amend=json.loads(amend_raw)
proof_path=BASE/'.masc/goal_verifications.json';proof_raw=proof_path.read_bytes();proof=json.loads(proof_raw)
goals_raw=(BASE/'.masc/goals.json').read_bytes();goals=json.loads(goals_raw);goal=next(g for g in goals['goals'] if g['id']=='goal-canary-three-results');assert goal['phase']=='verifying'
carriers=[]
for i,r in rows.items():
 system=req(i)['messages'][0]['content']
 if '### Approved Task Outcomes' in system and task1['notes'] is not None and 'vrf-9990ff88de3eb7953ce427f8e3a0ad07' in system:
  carriers.append({'request_sequence':i,'request_sha256':r['request_sha256'],'system_sha256':sha(system.encode())})
assert all(i in [r['request_sequence'] for r in carriers] for i in range(29,37))
report={'schema':'masc.independent-goal-canary-observation.v1','verdict':'G3_SCOPED_PASS','candidate_source':'32805eb764eab2710262446e925b0ea5c3a44c08','observed_at_utc':datetime.datetime.now(datetime.timezone.utc).isoformat(),'scope':'One actual configured single GLM-5.3 ordinary HTTP Keeper cohort. Controlled isolated canary fixtures: one Gate sleep20 approve and one Task001 operator-proxy verdict. No operator Goal link/nudge/file edit or human Goal confirmation. No causal comparison with Qwen, generic reliability, installed/deployed runtime or Official vendor success claim.','judgment_method':'Manual public report comparison to actual raw public Tool args/feedback, immutable/current artifacts and persisted Task/Goal/source-queue state; no string success gate.','criteria':{'after_approval_reread_partial_goal':'PASS: response29 Read -> request30 actual alpha-only Read feedback','after_approval_record1of3':'PASS: response30 measure -> request31 c43ffbe receipt before response31 Edit','execute_remaining_unmet_work':'PASS: response31 Edit beta/gamma only -> response32 Read -> request33 actual alltrue53B feedback','record_actual3of3':'PASS: response33 measure -> request34 ff7a4f receipt and latest persisted measurement','preserve_task_goal_human_authority':'PASS: Task2 AwaitingVerification; Goal verifying/proof_pending; final response36 explicitly awaits Task verdict, Goal verifier and human final confirmation','source_terminal_ack':'PASS: exact Task001/approved vrf9990 source acknowledged turn_completed with pending0'},'actual_sequence_file':str(OUT/'actual-tool-sequence-and-receipts.json'),'goal_id':goal['id'],'criterion_revision':goal['criterion_revision'],'goal_measurement_after_approval':one,'goal_measurement_after_remaining_work':three,'current_latest_measurement':S['state']['.masc/goal_measurements.json'],'actual_goal_final':goal,'goal_verification_file':{'path':str(proof_path),'sha256':sha(proof_raw),'value':proof},'tasks':[task1,task2],'authoritative_goal_task_links':S['state']['.masc/tasks/goal_task_links.json'],'artifact':{'bytes':len(current),'sha256':sha(current),'value':json.loads(current),'current_equals_task2_immutable':True,'Task2_verification':task2['verification_id']},'fresh_approved_outcome_system_carriers':carriers,'final_public_response':{'request_sequence':36,'request_sha256':rows[36]['request_sha256'],'response_sha256':rows[36]['response']['sha256'],'tool_calls':0,'finish_reasons':rows[36]['response']['finish_reasons'],'text':rows[36]['response']['public_text']},'source_terminal':queue,'original_operation':operation,'semantic_execution':S['semantic_execution'],'timing_correction':{'initial_checkpoint':'Original operation was continuation_checkpoint at18:06:15 under Gate wait, not complete.','original_operation_completed_utc':completed.isoformat(),'Task001_approved_utc':approved.isoformat(),'operation_completed_before_Task_approval_seconds':(approved-completed).total_seconds(),'amendment_recorded_at':amend['recorded_at'],'amendment_path':str(amend_path),'amendment_sha256':sha(amend_raw),'interpretation':'The amendment planned to permit approval midflight, but actual SQL settled/succeeded completion18:14:18 precedes Task approval18:16:32 (and amendment18:16:01). Preserve the plan and actual chronology; do not describe actual approval as midflight.','operation_events_file':str(OUT/'operation-boundary-events.json')},'source_ack_is_not_Goal_completion':True,'limits':['Task2 and Goal proof/human confirmation remain pending; observed file metric3/3 is not verified Goal completion.','Evaluator_unavailable and exactly one Gate proxy intervention are real conditions, not independent LLM approval success.','Private thought fields are excluded from this bundle. A separate earlier diagnostic output filter error occurred, was disclosed, and its raw content is neither retained nor used.','Snapshots have explicit read windows, not one global atomic read; each claimed raw request/response is hash-checked against its sealed proxy receipt.','Canonical main11case metric mutation remains Root authority; this observer does not update it.']}
(OUT/'diagnosis.json').write_text(json.dumps(report,indent=2,ensure_ascii=False)+'\n')
for name in ['diagnosis.json','actual-tool-sequence-and-receipts.json','operation-boundary-events.json']:print(name,sha((OUT/name).read_bytes()))
print('source_ACK_UTC',queue['ack_applied_at_utc']);print('operation_before_approval_seconds',(approved-completed).total_seconds())
