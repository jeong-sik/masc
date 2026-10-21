type error =
  | Execution_missing
  | Execution_ambiguous
  | Invalid_execution of string
  | Turn_mismatch of string
  | Invalid_run of string
  | Invalid_occurrence of string
  | Result_missing

let error_to_string = function
  | Execution_missing -> "No original execution is recorded for this keeper"
  | Execution_ambiguous -> "Multiple records share the original execution ID"
  | Invalid_execution detail -> "Invalid execution identity: " ^ detail
  | Turn_mismatch detail -> "Original turn identity mismatch: " ^ detail
  | Invalid_run detail -> "Invalid original raw run: " ^ detail
  | Invalid_occurrence detail -> "Invalid original tool occurrence: " ^ detail
  | Result_missing -> "No complete original tool result is retained"

let ( let* ) = Result.bind

type invocation = {
  keeper : string;
  execution_id : Ids.Execution_id.t;
  agent_name : string;
  turn_ref : Ids.Turn_ref.t;
  trace_id : string;
  absolute_turn : int;
  kind : Turn_record.turn_kind;
  tool_turn : int;
  planned_index : int;
  tool_use_id : string;
  tool : string;
}

let field fields name =
  match List.filter (fun (key, _) -> String.equal key name) fields with
  | [ _, value ] -> Ok value
  | [] -> Error (Invalid_execution ("missing " ^ name))
  | _ :: _ :: _ -> Error (Invalid_execution ("duplicate " ^ name))

let string_field fields name =
  let* value = field fields name in
  match value with
  | `String value when not (String.equal (String.trim value) "") -> Ok value
  | _ -> Error (Invalid_execution (name ^ " must be a nonblank string"))

let nonnegative_field fields name =
  let* value = field fields name in
  match value with
  | `Int value when value >= 0 -> Ok value
  | _ -> Error (Invalid_execution (name ^ " must be a nonnegative integer"))

let invocation ~keeper ~execution_id ~rows =
  let invalid detail = Error (Invalid_execution detail) in
  if not (Keeper_config.validate_name keeper) then invalid "invalid keeper"
  else
    let* row = match rows with
      | [] -> Error Execution_missing
      | [row] -> Ok row
      | _ :: _ :: _ -> Error Execution_ambiguous in
    let* fields = match row with
      | `Assoc fields -> Ok fields
      | _ -> invalid "ledger row must be an object" in
    let* recorded_keeper = string_field fields "keeper" in
    let* recorded_id = string_field fields "execution_id" in
    let* agent_name = string_field fields "agent_name" in
    let* record_kind = string_field fields "record_kind" in
    let* trace_id = string_field fields "trace_id" in
    let* session_id = string_field fields "session_id" in
    let* absolute_turn = nonnegative_field fields "keeper_turn_id" in
    let* tool_turn = nonnegative_field fields "turn" in
    let* planned_index = nonnegative_field fields "planned_index" in
    let* tool_use_id = string_field fields "tool_use_id" in
    let* tool = string_field fields "tool" in
    let* kind = string_field fields "turn_kind" in
    let* kind = match kind with
      | "direct" -> Ok Turn_record.Direct
      | "autonomous" -> Ok Turn_record.Autonomous
      | _ -> invalid "unknown turn_kind" in
    let* observation = Result.map_error (fun detail -> Invalid_execution detail)
        (Tool_observation.of_row row) in
    let* turn_ref = match observation with
      | None -> invalid "missing original Tool_observation"
      | Some observation -> Ok observation.turn_ref in
    if not (String.equal recorded_keeper keeper) then invalid "keeper differs"
    else if not (String.equal recorded_id (Ids.Execution_id.to_string execution_id))
    then invalid "execution ID differs"
    else if not (String.equal record_kind "tool_call") then invalid "not a tool call"
    else if not (String.equal session_id trace_id) then invalid "session differs"
    else if not (Ids.Turn_ref.equal turn_ref
        (Ids.Turn_ref.make ~trace_id ~absolute_turn))
    then invalid "Tool_observation turn differs"
    else Ok {keeper; execution_id; agent_name; turn_ref; trace_id; absolute_turn; kind;
      tool_turn; planned_index; tool_use_id; tool}

let turn_ref (invocation : invocation) = invocation.turn_ref

type target = { invocation : invocation; run : Turn_record.raw_trace_run_ref }
type binding = Awaiting_turn | Untraced_turn | Bound of target

let bind invocation = function
  | None -> Ok Awaiting_turn
  | Some (record : Turn_record.t) ->
    let mismatch detail = Error (Turn_mismatch detail) in
    if not (String.equal record.keeper invocation.keeper)
       || not (String.equal record.agent_name invocation.agent_name)
       || not (Ids.Turn_ref.equal record.turn_ref invocation.turn_ref)
       || not (String.equal record.trace_id invocation.trace_id)
       || record.absolute_turn <> invocation.absolute_turn
       || record.turn_kind <> invocation.kind
    then mismatch "keeper, turn, session or kind differs"
    else if List.length (List.filter (Ids.Execution_id.equal invocation.execution_id)
        record.execution_ids) <> 1
    then mismatch "execution must occur once in the original turn"
    else match record.raw_trace_run_ref with
      | None -> Ok Untraced_turn
      | Some run ->
        if not (String.equal run.session_id invocation.trace_id)
           || run.start_seq < 1 || run.end_seq < run.start_seq
           || String.equal (String.trim run.worker_run_id) ""
           || String.equal (String.trim run.agent_name) ""
        then Error (Invalid_run "invalid session or run boundaries")
        else Ok (Bound {invocation; run})

let run_ref target = target.run

type occurrence =
  | Not_started
  | Started of int
  | Finished of { start_seq : int; finish_seq : int; result : string; is_error : bool }

type scan = {
  target : target;
  previous_seq : int option;
  saw_start : bool;
  saw_end : bool;
  occurrence : occurrence;
}

let start target = {target; previous_seq=None; saw_start=false; saw_end=false;
  occurrence=Not_started}

let observe scan (record : Agent_core.Raw_trace.record) =
  let run = scan.target.run in
  let invocation = scan.target.invocation in
  let invalid detail = Error (Invalid_occurrence detail) in
  if record.seq < run.start_seq || record.seq > run.end_seq then Ok scan
  else if Option.fold ~none:false ~some:(fun previous -> record.seq <= previous)
      scan.previous_seq
  then Error (Invalid_run "repeated or out-of-order raw sequence")
  else
    let scan = {scan with previous_seq=Some record.seq} in
    if not (String.equal record.worker_run_id run.worker_run_id) then
      if record.seq = run.start_seq || record.seq = run.end_seq
      then Error (Invalid_run "run boundary belongs to another worker")
      else Ok scan
    else if record.trace_version <> Agent_core.Raw_trace.trace_version
         || not (String.equal record.agent_name run.agent_name)
         || record.session_id <> Some run.session_id
    then Error (Invalid_run "raw version, runtime agent or session differs")
    else
      let scan = {scan with
        saw_start=scan.saw_start || record.seq = run.start_seq;
        saw_end=scan.saw_end || record.seq = run.end_seq} in
      let matches = record.tool_turn = Some invocation.tool_turn
        && record.tool_planned_index = Some invocation.planned_index in
      match record.record_type with
      | Agent_core.Raw_trace.Tool_execution_started
      | Agent_core.Raw_trace.Tool_execution_finished when matches ->
        if record.tool_use_id <> Some invocation.tool_use_id
           || record.tool_name <> Some invocation.tool
        then invalid "tool identity differs at the original invocation coordinates"
        else
          (match record.record_type, scan.occurrence with
           | Agent_core.Raw_trace.Tool_execution_started, Not_started ->
               Ok {scan with occurrence=Started record.seq}
           | Agent_core.Raw_trace.Tool_execution_finished, Started start_seq ->
               (match record.tool_result, record.tool_error with
                | Some result, Some is_error ->
                    Ok {scan with occurrence=Finished {start_seq;
                      finish_seq=record.seq;result;is_error}}
                | None, (Some _ | None) | Some _, None -> Error Result_missing)
           | Agent_core.Raw_trace.Tool_execution_started, (Started _ | Finished _)
           | Agent_core.Raw_trace.Tool_execution_finished, (Not_started | Finished _) ->
               invalid "duplicate or unpaired start/finish"
           | (Agent_core.Raw_trace.Run_started | Assistant_block | Native_tool_started
             | Native_tool_finished | Hook_invoked | Run_finished),
             (Not_started | Started _ | Finished _) ->
               invalid "not a tool start/finish")
      | Agent_core.Raw_trace.Tool_execution_started
      | Agent_core.Raw_trace.Tool_execution_finished
      | Run_started | Assistant_block | Native_tool_started | Native_tool_finished
      | Hook_invoked | Run_finished -> Ok scan

type body = {
  execution_id : Ids.Execution_id.t;
  turn_ref : Ids.Turn_ref.t;
  start_seq : int;
  finish_seq : int;
  recorded_bytes : int;
  content : string;
  is_error : bool;
}

let full_redaction result =
  match Yojson.Safe.from_string result with
  | json -> Yojson.Safe.to_string (Observability_redact.redact_json_value json)
  | exception Yojson.Json_error _ -> Observability_redact.redact_text result

let finish scan =
  if not scan.saw_start || not scan.saw_end
  then Error (Invalid_run "raw stream does not cover both recorded run boundaries")
  else match scan.occurrence with
    | Not_started | Started _ -> Error Result_missing
    | Finished occurrence ->
      let invocation = scan.target.invocation in
      Ok {execution_id=invocation.execution_id;turn_ref=invocation.turn_ref;
        start_seq=occurrence.start_seq;finish_seq=occurrence.finish_seq;
        recorded_bytes=String.length occurrence.result;
        content=full_redaction occurrence.result;is_error=occurrence.is_error}
