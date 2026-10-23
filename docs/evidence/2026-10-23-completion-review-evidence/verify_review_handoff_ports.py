"""Bounded source-fragment checks, not native SDK/product execution.

Uses the actual Anti.run, Tool_bridge formatter, Tool_output codec, and result
accessors. Explicit ports replace evaluator/slot/error/SDK/Eio/prompt boundaries;
Store_above storage fails if entered. See the accompanying review report.
"""
from pathlib import Path
import argparse
import hashlib,json,subprocess,sys,datetime
parser=argparse.ArgumentParser(description="Execute actual review handoff and bridge formatting with explicit boundary ports.")
parser.add_argument("--repo",type=Path,required=True)
parser.add_argument("--output",type=Path,required=True)
args=parser.parse_args()
repo=args.repo.resolve()
out=args.output.resolve()
out.mkdir(parents=True,exist_ok=True)
fragments=[]
def take(p,start,end):
 s=(repo/p).read_text();a=s.index(start);z=s.index(end,a);part=s[a:z];fragments.append({'path':p,'start_line':s[:a].count('\n')+1,'end_line':s[:z].count('\n')+1,'sha256':hashlib.sha256(part.encode()).hexdigest(),'source_sha256':hashlib.sha256(s.encode()).hexdigest()});return part
tr='lib/tool_types/tool_result.ml';br='lib/tool_bridge.ml';ar='lib/task/anti_rationalization.ml';ty='packages/agent_core/lib/llm_provider/types.ml'
source=r'''
module Common=struct
'''
source+=take('lib/core/common.ml','let max_tool_result_wire_bytes','(** How much of one tool result')
source+=take('lib/core/common.ml','let max_agent_core_inline_result_bytes','(** Acceptance ceiling')
source+='end\nmodule Tool_output=struct\n'+take('lib/tool_blob_store/tool_output.ml','type invalid_sha256 =','type decode_result =')+'end\n'
source+=r'''
module Eio=struct module Switch=struct type t=unit end module Cancel=struct exception Cancelled of exn end end
module Types_core=struct type verifier_slot_kind=Catalog_slot type tool_schema=unit end
module Runtime_attempt_dispatch=struct type t=unit end
module Masc_domain=struct type tool_schema=unit end
module Agent_core=struct
 module Types=struct
  type image_source=Base64
  type content_block=Text of string|Image of {media_type:string;data:string;source_type:image_source}
  let text_block x=Text x
'''
source+=take(ty,'type tool_error_class =','type tool_failure_kind =')
source+=take(ty,'type tool_error =','(** Tool choice mode')
source+=take(ty,'type tool_output =','let tool_result_of_outcome')
source+='let tool_error_class_to_yojson=function Transient->`String "Transient_port"|Deterministic->`String "Deterministic_port"|Unknown->`String "Unknown_port"\n'
source+=r'''
 end
 module Error=struct
  type t=Internal of string|Size_refused|Transient_failure|Absent
  let to_string=function Internal s->s|Size_refused->"size port"|Transient_failure->"transient port"|Absent->"absent port"
  let is_retryable=function Transient_failure->true|Internal _|Size_refused|Absent->false
 end
end
module Llm_provider=struct module Types=Agent_core.Types end
module Keeper_runtime_failure_route=struct let core_error_is_model_absent=function Agent_core.Error.Absent->true|Internal _|Size_refused|Transient_failure->false end
module Tool_result=struct
'''
source+=take(tr,'type tool_failure_class =','let derived_tool_failure_class_of_yojson')
source+=take(tr,'type failure_effect_disposition =','let failure_effect_disposition_of_string')
source+=take(tr,'let tool_failure_class_to_string =','let tool_failure_class_of_string')
source+=take(tr,"type ('completed, 'deferred, 'failed) disposition =",'let unit_disposition_of_string')
source+=take(tr,'type output_payload =','let failure_data_of_explicit')
source+=take(tr,'let message : result -> string =','let failure_class : result')
source+=take(tr,'let to_json (result : result)','let tool_name : result')
source+=take(tr,'let data : result','let retained_artifacts : result')
source+=take(tr,'let metadata : result','let with_metadata')
source+='end\n'
source+=r'''
module Prompt_names=struct let tool_failure_dependency_unavailable="dependency" let tool_failure_policy_rejection="policy" let tool_failure_runtime_failure="runtime" let tool_failure_workflow_rejection="workflow" let tool_failure_operator_cancelled="cancelled" end
module Prompt_registry=struct
 type resolution={file_exists:bool;has_override:bool;effective:string}
 let reads=ref 0 and guidance=ref "ORIGINAL_GUIDANCE"
 let resolve_prompt _=incr reads;{file_exists=true;has_override=false;effective= !guidance}
end
module Log=struct module Misc=struct let error fmt=Printf.ksprintf (fun _->()) fmt end end
module Tool_bridge=struct
'''
source+=take(br,'let semantic_answer_fingerprint','type projection_error_kind')
source+=take(br,'type projection_error_kind =','let attach_artifact_manifest')
source+='let storage_calls=ref 0\nlet maybe_externalize ?base_path:_ ?stored_preview:_ ?answer_fingerprint:_ ?threshold_bytes:_ _ = incr storage_calls; failwith "FORBIDDEN storage port entered"\n'
source+=take(br,'let make_tool_error','(* The class is typed at the producer')
source+=take(br,'let failure_next_move','(** {1 Schema Conversion}')
source+=take(br,'let project_result','(** Create an AGENT_CORE [Tool.t]')
source+='end\nmodule Tool_shard_limits=struct\n'+take('lib/tool_types/tool_shard_limits.ml','let read_file_default_max_bytes','(* How many images')+'end\nmodule AR=struct\n'
source+=take(ar,'type lookup_surface =','type lookup_root =')
source+=take(ar,'type verdict =','let outcome_observer_fn')
source+=take(ar,'let outcome_observer_fn','(** Issue #8436')
source+=take(ar,'type gate =','let gate_to_string')
source+=take(ar,'type review_result =','(* ================================================================ *)')
source+=take(ar,'type provider_rest =','(* What one candidate')
source+=take(ar,'type candidate_failure =','let append_unique')
source+='let slots=ref ["A",Types_core.Catalog_slot;"B",Types_core.Catalog_slot]\nlet resolve_evaluator_slots _=Ok !slots\nlet unresolved_evaluator_runtime="unresolved"\nlet report_review_verdict_schema=()\n'
source+=take(ar,'let append_unique','(* The Task lane:')+'end\n'
source+=r'''
let check name condition=if condition then Printf.printf "PASS %s\n" name else failwith name
let member=Yojson.Safe.Util.member
let image data=Agent_core.Types.Image {media_type="image/png";data;source_type=Base64}
let args=`Assoc ["path",`String "actual/proof"]
let payload ?metadata ?(media=[]) data : Tool_result.result=Tool_result.Completed {retained_artifacts=[];data;content_blocks=Some media;metadata;tool_name="read";duration_ms=0.}
let failed ?metadata data_source : Tool_result.result=Tool_result.Failed {effect_disposition=Proven_pre_effect;class_=Workflow_rejection;message="short failure";data_source;metadata;tool_name="read";duration_ms=0.}
let entries blocks=List.filter_map (function Agent_core.Types.Text s->(try match member "prior_review_lookup" (Yojson.Safe.from_string s) with `Null->None|x->Some x with Yojson.Json_error _->None)|Agent_core.Types.Image _->None) blocks
let submitted=image "original-submitted-image"
let check_two_slots ?(after_lookup_return=(fun ()->())) label raw inspect=
 let reads=ref 0 and offered=ref [] in
 let lookup:AR.lookup_surface={schemas=[];dispatch=(fun ~name ~args:actual->incr reads;check (label^" original lookup identity") (name="read"&&actual=args);raw)} in
 Atomic.set AR.run_llm_reviewer_fn (fun ~base_path:_ ?sw:_ ~evaluator_runtime ~candidate_kind:_ ~prompt ?goal_blocks ~report_tool_schema:_ ~lookup ~on_tool_result:_ ~on_runtime_attempt_error:_ ()->
  offered:=!offered@[evaluator_runtime];let blocks=Option.get goal_blocks in
  check (label^" original prompt/media") (List.take 2 blocks=[Agent_core.Types.Text prompt;submitted]);
  if evaluator_runtime="A" then (let returned=lookup.dispatch ~name:"read" ~args in check (label^" handler result not modified") (returned == raw);after_lookup_return ();Error Agent_core.Error.Size_refused)
  else (let entry=List.hd(entries blocks) in check (label^" original slot/args relation") (member "evaluator_slot" entry=`String "A"&&member "arguments" entry=args);inspect entry blocks;Ok {AR.selected_runtime_id=evaluator_runtime;verdict=Some(AR.Approve "checked") }));
 let result=AR.run ~log_info:ignore ~log_warn:ignore ~render_prompt:(fun()->Ok "original prompt") ~goal_blocks:[submitted] ~lookup ~provider_rest:(fun _->AR.No_stated_rest) ~base_path:"port-no-files" () in
 check (label^" one real injected lookup and declared slots") (!reads=1 && !offered=["A";"B"] && result.verdict=Some(AR.Approve "checked"))
let ()=
 let limit=Tool_shard_limits.verification_evidence_max_bytes in
 let big=String.make (limit+1) 'm' in
 let metadata=`Assoc ["raw",`String big] in
 let expect_refusal label entry blocks=
  check (label^" actual bridge refusal retained") (member "kind" (member "projection_refusal" entry)=`String "inline_budget_exceeded"&&member "result" entry=`Null);
  check (label^" raw body/media absent") (List.length blocks=3)
 in
 check_two_slots "Completed oversize" (payload ~media:[image "rejected"] (`String big)) (expect_refusal "Completed oversize");
 check_two_slots "Failed metadata" (failed ~metadata Tool_result.Message_as_data) (expect_refusal "Failed metadata");
 check_two_slots "Failed explicit data" (failed (Tool_result.Explicit_data (`Assoc ["body",`String big]))) (expect_refusal "Failed explicit data");
 let media=image "actual-original-lookup" in
 check_two_slots "Complete original view" (payload ~metadata:(`Assoc ["host_only",`String "SECRET_PORT_METADATA"]) ~media:[media] (`String "original contradiction")) (fun entry blocks->
   let view=member "result" entry in check "actual content and native media preserved" (member "content" view=`String "original contradiction"&&member "is_error" view=`Bool false&&List.mem media blocks);
   check "host-only metadata not copied into handoff" (view=`Assoc ["content",`String "original contradiction";"is_error",`Bool false]));
 let reference=match Tool_output.make_artifact_ref ~sha256:(String.make 64 'a') ~bytes:10 ~preview:"original ref" ~mime:"text/plain" with Ok r->r|Error _->assert false in
 let raw=payload (Tool_output.normalized_artifact_ref_to_json reference) in
 check_two_slots "Missing artifact manifest" raw (fun entry blocks->check "actual artifact manifest refusal retained" (member "kind" (member "projection_refusal" entry)=`String "artifact_storage_failure"&&member "result" entry=`Null&&List.length blocks=3));
 Prompt_registry.reads:=0;Prompt_registry.guidance:="ORIGINAL_GUIDANCE";
 let raw=failed Tool_result.Message_as_data in
 check_two_slots ~after_lookup_return:(fun ()->
   check "policy changes after A lookup returned and before B assembly" (!(Prompt_registry.reads)=1);
   Prompt_registry.guidance:="NEW_GUIDANCE") "Frozen failed view" raw (fun entry _->
   let view=member "result" entry in
   check "failure formatting frozen before B assembly" (!(Prompt_registry.reads)=1 && member "is_error" view=`Bool true && member "recoverable" view=`Bool false && member "content" view=`String "short failure\nfailure_class=workflow_rejection — ORIGINAL_GUIDANCE"));
 check "probe never entered blob storage branch" (!(Tool_bridge.storage_calls)=0)
'''
(out/'probe.ml').write_text(source)
(out/'fragments.json').write_text(json.dumps(fragments,indent=2))
source_files=[]
for path in sorted({f['path'] for f in fragments}):
 data=(repo/path).read_bytes()
 recorded={f['source_sha256'] for f in fragments if f['path']==path}
 actual=hashlib.sha256(data).hexdigest()
 if recorded!={actual}: raise RuntimeError('source changed during extraction: '+path)
 destination=out/'executed-source'/path
 destination.parent.mkdir(parents=True,exist_ok=True)
 destination.write_bytes(data)
 source_files.append({'path':path,'sha256':actual})
(out/'source-manifest.json').write_text(json.dumps(source_files,indent=2))
argv=['ocamlfind','ocamlc','-package','yojson,digestif.ocaml','-linkpkg','-w','+a-4-27-40-41-42-70','-o','probe.exe','probe.ml'];p=subprocess.run(argv,cwd=out,text=True,capture_output=True);r={'source_head':subprocess.check_output(['git','-C',str(repo),'rev-parse','HEAD'],text=True).strip(),'script_sha256':hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),'ocamlc_version':subprocess.check_output(['ocamlc','-version'],text=True).strip(),'captured_at_utc':datetime.datetime.now(datetime.timezone.utc).isoformat(),'compile_argv':argv,'compile_exit':p.returncode,'compile_stdout':p.stdout,'compile_stderr':p.stderr}
if not p.returncode:
 q=subprocess.run(['./probe.exe'],cwd=out,text=True,capture_output=True);r.update(run_argv=['./probe.exe'],run_exit=q.returncode,run_stdout=q.stdout,run_stderr=q.stderr)
(out/'execution.json').write_text(json.dumps(r,indent=2));print(json.dumps(r,indent=2));sys.exit(r.get('run_exit',r['compile_exit']))
