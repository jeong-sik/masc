module R = Librarian_continuity_report
module S = Librarian_continuity_snapshot
module L = Keeper_librarian_runtime
module C = Keeper_librarian_input_capture
module B = Keeper_turn_boundaries
module U = Keeper_librarian_unread

type case =
  { id : string
  ; source : Keeper_librarian.input
  ; previous_state : string option
  ; unread_messages : U.t list
  ; suffix : Agent_core.Types.message list
  ; question : string
  }
type dataset = { provenance : R.provenance; cases : case list }
type work = Work_not_started | Work_started | Work_finished of L.working_state_inference
type snapshot = Snapshot_not_started | Snapshot_failed of string | Snapshot_ready of S.t
type progress =
  { work : work; selected_source : Keeper_librarian.input option
  ; snapshot : snapshot; baseline : R.progress; restored : R.progress }

open Result.Syntax
let initial_progress = {work=Work_not_started; selected_source=None; snapshot=Snapshot_not_started;
  baseline=R.Not_started; restored=R.Not_started}
let optional encode = Option.fold ~none:`Null ~some:encode
let text value = `String value
let variables values = `List (List.map (fun (key,value) ->
  `Assoc ["name",text key; "value",text value]) values)
let messages values = `List (List.map C.message_json values)
let case_to_yojson (case : case) =
  `Assoc ["id",text case.id; "source",C.to_json case.source;
    "previous_state",optional text case.previous_state;
    "unread_messages",U.list_to_json case.unread_messages;
    "suffix",messages case.suffix; "question",text case.question]

let preparation_json = function
  | L.Not_prepared -> `Assoc ["status",text "not_prepared"]
  | L.Prompt_failed {run_id;variables=values;detail} ->
    `Assoc ["status",text "failed";"run_id",text run_id;
      "variables",variables values;"detail",text detail]
  | L.Prompt_prepared prepared ->
    let resolution = prepared.resolution in
    `Assoc ["status",text "prepared";"run_id",text prepared.run_id;
      "evidence_scope",text "base_prompt_preparation";
      "source",text (Prompt_registry.prompt_source_to_string resolution.source);
      "effective_template",text resolution.effective;
      "file_value",optional text resolution.file_value;
      "override_value",optional text resolution.override_value;
      "file_path",optional text resolution.file_path;
      "file_exists",`Bool resolution.file_exists;"has_override",`Bool resolution.has_override;
      "variables",variables prepared.variables;"rendered_prompt",text prepared.rendered_prompt;
      "rendered_sha256",text Agent_core_sha256.(to_hex (digest_string prepared.rendered_prompt));
      "output_schema",prepared.output_schema]
let refusals values = `List (List.map (fun value -> text (Keeper_librarian_input_refusal.to_string value)) values)
let report_json (report : L.not_committed) =
  `Assoc ["detail",text report.detail;"walk_shows_size",`Bool report.walk_shows_size;
    "smaller_range_meets_same_failure",`Bool report.smaller_range_meets_same_failure;
    "message_descent",text (match report.message_descent with
      | L.No_descent_evidence -> "no_descent_evidence"
      | L.Smaller_input_may_help -> "smaller_input_may_help"
      | L.Invalid_output_blocks_descent -> "invalid_output_blocks_descent"
      | L.Unsettled_native_blocks_descent -> "unsettled_native_blocks_descent");
    "input_capacity_evidence",text (match report.input_capacity_evidence with
      | L.No_input_capacity_refusal -> "no_input_capacity_refusal"
      | L.Input_capacity_refused -> "input_capacity_refused");
    "provider_input_refusals",refusals report.provider_input_refusals]
let inference_json (inference : L.working_state_inference) =
  let outcome = match inference.outcome with
    | L.Inferred {working_state;served_by} ->
      `Assoc ["status",text "inferred";"working_state",text working_state;
        "served_by",`Assoc ["transport",text (match served_by with
          | L.Api_slot _ -> "api" | L.Cli_slot _ -> "cli");
          "slot_id",text (L.served_slot_id served_by)]]
    | L.Not_inferred failure ->
      `Assoc ["status",text "not_inferred";
        "reports",`List (List.map report_json failure.reports);
        "exhausted_input_refusals",optional refusals failure.exhausted_input_refusals] in
  `Assoc ["preparation",preparation_json inference.preparation;"outcome",outcome]
let progress_to_yojson progress =
  let work = match progress.work with
    | Work_not_started -> `Assoc ["status",text "not_started"]
    | Work_started -> `Assoc ["status",text "started"]
    | Work_finished inference -> `Assoc ["status",text "finished";"inference",inference_json inference] in
  let snapshot = match progress.snapshot with
    | Snapshot_not_started -> `Assoc ["status",text "not_started"]
    | Snapshot_failed detail -> `Assoc ["status",text "failed";"detail",text detail]
    | Snapshot_ready value -> `Assoc ["status",text "ready";"artifact",S.to_json value] in
  `Assoc ["work",work;"selected_source",optional C.to_json progress.selected_source;
    "snapshot",snapshot;"boundary_provenance",text "synthetic_fresh_history";
    "baseline",R.progress_to_yojson progress.baseline;"restored",R.progress_to_yojson progress.restored]

let fields keys = function
  | `Assoc fields when List.sort String.compare (List.map fst fields)=List.sort String.compare keys -> Ok fields
  | `Assoc _ | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ ->
    Error "Unexpected, duplicate, missing or non-object production evaluation fields"
let nonblank = function
  | `String value when String.trim value<>"" -> Ok value
  | `String _ | `Assoc _ | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `List _ ->
    Error "Expected nonblank production evaluation text"
let array parse = function
  | `List values -> List.fold_right (fun value result ->
      let* value=parse value in let* rest=result in Ok (value::rest)) values (Ok [])
  | `Assoc _ | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ -> Error "Expected array"
let boundary_lines (case : case) =
  let* position=B.position_of_messages case.source.messages in
  Ok [1,Ok {B.recorded_at=0.; event=B.Turn_ended
    {task_context=Keeper_turn_task_context.No_task;turn_ref=case.source.turn_ref;
      history_at_start=B.Fresh_history;position}}]

let select_source (case : case) =
  let source=case.source in
  let* lines=boundary_lines case in
  let trace_id=Ids.Turn_ref.trace_id source.turn_ref in
  let* range=S.checkpoint_prefix_range ~trace_id ~lines ~messages:source.messages
    |> Result.map_error S.error_to_string in
  let* ()=U.validate_atom_history ~trace_id ~history_start_boundary_line:range.history_start_boundary_line
    ~end_atom:range.end_atom ~messages:source.messages case.unread_messages in
  let* identities=U.sources_for_atom_range ~trace_id
    ~history_start_boundary_line:range.history_start_boundary_line ~start_atom:0
    ~end_atom:range.end_atom ~messages:source.messages in
  let labelled,_=Runtime_model_input_tail_window.annotate source.messages in
  let offsets=Array.make (List.length source.messages+1) 0 in
  let rec select index kept identities = function
    | [] -> (match identities with [] -> Ok (List.rev kept)
        | _::_ -> Error "Source identity list exceeds the selected checkpoint")
    | (message,label)::rest ->
      let* keep,identities=match label,identities with
        | Runtime_model_input_tail_window.Pinned,_ -> Ok (false,identities)
        | Runtime_model_input_tail_window.Atom _,identity::identities ->
          Ok (not (List.exists (fun (hole : U.t) -> hole.source=identity) case.unread_messages),identities)
        | Runtime_model_input_tail_window.Atom _,[] -> Error "Checkpoint message has no source identity" in
      offsets.(index+1)<-offsets.(index)+(if keep then 1 else 0);
      select (index+1) (if keep then message::kept else kept) identities rest in
  let* messages=select 0 [] identities labelled in
  let tool_count=List.length source.tool_observations in
  let* historical_task_contexts=List.fold_right (fun (context : Keeper_librarian_task_context.t) result ->
    let* rest=result in
    if context.first_message<0 || context.first_message>context.after_message
      || context.after_message>=Array.length offsets
      || context.first_tool_observation<0 || context.first_tool_observation>context.after_tool_observation
      || context.after_tool_observation>tool_count
    then Error "Historical task context exceeds its captured input"
    else Ok ({context with first_message=offsets.(context.first_message);
      after_message=offsets.(context.after_message)}::rest)) source.historical_task_contexts (Ok []) in
  Ok {source with messages;historical_task_contexts}
let parse_case json =
  let* f=fields ["id";"source";"previous_state";"unread_messages";"suffix";"question"] json in
  let* id=nonblank (List.assoc "id" f) in
  let* source=C.of_json (List.assoc "source" f) in
  let* question=nonblank (List.assoc "question" f) in
  let* previous_state=match List.assoc "previous_state" f with
    | `Null -> Ok None
    | (`Assoc _ | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _) as json ->
      Result.map Option.some (nonblank json) in
  let* unread_messages=U.list_of_json (List.assoc "unread_messages" f) in
  let* suffix=array C.message_of_json (List.assoc "suffix" f) in
  let case={id;source;previous_state;unread_messages;suffix;question} in
  let* ()=if source.messages=[] then Error "Source prefix must be nonempty" else Ok () in
  let* _=select_source case in
  Ok case
let parse_dataset json =
  let* f=fields ["provenance";"cases"] json in
  let* provenance=R.provenance_of_yojson (List.assoc "provenance" f) in
  let* cases=array parse_case (List.assoc "cases" f) in
  let ids=List.map (fun (case : case) -> case.id) cases in
  if cases=[] || List.length ids<>List.length (List.sort_uniq String.compare ids)
  then Error "Cases must be nonempty with unique identities"
  else Ok {provenance;cases}

let answer_prompt ~question ~state ~unread_messages source : R.prompt =
  { system="Answer the question using only the supplied Keeper context. Explicit unread holes are not evidence of their missing contents. State what the context does not establish."
  ; user=Yojson.Safe.to_string (`Assoc ["source",C.to_json source;
      "working_state",optional text state;"unread_messages",U.list_to_json unread_messages;
      "question",text question]) }

let evaluate_case ~infer ~generate ~judge ~judge_endpoint ~judge_model ~snapshot_path ~save (case : case) =
  let persist progress=let* ()=save progress in Ok progress in
  let* source=select_source case in
  let* progress=persist {initial_progress with work=Work_started;selected_source=Some source} in
  let inference=infer ~previous_state:case.previous_state ~unread_messages:case.unread_messages source in
  let* progress=persist {progress with work=Work_finished inference} in
  let trace_id=Ids.Turn_ref.trace_id case.source.turn_ref in
  let all_messages=case.source.messages @ case.suffix in
  let restored_input=match inference.outcome with
    | L.Not_inferred _ -> None
    | L.Inferred {working_state;served_by=_} ->
      Some (let* lines=boundary_lines case in
        let* snapshot=S.capture ~unread_messages:case.unread_messages ~trace_id ~lines
          ~messages:case.source.messages ~working_state |> Result.map_error S.error_to_string in
        let* ()=S.save ~path:snapshot_path snapshot |> Result.map_error S.error_to_string in
        let* loaded=S.load ~path:snapshot_path |> Result.map_error S.error_to_string in
        let* restored=S.restore ~trace_id ~lines ~messages:all_messages loaded
          |> Result.map_error S.error_to_string in
        Ok (loaded,restored)) in
  let* progress=match restored_input with
    | None -> Ok progress
    | Some (Error detail) -> persist {progress with snapshot=Snapshot_failed detail}
    | Some (Ok (snapshot,_)) -> persist {progress with snapshot=Snapshot_ready snapshot} in
  let baseline={case.source with messages=all_messages} in
  let reference=Yojson.Safe.to_string (`Assoc ["source",C.to_json baseline;
    "previous_state",optional text case.previous_state;
    "unread_messages",U.list_to_json case.unread_messages]) in
  let run_arm progress update prompt =
    let question=R.Provided case.question in
    match generate prompt with
    | Error failure -> persist (update progress (R.Answer_failed (question,failure)))
    | Ok answer ->
      let* progress=persist (update progress (R.Answer_ready {question;answer})) in
      let request=R.judge_request_for ~endpoint:judge_endpoint ~model:judge_model
        ~question_id:case.id ~reference ~question:case.question ~answer:answer.response.text in
      let result=match judge request with
        | Ok judgment -> R.Scored {question;answer;judgment}
        | Error error -> R.Judge_failed {question;answer;failure={request;error}} in
      persist (update progress result) in
  let* progress=run_arm progress (fun p baseline -> {p with baseline})
    (answer_prompt ~question:case.question ~state:case.previous_state
      ~unread_messages:case.unread_messages baseline) in
  match restored_input with
  | None | Some (Error _) -> Ok progress
  | Some (Ok (_,restored)) ->
    let source={case.source with messages=restored.messages;
      historical_task_contexts=[]} in
    run_arm progress (fun p restored -> {p with restored})
      (answer_prompt ~question:case.question ~state:(Some restored.working_state)
        ~unread_messages:restored.unread_messages source)
