"""Exercise verbatim ordinal propagation with explicit dependency ports.

This is not the native SDK or its durable replay test. See README.md.
"""
from pathlib import Path
import argparse
import hashlib
import json
import subprocess
import sys

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--output", type=Path, required=True)
args = parser.parse_args()
repo = Path(__file__).resolve().parents[3]
out = args.output.resolve()
out.mkdir(parents=True, exist_ok=True)
fragments=[]
def read(p): return (repo/p).read_text()
def extract(p,start,end):
 s=read(p); a=s.index(start); z=s.index(end,a); f=s[a:z]
 fragments.append({'path':p,'start_line':s[:a].count('\n')+1,'end_line':s[:z].count('\n')+1,'sha256':hashlib.sha256(f.encode()).hexdigest(),'source_sha256':hashlib.sha256(s.encode()).hexdigest()})
 return f
sdk='packages/agent_core/lib/agent/agent.ml'; rt='lib/runtime/runtime_agent.ml'
pre=r'''
module Types = struct
 type stop_reason = EndTurn
 type api_response = {id:string;model:string;content:string list;stop_reason:stop_reason;usage:unit option;telemetry:unit option}
end
module Checkpoint = struct type t={model:string;session_id:string;turn_count:int} end
module Terminal_tool_receipt = struct type t={response:Types.api_response} end
module Error = struct type input_required=string type t = Internal of string | Typed_empty | Other_error let to_string _="port_error" end
 type detailed_error={error:Error.t}
 type checkpoint_stage=After_tools
 type config={yield_on_tool:bool;model:string}
 type state={config:config;mutable turn_count:int}
 type outcome=[`Complete of Types.api_response | `ToolsExecuted of checkpoint_stage | `TerminalToolCompleted of Terminal_tool_receipt.t]
 type step={ordinal:int;count_after:int;outcome:(outcome,detailed_error) result}
 type agent={state:state;mutable steps:step list}
 module Pipeline = struct
  let resolve_turn_frontier a=match a.steps with x::_->Ok x|[]->Error (Error.Internal "empty port")
  let turn_frontier_ordinal s=s.ordinal
 end
 type lease=Held
 type release={before_tool_execution:(unit->unit) option;after:unit->lease}
 let acquire_provider_lease ~yield_enabled:_ ~on_resume:_ lease=lease
 let plan_provider_lease_release ~yield_enabled:_ ~on_yield:_ _={before_tool_execution=None;after=(fun()->Held)}
 let detailed_error_of_core_error error={error}
 let run_turn_core_detailed ~sw:_ ?clock:_ ~api_strategy:_ ?raw_trace_run:_ ?before_tool_execution:_ ~frontier a=
  a.steps<-List.tl a.steps;a.state.turn_count<-frontier.count_after;frontier.outcome
 let log_turn ~run_start:_ ~turn_start:_ ~turn_index:_ ~model:_ ~stop:_=()
 let stop_reason_label _="port_end"
 let checkpoint a : Checkpoint.t={model=a.state.config.model;session_id="port";turn_count=a.state.turn_count}
 module Advanced = struct
'''
adv=extract(sdk,'  type tool_boundary =','  let raw_trace_yield_stop_reason')
adv+=extract(sdk,'  let completed_tool_boundary','  let classify_trace_success')
adv+=extract(sdk,'  let run_loop_turns_detailed','  let run_loop_detailed')
ports=r'''
 end
 module Agent_core = struct
  module Types=Types
  module Checkpoint=Checkpoint
  module Terminal_tool_receipt=Terminal_tool_receipt
  module Error=Error
  module Raw_trace=struct type run_ref=unit type run_validation=unit end
  module Agent=struct module Advanced=Advanced end
 end
 module Runtime_observation=struct type runtime_observation=unit end
 module Runtime_agent_context=struct
'''
ctx=extract('lib/runtime/runtime_agent_context.ml','type stop_reason =','type config =')
rtpre='end\nmodule Runtime_agent=struct\n'
rtactual=extract(rt,'type stop_reason =','type cooperative_yield_reason =')
rtactual+=extract(rt,'type cooperative_yield_reason =','type cooperative_yield_decision =')
rtactual+=extract(rt,'type run_result =','(* ================================================================ *)')
rtactual+=extract(rt,'let stop_reason_of_cooperative_yield','let cooperative_boundary_callback')
rtactual+=extract(rt,'type classified_advanced_outcome =','(* ================================================================ *)')
sy='end\nmodule Synthetic=struct\nlet is_end_turn_empty_completion=function Error.Typed_empty->true | Error.Other_error | Error.Internal _->false\n'
sy+=extract('lib/keeper/keeper_turn_driver_try_provider.ml','let complete_saved_tool_terminal','(** Run a single provider attempt')
sy+='end\n'
sy+=extract('lib/keeper/keeper_turn_driver.ml','let run_result_answered','(* The prompt-sent callback')
tests=r'''
let response={Types.id="fixture";model="fixture";content=["ok"];stop_reason=Types.EndTurn;usage=None;telemetry=None}
let mk_step ordinal count_after outcome={ordinal;count_after;outcome=Ok outcome}
let mk_agent steps={state={config={yield_on_tool=false;model="fixture"};turn_count=999};steps}
let check name condition=if condition then Printf.printf "PASS %s\n" name else failwith name
let run ?(decision=Advanced.Continue) steps=Advanced.run_loop_turns_detailed ~sw:() ~api_strategy:() ~on_tool_boundary:(fun _->decision) (mk_agent steps)
let ()=
 (match run [mk_step 17 400 (`Complete response)] with
 |Ok (Advanced.Completed c)->check "completed_nonzero_frontier_without_hook" (c.provider_turn_ordinal=17)
 |_->assert false);
 (match run ~decision:Advanced.Yield [mk_step 19 0 (`ToolsExecuted After_tools)] with
 |Ok (Advanced.Yielded y)->check "yield_ordinal_independent_from_zero_count" (y.provider_turn_ordinal=19 && y.turn=0)
 |_->assert false);
 (match run [mk_step 23 100 (`TerminalToolCompleted {Terminal_tool_receipt.response})] with
 |Ok (Advanced.Terminal_tool_completed c)->
  check "terminal_ordinal_independent_from_count" (c.provider_turn_ordinal=23 && c.turn=100);
  (match Runtime_agent.classify_advanced_outcome ~yield_reason:None ~boundary_response:None (Advanced.Terminal_tool_completed c) with
  |Ok (Runtime_agent.Advanced_completed r)->check "runtime_terminal_projection" (r.provider_turn_ordinal=23 && r.response=response)
  |_->assert false)
 |_->assert false);
 (match run [mk_step 25 300 (`ToolsExecuted After_tools);mk_step 37 401 (`Complete response)] with
 |Ok (Advanced.Completed c)->check "continue_uses_next_resolved_frontier" (c.provider_turn_ordinal=37)
 |_->assert false);
 let reasons=[Runtime_agent.Operation_queued;Durable_stimulus_waiting;Repeated_tool_call {tool_name="actual";repeated_count=2};Repeated_assistant_text {repeated_count=3};Terminal_tool_completed] in
 List.iter (fun reason->let stop=Runtime_agent.stop_reason_of_cooperative_yield ~provider_turn_ordinal:29 ~turns_used:0 reason in check "runtime_yield_projection_final_ordinal" (Runtime_agent.final_provider_turn_ordinal stop=Some 29)) reasons;
 check "input_required_has_no_completion_ordinal" (Runtime_agent.final_provider_turn_ordinal (Runtime_agent.InputRequired {turns_used=500;request="question"})=None);
 let checkpoint={Checkpoint.model="fixture";session_id="fixture";turn_count=401} in
 let original=Error Error.Typed_empty in
 let complete saved witness cp result=Synthetic.complete_saved_tool_terminal ~tool_results_saved_in_attempt:saved ~observed_provider_turn_ordinal:witness ~checkpoint:cp result in
 check "synthetic_no_witness_preserves_original_error" (complete true None (Some checkpoint) original == original);
 check "synthetic_no_same_attempt_save_preserves_original_error" (complete false (Some 31) (Some checkpoint) original == original);
 check "synthetic_no_checkpoint_preserves_original_error" (complete true (Some 31) None original == original);
 let unrelated=Error Error.Other_error in
 check "synthetic_nonempty_error_preserved" (complete true (Some 31) (Some checkpoint) unrelated == unrelated);
 (match complete true (Some 31) (Some checkpoint) original with
 |Ok r->check "synthetic_actual_witness_not_checkpoint_count" (r.turns=401 && Runtime_agent.final_provider_turn_ordinal r.stop_reason=Some 31);check "answered_zero_count_typed_witness" (run_result_answered {r with turns=0});check "input_required_positive_count_not_answered" (not(run_result_answered {r with stop_reason=InputRequired {turns_used=500;request="question"}}))
 |_->assert false)
'''
source=pre+adv+ports+ctx+rtpre+rtactual+sy+tests
(out/'probe.ml').write_text(source)
(out/'fragments.json').write_text(json.dumps(fragments,indent=2))
cmd=['ocamlc','-I','+unix','-w','+a-70-4-42-40-41-27','-o','probe.exe','unix.cma','probe.ml']
p=subprocess.run(cmd,cwd=out,text=True,capture_output=True)
result={'compile_argv':cmd,'compile_exit':p.returncode,'compile_stdout':p.stdout,'compile_stderr':p.stderr}
if p.returncode==0:
 r=subprocess.run(['./probe.exe'],cwd=out,text=True,capture_output=True);result.update(run_argv=['./probe.exe'],run_exit=r.returncode,run_stdout=r.stdout,run_stderr=r.stderr)
(out/'execution.json').write_text(json.dumps(result,indent=2));print(json.dumps(result,indent=2))

sys.exit(result.get("run_exit", result["compile_exit"]))
