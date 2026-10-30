#!/usr/bin/env python3
"""Execute actual pure submission modules and receipt with named effect ports.

No Dune/native Workspace lock/store, sandbox backend, SDK or model is exercised.
A small adapter names the baseline/current transition-to-prepare ordering; the
 real transaction and native actor provenance are covered by the authored,
 unrun test_verification consumer fixture, not proved by this adapter.
"""
from pathlib import Path
import hashlib,json,subprocess,tempfile
ROOT=Path(__file__).resolve().parents[3]
OUT=Path(__file__).resolve().parent
BASE='32805eb764eab2710262446e925b0ea5c3a44c08'
def sha(b):return hashlib.sha256(b).hexdigest()
def source(path,baseline):
 return subprocess.check_output(['git','show',BASE+':'+path],cwd=ROOT).decode() if baseline else (ROOT/path).read_text()
def between(s,start,end):return s[s.index(start):s.index(end)]
DOMAIN='''type task_reclaim_policy = Allow_reclaim | Block_reclaim
 type task_action = Claim | Start | Release | Done_action | Submit_for_verification | Cancel
 type task_status = Todo | Claimed of {assignee:string;claimed_at:string}
 | InProgress of {assignee:string;started_at:string}
 | AwaitingVerification of {assignee:string;started_at:string;submitted_at:string;verification_id:string}
 | Done of {assignee:string;completed_at:string;notes:string option}
 | Cancelled of {cancelled_by:string;cancelled_at:string;reason:string option}
 type task_handoff_context={summary:string;reason:string option;next_step:string option;failure_mode:string option;
 reclaim_policy:task_reclaim_policy option;evidence_refs:string list;updated_at:string option;updated_by:string option}
 type task_contract={completion_contract:string list;required_evidence:string list;verify_gate_evidence:string list}
 type task={id:string;title:string;task_status:task_status;contract:task_contract option;
 handoff_context:task_handoff_context option;cycle_count:int;reclaim_policy:task_reclaim_policy option;do_not_reclaim_reason:string option}
 type backlog={tasks:task list}
 type verification_claim=Completion_evidence of {evidence_refs:string list}
'''
CLAIM_PORT='''let clear_reclaim_decision task = task
let derive_release_reclaim_policy _ _ = None
let derive_release_do_not_reclaim_reason _ _ = None
'''
DRIVER=r'''
open Masc_domain
module E=Workspace_task_transition_executor
module H=Workspace_task_verification
module S=Workspace_verification_store
let count=ref 0
let check name ok=if not ok then failwith name else (incr count;Printf.printf "PASS %s\n" name)
let producer="producer"
let old_id="vrf-rejected"
let artifact="artifact:workspace/acceptance.json"
let correction="keep beta and gamma false"
let summary="alpha-only artifact ready"
let handoff refs text={summary=text;reason=None;next_step=None;failure_mode=None;reclaim_policy=None;
 evidence_refs=refs;updated_at=Some "2026-10-25T00:00:00Z";updated_by=Some producer}
let old={id="task-001";title="independent task";task_status=InProgress{assignee=producer;started_at="start"};
 contract=Some{completion_contract=["alpha=true"];required_evidence=["artifact:required-only"];verify_gate_evidence=[]};
 handoff_context=Some(handoff [old_id] correction);cycle_count=0;reclaim_policy=None;do_not_reclaim_reason=None}
let current=handoff [artifact] summary
let new_status=AwaitingVerification{assignee=producer;started_at="start";submitted_at="submit";verification_id="vrf-current"}
@ADAPTER@
let spec task claim = Protocol.submit_request_spec ~config:() ~task ~assignee:producer
 ~verification_id:"vrf-current" ~claim:(Completion_evidence{evidence_refs=claim})
(* Acquisition/request-loading ports: classification, typed snapshot codecs and
   submission_receipt are actual source; the fixture file is read through this
   port rather than the production ownership/sandbox/store boundary. *)
let capture refs = List.map (fun reference -> match S.classify_evidence_reference reference with
 | S.Artifact_reference path -> let content=In_channel.with_open_bin path In_channel.input_all in
   S.Evidence_artifact{reference;content;bytes=String.length content;truncated=false}
 | S.Note_reference text -> S.Evidence_note text
 | S.Collaboration_reference _ -> failwith "unrequested collaboration port"
 | S.Unresolvable_reference -> S.Evidence_invalid_reference) refs
let receipt items =
 S.loaded := Some({S.id="vrf-current";task_id=old.id;worker=producer;created_at=0.},items);
 match S.submission_receipt ~base_path:"unused" ~request_id:"vrf-current" ~task_id:old.id ~worker:producer with
 | Ok r -> r | Error _ -> failwith "receipt scope"
let diagnostics json=Yojson.Safe.Util.(json |> member "diagnostics" |> to_list)
let () =
 let updated=apply old (Some current) in
 check "current Task carries the exact new handoff" (updated.handoff_context=Some current);
 check "current Task carries the pending request identity" (updated.task_status=new_status);
 check "current Task preserves original input immutability" (old.handoff_context=Some(handoff [old_id] correction));
 let claim=refs old updated (Some current) in
 check "claim contains current artifact and narrative only" (List.sort String.compare claim=[artifact;"note:"^summary]);
 let first=spec (capture_task old updated) claim in
 check "contract artifacts stay separate" (first.criteria=["alpha=true"] && List.assoc "required_artifacts" first.evidence_fields=`List[`String "artifact:required-only"]);
 check "required artifacts do not become submitted evidence" (not(List.mem "artifact:required-only" first.submitted_evidence));
 let captured=capture first.submitted_evidence in
 let first_receipt=receipt captured in
 @FIRST_EXPECTATION@
 let second=spec updated claim in
 check "same claim after handoff replacement has no correlation ref" (not(List.mem old_id second.submitted_evidence));
 check "same claim after handoff replacement captures without diagnostics" (diagnostics(receipt(capture second.submitted_evidence))=[]);
 let absent=apply old None in
 check "an absent exit handoff clears the previous handoff" (absent.handoff_context=None);
 @CURRENT_CHECKS@
 check "request receipt refuses a mismatched producer" (match S.submission_receipt ~base_path:"unused"
 ~request_id:"vrf-current" ~task_id:old.id ~worker:"another-producer" with
 | Error reason -> reason=S.Request_scope_mismatch | Ok _ -> false);
 let explicit_invalid=spec updated [artifact;old_id] in
 check "explicit malformed submitted evidence is not silently filtered" (List.mem old_id explicit_invalid.submitted_evidence);
 check "explicit malformed reference remains a typed diagnostic" (diagnostics(receipt(capture explicit_invalid.submitted_evidence))<>[]);
 Printf.printf "%d actual-source checks passed\n" !count
'''
results=[]
for baseline in [True,False]:
 name='baseline' if baseline else 'candidate'
 with tempfile.TemporaryDirectory(prefix='masc-submission-'+name+'-') as temp:
  work=Path(temp);inputs=[]
  def put(n,s,scope):
   (work/n).write_text(s);inputs.append({'file':n,'scope':scope,'sha256':sha(s.encode())})
  put('masc_domain.ml',DOMAIN,'Task/backlog DTO port containing consumed fields, not full wire schema')
  put('workspace_task_claim.ml',CLAIM_PORT,'unrelated reclaim policy port; submit branches do not invoke these effects')
  put('workspace_state.ml',between(source('lib/workspace/workspace_state.ml',baseline),'let normalized_string_list values =','(* ============================================ *)\n(* State Recovery'),'actual pure normalizer fragment')
  for p in ['lib/shared_types/json_kind.mli','lib/shared_types/json_kind.ml','lib/string_util/string_util.ml','lib/core/json_util.ml','lib/tool_types/tool_shard_limits.ml','lib/workspace/workspace_verification_snapshot.mli','lib/workspace/workspace_verification_snapshot.ml','lib/workspace/workspace_task_transition_executor.mli','lib/workspace/workspace_task_transition_executor.ml','lib/workspace/workspace_task_verification.mli','lib/workspace/workspace_task_verification.ml','lib/task/tool_task_completion_review.mli','lib/task/tool_task_completion_review.ml']:
   put(Path(p).name,source(p,baseline),'full actual module/interface')
  put('shared_types.ml','module Json_kind=Json_kind\n','actual Json_kind namespace alias')
  store=source('lib/workspace/workspace_verification_store.ml',baseline)
  grammar=between(store,'let artifact_reference_prefix =','(* A producer-relative artifact path resolves')
  receipt=between(store,'let submission_receipt ~base_path','let inspect_submitted_evidence_for_authority')
  put('workspace_verification_store.ml','include Workspace_verification_snapshot\n'+grammar+'\nlet loaded = ref None\nlet load_request_for_evidence _ _ = match !loaded with Some x->Ok x|None->Error Request_not_found\n'+receipt,'actual grammar and complete receipt function; explicit acquisition/load ports')
  put('workspace.ml','type config=unit\n','unused configuration port for pure spec')
  put('verification.ml','type criterion=string\n','criterion DTO port')
  put('masc_task_handlers.ml','module Tool_task_completion_review=Tool_task_completion_review\n','actual implementation alias')
  protocol=source('lib/verification_protocol.ml',baseline)
  put('protocol.ml',between(protocol,'type submit_request_spec =','let warn_contract_gap'),'complete actual request-spec type and constructor')
  if baseline:
   adapter='''let apply task argument = let r=E.build_backlog_update ~backlog:{tasks=[task]} ~task_id:task.id ~action:Submit_for_verification ~new_status ~handoff_context:argument in List.hd r.backlog.tasks
let refs old _updated argument=H.verification_submission_evidence_refs old ~notes:summary argument
let capture_task old _updated=old
'''
   first='''check "baseline reproduces inherited correlation ref in first capture" (List.mem old_id first.submitted_evidence);
 check "baseline first receipt contains invalid-reference diagnostic" (diagnostics first_receipt<>[]);'''
   more=''
  else:
   adapter='''let apply task argument = let r=E.build_backlog_update ~backlog:{tasks=[task]} ~task ~action:Submit_for_verification ~new_status ~handoff_context:argument in
 check "executor shares the immutable committed Task" (r.transitioned_task==List.hd r.backlog.tasks);r.transitioned_task
let refs _old updated _argument=H.verification_submission_evidence_refs updated ~notes:summary
let capture_task _old updated=updated
'''
   first='''check "candidate first capture excludes stale correlation and correction" (not(List.mem old_id first.submitted_evidence)&&not(List.mem ("note:"^correction)first.submitted_evidence));
 check "candidate first receipt has no diagnostics" (diagnostics first_receipt=[]);
 check "candidate snapshot contains corrected artifact values" (List.exists (function
 | S.Evidence_artifact a -> Yojson.Safe.from_string a.content=`Assoc["alpha",`Bool true;"beta",`Bool false;"gamma",`Bool false]
 | S.Evidence_collaboration _ | S.Evidence_note _ | S.Evidence_invalid_reference
 | S.Evidence_artifact_unreadable _ | S.Evidence_artifact_binary _ -> false) captured);'''
   more='''let no_handoff_claim=H.verification_submission_evidence_refs absent ~notes:summary in
 check "note-only retry does not revive old handoff" (no_handoff_claim=["note:"^summary]);
 let defensive=spec old claim in
 check "projection reads supplied claim even if handed a prior Task" (defensive.submitted_evidence=first.submitted_evidence);'''
  driver=DRIVER.replace('@ADAPTER@',adapter).replace('@FIRST_EXPECTATION@',first).replace('@CURRENT_CHECKS@',more)
  put('probe.ml',driver,'driver; baseline/current ordering adapter explicit, not full transaction proof')
  (work/'workspace').mkdir();(work/'workspace/acceptance.json').write_text('{"alpha":true,"beta":false,"gamma":false}\n')
  order=['masc_domain.ml','string_util.ml','workspace_task_claim.ml','workspace_state.ml','json_kind.mli','json_kind.ml','shared_types.ml','json_util.ml','tool_shard_limits.ml','workspace_verification_snapshot.mli','workspace_verification_snapshot.ml','workspace_verification_store.ml','workspace_task_transition_executor.mli','workspace_task_transition_executor.ml','workspace_task_verification.mli','workspace_task_verification.ml','tool_task_completion_review.mli','tool_task_completion_review.ml','workspace.ml','verification.ml','masc_task_handlers.ml','protocol.ml','probe.ml']
  cmd=['ocamlfind','ocamlc','-w','+4+32+69','-warn-error','+4+32+69','-package','yojson,digestif.ocaml,uutf,ppx_deriving_yojson','-linkpkg',*order,'-o','probe']
  compiled=subprocess.run(cmd,cwd=work,text=True,capture_output=True)
  executed=subprocess.run([str(work/'probe')],cwd=work,text=True,capture_output=True)if compiled.returncode==0 else None
  result={'name':name,'base':BASE,'inputs':inputs,'compile':{'command':cmd,'exit':compiled.returncode,'output':compiled.stdout+compiled.stderr},'execution':None if executed is None else {'exit':executed.returncode,'output':executed.stdout+executed.stderr}}
  results.append(result)
report={'scope':__doc__,'base':BASE,'results':results}
(OUT/'source-check.json').write_text(json.dumps(report,indent=2)+'\n')
for r in results:
 print(r['name'],r['compile']['exit'],r['execution'])
 if r['compile']['exit']:print(r['compile']['output'])
if any(r['compile']['exit'] or r['execution'] is None or r['execution']['exit']for r in results):raise SystemExit(1)
