
module E=Actual_evaluation
module R=Librarian_continuity_report
module L=Keeper_librarian_runtime
module S=Librarian_continuity_snapshot
module C=Keeper_librarian_input_capture
module U=Keeper_librarian_unread
module H=Keeper_librarian_task_context
module A=Agent_core.Types
let count=ref 0
let check name condition=incr count;if not condition then failwith name
let get=function Ok x->x|Error e->failwith e
let contains needle haystack=
 let rec go i=i+String.length needle<=String.length haystack &&
  (String.sub haystack i (String.length needle)=needle||go(i+1)) in go 0
let field name=function `Assoc fields->List.assoc name fields|_->failwith("object expected "^name)
let message role value:A.message={role;content=[A.Text value];name=None;tool_call_id=None;metadata=[]}
let saved_artifacts=ref []
let generation (prompt:R.prompt) text:R.generation=
 {request={runtime_id="port-answer";requested_model="port-answer-model";prompt;prepared_requests=[]};response={response_id="port-response";model="port-answer-model";text}}
let failed prompt:R.failed_generation={request=(generation prompt "").request;error="answer port refused";incomplete_response=None}
let judgment request:R.judgment={request;response_model="port-judge";request_body_sha256=String.make 64 'a';probability=0.}
let scored=function R.Scored _->true|_->false
let reset ()=
 L.calls:=[];L.request_arguments:=[];L.mode:="success";L.rendered:="ORIGINAL_PREPARED_PROMPT";L.capture_observer:=(fun()->());
 S.events:=[];S.fail:=false;S.stored:=None
let ()=
 let dataset_json=Yojson.Safe.from_file Sys.argv.(1) in
 S.selected_end_atom:=2;
 let dataset=E.parse_dataset dataset_json |> get in
 check "actual dataset parser accepts both supplied captures" (List.length dataset.cases=2);
 check "wrong provenance refused" (Result.is_error(E.parse_dataset(`Assoc["provenance",`List[`String "Private"];"cases",`List[]])));
 check "empty dataset refused" (Result.is_error(E.parse_dataset(`Assoc["provenance",`List[`String "Synthetic"];"cases",`List[]])));
 let base=List.hd dataset.cases in
 let case_json=E.case_to_yojson base in
 check "duplicate identity refused" (Result.is_error(E.parse_dataset(`Assoc["provenance",`List[`String "Synthetic"];"cases",`List[case_json;case_json]])));
 check "duplicate top-level field refused" (Result.is_error(E.parse_dataset(`Assoc["provenance",`List[`String "Synthetic"];"provenance",`List[`String "Synthetic"];"cases",`List[case_json]])));
 let pinned=message A.System "PINNED_ONLY" in
 let prefix=message A.User "PREFIX_SENTINEL" in
 let assistant:A.message={(message A.Assistant "tool pair") with content=[A.ToolUse{id="t1";name="lookup";input=`Assoc[]}]} in
 let tool:A.message={(message A.Tool "UNREAD_SECRET") with content=[A.ToolResult{tool_use_id="t1";content="UNREAD_SECRET";outcome=A.Tool_succeeded;json=None;content_blocks=None}];tool_call_id=Some "t1"} in
 let final=message A.User "PREFIX_END" in
 let history=[pinned;prefix;assistant;tool;final] in
 let trace_id="fixture-trace" in
 let source={base.source with turn_ref=Ids.Turn_ref.make ~trace_id ~absolute_turn:1;messages=history;
  historical_task_contexts=[{H.scope={source=Atom_span{trace_id;start_atom=0;end_atom=3};attribution=Unattributed};first_message=1;after_message=4;first_tool_observation=0;after_tool_observation=0}]} in
 let hole=U.for_atom ~trace_id ~history_start_boundary_line:1 ~atom:1 ~message_in_atom:1 ~messages:history ~reasons:[Keeper_librarian_input_refusal.Context_overflow] |> get in
 let suffix=[message A.User "FUTURE_SUFFIX_SENTINEL"] in
 let case:E.case={id="selection";source;previous_state=Some "OPAQUE_PREVIOUS";unread_messages=[hole];suffix;question="QUESTION_SENTINEL"} in
 S.selected_end_atom:=3;S.restored_messages:=pinned::suffix;
 let parsed=E.parse_dataset(`Assoc["provenance",`List[`String "Synthetic"];"cases",`List[E.case_to_yojson case]]) |> get in
 check "actual source codec preserves full original capture" ((List.hd parsed.cases).source.messages=history);
 let infer ~previous_state ~unread_messages input=L.infer_working_state ~base_path:"port-base" ~keepers_dir:"port-keepers" ~keeper_id:"port-keeper" ~previous_state ~unread_messages input in
 let run ?(infer=infer) ?(generate=fun prompt->Ok(generation prompt "answer")) ?(judge=fun request->Ok(judgment request)) ?(save=fun _->Ok()) case=
  E.evaluate_case ~infer ~generate ~judge ~judge_endpoint:"https://port.invalid/judge" ~judge_model:"port-judge" ~snapshot_path:"port.snapshot" ~save case in
 reset();
 let snapshots=ref [] and prompts=ref [] and refs=ref [] in
 let save progress=snapshots:= !snapshots@[progress];saved_artifacts:=E.progress_to_yojson progress::!saved_artifacts;Ok() in
 L.capture_observer:=(fun()->check "Work_started persisted before preparation/inference" (match List.rev !snapshots with {E.work=Work_started;_}::_->true|_->false));
 let result=run case ~save
  ~generate:(fun prompt->
   check "snapshot_ready persisted before answer effect" (match List.rev !snapshots with {E.snapshot=Snapshot_ready _;_}::_->true|_->false);
   prompts:= !prompts@[prompt];Ok(generation prompt "answer"))
  ~judge:(fun request->refs:=request.R.reference::!refs;
   check "answer_ready persisted before judge effect" (match List.rev !snapshots with {E.baseline=R.Answer_ready _;_}::_->true|{E.restored=R.Answer_ready _;_}::_->true|_->false);
   Ok(judgment request)) |> get in
 check "both arms retain raw zero scores" (scored result.baseline&&scored result.restored);
 check "single actual wrapper inference call" (List.length !L.calls=1);
 let selected=Option.get result.selected_source in
 check "pinned and declared hole absent from inference" (selected.messages=[prefix;assistant;final]);
 check "historical retained-message offsets adjusted" (match selected.historical_task_contexts with [{first_message=0;after_message=2;_}]->true|_->false);
 check "actual wrapper receives exactly selected source" (!L.calls=[selected]);
 check "actual wrapper passes previous state and holes unchanged" (!L.request_arguments=[case.previous_state,case.unread_messages]);
 check "same judge reference for both arms" (List.length(List.sort_uniq String.compare !refs)=1);
 check "snapshot effects ordered" (!S.events=["snapshot_capture";"snapshot_save";"snapshot_load";"snapshot_restore"]);
 let inference=match result.work with E.Work_finished value->value|_->failwith "work missing" in
 let preparation=match inference.preparation with L.Prompt_prepared p->p|_->failwith "preparation missing" in
 check "actual preparation field freezes rendered prompt" (preparation.rendered_prompt="ORIGINAL_PREPARED_PROMPT" && !L.rendered="LATE_TEMPLATE");
 check "captured resolution identity frozen" (preparation.resolution.effective="ORIGINAL_PREPARED_PROMPT" && preparation.run_id="port-run-id");
 let variables=Yojson.Safe.to_string(E.progress_to_yojson result) in
 check "persisted report retains prepared evidence" (contains "ORIGINAL_PREPARED_PROMPT" variables);
 let actual_vars=String.concat "" (List.map snd preparation.variables) in
 check "prefix reaches preparation port" (contains "PREFIX_SENTINEL" actual_vars);
 check "question/suffix not passed to inference" (not(contains case.question actual_vars)&&not(contains "FUTURE_SUFFIX_SENTINEL" actual_vars));
 check "unread contents and pinned message not passed to inference" (not(contains "UNREAD_SECRET" actual_vars)&&not(contains "PINNED_ONLY" actual_vars));
 let first=List.nth !prompts 0 and second=List.nth !prompts 1 in
 check "baseline retains full source plus suffix/prior state" (contains "PREFIX_SENTINEL" first.R.user && contains "FUTURE_SUFFIX_SENTINEL" first.user && contains "OPAQUE_PREVIOUS" first.user);
 check "restored answer uses new state and configured restored suffix" (contains "NEW_WORKING_STATE" second.R.user && contains "FUTURE_SUFFIX_SENTINEL" second.user && not(contains "PREFIX_SENTINEL" second.user));
 let old_source=Yojson.Safe.from_string first.user |> field "source" and new_source=Yojson.Safe.from_string second.user |> field "source" in
 List.iter(fun name->check("same common context "^name)(field name old_source=field name new_source)) ["current";"working_context";"keeper_instructions";"goal_context";"tool_observations";"counterpart_observations"];
 let holes=List.map(fun (atom,message_in_atom)->U.for_atom ~trace_id ~history_start_boundary_line:1 ~atom ~message_in_atom ~messages:history ~reasons:[Keeper_librarian_input_refusal.Context_overflow] |> get) [0,0;1,0;1,1;2,0] in
 reset();let all_holes=run {case with unread_messages=holes} |> get in
 check "all-hole selection can infer an empty prefix" ((Option.get all_holes.selected_source).messages=[]);
 let altered_hole={hole with U.source=(match hole.source with Atom v->Atom {v with message_sha256=String.make 64 '0'}|Official_turn _->assert false)} in
 check "mismatched unread identity rejected by actual validation" (Result.is_error(E.parse_dataset(`Assoc["provenance",`List[`String "Synthetic"];"cases",`List[E.case_to_yojson {case with unread_messages=[altered_hole]}]])));
 check "bad historical offsets refused" (Result.is_error(E.parse_dataset(`Assoc["provenance",`List[`String "Synthetic"];"cases",`List[E.case_to_yojson {case with source={source with historical_task_contexts=[{(List.hd source.historical_task_contexts) with after_message=6}]}}]])));
 List.iter(fun (name,fail_generation,fail_judge,expected_baseline,expected_restored)->
  reset();let gc=ref 0 and jc=ref 0 in
  let result=run case ~generate:(fun prompt->incr gc;if !gc=fail_generation then Error(failed prompt) else Ok(generation prompt "answer"))
   ~judge:(fun request->incr jc;if !jc=fail_judge then Error "judge port refused" else Ok(judgment request)) |> get in
  check(name^" independent baseline")(scored result.baseline=expected_baseline);
  check(name^" independent restored")(scored result.restored=expected_restored);
  check(name^" retains failure classification")
   (match fail_generation,fail_judge,result.baseline,result.restored with
    |1,_,R.Answer_failed _,_|2,_,_,R.Answer_failed _|_,1,R.Judge_failed _,_|_,2,_,R.Judge_failed _->true
    |_->false))
  ["baseline generation",1,0,false,true;"baseline judge",0,1,false,true;"restored generation",2,0,true,false;"restored judge",0,2,true,false];
 List.iter(fun mode->reset();L.mode:=mode;let gc=ref 0 in
  let result=run case ~generate:(fun p->incr gc;Ok(generation p "baseline")) |> get in
  check(mode^" preserves baseline")(scored result.baseline && result.restored=R.Not_started && !gc=1);
  check(mode^" preserves typed preparation status")(match mode,result.work with
   |"prompt_failed",Work_finished{preparation=L.Prompt_failed _;_}->true
   |"not_prepared",Work_finished{preparation=L.Not_prepared;_}->true
   |_->false)) ["prompt_failed";"not_prepared"];
 reset();S.fail:=true;let result=run case |> get in
 check "snapshot failure preserves baseline independently" (scored result.baseline && result.restored=R.Not_started && (match result.snapshot with Snapshot_failed _->true|_->false));
 List.iter(fun failed_save->reset();let saves=ref 0 and gc=ref 0 in
  let result=run case ~save:(fun _->incr saves;if !saves=failed_save then Error "durability port refused" else Ok())
   ~generate:(fun p->incr gc;Ok(generation p "answer")) in
  check(Printf.sprintf "save %d failure immediately returned" failed_save)(result=Error "durability port refused");
  check(Printf.sprintf "save %d failure fences later generation" failed_save)(!gc=0);
  if failed_save=1 then check "first save failure fences inference" (!L.calls=[]);
  if failed_save=2 then check "second save failure fences snapshot effects" (!S.events=[])) [1;2;3];
 reset();let saves=ref 0 and judges=ref 0 in
 let result=run case ~save:(fun _->incr saves;if !saves=4 then Error "answer receipt refused" else Ok())
  ~judge:(fun r->incr judges;Ok(judgment r)) in
 check "answer persistence failure fences judge" (result=Error "answer receipt refused" && !judges=0);
 reset();L.mode:="cancel";let durable=ref None in
 let cancelled=try ignore(run case ~save:(fun p->durable:=Some p;Ok()));false with L.Port_cancelled->true in
 check "cancellation propagates and retains durable Work_started" (cancelled&&(match !durable with Some{work=Work_started;_}->true|_->false));
 let output=Yojson.Safe.pretty_to_string(`Assoc["assertions",`Int !count;"saved_progress_artifacts",`List(List.rev !saved_artifacts)]) in
 Out_channel.with_open_bin Sys.argv.(2) (fun channel->output_string channel output);
 Printf.printf "%d assertions PASS\n" !count
