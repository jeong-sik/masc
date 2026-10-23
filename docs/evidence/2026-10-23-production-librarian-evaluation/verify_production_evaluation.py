#!/usr/bin/env python3
"""Run actual evaluator/selection/input codecs with explicit external ports.

Not a MASC native build, real snapshot/range authority, real prompt renderer,
or a provider inference. Full port inventory is emitted with the receipt.
"""
import argparse
import datetime
import hashlib
import json
from pathlib import Path
import re
import shlex
import subprocess

parser = argparse.ArgumentParser()
parser.add_argument('--repo', type=Path, required=True)
parser.add_argument('--output', type=Path, required=True)
args = parser.parse_args()
repo, out = args.repo.resolve(), args.output.resolve()
out.mkdir(parents=True, exist_ok=True)
sources, fragments = {}, []


def take(path, start=None, end=None):
    source = sources.setdefault(path, (repo/path).read_text())
    first = source.index(start) if start else 0
    after = source.index(end, first) if end else len(source)
    result = source[first:after]
    fragments.append({'path': path, 'first_line': source.count('\n', 0, first)+1,
                      'last_line': source.count('\n', 0, after)+1,
                      'sha256': hashlib.sha256(result.encode()).hexdigest()})
    return result


def module(name, source):
    return '\nmodule '+name+' = struct\n'+source+'\nend\n'


def no_codegen(source):
    # Keep the actual declarations/default attributes; omit unused SDK show derivation.
    return re.sub(r'\[@@deriving show\]|\[@@deriving yojson, show\]', '', source)


ty = 'packages/agent_core/lib/llm_provider/types.ml'
ev = 'lib/librarian_production_evaluation.ml'
rt = 'lib/keeper/keeper_librarian_runtime.ml'
ci = 'lib/keeper/keeper_librarian_input_capture.ml'
win = 'lib/runtime/runtime_model_input_tail_window.ml'
text = r'''
module Json_util=struct let kind_name _="port JSON kind" end
module Goal_phase=struct type t=Yojson.Safe.t let of_yojson x=Ok x let to_yojson x=x end
module Goal_store=struct type criterion=Yojson.Safe.t let criterion_of_yojson x=Ok x let criterion_to_yojson x=x end
module Keeper_memory_os_types=struct
 type fact=Yojson.Safe.t
 let fact_of_json x=Ok x let fact_to_json x=x let wire_error_to_string x=x
end
module Keeper_turn_task_context=struct
 type t=No_task|Opaque of Yojson.Safe.t
 let of_json=function `Assoc ["kind",`String "no_task"]->Ok No_task|x->Ok(Opaque x)
 let to_json=function No_task->`Assoc["kind",`String "no_task"]|Opaque x->x
end
'''
text += module('Ids', take('lib/types/ids.ml', 'module Turn_ref : sig', '(** Thread identifier'))
text += module('Keeper_identity', take('lib/keeper/keeper_identity.ml', 'module Keeper_id = struct'))
sdk = no_codegen(take(ty, 'type role =', 'let role_to_string'))
sdk += no_codegen(take(ty, 'type tool_error_class =', 'let tool_failure_kind_is_recoverable'))
sdk += no_codegen(take(ty, 'type media_source_kind =', 'let media_source_kind_to_string'))
sdk += no_codegen(take(ty, 'type reasoning_detail =', 'type tool_output ='))
sdk += no_codegen(take(ty, 'type metadata =', '\n\n'))+'\n'
sdk += take(ty, 'module Extra_system_context_provenance =', '\nmodule ',)
sdk += no_codegen(take(ty, 'type message =', 'module Message_value ='))
text += module('Agent_core', module('Types', sdk)+r'''
 module Checkpoint=struct
  let serializer : (Types.message -> Yojson.Safe.t) ref=ref(fun _->failwith "unbound checkpoint codec port")
  let message_to_json message=(!serializer) message
 end
''')
text += module('Keeper_librarian_context', take('lib/keeper/keeper_librarian_context.ml', 'type source =', 'let version'))
h = take('lib/keeper/keeper_librarian_task_context.ml', 'type source =', 'let atom_spans')
h += take('lib/keeper/keeper_librarian_task_context.ml', 'let source_to_json =')
text += module('Keeper_librarian_task_context', h)
cp = 'lib/keeper/keeper_counterpart_observation.ml'
counterpart = take(cp, 'type origin =', 'let workspace_id_of_surface')
counterpart += take(cp, 'let option_string_field', 'let render_for_prompt')
text += module('Keeper_counterpart_observation', counterpart)
lib = 'open Keeper_memory_os_types\n'+take('lib/keeper/keeper_librarian.ml', 'type current_selection =', '(* A new claim')
source = sources['lib/keeper/keeper_librarian.ml']
first=source.index('let goal_context_to_json =');after=source.index('\n;;',first)+3
lib += take('lib/keeper/keeper_librarian.ml', 'let goal_context_to_json =', source[after:after+30])
text += module('Keeper_librarian', lib)
text += module('Keeper_librarian_input_capture', take(ci))
text += '\nlet ()=Agent_core.Checkpoint.serializer:=Keeper_librarian_input_capture.message_json\n'
window = take(win, 'let working_state_marker_key', 'type budget_error =')
window += take(win, 'let is_extra_context', 'let first_atom_at_or_after')
text += module('Runtime_model_input_tail_window', window)
su = 'lib/string_util/string_util.ml'
text += module('String_util', take(su, 'let is_lowercase_sha256_hex'))
text += module('Keeper_librarian_input_refusal', take('lib/keeper/keeper_librarian_input_refusal.ml'))
text += module('Keeper_librarian_unread', take('lib/keeper/keeper_librarian_unread.ml'))
text += r'''
module Keeper_turn_boundaries=struct
 type position=unit
 type history_at_start=Fresh_history
 type event=Turn_ended of {task_context:Keeper_turn_task_context.t;turn_ref:Ids.Turn_ref.t;history_at_start:history_at_start;position:position}
 type t={recorded_at:float;event:event}
 let position_of_messages _=Ok ()
end
module Prompt_registry=struct
 type prompt_source=Override|File|Missing
 type prompt_resolution={effective:string;source:prompt_source;file_value:string option;override_value:string option;file_path:string option;file_exists:bool;has_override:bool}
 let prompt_source_to_string=function Override->"override"|File->"file"|Missing->"missing"
end
module Exact_output=struct type requirement=Yojson.Safe.t let domain_schema x=x end
'''
runtime = '[@@@warning "+4+32+69"]\n[@@@warnerror "+a"]\n'+take(rt, 'type input_capacity_evidence =', 'type exact_execution_error =')
runtime += take(rt, 'type served_slot =', 'type extraction_error =')
runtime += take(rt, 'type librarian_prompt_material =', '(* A process-only decision')
runtime += take(rt, 'type not_committed =', 'let merge_message_descent')
runtime += r'''
type write_scope=Context_only
type inference=Infer_memory of unit|Infer_state of {previous_state:string option;unread_messages:Keeper_librarian_unread.t list;preparation:working_state_preparation ref;observe:served_by:served_slot->string->unit;observe_failure:Keeper_librarian_input_refusal.t list option->unit}
exception Port_cancelled
let rendered=ref "ORIGINAL_PREPARED_PROMPT"
let mode=ref "success"
let calls=ref []
let request_arguments : (string option * Keeper_librarian_unread.t list) list ref=ref []
let capture_observer=ref(fun ()->())
let run_pass ~write_scope:_ ?inference ~on_not_committed ?cli_runner:_ ~base_path:_ ~keepers_dir:_ ~keeper_id:_ ~expected_revision:_ (input:Keeper_librarian.input)=
 calls:= input::!calls;
 (match inference with Some(Infer_state request)->request_arguments:=(request.previous_state,request.unread_messages)::!request_arguments|None|Some(Infer_memory _)->());
 if !mode="cancel" then raise Port_cancelled;
 if !mode<>"not_prepared" then begin
 let run_id="port-run-id" in
 let prompt_variables=["history",Yojson.Safe.to_string(Keeper_librarian_input_capture.to_json input)] in
 let resolution:Prompt_registry.prompt_resolution={effective= !rendered;source=File;file_value=Some !rendered;override_value=None;file_path=Some "port-template.md";file_exists=true;has_override=false} in
 let prompt_material=if !mode="prompt_failed" then Error "port renderer refused" else Ok {resolution;rendered= !rendered} in
 let requirement=`Assoc ["type",`String "object"] in
'''
runtime += take(rt, '        (match inference with\n         | None | Some (Infer_memory _) -> ()\n         | Some (Infer_state observation) ->', '        Exact_lane_run_registry.register_running')
runtime += r'''
 (!capture_observer)();rendered:="LATE_TEMPLATE";
 end;
 if !mode="success" then (match inference with Some(Infer_state v)->v.observe ~served_by:(Api_slot "port-slot") "NEW_WORKING_STATE"|None|Some(Infer_memory _)->())
 else begin
 let report={input_capacity_evidence=No_input_capacity_refusal;message_descent=No_descent_evidence;provider_input_refusals=[];detail="port inference failure";walk_shows_size=false;smaller_range_meets_same_failure=false} in
 on_not_committed report;
 match inference with Some(Infer_state v)->v.observe_failure None|None|Some(Infer_memory _)->()
 end
'''
runtime += take(rt, 'type inference_failure =', 'type memory_inference =')
text += module('Keeper_librarian_runtime', runtime)
text += r'''
module Librarian_continuity_snapshot=struct
 type range={history_start_boundary_line:int;end_atom:int}
 type t={working_state:string;unread_messages:Keeper_librarian_unread.t list}
 type restored={working_state:string;messages:Agent_core.Types.message list;unread_messages:Keeper_librarian_unread.t list}
 let selected_end_atom=ref 2
 let events=ref []
 let fail=ref false
 let restored_messages=ref []
 let stored : t option ref=ref None
 let error_to_string x=x
 let checkpoint_prefix_range ~trace_id ~lines:_ ~messages:_=Ok {history_start_boundary_line=1;end_atom=(if trace_id="synthetic-destination" then 3 else !selected_end_atom)}
 let capture ~unread_messages ~trace_id:_ ~lines:_ ~messages:_ ~working_state : (t,string) result=
  events:= !events@["snapshot_capture"];if !fail then Error "snapshot port refused" else Ok {working_state;unread_messages}
 let save ~path:_ snapshot=events:= !events@["snapshot_save"];stored:=Some snapshot;Ok ()
 let load ~path:_=events:= !events@["snapshot_load"];match !stored with Some s->Ok s|None->Error "snapshot port absent"
 let restore ~trace_id:_ ~lines:_ ~messages:_ (snapshot:t)=events:= !events@["snapshot_restore"];Ok {working_state=snapshot.working_state;messages= !restored_messages;unread_messages=snapshot.unread_messages}
 let to_json (snapshot:t)=`Assoc ["working_state",`String snapshot.working_state;"unread_messages",Keeper_librarian_unread.list_to_json snapshot.unread_messages]
end
module Llm_provider=struct module Request_wire_observer=struct type observation=unit [@@deriving yojson] end end
'''
rp = 'lib/librarian_continuity_report.ml'
report = take(rp, 'type fact =', 'type sample =')
report += take(rp, 'let judge_request_for', 'let judge_request ~')
text += module('Librarian_continuity_report', report)
text += '\nmodule Actual_evaluation : sig\n'+take('lib/librarian_production_evaluation.mli')+'\nend = struct\n[@@@warning "+4+32+69"]\n[@@@warnerror "+a"]\n'+take(ev)+'\nend\n'
text += (Path(__file__).with_name('probe_cases.ml')).read_text()
dataset='benchmarks/data/librarian_production_synthetic.json'
take(dataset)
(out/'probe.ml').write_text(text)
for path, source in sources.items():
    saved=out/'executed-source'/path
    saved.parent.mkdir(parents=True,exist_ok=True)
    saved.write_text(source)
    if (repo/path).read_text()!=source:
        raise RuntimeError('Source changed during extraction: '+path)
head=subprocess.check_output(['git','--no-optional-locks','-C',str(repo),'rev-parse','HEAD'],text=True).strip()
manifest=[]
for path,source in sources.items():
    expected=subprocess.check_output(['git','--no-optional-locks','-C',str(repo),'rev-parse',head+':'+path],text=True).strip()
    data=source.encode()
    blob=hashlib.sha1(b'blob '+str(len(data)).encode()+b'\0'+data).hexdigest()
    manifest.append({'path':path,'sha256':hashlib.sha256(data).hexdigest(),'git_blob':blob,'head_blob':expected,'matches_head_blob':blob==expected})
(out/'source-manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')
(out/'fragments.json').write_text(json.dumps(fragments,indent=2)+'\n')
query=lambda name:subprocess.check_output(['ocamlfind','query',name],text=True).strip()
ppx=shlex.quote(str(Path(query('ppx_deriving'))/'ppx_deriving'))+' '+shlex.quote(str(Path(query('ppx_deriving_yojson'))/'ppx_deriving_yojson.cma'))
argv=['ocamlfind','ocamlc','-package','yojson,digestif.ocaml,ppx_deriving_yojson.runtime','-linkpkg','-ppx',ppx,'-w','+a-4-27-32-40-41-42-70','-o','probe.exe','probe.ml']
compiled=subprocess.run(argv,cwd=out,text=True,capture_output=True)
receipt={'source_state':'All extracted source/dataset bytes match recorded commit blobs' if all(e['matches_head_blob'] for e in manifest) else 'working tree; source hashes authoritative','source_commit':head,'all_extracted_sources_match_commit':all(e['matches_head_blob'] for e in manifest),'local_warning_checks':{'actual_evaluator_and_runtime_fragments':'+4+32+69; warnerror +a','ports_and_fixture':'+a-4-27-32-40-41-42-70; no whole module typing claim'},'captured_at_utc':datetime.datetime.now(datetime.timezone.utc).isoformat(),'script_sha256':hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),'cases_sha256':hashlib.sha256(Path(__file__).with_name('probe_cases.ml').read_bytes()).hexdigest(),'compile_argv':argv,'compile_exit':compiled.returncode,'compile_stdout':compiled.stdout,'compile_stderr':compiled.stderr,
 'ports':['SDK Checkpoint.message_to_json delegates to actual capture codec (not real checkpoint bytes)','Memory fact/Goal/Task external domain codecs are opaque JSON ports','Turn boundary/range authority and snapshot capture/save/load/restore are explicit typed fixture ports; no actual snapshot correctness tested','Prompt renderer/preflight/provider run_pass are explicit SDK ports surrounding the actual preparation capture and actual inference wrapper','Provider request-wire observation is unit; generate/judge are injected effects'],
 'actual':['Entire evaluator ML/MLI','Entire capture codec','Entire unread identity/validation module','Atom annotation/classification/digest fragments','Actual prompt preparation capture assignment and infer_working_state wrapper','Actual report type codecs and judge_request_for'],
 'scope':'Source-fragment bytecode execution only. No paid provider, native MASC, actual snapshot/range authority, full module typing, Dune or CI.'}
code=compiled.returncode
if code==0:
    run_argv=[str(out/'probe.exe'),str(out/'executed-source'/dataset),str(out/'observations.json')]
    result=subprocess.run(run_argv,cwd=out,text=True,capture_output=True)
    receipt.update(run_argv=run_argv,run_exit=result.returncode,run_stdout=result.stdout,run_stderr=result.stderr)
    code=result.returncode
(out/'execution.json').write_text(json.dumps(receipt,indent=2)+'\n')
print(json.dumps(receipt,indent=2))
raise SystemExit(code)
