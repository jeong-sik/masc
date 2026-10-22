module Capture = Keeper_librarian_admission_capture
module Owner = Lane_addon_tool_request_owner
module Progress = Lane_addon_request_progress
module Exact = Lane_addon_exact
module Runtime = Lane_addon_runtime
let ( let* ) = Result.bind

type error = Unavailable of string | Rejected of string | Uncertain of string
let error_to_string = function
  | Unavailable detail | Rejected detail | Uncertain detail -> detail

type wait = Capacity | Worker_pending | Worker_unknown | Missing_after_dispatch
  | Journal_recheck
type result =
  | Pending of wait * Owner.retained
  | Answered of Exact.final * Owner.retained
  | Refused of Exact.final * Owner.retained
  | Commit_pending of Owner.retained
  | Settled of Owner.retained

type call = expected:Capture.destination -> original:Owner.retained ->
  arguments:Yojson.Safe.t -> (Mcp_protocol.Mcp_types.tool_result, error) Stdlib.result

let rejected value = Result.map_error (fun detail -> Rejected detail) value
let runtime_error = function
  | Runtime.Unavailable detail -> Unavailable detail
  | Runtime.Outcome_unknown detail -> Uncertain detail
  | Runtime.Host_refusal refusal ->
    (match refusal with
     | Lane_addon_call_context.Rejected detail | Activity_disabled detail -> Rejected detail
     | Unavailable detail | Activity_unobserved detail -> Unavailable detail)

let check_identity ~(destination : Capture.destination) (original : Owner.retained)
    (exact : Exact.request) =
  if original.request_id = exact.request_id
     && original.installation_id = destination.installation_id
     && original.package_id = destination.package_id && original.tool = destination.tool
  then
    let* installation = rejected (Owner.installation_of_id original.installation_id) in
    match installation with
    | Owner.Configuration declaration_id -> Ok declaration_id
    | Owner.Manual _ -> Error (Rejected "Original admission requires its configured installation")
  else Error (Rejected "Original admission destination or Exact request identity differs")

let confirm_destination ~config ~reserved ~(destination : Capture.destination) =
  let snapshot = Runtime.tool_export_snapshot ~config
    ~access:Lane_addon_sources.Operator_configuration ~reserved in
  let* () =
    match List.find_opt
      (fun (conflict : Lane_addon_tool_export.conflict) -> conflict.name = destination.tool)
      snapshot.conflicts with
    | Some conflict -> Error (Rejected (Lane_addon_tool_export.conflict_to_string conflict))
    | None -> Ok () in
  let* export =
    match List.find_opt
      (fun (export : Runtime.tool_export) -> export.tool.name = destination.tool)
      snapshot.exports with
    | Some export -> Ok export
    | None -> Error (Unavailable "Original admission Add-on export is unavailable") in
  Runtime.with_tool_request_destination ~config
    ~access:Lane_addon_sources.Operator_configuration ~reserved ~export
    ~publish:(fun (actual : Runtime.tool_request_destination) ->
      if actual.installation_id = destination.installation_id
         && actual.package_id = destination.package_id && actual.tool = destination.tool
         && actual.configuration_revision = destination.configuration_revision
      then Ok ()
      else Error (Runtime.Host_refusal (Lane_addon_call_context.Rejected
        "Fresh admission destination differs from its original semantic configuration")))
  |> Result.map_error runtime_error

type worker_state = Absent | Waiting | Capacity_wait | Finished of Exact.final
let decode_reply ~request_id ~schema (response : Mcp_protocol.Mcp_types.tool_result) =
  let context = "Admission Add-on reply" in
  let* () = match response.is_error with
    | Some true -> Error (Unavailable (Agent_core.Mcp.text_of_tool_result response))
    | None | Some false -> Ok () in
  let* json = match response.structured_content with
    | Some json -> Ok json
    | None -> Error (Rejected "Admission reply has no structured content") in
  let parse () =
    let* fields = Candle_json.object_fields ~context json in
    let* id, fields = Candle_json.field ~context "request_id" Candle_json.as_non_blank fields in
    let* () = if id = request_id then Ok ()
      else Error "Admission reply belongs to another original request" in
    let* state, fields = Candle_json.field ~context "state" Candle_json.as_string fields in
    let* state, fields = match state with
      | "absent" -> Ok (Absent, fields)
      | "pending" -> Ok (Waiting, fields)
      | "capacity_wait" -> Ok (Capacity_wait, fields)
      | "finished" ->
        let* final, fields = Candle_json.field ~context "result"
          (Exact.final_of_json ~schema) fields in
        Ok (Finished final, fields)
      | _ -> Error "Unknown admission worker state" in
    let* () = Candle_json.finish ~context fields in
    Ok (state, json) in
  rejected (parse ())

type publication = New of Owner.retained | Acknowledged of Owner.retained
let publish ~store original event =
  Eio_unix.run_in_systhread (fun () ->
    match Owner.advance ~store ~expected:original ~event with
    | Ok (Owner.Stored record) -> Ok (New record)
    | Ok (Owner.Already_stored record) -> Ok (Acknowledged record)
    | Ok (Owner.Unconfirmed detail) -> Error (Uncertain detail)
    | Error error -> Error (Unavailable (Owner.update_error_to_string error)))
let published_record = function New record | Acknowledged record -> record

let same_observation left right = match left, right with
  | Progress.Waiting left, Progress.Waiting right
  | Progress.Outcome_unknown left, Progress.Outcome_unknown right
  | Progress.Absent left, Progress.Absent right -> Yojson.Safe.equal left right
  | Progress.Waiting _, (Progress.Outcome_unknown _ | Progress.Absent _)
  | Progress.Outcome_unknown _, (Progress.Waiting _ | Progress.Absent _)
  | Progress.Absent _, (Progress.Waiting _ | Progress.Outcome_unknown _) -> false

let resume ~store ~config ~reserved ~destination ~(original : Owner.retained)
    ~exact ~schema ~validate_answer ~(call : call) =
  let* declaration_id = check_identity ~destination original exact in
  let terminal original final = match final with
    | Exact.Call_final (Exact.Answered {output; _}) ->
      let* () = rejected (validate_answer (Exact.checked_json output)) in
      Ok (Answered (final, original))
    | Exact.Call_final (Exact.Invalid_output _ | Exact.Input_refused _ | Exact.Output_limit_reached _)
    | Exact.Outcome_unknown | Exact.Not_allowed _ | Exact.Request_id_reused ->
      Ok (Refused (final, original)) in
  let observe (original : Owner.retained) reason observation evidence =
    let observation = observation evidence in
    match Progress.phase original.progress with
    | Progress.Dispatch_pending (Some previous) when same_observation previous observation ->
      Ok (Pending (reason, original))
    | Progress.Captured | Progress.Admission_wait _ | Progress.Dispatch_pending (None | Some _)
    | Progress.Judged _ | Progress.Committing _ | Progress.Commit_unknown _ | Progress.Finished _
    | Progress.Conflicted _ | Progress.Rejected _ | Progress.Subdividing _ | Progress.Subdivided _ ->
      let* published = publish ~store original (Progress.Execution_observed observation) in
      Ok (Pending (reason, published_record published)) in
  let finish original final =
    let* _ = terminal original final in
    let event = match final with
      | Exact.Call_final (Exact.Answered _) -> Progress.Judgment_retained (Exact.final_to_json final)
      | Exact.Call_final (Exact.Invalid_output _ | Exact.Input_refused _ | Exact.Output_limit_reached _)
      | Exact.Outcome_unknown | Exact.Not_allowed _ | Exact.Request_id_reused ->
        Progress.Refused {stage = Progress.Execution; evidence = Exact.final_to_json final} in
    let* published = publish ~store original event in
    terminal (published_record published) final in
  let received original ~submission state evidence = match state with
    | Waiting -> observe original Worker_pending (fun value -> Progress.Waiting value) evidence
    | Absent -> observe original Missing_after_dispatch (fun value -> Progress.Absent value) evidence
    | Capacity_wait ->
      if submission then
        let* published = publish ~store original (Progress.Admission_declined evidence) in
        Ok (Pending (Capacity, published_record published))
      else Error (Rejected "A worker read cannot grant a pre-admission capacity refusal")
    | Finished final -> finish original final in
  let invoke (original : Owner.retained) arguments =
    let* () = confirm_destination ~config ~reserved ~destination in
    let* response = call ~expected:destination ~original ~arguments in
    decode_reply ~request_id:original.request_id ~schema response in
  let read = `Assoc ["kind", `String "read"; "request_id", `String original.request_id] in
  let admit original =
    let* published = publish ~store original Progress.Dispatch_intended in
    match published with
    | Acknowledged record -> Ok (Pending (Journal_recheck, record))
    | New original ->
      let submit = `Assoc ["kind", `String "submit"; "request", Exact.request_to_json exact] in
      (match invoke original submit with
       | Ok (state, evidence) -> received original ~submission:true state evidence
       | Error error ->
         (* A missing or malformed reply can follow durable admission. Keep
            the original intent; no later absence grants another submit. *)
         observe original Worker_unknown (fun value -> Progress.Outcome_unknown value)
           (`Assoc ["detail", `String (error_to_string error)])) in
  match Progress.phase original.progress with
  | Progress.Judged judgment ->
    let* final = rejected (Exact.final_of_json ~schema judgment) in
    (match final with
     | Exact.Call_final (Exact.Answered _) -> terminal original final
     | Exact.Call_final (Exact.Invalid_output _ | Exact.Input_refused _ | Exact.Output_limit_reached _)
     | Exact.Outcome_unknown | Exact.Not_allowed _ | Exact.Request_id_reused ->
       Error (Rejected "Original admission judgment does not contain an answered result"))
  | Progress.Committing _ | Progress.Commit_unknown _ -> Ok (Commit_pending original)
  | Progress.Rejected {stage = Progress.Execution; evidence}
  | Progress.Subdividing ({stage = Progress.Execution; evidence}, _)
  | Progress.Subdivided ({stage = Progress.Execution; evidence}, _) ->
    let* final = rejected (Exact.final_of_json ~schema evidence) in
    (match final with
     | Exact.Call_final (Exact.Answered _) ->
       Error (Rejected "Refused original admission cannot contain an answered judgment")
     | Exact.Call_final (Exact.Invalid_output _ | Exact.Input_refused _ | Exact.Output_limit_reached _)
     | Exact.Outcome_unknown | Exact.Not_allowed _ | Exact.Request_id_reused -> terminal original final)
  | Progress.Finished _ | Progress.Conflicted _ | Progress.Rejected {stage = Progress.Before_dispatch; _}
  | Progress.Subdividing ({stage = Progress.Before_dispatch; _}, _)
  | Progress.Subdivided ({stage = Progress.Before_dispatch; _}, _) -> Ok (Settled original)
  | Progress.Captured | Progress.Admission_wait _ ->
    let* state, _evidence = invoke original read in
    (match state with
     | Absent -> admit original
     | Waiting | Capacity_wait | Finished _ ->
       Error (Rejected "Worker state contradicts original pre-admission progress"))
  | Progress.Dispatch_pending _ ->
    let* retained = Eio_unix.run_in_systhread (fun () ->
      Exact.observe_retained ~store ~declaration_id ~schema exact)
      |> Result.map_error (fun detail -> Unavailable detail) in
    (match retained with
     | Exact.Retained_terminal final -> finish original final
     | Exact.Retained_absent | Exact.Retained_open ->
       match invoke original read with
       | Ok (state, evidence) -> received original ~submission:false state evidence
       | Error error ->
         observe original Worker_unknown (fun value -> Progress.Outcome_unknown value)
           (`Assoc ["detail", `String (error_to_string error)]))
