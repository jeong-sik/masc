import json, pathlib, hashlib, datetime
base=pathlib.Path('/Users/dancer/.masc-integration/collaboration-baseline-68c7668')
b=base/'.masc'; out=pathlib.Path('/tmp/masc-fusion-consumption-2578')
rid='kmsg-f381606a185bf86825c3f99ffd36e185'
def sha(data): return hashlib.sha256(data).hexdigest()
def save(name,value):
 p=out/name;p.write_text(json.dumps(value,ensure_ascii=False,indent=2)+'\n');return {'path':name,'sha256':sha(p.read_bytes())}
def rows(p):return [json.loads(l) for l in p.open()]
board=next(x for x in rows(b/'board_posts.jsonl') if (x.get('origin') or {}).get('fusion_run_id')==rid)
# Only the requested run's user-authored source, generated deliberation and origin.
board_ref=save('deliberation.redacted.json',{k:board[k] for k in ['id','author','title','visibility','created_at','expires_at','origin','meta']})
reaction=next(x for x in rows(b/'keepers/exhibit-editor/reaction-ledger/v7/2026-09/12.jsonl') if x.get('reaction',{}).get('post_id')=='fusion-run:'+rid)
reaction_ref=save('delivery-ack.redacted.json',reaction)
ids=['call_a5133fc99801463bba33aec3','call_573e0c4f142b41729774eb0f','call_da80af6bdb854d0c9f06f535','call_fa6a3120ec6243828fb2d2df']
logs={x.get('tool_use_id'):x for x in rows(b/'tool_calls/2026-09/12.jsonl') if x.get('tool_use_id') in ids}
trace=b/'keepers/exhibit-editor/raw-traces/turn-1789218949922-5f38-000061.jsonl'
raw=rows(trace);operations=[]
for tid in ids:
 t=logs[tid]
 entry={k:t.get(k) for k in ['ts','keeper','tool','success','execution_id','tool_use_id','turn','keeper_turn_id','turn_kind','lane','prompt_fingerprint','runtime_profile','trace_id','task_id','input','output']}
 entry['raw_records']=[{k:x.get(k) for k in ['seq','ts','record_type','worker_run_id','tool_use_id','tool_name','tool_input','tool_result','tool_error']} for x in raw if x.get('tool_use_id')==tid and x['record_type'] in ['tool_execution_started','tool_execution_finished']]
 if t['tool']=='Edit':
  f=next(x for x in entry['raw_records'] if x['record_type']=='tool_execution_finished')
  manifest_sha=f['tool_result'].split('sha256=')[1].split(' ')[0]
  mp=b/'tool_blobs'/manifest_sha[:2]/manifest_sha;manifest=json.loads(mp.read_text())['structured_content']; snaps=manifest['edit_snapshots'];entry['effect']={k:manifest[k] for k in ['ok','changed','mode','occurrences','bytes_written','via','edit_snapshots']}
  content={}
  for side in ['before','after']:
   ref=snaps[side]['_blob'];p=b/'tool_blobs'/ref['sha256'][:2]/ref['sha256'];data=p.read_bytes();assert sha(data)==ref['sha256'] and len(data)==ref['bytes'];content[side]=data.decode();(out/(ref['sha256']+'.md')).write_bytes(data)
  inp=next(x['tool_input'] for x in entry['raw_records'] if x['record_type']=='tool_execution_started')
  assert content['before'].replace(inp['old_string'],inp['new_string'],1)==content['after']
  entry['exact_replacement_verified']=True
 operations.append(entry)
ops_ref=save('consumption-edits.redacted.json',{'raw_trace_relative_path':str(trace.relative_to(base)),'raw_trace_sha256':sha(trace.read_bytes()),'operations':operations})
meta=board['meta'];reg=[x for x in rows(b/'fusion-runs.jsonl') if x.get('id')==rid]
receipt={'schema':'fusion-consumption-audit.v1','run_id':rid,'captured_at':datetime.datetime.now(datetime.timezone.utc).isoformat(),'scope':'Read-only durable evidence; no live/model/tool invocation. All writes are under this /tmp audit directory.','registry':reg,'board':{'post_id':board['id'],'origin':board['origin'],'visibility':board['visibility'],'created_at':board['created_at'],'expires_at':board['expires_at'],'full_evidence':board_ref},'source_context':meta['source_context'],'panel_outcomes':[{k:p.get(k) for k in ['model','status','input_tokens','output_tokens']} | {'answer_sha256':sha(p['answer'].encode()),'answer_bytes':len(p['answer'].encode())} for p in meta['panel']],'judge':{'status':meta['judge']['status'],'decision':meta['judge']['decision'],'observed_actor':next(x for x in meta['tool_trace']['observed_actors'] if x['phase']=='judge')},'tool_trace':meta['tool_trace'],'delivery_ack':reaction_ref,'consumption':ops_ref,'findings':['Fusion completed with two answered panels (GLM, Codex) and GLM synthesized judge; this is not verdict_insufficient or three panelists.','Exact result and correct board ID were delivered in fusion_completed source and terminally acknowledged at 1789219046.587685.','Editor turn 411 used mistyped post ID p-c0bb49d30e7a617ea654d100e845215 instead of actual p-c0bb49d30e7a617ea6596d100e845215. NotFound tool prose said deleted or expired; actual post exists and expires seven days after creation.','Turn 411 successfully edited decision.md three times. It recorded panel 3/3/verdict_insufficient, claimed TTL loss, and attributed an A+C recommendation; the source instead recommends C main plus B silent-choice support and conditional A. This is inaccurate consumption despite successful delivery and file effects.','Subsequent turn 414 review.md repeats those inaccurate attribution claims.','source_context task is null and goals is empty; question/decision_context explicitly describe the adaptation decision, and origin joins originating turn 408.','Codex panel answer is durably preserved but its tool trace is explicitly official_client_uninstrumented and usage fields are zero; no native tool trace completeness or zero-cost claim.']}
save('receipt.redacted.json',receipt)
print(json.dumps({'receipt':str(out/'receipt.redacted.json'),'board_post':board['id'],'panels':receipt['panel_outcomes'],'edit_execution_ids':[x['execution_id'] for x in operations if x['tool']=='Edit'],'verified_exact_edits':3},ensure_ascii=False))
